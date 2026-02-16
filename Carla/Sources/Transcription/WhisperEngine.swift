import Foundation

/// Errors surfaced by whisper engine implementations.
public enum WhisperEngineError: Error, Sendable, Equatable {
  case unsupportedLanguage(String)
  case decodingFailed
  case modelUnavailable(WhisperModel)
  case runtimeFailure(String)
}

/// Abstraction over whisper.cpp bindings.
public protocol WhisperTranscribingEngine: Sendable {
  /// Transcribes an in-memory realtime chunk.
  func transcribeStreamingChunk(
    _ chunk: AudioChunk,
    model: WhisperModel,
    languageHint: WhisperLanguageHint?
  ) async throws -> WhisperTranscriptionResult

  /// Transcribes a finalized audio file.
  func transcribeAudioFile(
    at fileURL: URL,
    model: WhisperModel,
    languageHint: WhisperLanguageHint?
  ) async throws -> WhisperTranscriptionResult
}

/// Language behavior for realtime and post-recording transcription.
public struct TranscriptionLanguageConfiguration: Sendable, Equatable {
  public let primaryLanguageCode: String?
  public let autoDetectFallback: Bool

  public init(primaryLanguageCode: String?, autoDetectFallback: Bool = true) {
    self.primaryLanguageCode = primaryLanguageCode
    self.autoDetectFallback = autoDetectFallback
  }

  /// Returns the initial language hint for an engine request.
  public func primaryHint() -> WhisperLanguageHint? {
    guard let primaryLanguageCode, !primaryLanguageCode.isEmpty else {
      return autoDetectFallback ? .autoDetect : nil
    }
    return .fixed(code: primaryLanguageCode)
  }

  /// Returns fallback hint when a fixed language fails.
  public func fallbackHint(after error: Error, previousHint: WhisperLanguageHint?)
    -> WhisperLanguageHint?
  {
    guard autoDetectFallback else { return nil }
    guard case .fixed = previousHint else { return nil }
    guard let engineError = error as? WhisperEngineError, case .unsupportedLanguage = engineError
    else {
      return nil
    }
    return .autoDetect
  }
}
