import Foundation

/// Raw segment payload returned by an MLX Whisper backend.
public struct MLXSegmentPayload: Sendable, Equatable {
  public let startMs: Int
  public let endMs: Int
  public let text: String
  public let confidence: Float?

  public init(startMs: Int, endMs: Int, text: String, confidence: Float?) {
    self.startMs = startMs
    self.endMs = endMs
    self.text = text
    self.confidence = confidence
  }
}

/// Raw transcription payload returned by an MLX Whisper backend.
public struct MLXTranscriptionPayload: Sendable, Equatable {
  public let segments: [MLXSegmentPayload]
  public let detectedLanguageCode: String?

  public init(segments: [MLXSegmentPayload], detectedLanguageCode: String?) {
    self.segments = segments
    self.detectedLanguageCode = detectedLanguageCode
  }
}

/// MLX/library error surface normalized by ``MLXWhisperEngine``.
public enum MLXWhisperLibraryError: Error, Sendable, Equatable {
  case unsupportedLanguage(String)
  case modelNotFound(String)
  case modelNotLoaded(String)
  case invalidAudio(String)
  case decodeFailure(String)
  case libraryFailure(code: Int, message: String)
  case runtimeFailure(String)
}

/// Protocol for concrete MLX Whisper adapters.
public protocol MLXWhisperBinding: Sendable {
  func transcribePCM(
    samples: [Float],
    sampleRate: Double,
    modelID: String,
    languageCode: String?
  ) async throws -> MLXTranscriptionPayload

  func transcribeFile(
    fileURL: URL,
    modelID: String,
    languageCode: String?
  ) async throws -> MLXTranscriptionPayload
}

/// ASR engine adapter backed by an MLX Whisper binding.
public struct MLXWhisperEngine: ASRTranscribingEngine {
  public typealias ModelIDResolver = @Sendable (ASRModelProfile) -> String

  private let binding: MLXWhisperBinding
  private let modelIDForProfile: ModelIDResolver

  public init(
    binding: MLXWhisperBinding,
    modelIDForProfile: @escaping ModelIDResolver = { profile in
      switch profile {
      case .base:
        return "mlx-community/whisper-base"
      case .small:
        return "mlx-community/whisper-small"
      case .medium:
        return "mlx-community/whisper-medium"
      case .large:
        return "mlx-community/whisper-large-v3"
      }
    }
  ) {
    self.binding = binding
    self.modelIDForProfile = modelIDForProfile
  }

  public func transcribeStreamingChunk(
    _ chunk: AudioChunk,
    model: ASRModelProfile,
    languageHint: ASRLanguageHint?
  ) async throws -> ASRTranscriptionResult {
    do {
      let payload = try await binding.transcribePCM(
        samples: chunk.samples,
        sampleRate: chunk.sampleRate,
        modelID: modelIDForProfile(model),
        languageCode: Self.resolveLanguageCode(from: languageHint)
      )
      return Self.normalize(payload)
    } catch {
      throw Self.mapError(error, model: model)
    }
  }

  public func transcribeAudioFile(
    at fileURL: URL,
    model: ASRModelProfile,
    languageHint: ASRLanguageHint?
  ) async throws -> ASRTranscriptionResult {
    do {
      let payload = try await binding.transcribeFile(
        fileURL: fileURL,
        modelID: modelIDForProfile(model),
        languageCode: Self.resolveLanguageCode(from: languageHint)
      )
      return Self.normalize(payload)
    } catch {
      throw Self.mapError(error, model: model)
    }
  }

  static func defaultModelID(for profile: ASRModelProfile) -> String {
    switch profile {
    case .base:
      return "mlx-community/whisper-base"
    case .small:
      return "mlx-community/whisper-small"
    case .medium:
      return "mlx-community/whisper-medium"
    case .large:
      return "mlx-community/whisper-large-v3"
    }
  }

  static func resolveLanguageCode(from hint: ASRLanguageHint?) -> String? {
    guard case .fixed(let code) = hint else { return nil }
    let normalized = code
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    return normalized.isEmpty ? nil : normalized
  }

  static func normalize(_ payload: MLXTranscriptionPayload) -> ASRTranscriptionResult {
    let normalizedSegments: [ASRSegment] = payload.segments.compactMap { segment in
      let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return nil }

      let start = max(0.0, Double(segment.startMs) / 1000.0)
      let endRaw = max(0.0, Double(segment.endMs) / 1000.0)
      let end = max(start, endRaw)
      let confidence = min(max(segment.confidence ?? 0.5, 0.0), 1.0)

      return ASRSegment(startTime: start, endTime: end, text: text, confidence: confidence)
    }

    let normalizedLanguage = payload.detectedLanguageCode?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()

    return ASRTranscriptionResult(
      segments: normalizedSegments,
      detectedLanguageCode: normalizedLanguage?.isEmpty == true ? nil : normalizedLanguage
    )
  }

  static func mapError(_ error: Error, model: ASRModelProfile) -> ASREngineError {
    if let engineError = error as? ASREngineError {
      return engineError
    }

    if let mlxError = error as? MLXWhisperLibraryError {
      switch mlxError {
      case .unsupportedLanguage(let code):
        return .unsupportedLanguage(code)
      case .modelNotFound, .modelNotLoaded:
        return .modelUnavailable(model)
      case .invalidAudio, .decodeFailure:
        return .decodingFailed
      case .libraryFailure(let code, let message):
        return .runtimeFailure("mlx-library(\(code)): \(message)")
      case .runtimeFailure(let message):
        return .runtimeFailure(message)
      }
    }

    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoSuchFileError {
      return .modelUnavailable(model)
    }

    return .runtimeFailure(String(describing: error))
  }
}
