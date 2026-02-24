import Foundation

/// Production MLX binding shim used by app runtime wiring.
///
/// The concrete MLX backend is expected to be provided by a future integration layer.
/// Until then, this adapter provides deterministic error semantics and model readiness checks.
public actor MLXWhisperBindingImpl: MLXWhisperBinding {
  private let modelManager: MLXModelManager

  public init(modelManager: MLXModelManager = MLXModelManager()) {
    self.modelManager = modelManager
  }

  public func transcribePCM(
    samples: [Float],
    sampleRate: Double,
    modelID: String,
    languageCode: String?
  ) async throws -> MLXTranscriptionPayload {
    _ = (samples, sampleRate, languageCode)
    try await ensureModelReady(modelID)
    return MLXTranscriptionPayload(segments: [], detectedLanguageCode: languageCode)
  }

  public func transcribeFile(
    fileURL: URL,
    modelID: String,
    languageCode: String?
  ) async throws -> MLXTranscriptionPayload {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      throw MLXWhisperLibraryError.decodeFailure("audio file missing at \(fileURL.path)")
    }

    _ = languageCode
    try await ensureModelReady(modelID)
    return MLXTranscriptionPayload(segments: [], detectedLanguageCode: languageCode)
  }

  private func ensureModelReady(_ modelID: String) async throws {
    let canonical = MLXModelCatalog.resolveModelID(fromSettingsValue: modelID)
    let ready = await modelManager.validateModelID(canonical)
    guard ready else {
      throw MLXWhisperLibraryError.modelNotFound(canonical)
    }
  }
}
