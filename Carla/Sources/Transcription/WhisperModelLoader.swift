import Foundation

/// Manages whisper.cpp model file locations and lifecycle.
public actor WhisperModelLoader {
  /// Model file information with path and availability status.
  public struct ModelFile: Sendable {
    public let model: WhisperModel
    public let url: URL
    public let sizeBytes: Int64?
    public let isAvailable: Bool

    public init(model: WhisperModel, url: URL, sizeBytes: Int64?, isAvailable: Bool) {
      self.model = model
      self.url = url
      self.sizeBytes = sizeBytes
      self.isAvailable = isAvailable
    }
  }

  /// Errors from model loading operations.
  public enum ModelLoaderError: Error, Sendable {
    case modelNotFound(WhisperModel)
    case modelDirectoryCreationFailed(Error)
    case invalidModelFile(URL)
  }

  /// Default model directory location in Application Support.
  public static var defaultModelsDirectory: URL {
    let appSupport = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first!
    return appSupport.appendingPathComponent("Carla/Models", isDirectory: true)
  }

  private let modelsDirectory: URL
  private let fileManager: FileManager

  /// Creates a model loader with a custom models directory.
  public init(modelsDirectory: URL = defaultModelsDirectory, fileManager: FileManager = .default) {
    self.modelsDirectory = modelsDirectory
    self.fileManager = fileManager
  }

  /// Ensures the models directory exists.
  public func ensureModelsDirectoryExists() throws {
    if !fileManager.fileExists(atPath: modelsDirectory.path) {
      do {
        try fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
      } catch {
        throw ModelLoaderError.modelDirectoryCreationFailed(error)
      }
    }
  }

  /// Returns the expected file path for a given model.
  public func modelFilePath(for model: WhisperModel) -> URL {
    modelsDirectory.appendingPathComponent(modelFileName(for: model))
  }

  /// Returns the canonical file name for a whisper model.
  public func modelFileName(for model: WhisperModel) -> String {
    switch model {
    case .base:
      return "ggml-base.bin"
    case .small:
      return "ggml-small.bin"
    case .medium:
      return "ggml-medium.bin"
    case .large:
      return "ggml-large.bin"
    }
  }

  /// Checks if a model is available locally.
  public func isModelAvailable(_ model: WhisperModel) -> Bool {
    let path = modelFilePath(for: model)
    return fileManager.fileExists(atPath: path.path)
  }

  /// Returns information about a specific model file.
  public func modelInfo(for model: WhisperModel) -> ModelFile {
    let url = modelFilePath(for: model)
    let exists = fileManager.fileExists(atPath: url.path)
    var sizeBytes: Int64? = nil

    if exists {
      do {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        sizeBytes = attributes[.size] as? Int64
      } catch {
        // Ignore attribute errors, just report no size
      }
    }

    return ModelFile(model: model, url: url, sizeBytes: sizeBytes, isAvailable: exists)
  }

  /// Returns information about all supported models.
  public func allModels() -> [ModelFile] {
    [WhisperModel.base, .small, .medium, .large].map { modelInfo(for: $0) }
  }

  /// Returns the path to a model file, throwing if not available.
  public func requireModelPath(for model: WhisperModel) throws -> URL {
    let url = modelFilePath(for: model)
    guard fileManager.fileExists(atPath: url.path) else {
      throw ModelLoaderError.modelNotFound(model)
    }
    return url
  }

  /// Expected download URLs for Hugging Face hosted models.
  public func downloadURL(for model: WhisperModel) -> URL {
    let baseURL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main"
    let fileName = modelFileName(for: model)
    return URL(string: "\(baseURL)/\(fileName)")!
  }

  /// Registers a model file from an external location (e.g., after download).
  /// Copies or moves the file to the models directory.
  public func registerModel(_ model: WhisperModel, from sourceURL: URL, copy: Bool = true) throws {
    try ensureModelsDirectoryExists()

    let destinationURL = modelFilePath(for: model)

    // Remove existing file if present
    if fileManager.fileExists(atPath: destinationURL.path) {
      try fileManager.removeItem(at: destinationURL)
    }

    if copy {
      try fileManager.copyItem(at: sourceURL, to: destinationURL)
    } else {
      try fileManager.moveItem(at: sourceURL, to: destinationURL)
    }
  }

  /// Removes a model file from the models directory.
  public func removeModel(_ model: WhisperModel) throws {
    let url = modelFilePath(for: model)
    if fileManager.fileExists(atPath: url.path) {
      try fileManager.removeItem(at: url)
    }
  }

  /// Returns the models directory URL.
  public var directory: URL {
    modelsDirectory
  }
}
