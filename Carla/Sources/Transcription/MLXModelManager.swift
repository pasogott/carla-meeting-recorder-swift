import Foundation

/// Tracks download progress for a single model transfer.
public struct ModelDownloadProgress: Sendable, Equatable {
  public let model: ASRModelProfile
  public let modelID: String
  public let bytesDownloaded: Int64
  public let totalBytes: Int64?
  public let isComplete: Bool
  public let error: String?

  public var fractionComplete: Double {
    guard let total = totalBytes, total > 0 else { return 0 }
    return Double(bytesDownloaded) / Double(total)
  }

  public var formattedProgress: String {
    let downloaded = ByteCountFormatter.string(fromByteCount: bytesDownloaded, countStyle: .file)
    if let totalBytes {
      let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
      return "\(downloaded) / \(total)"
    }
    return downloaded
  }

  public init(
    model: ASRModelProfile,
    modelID: String? = nil,
    bytesDownloaded: Int64 = 0,
    totalBytes: Int64? = nil,
    isComplete: Bool = false,
    error: String? = nil
  ) {
    self.model = model
    self.modelID = modelID ?? MLXModelCatalog.modelID(for: model)
    self.bytesDownloaded = bytesDownloaded
    self.totalBytes = totalBytes
    self.isComplete = isComplete
    self.error = error
  }

  public init(
    modelID: String,
    bytesDownloaded: Int64 = 0,
    totalBytes: Int64? = nil,
    isComplete: Bool = false,
    error: String? = nil
  ) {
    let profile = MLXModelCatalog.profile(forSettingsValue: modelID) ?? .base
    self.init(
      model: profile,
      modelID: modelID,
      bytesDownloaded: bytesDownloaded,
      totalBytes: totalBytes,
      isComplete: isComplete,
      error: error
    )
  }
}

/// Artifact contract entry for a required model file.
public struct MLXModelArtifact: Sendable, Equatable {
  public let relativePath: String
  public let sourceURL: URL
  public let checksumSHA256: String?

  public init(relativePath: String, sourceURL: URL, checksumSHA256: String? = nil) {
    self.relativePath = relativePath
    self.sourceURL = sourceURL
    self.checksumSHA256 = checksumSHA256
  }
}

/// Human + machine-readable policy for a managed MLX model.
public enum MLXModelPolicyTier: String, Sendable, Equatable {
  case requiredDefault = "required_default"
  case optionalQuality = "optional_quality"
  case pressureFallback = "pressure_fallback"
  case legacyCompatibility = "legacy_compatibility"
}

/// Catalog entry for a managed MLX model.
public struct MLXModelDescriptor: Sendable, Equatable {
  public let profile: ASRModelProfile
  public let modelID: String
  public let displayName: String
  public let policyTier: MLXModelPolicyTier
  public let targetLanguageCodes: [String]
  public let cacheFileName: String
  public let downloadURL: URL
  public let expectedSizeBytes: ClosedRange<Int64>
  public let requiredArtifacts: [MLXModelArtifact]

  public init(
    profile: ASRModelProfile,
    modelID: String,
    displayName: String,
    policyTier: MLXModelPolicyTier,
    targetLanguageCodes: [String],
    cacheFileName: String,
    downloadURL: URL,
    expectedSizeBytes: ClosedRange<Int64>,
    requiredArtifacts: [MLXModelArtifact]
  ) {
    self.profile = profile
    self.modelID = modelID
    self.displayName = displayName
    self.policyTier = policyTier
    self.targetLanguageCodes = targetLanguageCodes
    self.cacheFileName = cacheFileName
    self.downloadURL = downloadURL
    self.expectedSizeBytes = expectedSizeBytes
    self.requiredArtifacts = requiredArtifacts
  }
}

/// Canonical MLX model catalog and legacy mapping helpers.
public enum MLXModelCatalog {
  public static let manifestVersion = "2026-02-24"

