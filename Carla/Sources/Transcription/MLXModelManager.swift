import CryptoKit
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

public enum MLXModelValidationError: Error, Sendable, Equatable {
  case unsupportedModelID(String)
  case artifactContractMissing(modelID: String, relativePath: String)
  case checksumMissing(modelID: String, relativePath: String)
  case fileMissing(modelID: String, path: URL)
  case checksumComputationFailed(modelID: String, path: URL)
  case checksumMismatch(modelID: String, relativePath: String, expected: String, actual: String)

  public var message: String {
    switch self {
    case .unsupportedModelID(let modelID):
      return "Unsupported model ID: \(modelID)"
    case .artifactContractMissing(let modelID, let relativePath):
      return "Artifact contract missing for \(modelID): \(relativePath)"
    case .checksumMissing(let modelID, let relativePath):
      return "Missing checksum for \(modelID): \(relativePath)"
    case .fileMissing(let modelID, let path):
      return "Required artifact missing for \(modelID): \(path.lastPathComponent)"
    case .checksumComputationFailed(let modelID, let path):
      return "Unable to compute checksum for \(modelID): \(path.lastPathComponent)"
    case .checksumMismatch(let modelID, let relativePath, let expected, let actual):
      return "Checksum mismatch for \(modelID)/\(relativePath). Expected \(expected), got \(actual)"
    }
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
      guard await validationError(forModelID: modelID) == nil else {
        missing.append(profile)
        continue
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
      let stagingURL = destinationURL.appendingPathExtension("staging")

      try ensureDirectory(at: stagingURL)

      var downloadedBytes = try existingDownloadedBytes(in: stagingURL, artifacts: descriptor.requiredArtifacts)
      continuation.yield(
        ModelDownloadProgress(
          model: descriptor.profile,
          modelID: descriptor.modelID,
          bytesDownloaded: downloadedBytes,
          totalBytes: nil
        )
      )

      for artifact in descriptor.requiredArtifacts {
        try Task.checkCancellation()

        let artifactURL = try safeArtifactURL(root: stagingURL, relativePath: artifact.relativePath)
        if FileManager.default.fileExists(atPath: artifactURL.path) {
          continue
        }

        let result = try await downloadArtifact(
          artifact,
          to: artifactURL,
          modelID: descriptor.modelID,
          model: descriptor.profile,
          alreadyDownloadedBytes: downloadedBytes,
          continuation: continuation
        )

        downloadedBytes += result.bytesDownloaded
      }

      try atomicallyFinalizeModel(fromStaging: stagingURL, to: destinationURL)

      continuation.yield(
        ModelDownloadProgress(
          model: descriptor.profile,
          modelID: descriptor.modelID,
          bytesDownloaded: downloadedBytes,
          totalBytes: downloadedBytes,
          isComplete: true
        )
      )
      continuation.finish()
    } catch is CancellationError {
      continuation.finish()
    } catch {
      let categorized = categorizeDownloadError(error)
      continuation.yield(
        ModelDownloadProgress(
          model: descriptor.profile,
          modelID: descriptor.modelID,
          error: categorized.message
        )
      )
      continuation.finish()
    }
  }

  private struct ArtifactDownloadResult {
    let bytesDownloaded: Int64
  }

  enum ModelDownloadErrorCategory: String, Sendable {
    case networkUnreachable
    case httpStatusFailure
    case diskFull
    case permissionDenied
    case corruptedArtifacts
    case invalidResponse
    case invalidManifestPath
    case unknown
  }

  struct CategorizedDownloadError: Error {
    let category: ModelDownloadErrorCategory
    let detail: String

    var message: String {
      switch category {
      case .networkUnreachable:
        return "Network unreachable while downloading model artifacts. Check your connection and retry."
      case .httpStatusFailure:
        return "Model artifact download failed due to server response. Retry in a few minutes."
      case .diskFull:
        return "Download failed: not enough disk space for model artifacts. Free space and retry."
      case .permissionDenied:
        return "Download failed: insufficient permissions to write model artifacts."
      case .corruptedArtifacts:
        return "Downloaded artifacts appear corrupted. Delete model files and retry."
      case .invalidResponse:
        return "Download failed: invalid server response."
      case .invalidManifestPath:
        return "Download failed due to invalid artifact path in manifest."
      case .unknown:
        return "Download failed: \(detail)"
      }
    }
  }

