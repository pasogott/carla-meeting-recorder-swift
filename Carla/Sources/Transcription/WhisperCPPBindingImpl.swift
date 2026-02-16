@preconcurrency import AVFoundation
import Foundation
import whisper

/// Errors specific to whisper.cpp binding operations.
public enum WhisperBindingError: Error, Sendable {
  case modelLoadFailed(URL)
  case contextCreationFailed
  case transcriptionFailed(String)
  case fileNotFound(URL)
  case invalidAudioFormat(String)
  case audioReadFailed(URL, String)
}

/// Wrapper class for whisper context that handles cleanup on deallocation.
private final class WhisperContextHandle: @unchecked Sendable {
  let pointer: OpaquePointer

  init(_ pointer: OpaquePointer) {
    self.pointer = pointer
  }

  deinit {
    whisper_free(pointer)
  }
}

/// One-shot wrapper to satisfy Swift 6 sendability checks for AVAudioConverter input blocks.
private final class AudioConverterInputBox: @unchecked Sendable {
  var buffer: AVAudioPCMBuffer?

  init(_ buffer: AVAudioPCMBuffer) {
    self.buffer = buffer
  }
}

/// Actor managing whisper.cpp context lifecycle and transcription execution.
/// All whisper.cpp FFI calls happen within this actor to ensure thread safety.
public actor WhisperCPPBindingImpl: WhisperCPPBinding {

  private var loadedContexts: [WhisperModel: WhisperContextHandle] = [:]
  private let modelLoader: WhisperModelLoader

  /// Creates a binding implementation with the specified model loader.
  public init(modelLoader: WhisperModelLoader = WhisperModelLoader()) {
    self.modelLoader = modelLoader
  }

  // MARK: - WhisperCPPBinding Protocol

  public func transcribePCM(
    samples: [Float],
    sampleRate: Double,
    model: WhisperModel,
    languageHint: WhisperLanguageHint?
  ) async throws -> WhisperTranscriptionResult {
    // Resample to 16kHz if needed (whisper.cpp requires 16kHz mono)
    let resampledSamples = try resampleIfNeeded(
      samples: samples, fromRate: sampleRate, toRate: 16000)

    guard !resampledSamples.isEmpty else {
      return WhisperTranscriptionResult(segments: [], detectedLanguageCode: nil)
    }

    // Get or load the whisper context
    let ctx = try await getOrLoadContext(for: model)

    // Run transcription
    return try performTranscription(
      ctx: ctx.pointer, samples: resampledSamples, languageHint: languageHint)
  }

  public func transcribeFile(
    fileURL: URL,
    model: WhisperModel,
    languageHint: WhisperLanguageHint?
  ) async throws -> WhisperTranscriptionResult {
    // Verify file exists
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      throw WhisperBindingError.fileNotFound(fileURL)
    }

    // Read audio samples from file
    let (samples, sampleRate) = try readAudioSamples(from: fileURL)
    let resampledSamples = try resampleIfNeeded(
      samples: samples, fromRate: sampleRate, toRate: 16000)

    guard !resampledSamples.isEmpty else {
      return WhisperTranscriptionResult(segments: [], detectedLanguageCode: nil)
    }

    // Get or load the whisper context
    let ctx = try await getOrLoadContext(for: model)

    // Run transcription
    return try performTranscription(
      ctx: ctx.pointer, samples: resampledSamples, languageHint: languageHint)
  }

  // MARK: - Context Management

  private func getOrLoadContext(for model: WhisperModel) async throws -> WhisperContextHandle {
    // Return cached context if available
    if let ctx = loadedContexts[model] {
      return ctx
    }

    // Load the model
    let modelPath = try await modelLoader.requireModelPath(for: model)

    // Initialize whisper context with default parameters
    var params = whisper_context_default_params()
    params.use_gpu = true

    guard let ptr = whisper_init_from_file_with_params(modelPath.path, params) else {
      throw WhisperBindingError.modelLoadFailed(modelPath)
    }

    let handle = WhisperContextHandle(ptr)
    loadedContexts[model] = handle
    return handle
  }

  /// Unloads a specific model from memory.
  public func unloadModel(_ model: WhisperModel) {
    loadedContexts.removeValue(forKey: model)
  }

  /// Unloads all models from memory.
  public func unloadAllModels() {
    loadedContexts.removeAll()
  }

  // MARK: - Transcription Core

  private func performTranscription(
    ctx: OpaquePointer,
    samples: [Float],
    languageHint: WhisperLanguageHint?
  ) throws -> WhisperTranscriptionResult {
    guard !samples.isEmpty else {
      return WhisperTranscriptionResult(segments: [], detectedLanguageCode: nil)
    }

    var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)

    // Configure language - need to handle string lifetime carefully
    var languageCode: String?
    switch languageHint {
    case .fixed(let code):
      languageCode = code
      params.detect_language = false
    case .autoDetect:
      languageCode = nil
      params.detect_language = true
    case .none:
      languageCode = nil
      params.detect_language = true
    }

    // Configure for quality
    params.n_threads = Int32(ProcessInfo.processInfo.activeProcessorCount)
    params.print_progress = false
    params.print_timestamps = false
    params.print_special = false
    params.translate = false
    params.no_timestamps = false

    // Run whisper_full with proper string handling
    let result: Int32
    if let code = languageCode {
      result = code.withCString { codePtr in
        params.language = codePtr
        return samples.withUnsafeBufferPointer { samplesPtr in
          guard let base = samplesPtr.baseAddress else { return -1 }
          return whisper_full(ctx, params, base, Int32(samples.count))
        }
      }
    } else {
      params.language = nil
      result = samples.withUnsafeBufferPointer { samplesPtr in
        guard let base = samplesPtr.baseAddress else { return -1 }
        return whisper_full(ctx, params, base, Int32(samples.count))
      }
    }

    guard result == 0 else {
      throw WhisperBindingError.transcriptionFailed("whisper_full returned \(result)")
    }

    // Extract segments
    let numSegments = whisper_full_n_segments(ctx)
    var segments: [WhisperSegment] = []

    for i in 0..<numSegments {
      let startTime = TimeInterval(whisper_full_get_segment_t0(ctx, i)) / 100.0
      let endTime = TimeInterval(whisper_full_get_segment_t1(ctx, i)) / 100.0

      guard let textPtr = whisper_full_get_segment_text(ctx, i) else {
        continue
      }
      let text = String(cString: textPtr).trimmingCharacters(in: .whitespacesAndNewlines)

      // Skip empty segments
      guard !text.isEmpty else { continue }

      // Get token-level probabilities for confidence estimation
      let numTokens = whisper_full_n_tokens(ctx, i)
      var totalProb: Float = 0
      var tokenCount: Int32 = 0

      for j in 0..<numTokens {
        let tokenData = whisper_full_get_token_data(ctx, i, j)
        if tokenData.p > 0 {
          totalProb += tokenData.p
          tokenCount += 1
        }
      }

      let confidence = tokenCount > 0 ? totalProb / Float(tokenCount) : 0.5

      segments.append(
        WhisperSegment(
          startTime: startTime,
          endTime: endTime,
          text: text,
          confidence: confidence
        ))
    }

    // Get detected language
    let langId = whisper_full_lang_id(ctx)
    let detectedLanguage: String?
    if langId >= 0 {
      if let langPtr = whisper_lang_str(langId) {
        detectedLanguage = String(cString: langPtr)
      } else {
        detectedLanguage = nil
      }
    } else {
      detectedLanguage = nil
    }

    return WhisperTranscriptionResult(
      segments: segments,
      detectedLanguageCode: detectedLanguage
    )
  }

  // MARK: - Audio Processing

  private func resampleIfNeeded(samples: [Float], fromRate: Double, toRate: Double) throws
    -> [Float]
  {
    guard fromRate > 0, toRate > 0 else {
      throw WhisperBindingError.invalidAudioFormat("Invalid sample rate")
    }

    guard fromRate != toRate else { return samples }

    let ratio = toRate / fromRate
    let newLength = Int(Double(samples.count) * ratio)

    // If the input is too short to produce any output at the target rate, treat as silence.
    guard newLength > 0 else { return [] }

    // Linear interpolation resampling (basic but functional)
    var resampled = [Float](repeating: 0, count: newLength)

    for i in 0..<newLength {
      let srcIndex = Double(i) / ratio
      let srcIndexFloor = Int(srcIndex)
      let srcIndexCeil = min(srcIndexFloor + 1, samples.count - 1)
      let fraction = Float(srcIndex - Double(srcIndexFloor))

      if srcIndexFloor < samples.count {
        resampled[i] = samples[srcIndexFloor] * (1 - fraction) + samples[srcIndexCeil] * fraction
      }
    }

    return resampled
  }

  private func readAudioSamples(from fileURL: URL) throws -> (samples: [Float], sampleRate: Double)
  {
    let file: AVAudioFile
    do {
      file = try AVAudioFile(forReading: fileURL)
    } catch {
      throw WhisperBindingError.audioReadFailed(fileURL, error.localizedDescription)
    }

    let inputFormat = file.processingFormat
    guard inputFormat.channelCount > 0 else {
      throw WhisperBindingError.invalidAudioFormat("Audio file has no channels")
    }

    guard
      let monoFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: inputFormat.sampleRate,
        channels: 1,
        interleaved: false
      )
    else {
      throw WhisperBindingError.invalidAudioFormat("Failed to create mono float audio format")
    }

    guard let converter = AVAudioConverter(from: inputFormat, to: monoFormat) else {
      throw WhisperBindingError.invalidAudioFormat("Unsupported audio format")
    }

    let bufferCapacity: AVAudioFrameCount = 8_192
    var allSamples: [Float] = []

    while file.framePosition < file.length {
      let remaining = file.length - file.framePosition
      let framesToRead = AVAudioFrameCount(min(Int64(bufferCapacity), remaining))

      guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: framesToRead)
      else {
        throw WhisperBindingError.invalidAudioFormat("Failed to allocate input buffer")
      }

      try file.read(into: inputBuffer, frameCount: framesToRead)
      if inputBuffer.frameLength == 0 { break }

      guard
        let outputBuffer = AVAudioPCMBuffer(
          pcmFormat: monoFormat, frameCapacity: inputBuffer.frameLength)
      else {
        throw WhisperBindingError.invalidAudioFormat("Failed to allocate output buffer")
      }

      var conversionError: NSError?
      let inputBox = AudioConverterInputBox(inputBuffer)
      let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
        if let buffer = inputBox.buffer {
          inputBox.buffer = nil
          outStatus.pointee = .haveData
          return buffer
        }

        outStatus.pointee = .endOfStream
        return nil
      }

      converter.reset()
      let status = converter.convert(
        to: outputBuffer, error: &conversionError, withInputFrom: inputBlock)

      if let conversionError {
        throw WhisperBindingError.invalidAudioFormat(conversionError.localizedDescription)
      }

      if status == .error {
        throw WhisperBindingError.invalidAudioFormat("Audio conversion failed")
      }

      let count = Int(outputBuffer.frameLength)
      guard count > 0, let channelData = outputBuffer.floatChannelData else { continue }
      allSamples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: count))
    }

    return (allSamples, inputFormat.sampleRate)
  }
}

// MARK: - Convenience Extensions

extension WhisperCPPBindingImpl {
  /// Creates a binding implementation and verifies a model is available.
  public static func withModel(
    _ model: WhisperModel,
    modelLoader: WhisperModelLoader = WhisperModelLoader()
  ) async throws -> WhisperCPPBindingImpl {
    let binding = WhisperCPPBindingImpl(modelLoader: modelLoader)
    // Verify model exists
    _ = try await modelLoader.requireModelPath(for: model)
    return binding
  }
}
