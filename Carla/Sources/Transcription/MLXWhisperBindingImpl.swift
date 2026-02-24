import Foundation

/// Request envelope used by concrete MLX runtime adapters.
struct MLXRuntimeTranscriptionRequest: Sendable {
  let audioFileURL: URL
  let modelID: String
  let languageCode: String?
}

/// Runtime-neutral segment emitted by concrete MLX runtime adapters.
struct MLXRuntimeSegment: Sendable, Equatable {
  let startSeconds: Double
  let endSeconds: Double
  let text: String
  let confidence: Float?
}

/// Runtime-neutral transcription emitted by concrete MLX runtime adapters.
struct MLXRuntimeTranscription: Sendable, Equatable {
  let detectedLanguageCode: String?
  let segments: [MLXRuntimeSegment]
}

/// Protocol for concrete MLX runtime adapters.
protocol MLXWhisperRuntime: Sendable {
  func transcribe(_ request: MLXRuntimeTranscriptionRequest) async throws -> MLXRuntimeTranscription
}

/// Python-backed runtime adapter that executes mlx-whisper inference.
struct MLXPythonWhisperRuntime: MLXWhisperRuntime {
  private struct RuntimeOutput: Decodable {
    struct Segment: Decodable {
      let start: Double?
      let end: Double?
      let text: String?
      let confidence: Double?
      let avgLogprob: Double?

      enum CodingKeys: String, CodingKey {
        case start
        case end
        case text
        case confidence
        case avgLogprob = "avg_logprob"
      }
    }

    let language: String?
    let segments: [Segment]?
  }

