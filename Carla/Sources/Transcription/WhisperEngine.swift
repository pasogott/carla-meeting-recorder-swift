import Foundation

/// Errors surfaced by backend-neutral ASR engine implementations.
public enum ASREngineError: Error, Sendable, Equatable {
  case unsupportedLanguage(String)
  case decodingFailed
  case modelUnavailable(ASRModelProfile)
  case runtimeFailure(String)
}

/// Baseline event payload for observability hooks.
public enum ASRMetricEvent: Sendable, Equatable {
  case latency(operation: ASRMetricOperation, durationMs: Double, success: Bool)
  case queueBackpressure(operation: ASRMetricOperation, queuedItems: Int, droppedItems: Int)
  case retry(operation: ASRMetricOperation, attempt: Int, reason: String)
  case stopToFinal(durationMs: Double)
}

/// Logical operation kind associated with ASR metric events.
public enum ASRMetricOperation: String, Sendable, Equatable {
  case streamChunk
  case transcribeFile
  case finishRealtimeJob
}

/// Optional metrics sink for orchestrator/engine instrumentation.
public protocol ASRMetricsHook: Sendable {
  func record(_ event: ASRMetricEvent)
}

/// No-op hook used as a safe default when callers do not provide instrumentation.
public struct NoopASRMetricsHook: ASRMetricsHook {
  public init() {}

  public func record(_ event: ASRMetricEvent) {
    _ = event
  }
}

/// Abstraction over ASR backend bindings.
public protocol ASRTranscribingEngine: Sendable {
  /// Transcribes an in-memory realtime chunk.
  func transcribeStreamingChunk(
    _ chunk: AudioChunk,
    model: ASRModelProfile,
    languageHint: ASRLanguageHint?
  ) async throws -> ASRTranscriptionResult

  /// Transcribes a finalized audio file.
  func transcribeAudioFile(
    at fileURL: URL,
    model: ASRModelProfile,
    languageHint: ASRLanguageHint?
  ) async throws -> ASRTranscriptionResult
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
  public func primaryHint() -> ASRLanguageHint? {
    guard let primaryLanguageCode, !primaryLanguageCode.isEmpty else {
      return autoDetectFallback ? .autoDetect : nil
    }
    return .fixed(code: primaryLanguageCode)
  }

  /// Returns fallback hint when a fixed language fails.
  public func fallbackHint(after error: Error, previousHint: ASRLanguageHint?)
    -> ASRLanguageHint?
  {
    guard autoDetectFallback else { return nil }
    guard case .fixed = previousHint else { return nil }
    guard let engineError = error as? ASREngineError, case .unsupportedLanguage = engineError
    else {
      return nil
    }
    return .autoDetect
  }
}

// MARK: - Backward compatibility aliases

public typealias WhisperEngineError = ASREngineError
public typealias WhisperTranscribingEngine = ASRTranscribingEngine
