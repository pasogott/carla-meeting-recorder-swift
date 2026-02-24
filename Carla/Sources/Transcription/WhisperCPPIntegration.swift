import Foundation

/// Protocol for concrete whisper.cpp FFI adapters.
public protocol WhisperCPPBinding: Sendable {
  /// Performs transcription of PCM data in-memory.
  func transcribePCM(
    samples: [Float],
    sampleRate: Double,
    model: ASRModelProfile,
    languageHint: ASRLanguageHint?
  ) async throws -> ASRTranscriptionResult

  /// Performs transcription for a file-backed request.
  func transcribeFile(
    fileURL: URL,
    model: ASRModelProfile,
    languageHint: ASRLanguageHint?
  ) async throws -> ASRTranscriptionResult
}

/// Production-ready wrapper shape for whisper.cpp bindings.
public struct WhisperCPPEngine: ASRTranscribingEngine {
  private let binding: WhisperCPPBinding

  public init(binding: WhisperCPPBinding) {
    self.binding = binding
  }

  public func transcribeStreamingChunk(
    _ chunk: AudioChunk,
    model: ASRModelProfile,
    languageHint: ASRLanguageHint?
  ) async throws -> ASRTranscriptionResult {
    try await binding.transcribePCM(
      samples: chunk.samples,
      sampleRate: chunk.sampleRate,
      model: model,
      languageHint: languageHint
    )
  }

  public func transcribeAudioFile(
    at fileURL: URL,
    model: ASRModelProfile,
    languageHint: ASRLanguageHint?
  ) async throws -> ASRTranscriptionResult {
    try await binding.transcribeFile(fileURL: fileURL, model: model, languageHint: languageHint)
  }
}