  private func categorizeDownloadError(_ error: Error) -> CategorizedDownloadError {
    if let categorized = error as? CategorizedDownloadError {
      return categorized
    }

    if let urlError = error as? URLError {
      switch urlError.code {
      case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
           .internationalRoamingOff, .callIsActive, .dataNotAllowed, .timedOut:
        return CategorizedDownloadError(category: .networkUnreachable, detail: urlError.localizedDescription)
      case .noPermissionsToReadFile, .userAuthenticationRequired, .userCancelledAuthentication:
        return CategorizedDownloadError(category: .permissionDenied, detail: urlError.localizedDescription)
      default:
        return CategorizedDownloadError(category: .unknown, detail: urlError.localizedDescription)
      }
    }

    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain {
      switch nsError.code {
      case NSFileWriteOutOfSpaceError:
        return CategorizedDownloadError(category: .diskFull, detail: nsError.localizedDescription)
      case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
        return CategorizedDownloadError(category: .permissionDenied, detail: nsError.localizedDescription)
      default:
        break
      }
    }

    return CategorizedDownloadError(category: .unknown, detail: nsError.localizedDescription)
  }

  private func existingDownloadedBytes(in stagingRoot: URL, artifacts: [MLXModelArtifact]) throws -> Int64 {
    var total: Int64 = 0
    for artifact in artifacts {
      let artifactURL = try safeArtifactURL(root: stagingRoot, relativePath: artifact.relativePath)
      if FileManager.default.fileExists(atPath: artifactURL.path) {
        total += fileSize(at: artifactURL)
        continue
      }

      let partial = artifactURL.appendingPathExtension("partial")
      if FileManager.default.fileExists(atPath: partial.path) {
        total += fileSize(at: partial)
      }
    }
    return total
  }

  private func downloadArtifact(
    _ artifact: MLXModelArtifact,
    to artifactURL: URL,
    modelID: String,
    model: ASRModelProfile,
    alreadyDownloadedBytes: Int64,
    continuation: AsyncStream<ModelDownloadProgress>.Continuation
  ) async throws -> ArtifactDownloadResult {
    let fileManager = FileManager.default
    try ensureDirectory(at: artifactURL.deletingLastPathComponent())

    let partialURL = artifactURL.appendingPathExtension("partial")
    let resumedBytes = fileManager.fileExists(atPath: partialURL.path) ? fileSize(at: partialURL) : 0

    var request = URLRequest(url: artifact.sourceURL)
    if resumedBytes > 0 {
      request.setValue("bytes=\(resumedBytes)-", forHTTPHeaderField: "Range")
    }

    let (bytes, response) = try await URLSession.shared.bytes(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw CategorizedDownloadError(category: .invalidResponse, detail: "non-http response")
    }

    guard http.statusCode == 200 || http.statusCode == 206 else {
      throw CategorizedDownloadError(category: .httpStatusFailure, detail: "HTTP \(http.statusCode)")
    }

    let appending = http.statusCode == 206 && resumedBytes > 0
    if !appending, fileManager.fileExists(atPath: partialURL.path) {
      try fileManager.removeItem(at: partialURL)
    }

    fileManager.createFile(atPath: partialURL.path, contents: nil)
    let handle = try FileHandle(forWritingTo: partialURL)
    defer { try? handle.close() }

    if appending {
      try handle.seekToEnd()
    } else {
      try handle.truncate(atOffset: 0)
    }

    var written = resumedBytes
    var buffer = Data()
    let flushThreshold = 64 * 1024

    for try await byte in bytes {
      try Task.checkCancellation()
      buffer.append(byte)

      if buffer.count >= flushThreshold {
        try handle.write(contentsOf: buffer)
        written += Int64(buffer.count)
        buffer.removeAll(keepingCapacity: true)

        continuation.yield(
          ModelDownloadProgress(
            model: model,
            modelID: modelID,
            bytesDownloaded: alreadyDownloadedBytes + written,
            totalBytes: nil
          )
        )
      }
    }

    if !buffer.isEmpty {
      try handle.write(contentsOf: buffer)
      written += Int64(buffer.count)
    }

    if let expectedChecksum = normalizedChecksum(artifact.checksumSHA256) {
      guard let actualChecksum = computeSHA256Hex(for: partialURL), actualChecksum == expectedChecksum else {
        throw CategorizedDownloadError(category: .corruptedArtifacts, detail: artifact.relativePath)
      }
    }

    if fileManager.fileExists(atPath: artifactURL.path) {
      try fileManager.removeItem(at: artifactURL)
    }
    try fileManager.moveItem(at: partialURL, to: artifactURL)

    return ArtifactDownloadResult(bytesDownloaded: written)
  }

