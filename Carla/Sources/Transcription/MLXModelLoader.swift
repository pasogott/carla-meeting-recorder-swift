import Foundation

/// Manages transcription model file locations and lifecycle.
public actor MLXModelLoader {
  /// Model file information with path and availability status.
  public struct ModelFile: Sendable, Equatable {
    public let model: ASRModelProfile
    public let url: URL
    public let sizeBytes: Int64?
    public let isAvailable: Bool

    public init(model: ASRModelProfile, url: URL, sizeBytes: Int64?, isAvailable: Bool) {
      self.model = model
      self.url = url
      self.sizeBytes = sizeBytes
      self.isAvailable = isAvailable
    }
  }

  /// MLX model file information with path and availability status.
  public struct ManagedModelFile: Sendable, Equatable {
    public let modelID: String
    public let url: URL
    public let sizeBytes: Int64?
    public let isAvailable: Bool

    public init(modelID: String, url: URL, sizeBytes: Int64?, isAvailable: Bool) {
      self.modelID = modelID
      self.url = url
      self.sizeBytes = sizeBytes
      self.isAvailable = isAvailable
    }
  }

  /// Known legacy ggml model artifacts from pre-MLX lifecycle.
  public enum LegacyGGMLModel: String, CaseIterable, Sendable {
    case base = "ggml-base.bin"
    case small = "ggml-small.bin"
    case medium = "ggml-medium.bin"
    case large = "ggml-large.bin"
  }

  /// Errors from model loading operations.
  public enum ModelLoaderError: Error, Sendable {
    case modelNotFound(ASRModelProfile)
    case modelIDNotFound(String)
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

  /// Returns the expected file path for a given legacy profile model.
  public func modelFilePath(for model: ASRModelProfile) -> URL {
    modelsDirectory.appendingPathComponent(modelFileName(for: model))
  }

  /// Returns the expected file path for a managed MLX model ID.
  public func modelFilePath(forModelID modelID: String, cacheFileName: String? = nil) -> URL {
    let fileName = cacheFileName ?? sanitizedModelCacheName(for: modelID)
    return modelsDirectory.appendingPathComponent(fileName)
  }

  /// Returns the canonical file name for a legacy ggml profile model.
  public func modelFileName(for model: ASRModelProfile) -> String {
    switch model {
    case .base:
      return LegacyGGMLModel.base.rawValue
    case .small:
      return LegacyGGMLModel.small.rawValue
    case .medium:
      return LegacyGGMLModel.medium.rawValue
    case .large:
      return LegacyGGMLModel.large.rawValue
    }
  }

  /// Checks if a legacy profile model is available locally.
  public func isModelAvailable(_ model: ASRModelProfile) -> Bool {
    let path = modelFilePath(for: model)
    return fileManager.fileExists(atPath: path.path)
  }

  /// Checks if a managed MLX model ID is available locally.
  public func isModelIDAvailable(_ modelID: String, cacheFileName: String? = nil) -> Bool {
    let path = modelFilePath(forModelID: modelID, cacheFileName: cacheFileName)
    return fileManager.fileExists(atPath: path.path)
  }

  /// Returns information about a specific legacy profile model file.
  public func modelInfo(for model: ASRModelProfile) -> ModelFile {
    let url = modelFilePath(for: model)
    let exists = fileManager.fileExists(atPath: url.path)
    let sizeBytes = fileSizeIfExists(at: url)
    return ModelFile(model: model, url: url, sizeBytes: sizeBytes, isAvailable: exists)
  }

  /// Returns information about a specific managed MLX model file.
  public func modelInfo(forModelID modelID: String, cacheFileName: String? = nil) -> ManagedModelFile {
    let url = modelFilePath(forModelID: modelID, cacheFileName: cacheFileName)
    let exists = fileManager.fileExists(atPath: url.path)
    let sizeBytes = fileSizeIfExists(at: url)
    return ManagedModelFile(modelID: modelID, url: url, sizeBytes: sizeBytes, isAvailable: exists)
  }

  /// Returns information about all supported legacy profile models.
  public func allModels() -> [ModelFile] {
    [ASRModelProfile.base, .small, .medium, .large].map { modelInfo(for: $0) }
  }

  /// Returns information about all provided managed model IDs.
  public func allModels(modelIDs: [String], cacheFileNames: [String: String] = [:]) -> [ManagedModelFile] {
    modelIDs.map { modelID in
      modelInfo(forModelID: modelID, cacheFileName: cacheFileNames[modelID])
    }
  }

  /// Returns the path to a legacy model file, throwing if not available.
  public func requireModelPath(for model: ASRModelProfile) throws -> URL {
    let url = modelFilePath(for: model)
    guard fileManager.fileExists(atPath: url.path) else {
      throw ModelLoaderError.modelNotFound(model)
    }
    return url
  }

  /// Returns the path to a managed model file, throwing if not available.
  public func requireModelPath(forModelID modelID: String, cacheFileName: String? = nil) throws -> URL {
    let url = modelFilePath(forModelID: modelID, cacheFileName: cacheFileName)
    guard fileManager.fileExists(atPath: url.path) else {
      throw ModelLoaderError.modelIDNotFound(modelID)
    }
    return url
  }

  /// Registers a legacy model file from an external location.
  public func registerModel(_ model: ASRModelProfile, from sourceURL: URL, copy: Bool = true) throws {
    try ensureModelsDirectoryExists()
    let destinationURL = modelFilePath(for: model)
    try replaceItem(at: destinationURL, with: sourceURL, copy: copy)
  }

  /// Registers a managed model file from an external location.
  public func registerModelID(
    _ modelID: String,
    cacheFileName: String? = nil,
    from sourceURL: URL,
    copy: Bool = true
  ) throws {
    try ensureModelsDirectoryExists()
    let destinationURL = modelFilePath(forModelID: modelID, cacheFileName: cacheFileName)
    try replaceItem(at: destinationURL, with: sourceURL, copy: copy)
  }

  /// Removes a legacy model file from the models directory.
  public func removeModel(_ model: ASRModelProfile) throws {
    let url = modelFilePath(for: model)
    if fileManager.fileExists(atPath: url.path) {
      try fileManager.removeItem(at: url)
    }
  }

  /// Removes a managed model file from the models directory.
  public func removeModelID(_ modelID: String, cacheFileName: String? = nil) throws {
    let url = modelFilePath(forModelID: modelID, cacheFileName: cacheFileName)
    if fileManager.fileExists(atPath: url.path) {
      try fileManager.removeItem(at: url)
    }
  }

  /// Lists legacy ggml artifacts currently on disk.
  public func legacyGGMLFiles() -> [URL] {
    LegacyGGMLModel.allCases
      .map { modelsDirectory.appendingPathComponent($0.rawValue) }
      .filter { fileManager.fileExists(atPath: $0.path) }
  }

  /// Removes all discovered legacy ggml artifacts and returns deleted URLs.
  public func removeLegacyGGMLFiles() throws -> [URL] {
    let files = legacyGGMLFiles()
    for file in files {
      try fileManager.removeItem(at: file)
    }
    return files
  }

  /// Returns the models directory URL.
  public var directory: URL {
    modelsDirectory
  }

  private func fileSizeIfExists(at url: URL) -> Int64? {
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    do {
      let attributes = try fileManager.attributesOfItem(atPath: url.path)
      return attributes[.size] as? Int64
    } catch {
      return nil
    }
  }

  private func sanitizedModelCacheName(for modelID: String) -> String {
    let safe = modelID
      .lowercased()
      .replacingOccurrences(of: "/", with: "--")
      .replacingOccurrences(of: ":", with: "-")
      .replacingOccurrences(of: " ", with: "-")
    return "\(safe).mlxmodel"
  }

  private func replaceItem(at destinationURL: URL, with sourceURL: URL, copy: Bool) throws {
    if fileManager.fileExists(atPath: destinationURL.path) {
      try fileManager.removeItem(at: destinationURL)
    }

    if copy {
      try fileManager.copyItem(at: sourceURL, to: destinationURL)
    } else {
      try fileManager.moveItem(at: sourceURL, to: destinationURL)
    }
  }
}
