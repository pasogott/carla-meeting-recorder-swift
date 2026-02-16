import Foundation

/// Mock whisper engine used for tests and non-native build environments.
public actor MockWhisperEngine: WhisperTranscribingEngine {
  public enum Mode: Sendable {
    case synthetic
    case custom(
      stream:
        @Sendable (AudioChunk, WhisperModel, WhisperLanguageHint?) async throws ->
        WhisperTranscriptionResult,
      file:
        @Sendable (URL, WhisperModel, WhisperLanguageHint?) async throws ->
        WhisperTranscriptionResult
    )
  }

  private var streamingRequestCount: Int = 0
  private let mode: Mode

  public init(mode: Mode = .synthetic) {
    self.mode = mode
  }

  public func transcribeStreamingChunk(
    _ chunk: AudioChunk,
    model: WhisperModel,
    languageHint: WhisperLanguageHint?
  ) async throws -> WhisperTranscriptionResult {
    switch mode {
    case .custom(let stream, _):
      return try await stream(chunk, model, languageHint)
    case .synthetic:
      streamingRequestCount += 1
      let text = "chunk-\(streamingRequestCount)"
      let lang = resolvedLanguage(from: languageHint)
      return WhisperTranscriptionResult(
        segments: [
          WhisperSegment(
            startTime: 0,
            endTime: chunk.endTime - chunk.startTime,
            text: text,
            confidence: 0.9
          )
        ],
        detectedLanguageCode: lang
      )
    }
  }

  public func transcribeAudioFile(
    at fileURL: URL,
    model: WhisperModel,
    languageHint: WhisperLanguageHint?
  ) async throws -> WhisperTranscriptionResult {
    switch mode {
    case .custom(_, let file):
      return try await file(fileURL, model, languageHint)
    case .synthetic:
      let fileStem = fileURL.deletingPathExtension().lastPathComponent
      return WhisperTranscriptionResult(
        segments: [
          WhisperSegment(startTime: 0, endTime: 1.0, text: "polish-\(fileStem)", confidence: 0.95)
        ],
        detectedLanguageCode: resolvedLanguage(from: languageHint)
      )
    }
  }

  private func resolvedLanguage(from hint: WhisperLanguageHint?) -> String? {
    switch hint {
    case .fixed(let code):
      return code
    case .autoDetect:
      return "en"
    case .none:
      return nil
    }
  }
}