  private func safeArtifactURL(root: URL, relativePath: String) throws -> URL {
    let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
      !trimmed.hasPrefix("/"),
      !trimmed.split(separator: "/").contains("..")
    else {
      throw CategorizedDownloadError(category: .invalidManifestPath, detail: relativePath)
    }

    return root.appendingPathComponent(trimmed)
  }

  private func ensureDirectory(at url: URL) throws {
    var isDirectory = ObjCBool(false)
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
      if isDirectory.boolValue { return }
      try FileManager.default.removeItem(at: url)
    }

    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  private func atomicallyFinalizeModel(fromStaging stagingURL: URL, to destinationURL: URL) throws {
    let fileManager = FileManager.default
    let backupURL = destinationURL.appendingPathExtension("backup")

    if fileManager.fileExists(atPath: backupURL.path) {
      try fileManager.removeItem(at: backupURL)
    }

    if fileManager.fileExists(atPath: destinationURL.path) {
      try fileManager.moveItem(at: destinationURL, to: backupURL)
    }

    do {
      try fileManager.moveItem(at: stagingURL, to: destinationURL)
      if fileManager.fileExists(atPath: backupURL.path) {
        try fileManager.removeItem(at: backupURL)
      }
    } catch {
      if fileManager.fileExists(atPath: destinationURL.path) {
        try? fileManager.removeItem(at: destinationURL)
      }
      if fileManager.fileExists(atPath: backupURL.path) {
        try? fileManager.moveItem(at: backupURL, to: destinationURL)
      }
      throw error
    }
  }

  private func fileSize(at url: URL) -> Int64 {
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    return attrs?[.size] as? Int64 ?? 0
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
    await validationError(forModelID: modelID) == nil
  }

  public func validationError(forModelID modelID: String) async -> MLXModelValidationError? {
    let canonical = MLXModelCatalog.resolveModelID(fromSettingsValue: modelID)
    guard let descriptor = MLXModelCatalog.descriptorByID[canonical] else {
      return .unsupportedModelID(canonical)
    }

    let modelURL = await modelLoader.modelFilePath(
      forModelID: descriptor.modelID,
      cacheFileName: descriptor.cacheFileName
    )
    return validatePrimaryArtifact(descriptor: descriptor, artifactURL: modelURL)
  }

  private func validatePrimaryArtifact(
    descriptor: MLXModelDescriptor,
    artifactURL: URL
  ) -> MLXModelValidationError? {
    guard let primaryArtifact = descriptor.requiredArtifacts.first(where: { $0.relativePath == "model.bin" }) else {
      return .artifactContractMissing(modelID: descriptor.modelID, relativePath: "model.bin")
    }

    guard let checksum = normalizedChecksum(primaryArtifact.checksumSHA256) else {
      return .checksumMissing(modelID: descriptor.modelID, relativePath: primaryArtifact.relativePath)
    }

    guard FileManager.default.fileExists(atPath: artifactURL.path) else {
      return .fileMissing(modelID: descriptor.modelID, path: artifactURL)
    }

    guard let actual = computeSHA256Hex(for: artifactURL) else {
      return .checksumComputationFailed(modelID: descriptor.modelID, path: artifactURL)
    }

    guard actual == checksum else {
      return .checksumMismatch(
        modelID: descriptor.modelID,
        relativePath: primaryArtifact.relativePath,
        expected: checksum,
        actual: actual
      )
    }

    return nil
  }

  private func normalizedChecksum(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard normalized.count == 64 else { return nil }
    guard normalized.allSatisfy({ $0.isHexDigit }) else { return nil }
    return normalized
  }

  private func computeSHA256Hex(for url: URL) -> String? {
    guard let stream = InputStream(url: url) else { return nil }
    stream.open()
    defer { stream.close() }

    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 1024 * 1024)

    while stream.hasBytesAvailable {
      let read = stream.read(&buffer, maxLength: buffer.count)
      if read < 0 {
        return nil
      }
      if read == 0 {
        break
      }
      hasher.update(data: Data(buffer.prefix(read)))
    }

    let digest = hasher.finalize()
    return digest.map { String(format: "%02x", $0) }.joined()
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