  func transcribe(_ request: MLXRuntimeTranscriptionRequest) async throws -> MLXRuntimeTranscription {
    let script = #"""
import json
import sys

try:
  import mlx_whisper
except Exception as exc:
  print(str(exc), file=sys.stderr)
  sys.exit(90)

audio_path = sys.argv[1]
model_id = sys.argv[2]
language = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else None

try:
  result = mlx_whisper.transcribe(
    audio=audio_path,
    path_or_hf_repo=model_id,
    language=language
  )
except Exception as exc:
  print(str(exc), file=sys.stderr)
  sys.exit(2)

segments = []
for seg in result.get("segments", []) or []:
  confidence = seg.get("confidence")
  if confidence is None:
    avg = seg.get("avg_logprob")
    if avg is not None:
      try:
        confidence = float(__import__("math").exp(avg))
      except Exception:
        confidence = None

  segments.append({
    "start": seg.get("start"),
    "end": seg.get("end"),
    "text": seg.get("text", ""),
    "confidence": confidence,
    "avg_logprob": seg.get("avg_logprob")
  })

print(json.dumps({
  "language": result.get("language"),
  "segments": segments
}))
"""#

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")

    let language = request.languageCode ?? ""
    process.arguments = ["python3", "-c", script, request.audioFileURL.path, request.modelID, language]

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      throw MLXWhisperLibraryError.runtimeFailure("failed to start mlx python runtime: \(error.localizedDescription)")
    }

    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    let stdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    guard process.terminationStatus == 0 else {
      if process.terminationStatus == 90 {
        throw MLXWhisperLibraryError.runtimeFailure("mlx_whisper python package is unavailable")
      }
      let message = stderr.isEmpty ? stdout : stderr
      throw MLXWhisperLibraryError.libraryFailure(code: Int(process.terminationStatus), message: message)
    }

    guard let json = stdout.data(using: .utf8) else {
      throw MLXWhisperLibraryError.decodeFailure("mlx runtime returned non-utf8 output")
    }

    let decoded: RuntimeOutput
    do {
      decoded = try JSONDecoder().decode(RuntimeOutput.self, from: json)
    } catch {
      throw MLXWhisperLibraryError.decodeFailure("mlx runtime returned invalid transcription payload")
    }

    let segments = (decoded.segments ?? []).map { raw in
      MLXRuntimeSegment(
        startSeconds: raw.start ?? 0,
        endSeconds: raw.end ?? 0,
        text: raw.text ?? "",
        confidence: raw.confidence.map(Float.init)
      )
    }

    return MLXRuntimeTranscription(detectedLanguageCode: decoded.language, segments: segments)
  }
}

/// Production MLX binding used by app runtime wiring.
public actor MLXWhisperBindingImpl: MLXWhisperBinding {
  private let modelManager: MLXModelManager
  private let runtime: any MLXWhisperRuntime

  public init(modelManager: MLXModelManager = MLXModelManager()) {
    self.modelManager = modelManager
    runtime = MLXPythonWhisperRuntime()
  }

  init(
    modelManager: MLXModelManager,
    runtime: any MLXWhisperRuntime
  ) {
    self.modelManager = modelManager
    self.runtime = runtime
  }

  public func transcribePCM(
    samples: [Float],
    sampleRate: Double,
    modelID: String,
    languageCode: String?
  ) async throws -> MLXTranscriptionPayload {
    guard !samples.isEmpty else {
      throw MLXWhisperLibraryError.invalidAudio("pcm samples are empty")
    }

    guard sampleRate.isFinite, sampleRate > 0 else {
      throw MLXWhisperLibraryError.invalidAudio("invalid sample rate \(sampleRate)")
    }

    let canonicalModelID = MLXModelCatalog.resolveModelID(fromSettingsValue: modelID)
    try await ensureModelReady(canonicalModelID)

    let wavURL = try writeTemporaryPCMAsWAV(samples: samples, sampleRate: sampleRate)
    defer { try? FileManager.default.removeItem(at: wavURL) }

    do {
      let runtimePayload = try await runtime.transcribe(
        MLXRuntimeTranscriptionRequest(
          audioFileURL: wavURL,
          modelID: canonicalModelID,
          languageCode: languageCode
        )
      )
      return Self.toEnginePayload(runtimePayload)
    } catch {
      throw Self.mapRuntimeError(error, modelID: canonicalModelID, languageCode: languageCode)
    }
  }

  public func transcribeFile(
    fileURL: URL,
    modelID: String,
    languageCode: String?
  ) async throws -> MLXTranscriptionPayload {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      throw MLXWhisperLibraryError.decodeFailure("audio file missing at \(fileURL.path)")
    }

    let canonicalModelID = MLXModelCatalog.resolveModelID(fromSettingsValue: modelID)
    try await ensureModelReady(canonicalModelID)

    do {
      let runtimePayload = try await runtime.transcribe(
        MLXRuntimeTranscriptionRequest(
          audioFileURL: fileURL,
          modelID: canonicalModelID,
          languageCode: languageCode
        )
      )
      return Self.toEnginePayload(runtimePayload)
    } catch {
      throw Self.mapRuntimeError(error, modelID: canonicalModelID, languageCode: languageCode)
    }
  }

  private func ensureModelReady(_ canonicalModelID: String) async throws {
    let ready = await modelManager.validateModelID(canonicalModelID)
    guard ready else {
      throw MLXWhisperLibraryError.modelNotFound(canonicalModelID)
    }
  }

  private func writeTemporaryPCMAsWAV(samples: [Float], sampleRate: Double) throws -> URL {
    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("carla-mlx-pcm-\(UUID().uuidString)")
      .appendingPathExtension("wav")

    let pcm16 = samples.map { sample -> Int16 in
      let clamped = max(-1.0, min(1.0, sample))
      return Int16(clamped * Float(Int16.max))
    }

    let channels: UInt16 = 1
    let bitsPerSample: UInt16 = 16
    let bytesPerSample = Int(bitsPerSample / 8)
    let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bytesPerSample)
    let blockAlign = channels * UInt16(bytesPerSample)
    let dataSize = UInt32(pcm16.count * bytesPerSample)
    let riffChunkSize = UInt32(36) + dataSize

    var data = Data()
    data.append("RIFF".data(using: .ascii)!)
    data.append(contentsOf: withUnsafeBytes(of: riffChunkSize.littleEndian, Array.init))
    data.append("WAVE".data(using: .ascii)!)
    data.append("fmt ".data(using: .ascii)!)

    let fmtChunkSize: UInt32 = 16
    let audioFormat: UInt16 = 1
    data.append(contentsOf: withUnsafeBytes(of: fmtChunkSize.littleEndian, Array.init))
    data.append(contentsOf: withUnsafeBytes(of: audioFormat.littleEndian, Array.init))
    data.append(contentsOf: withUnsafeBytes(of: channels.littleEndian, Array.init))
    data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian, Array.init))
    data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian, Array.init))
    data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian, Array.init))
    data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian, Array.init))

    data.append("data".data(using: .ascii)!)
    data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian, Array.init))

    for sample in pcm16 {
      data.append(contentsOf: withUnsafeBytes(of: sample.littleEndian, Array.init))
    }

    do {
      try data.write(to: tempURL, options: .atomic)
      return tempURL
    } catch {
      throw MLXWhisperLibraryError.invalidAudio("failed to materialize pcm buffer as wav")
    }
  }

  private static func toEnginePayload(_ payload: MLXRuntimeTranscription) -> MLXTranscriptionPayload {
    let segments = payload.segments.map { segment in
      MLXSegmentPayload(
        startMs: Int((segment.startSeconds * 1000.0).rounded()),
        endMs: Int((segment.endSeconds * 1000.0).rounded()),
        text: segment.text,
        confidence: segment.confidence
      )
    }

    return MLXTranscriptionPayload(
      segments: segments,
      detectedLanguageCode: payload.detectedLanguageCode
    )
  }

  private static func mapRuntimeError(
    _ error: Error,
    modelID: String,
    languageCode: String?
  ) -> MLXWhisperLibraryError {
    if let known = error as? MLXWhisperLibraryError {
      if case .libraryFailure(_, let message) = known {
        return mapLibraryFailureMessage(message, modelID: modelID, languageCode: languageCode) ?? known
      }
      return known
    }

    let message = (error as NSError).localizedDescription
    return mapLibraryFailureMessage(message, modelID: modelID, languageCode: languageCode)
      ?? MLXWhisperLibraryError.runtimeFailure(message)
  }

  private static func mapLibraryFailureMessage(
    _ message: String,
    modelID: String,
    languageCode: String?
  ) -> MLXWhisperLibraryError? {
    let normalized = message.lowercased()

    if normalized.contains("unsupported") && normalized.contains("language") {
      return .unsupportedLanguage(languageCode ?? "unknown")
    }

    if normalized.contains("model") && (normalized.contains("not found") || normalized.contains("missing")) {
      return .modelNotLoaded(modelID)
    }

    if normalized.contains("audio") && (
      normalized.contains("decode") || normalized.contains("invalid") || normalized.contains("corrupt")
    ) {
      return .decodeFailure(message)
    }

    if normalized.contains("no such file") {
      return .decodeFailure(message)
    }

    return nil
  }
}
