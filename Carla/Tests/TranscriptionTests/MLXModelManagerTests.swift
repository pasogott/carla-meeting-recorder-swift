import XCTest

@testable import CarlaTranscription

final class MLXModelManagerTests: XCTestCase {

  var tempDirectory: URL!
  var modelLoader: MLXModelLoader!
  var modelManager: MLXModelManager!

  override func setUp() async throws {
    try await super.setUp()

    tempDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("MLXModelManagerTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

    modelLoader = MLXModelLoader(modelsDirectory: tempDirectory)
    modelManager = MLXModelManager(modelLoader: modelLoader)
  }

  override func tearDown() async throws {
    if let tempDir = tempDirectory {
      try? FileManager.default.removeItem(at: tempDir)
    }
    try await super.tearDown()
  }

  // MARK: - Catalog and Mapping

  func testResolveModelIDMapsLegacyValuesDeterministically() async {
    let baseID = await modelManager.resolveModelID(fromSettingsValue: "base")
    let smallID = await modelManager.resolveModelID(fromSettingsValue: "small")
    let mediumID = await modelManager.resolveModelID(fromSettingsValue: "medium")
    let largeID = await modelManager.resolveModelID(fromSettingsValue: "large")

    XCTAssertEqual(baseID, "mlx-community/whisper-base")
    XCTAssertEqual(smallID, "mlx-community/whisper-small")
    XCTAssertEqual(mediumID, "mlx-community/whisper-medium")
    XCTAssertEqual(largeID, "mlx-community/whisper-large-v3")
  }

  func testResolveModelIDKeepsCanonicalModelIDReadable() async {
    let existing = "mlx-community/whisper-small"
    let resolved = await modelManager.resolveModelID(fromSettingsValue: existing)
    XCTAssertEqual(resolved, existing)
  }

  func testResolveModelIDFallsBackToBase() async {
    let resolved = await modelManager.resolveModelID(fromSettingsValue: "unknown-model")
    XCTAssertEqual(resolved, "mlx-community/whisper-base")
  }

  // MARK: - Required Models

  func testRequiredModelsIncludesBase() {
    XCTAssertTrue(MLXModelManager.requiredModels.contains(.base))
  }

  func testOptionalModelsExcludesBase() {
    XCTAssertFalse(MLXModelManager.optionalModels.contains(.base))
    XCTAssertTrue(MLXModelManager.optionalModels.contains(.small))
  }

  // MARK: - Readiness and Validation

  func testAreRequiredModelsAvailableWhenMissing() async {
    let available = await modelManager.areRequiredModelsAvailable()
    XCTAssertFalse(available)
  }

  func testAreRequiredModelsAvailableWhenRequiredMLXArtifactExists() async throws {
    let descriptor = try XCTUnwrap(MLXModelCatalog.descriptorByProfile[.base])
    let modelURL = await modelLoader.modelFilePath(
      forModelID: descriptor.modelID,
      cacheFileName: descriptor.cacheFileName
    )
    try createFile(at: modelURL, size: descriptor.expectedSizeBytes.lowerBound)

    let available = await modelManager.areRequiredModelsAvailable()
    XCTAssertTrue(available)
  }

  func testValidateModelReturnsFalseWhenWrongSize() async throws {
    let descriptor = try XCTUnwrap(MLXModelCatalog.descriptorByProfile[.base])
    let modelURL = await modelLoader.modelFilePath(
      forModelID: descriptor.modelID,
      cacheFileName: descriptor.cacheFileName
    )
    try createFile(at: modelURL, size: 1024)

    let valid = await modelManager.validateModel(.base)
    XCTAssertFalse(valid)
  }

  // MARK: - Legacy Cleanup Gating

  func testCleanupLegacyGGMLArtifactsDoesNotRunWhenMLXNotReady() async throws {
    let legacyPath = await modelLoader.modelFilePath(for: .base)
    try createFile(at: legacyPath, size: 4096)

    let removed = try await modelManager.cleanupLegacyGGMLArtifactsIfReady()
    XCTAssertTrue(removed.isEmpty)

    var isDirectory = ObjCBool(false)
    let stillExists = FileManager.default.fileExists(atPath: legacyPath.path, isDirectory: &isDirectory)
    XCTAssertTrue(stillExists)
    XCTAssertFalse(isDirectory.boolValue)
  }

  func testCleanupLegacyGGMLArtifactsRunsAfterMLXReadiness() async throws {
    let descriptor = try XCTUnwrap(MLXModelCatalog.descriptorByProfile[.base])
    let modelURL = await modelLoader.modelFilePath(
      forModelID: descriptor.modelID,
      cacheFileName: descriptor.cacheFileName
    )
    try createFile(at: modelURL, size: descriptor.expectedSizeBytes.lowerBound)

    let legacyBase = await modelLoader.modelFilePath(for: .base)
    let legacySmall = await modelLoader.modelFilePath(for: .small)
    try createFile(at: legacyBase, size: 4096)
    try createFile(at: legacySmall, size: 4096)

    let removed = try await modelManager.cleanupLegacyGGMLArtifactsIfReady()

    XCTAssertEqual(Set(removed), Set([legacyBase, legacySmall]))
    XCTAssertFalse(FileManager.default.fileExists(atPath: legacyBase.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: legacySmall.path))
  }

  // MARK: - Download Progress

  func testModelDownloadProgressFormattedProgress() {
    let progress = ModelDownloadProgress(
      model: .base,
      modelID: "mlx-community/whisper-base",
      bytesDownloaded: 75_000_000,
      totalBytes: 150_000_000
    )

    XCTAssertEqual(progress.fractionComplete, 0.5, accuracy: 0.01)
    XCTAssertFalse(progress.isComplete)
    XCTAssertNil(progress.error)
  }

  func testModelDownloadProgressComplete() {
    let progress = ModelDownloadProgress(
      modelID: "mlx-community/whisper-base",
      bytesDownloaded: 150_000_000,
      totalBytes: 150_000_000,
      isComplete: true
    )

    XCTAssertEqual(progress.fractionComplete, 1.0, accuracy: 0.01)
    XCTAssertTrue(progress.isComplete)
  }

  func testModelDownloadProgressWithError() {
    let progress = ModelDownloadProgress(
      modelID: "mlx-community/whisper-base",
      error: "Network unavailable"
    )

    XCTAssertFalse(progress.isComplete)
    XCTAssertEqual(progress.error, "Network unavailable")
  }

  // MARK: - Helpers

  private func createFile(at url: URL, size: Int64) throws {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: UInt64(size))
  }
}
