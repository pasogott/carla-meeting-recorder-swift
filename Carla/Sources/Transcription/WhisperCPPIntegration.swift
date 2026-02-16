import Foundation

/// Protocol for concrete whisper.cpp FFI adapters.
public protocol WhisperCPPBinding: Sendable {
  /// Performs transcription of PCM data in-memory.
  func transcribePCM(
    samples: [Float],
    sampleRate: Double,
    model: WhisperModel,
    languageHint: WhisperLanguageHint?
  ) async throws -> WhisperTranscriptionResult

  /// Performs transcription for a file-backed request.
  func transcribeFile(
    fileURL: URL,
    model: WhisperModel,
    languageHint: WhisperLanguageHint?
  ) async throws -> WhisperTranscriptionResult
}

/// Production-ready wrapper shape for whisper.cpp bindings.
/// Replace `fatalError` stubs once C/C++ bridge is linked.
public struct WhisperCPPEngine: WhisperTranscribingEngine {
  private let binding: WhisperCPPBinding

  public init(binding: WhisperCPPBinding) {
    self.binding = binding
  }

  public func transcribeStreamingChunk(
    _ chunk: AudioChunk,
    model: WhisperModel,
    languageHint: WhisperLanguageHint?
  ) async throws -> WhisperTranscriptionResult {
    try await binding.transcribePCM(
      samples: chunk.samples,
      sampleRate: chunk.sampleRate,
      model: model,
      languageHint: languageHint
    )
  }

  public func transcribeAudioFile(
    at fileURL: URL,
    model: WhisperModel,
    languageHint: WhisperLanguageHint?
  ) async throws -> WhisperTranscriptionResult {
    try await binding.transcribeFile(fileURL: fileURL, model: model, languageHint: languageHint)
  }
}