  public static let descriptors: [MLXModelDescriptor] = [
    MLXModelDescriptor(
      profile: .base,
      modelID: "mlx-community/whisper-base",
      displayName: "Base (legacy compatibility)",
      policyTier: .legacyCompatibility,
      targetLanguageCodes: ["en", "de"],
      cacheFileName: "mlx-community--whisper-base.mlxmodel",
      downloadURL: URL(string: "https://huggingface.co/mlx-community/whisper-base/resolve/main/model.bin")!,
      expectedSizeBytes: 120_000_000...180_000_000,
      requiredArtifacts: artifacts(for: "mlx-community/whisper-base")
    ),
    MLXModelDescriptor(
      profile: .small,
      modelID: "mlx-community/whisper-small",
      displayName: "Small (pressure fallback)",
      policyTier: .pressureFallback,
      targetLanguageCodes: ["en", "de"],
      cacheFileName: "mlx-community--whisper-small.mlxmodel",
      downloadURL: URL(string: "https://huggingface.co/mlx-community/whisper-small/resolve/main/model.bin")!,
      expectedSizeBytes: 380_000_000...600_000_000,
      requiredArtifacts: artifacts(for: "mlx-community/whisper-small")
    ),
    MLXModelDescriptor(
      profile: .medium,
      modelID: "mlx-community/whisper-medium",
      displayName: "Medium (default)",
      policyTier: .requiredDefault,
      targetLanguageCodes: ["en", "de"],
      cacheFileName: "mlx-community--whisper-medium.mlxmodel",
      downloadURL: URL(string: "https://huggingface.co/mlx-community/whisper-medium/resolve/main/model.bin")!,
      expectedSizeBytes: 1_100_000_000...1_900_000_000,
      requiredArtifacts: artifacts(for: "mlx-community/whisper-medium")
    ),
    MLXModelDescriptor(
      profile: .large,
      modelID: "mlx-community/whisper-large-v3",
      displayName: "Large v3 (optional quality)",
      policyTier: .optionalQuality,
      targetLanguageCodes: ["en", "de"],
      cacheFileName: "mlx-community--whisper-large-v3.mlxmodel",
      downloadURL: URL(string: "https://huggingface.co/mlx-community/whisper-large-v3/resolve/main/model.bin")!,
      expectedSizeBytes: 2_100_000_000...4_200_000_000,
      requiredArtifacts: artifacts(for: "mlx-community/whisper-large-v3")
    ),
  ]

  public static let descriptorByProfile: [ASRModelProfile: MLXModelDescriptor] =
    Dictionary(uniqueKeysWithValues: descriptors.map { ($0.profile, $0) })

  public static let descriptorByID: [String: MLXModelDescriptor] =
    Dictionary(uniqueKeysWithValues: descriptors.map { ($0.modelID, $0) })

  public static let requiredProfiles: [ASRModelProfile] = [.medium]

  public static var requiredModelIDs: [String] {
    requiredProfiles.compactMap { descriptorByProfile[$0]?.modelID }
  }

  public static func modelID(for profile: ASRModelProfile) -> String {
    descriptorByProfile[profile]?.modelID ?? MLXWhisperEngine.defaultModelID(for: profile)
  }

  public static func label(for modelID: String) -> String {
    descriptorByID[modelID]?.displayName ?? modelID
  }

  /// Maps settings values (legacy names or model IDs) to canonical MLX model ID.
  public static func resolveModelID(fromSettingsValue rawValue: String) -> String {
    let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let profile = profile(forSettingsValue: normalized) {
      return modelID(for: profile)
    }
    if let descriptor = descriptorByID[normalized] {
      return descriptor.modelID
    }
    return modelID(for: .medium)
  }

  public static func profile(forSettingsValue rawValue: String) -> ASRModelProfile? {
    let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    switch normalized {
    case "base":
      return .medium
    case "small":
      return .small
    case "medium":
      return .medium
    case "large", "large-v3", "large_v3":
      return .large
    default:
      if let byID = descriptorByID[normalized] {
        return byID.profile
      }
      return nil
    }
  }

  private static func artifacts(for modelID: String) -> [MLXModelArtifact] {
    let baseURL = "https://huggingface.co/\(modelID)/resolve/main"
    return [
      MLXModelArtifact(relativePath: "config.json", sourceURL: URL(string: "\(baseURL)/config.json")!),
      MLXModelArtifact(relativePath: "generation_config.json", sourceURL: URL(string: "\(baseURL)/generation_config.json")!),
      MLXModelArtifact(relativePath: "preprocessor_config.json", sourceURL: URL(string: "\(baseURL)/preprocessor_config.json")!),
      MLXModelArtifact(relativePath: "tokenizer.json", sourceURL: URL(string: "\(baseURL)/tokenizer.json")!),
      MLXModelArtifact(relativePath: "tokenizer_config.json", sourceURL: URL(string: "\(baseURL)/tokenizer_config.json")!),
      MLXModelArtifact(relativePath: "vocab.json", sourceURL: URL(string: "\(baseURL)/vocab.json")!),
      MLXModelArtifact(relativePath: "merges.txt", sourceURL: URL(string: "\(baseURL)/merges.txt")!),
      MLXModelArtifact(relativePath: "model.bin", sourceURL: URL(string: "\(baseURL)/model.bin")!),
    ]
  }
}

/// Manages downloading, validating, and migrating managed MLX model artifacts.
public actor MLXModelManager {
  private let modelLoader: MLXModelLoader

  /// Per-model producer tasks.
  private var downloadTasks: [String: Task<Void, Never>] = [:]

  public init(modelLoader: MLXModelLoader = MLXModelLoader()) {
    self.modelLoader = modelLoader
  }

  /// Required profiles for backward compatibility with existing AppState wiring.
  public static var requiredModels: [ASRModelProfile] {
    MLXModelCatalog.requiredProfiles
  }

  /// Optional profiles for quality/runtime policy selection.
  public static var optionalModels: [ASRModelProfile] {
    [.small, .large]
  }

  public static var availableModels: [MLXModelDescriptor] {
    MLXModelCatalog.descriptors
  }

  // MARK: - Mapping

  public func resolveModelID(fromSettingsValue rawValue: String) -> String {
    MLXModelCatalog.resolveModelID(fromSettingsValue: rawValue)
  }

  // MARK: - Availability

  /// Checks which required legacy profiles map to missing MLX models.
  public func checkMissingModels() async -> [ASRModelProfile] {
    var missing: [ASRModelProfile] = []
    for profile in Self.requiredModels {
      let modelID = MLXModelCatalog.modelID(for: profile)
      guard let descriptor = MLXModelCatalog.descriptorByID[modelID] else {
        missing.append(profile)
        continue
      }

      let info = await modelLoader.modelInfo(
        forModelID: descriptor.modelID,
        cacheFileName: descriptor.cacheFileName
      )

      if !info.isAvailable || !descriptor.expectedSizeBytes.contains(info.sizeBytes ?? -1) {
        missing.append(profile)
      }
    }
    return missing
  }

  public func areRequiredModelsAvailable() async -> Bool {
    await checkMissingModels().isEmpty
  }

  /// Legacy model info shim retained for API compatibility.
  public func getAllModelInfo() async -> [MLXModelLoader.ModelFile] {
    await modelLoader.allModels()
  }

  /// Managed MLX model info for settings/onboarding.
  public func getAllManagedModelInfo() async -> [MLXModelLoader.ManagedModelFile] {
    let ids = MLXModelCatalog.descriptors.map(\.modelID)
    let names = Dictionary(uniqueKeysWithValues: MLXModelCatalog.descriptors.map { ($0.modelID, $0.cacheFileName) })
    return await modelLoader.allModels(modelIDs: ids, cacheFileNames: names)
  }

  // MARK: - Download

  /// Compatibility API: downloads profile-mapped MLX model.
  public func downloadModel(_ model: ASRModelProfile) -> AsyncStream<ModelDownloadProgress> {
    let modelID = MLXModelCatalog.modelID(for: model)
    return downloadModel(modelID)
  }

  /// Downloads by canonical MLX model ID with resumable transfer.
  public func downloadModel(_ modelID: String) -> AsyncStream<ModelDownloadProgress> {
    AsyncStream { continuation in
      let canonicalModelID = MLXModelCatalog.resolveModelID(fromSettingsValue: modelID)
      guard let descriptor = MLXModelCatalog.descriptorByID[canonicalModelID] else {
        continuation.yield(ModelDownloadProgress(modelID: canonicalModelID, error: "Unsupported model ID"))
        continuation.finish()
        return
      }

      downloadTasks[descriptor.modelID]?.cancel()

      let producer = Task {
        await self.performDownload(descriptor, continuation: continuation)
      }

      downloadTasks[descriptor.modelID] = producer

      continuation.onTermination = { @Sendable _ in
        Task { await self.cancelDownload(descriptor.modelID) }
      }
    }
  }

  private func performDownload(
    _ descriptor: MLXModelDescriptor,
    continuation: AsyncStream<ModelDownloadProgress>.Continuation
  ) async {
    defer { downloadTasks.removeValue(forKey: descriptor.modelID) }

    do {
      try Task.checkCancellation()
      try await modelLoader.ensureModelsDirectoryExists()

      let destinationURL = await modelLoader.modelFilePath(
        forModelID: descriptor.modelID,
        cacheFileName: descriptor.cacheFileName
      )
      let partialURL = destinationURL.appendingPathExtension("partial")

      var resumedBytes: Int64 = 0
      if FileManager.default.fileExists(atPath: partialURL.path) {
        let attrs = try FileManager.default.attributesOfItem(atPath: partialURL.path)
        resumedBytes = attrs[.size] as? Int64 ?? 0
      }

      var request = URLRequest(url: descriptor.downloadURL)
      if resumedBytes > 0 {
        request.setValue("bytes=\(resumedBytes)-", forHTTPHeaderField: "Range")
      }

      let (bytes, response) = try await URLSession.shared.bytes(for: request)
      guard let http = response as? HTTPURLResponse else {
        continuation.yield(ModelDownloadProgress(modelID: descriptor.modelID, error: "Invalid response"))
        continuation.finish()
        return
      }

      guard http.statusCode == 200 || http.statusCode == 206 else {
        continuation.yield(
          ModelDownloadProgress(modelID: descriptor.modelID, error: "HTTP error: \(http.statusCode)")
        )
        continuation.finish()
        return
      }

      let appending = http.statusCode == 206 && resumedBytes > 0
      if !appending, FileManager.default.fileExists(atPath: partialURL.path) {
        try FileManager.default.removeItem(at: partialURL)
      }

      FileManager.default.createFile(atPath: partialURL.path, contents: nil)
      guard let handle = try? FileHandle(forWritingTo: partialURL) else {
        continuation.yield(ModelDownloadProgress(modelID: descriptor.modelID, error: "Unable to open cache file"))
        continuation.finish()
        return
      }
      defer { try? handle.close() }

      if appending {
        try handle.seekToEnd()
      } else {
        try handle.truncate(atOffset: 0)
      }

      let contentLength = response.expectedContentLength
      let totalBytes: Int64?
      if contentLength > 0 {
        totalBytes = appending ? resumedBytes + contentLength : contentLength
      } else {
        totalBytes = nil
      }

      var writtenBytes = resumedBytes
      continuation.yield(
        ModelDownloadProgress(
          model: descriptor.profile,
          modelID: descriptor.modelID,
          bytesDownloaded: writtenBytes,
          totalBytes: totalBytes
        )
      )

      var buffer = Data()
      let flushThreshold = 64 * 1024

      for try await byte in bytes {
        try Task.checkCancellation()
        buffer.append(byte)

        if buffer.count >= flushThreshold {
          try handle.write(contentsOf: buffer)
          writtenBytes += Int64(buffer.count)
          buffer.removeAll(keepingCapacity: true)

          continuation.yield(
            ModelDownloadProgress(
              model: descriptor.profile,
              modelID: descriptor.modelID,
              bytesDownloaded: writtenBytes,
              totalBytes: totalBytes
            )
          )
        }
      }

      if !buffer.isEmpty {
        try handle.write(contentsOf: buffer)
        writtenBytes += Int64(buffer.count)
      }

      guard descriptor.expectedSizeBytes.contains(writtenBytes) else {
        continuation.yield(
          ModelDownloadProgress(
            model: descriptor.profile,
            modelID: descriptor.modelID,
            bytesDownloaded: writtenBytes,
            totalBytes: totalBytes,
            error: "Downloaded file size (\(writtenBytes)) outside expected range"
          )
        )
        continuation.finish()
        return
      }

      try await modelLoader.registerModelID(
        descriptor.modelID,
        cacheFileName: descriptor.cacheFileName,
        from: partialURL,
        copy: false
      )

      continuation.yield(
        ModelDownloadProgress(
          model: descriptor.profile,
          modelID: descriptor.modelID,
          bytesDownloaded: writtenBytes,
          totalBytes: max(totalBytes ?? 0, writtenBytes),
          isComplete: true
        )
      )
      continuation.finish()
    } catch is CancellationError {
      continuation.finish()
    } catch {
      continuation.yield(ModelDownloadProgress(modelID: descriptor.modelID, error: error.localizedDescription))
      continuation.finish()
    }
  }

  public func downloadRequiredModels() -> AsyncStream<ModelDownloadProgress> {
    AsyncStream { continuation in
      let task = Task {
        let required = Self.requiredModels

        for profile in required {
          if Task.isCancelled {
            continuation.finish()
            return
          }

          for await progress in self.downloadModel(profile) {
            continuation.yield(progress)
            if progress.error != nil {
              continuation.finish()
              return
            }
          }
        }

        continuation.finish()
      }

      continuation.onTermination = { @Sendable _ in
        task.cancel()
      }
    }
  }

  // MARK: - Cancellation

  public func cancelDownload(_ model: ASRModelProfile) {
    cancelDownload(MLXModelCatalog.modelID(for: model))
  }

  public func cancelDownload(_ modelID: String) {
    let canonical = MLXModelCatalog.resolveModelID(fromSettingsValue: modelID)
    downloadTasks[canonical]?.cancel()
    downloadTasks.removeValue(forKey: canonical)
  }

  public func cancelAllDownloads() {
    for task in downloadTasks.values {
      task.cancel()
    }
    downloadTasks.removeAll()
  }

  // MARK: - Validation

  /// Compatibility API for profile validation.
  public func validateModel(_ model: ASRModelProfile) async -> Bool {
    let modelID = MLXModelCatalog.modelID(for: model)
    return await validateModelID(modelID)
  }

  public func validateModelID(_ modelID: String) async -> Bool {
    let canonical = MLXModelCatalog.resolveModelID(fromSettingsValue: modelID)
    guard let descriptor = MLXModelCatalog.descriptorByID[canonical] else { return false }

    let info = await modelLoader.modelInfo(
      forModelID: descriptor.modelID,
      cacheFileName: descriptor.cacheFileName
    )
    guard info.isAvailable, let size = info.sizeBytes else { return false }
    return descriptor.expectedSizeBytes.contains(size)
  }

  public func removeModel(_ model: ASRModelProfile) async throws {
    let modelID = MLXModelCatalog.modelID(for: model)
    try await removeModelID(modelID)
  }

  public func removeModelID(_ modelID: String) async throws {
    let canonical = MLXModelCatalog.resolveModelID(fromSettingsValue: modelID)
    guard let descriptor = MLXModelCatalog.descriptorByID[canonical] else { return }
    try await modelLoader.removeModelID(descriptor.modelID, cacheFileName: descriptor.cacheFileName)
  }

  // MARK: - Migration & Cleanup

  /// Removes legacy ggml artifacts only after MLX readiness succeeds.
  @discardableResult
  public func cleanupLegacyGGMLArtifactsIfReady() async throws -> [URL] {
    guard await areRequiredModelsAvailable() else { return [] }
    return try await modelLoader.removeLegacyGGMLFiles()
  }
}
