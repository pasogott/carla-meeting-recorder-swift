import XCTest

@testable import CarlaTranscription

final class WhisperModelManagerTests: XCTestCase {

  var tempDirectory: URL!
  var modelLoader: WhisperModelLoader!
  var modelManager: WhisperModelManager!

  override func setUp() async throws {
    try await super.setUp()

    // Create a temporary directory for testing
    tempDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("WhisperModelManagerTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

    modelLoader = WhisperModelLoader(modelsDirectory: tempDirectory)
    modelManager = WhisperModelManager(modelLoader: modelLoader)
  }

  override func tearDown() async throws {
    // Clean up temp directory
    if let tempDir = tempDirectory {
      try? FileManager.default.removeItem(at: tempDir)
    }
    try await super.tearDown()
  }

  // MARK: - Required Models

  func testRequiredModelsIncludesBase() {
    XCTAssertTrue(WhisperModelManager.requiredModels.contains(.base))
  }

  func testOptionalModelsExcludesBase() {
    XCTAssertFalse(WhisperModelManager.optionalModels.contains(.base))
    XCTAssertTrue(WhisperModelManager.optionalModels.contains(.small))
  }

  // MARK: - Model Availability

  func testCheckMissingModelsWhenNoneExist() async {
    let missing = await modelManager.checkMissingModels()
    XCTAssertEqual(missing, [.base])
  }

  func testAreRequiredModelsAvailableWhenMissing() async {
    let available = await modelManager.areRequiredModelsAvailable()
    XCTAssertFalse(available)
  }

  func testAreRequiredModelsAvailableWhenPresent() async throws {
    // Create a fake model file
    let modelPath = await modelLoader.modelFilePath(for: .base)
    let fakeData = Data(repeating: 0, count: 150_000_000)  // ~150MB of zeros
    try fakeData.write(to: modelPath)

    let available = await modelManager.areRequiredModelsAvailable()
    XCTAssertTrue(available)
  }

  // MARK: - Model Info

  func testGetAllModelInfo() async {
    let models = await modelManager.getAllModelInfo()
    XCTAssertEqual(models.count, 4)  // base, small, medium, large

    let modelTypes = models.map { $0.model }
    XCTAssertTrue(modelTypes.contains(.base))
    XCTAssertTrue(modelTypes.contains(.small))
    XCTAssertTrue(modelTypes.contains(.medium))
    XCTAssertTrue(modelTypes.contains(.large))
  }

  func testModelInfoShowsUnavailable() async {
    let models = await modelManager.getAllModelInfo()
    for model in models {
      XCTAssertFalse(model.isAvailable)
    }
  }

  // MARK: - Model Validation

  func testValidateModelReturnsFalseWhenMissing() async {
    let valid = await modelManager.validateModel(.base)
    XCTAssertFalse(valid)
  }

  func testValidateModelReturnsTrueWhenPresentWithValidSize() async throws {
    // Create a fake model file with size in expected range
    let modelPath = await modelLoader.modelFilePath(for: .base)
    let fakeData = Data(repeating: 0, count: 150_000_000)  // ~150MB
    try fakeData.write(to: modelPath)

    let valid = await modelManager.validateModel(.base)
    XCTAssertTrue(valid)
  }

  func testValidateModelReturnsFalseWhenWrongSize() async throws {
    // Create a file that's too small
    let modelPath = await modelLoader.modelFilePath(for: .base)
    let fakeData = Data(repeating: 0, count: 1000)  // Way too small
    try fakeData.write(to: modelPath)

    let valid = await modelManager.validateModel(.base)
    XCTAssertFalse(valid)
  }

  // MARK: - Download Progress

  func testModelDownloadProgressFormattedProgress() {
    let progress = ModelDownloadProgress(
      model: .base,
      bytesDownloaded: 75_000_000,
      totalBytes: 150_000_000
    )

    XCTAssertEqual(progress.fractionComplete, 0.5, accuracy: 0.01)
    XCTAssertFalse(progress.isComplete)
    XCTAssertNil(progress.error)
  }

  func testModelDownloadProgressComplete() {
    let progress = ModelDownloadProgress(
      model: .base,
      bytesDownloaded: 150_000_000,
      totalBytes: 150_000_000,
      isComplete: true
    )

    XCTAssertEqual(progress.fractionComplete, 1.0, accuracy: 0.01)
    XCTAssertTrue(progress.isComplete)
  }

  func testModelDownloadProgressWithError() {
    let progress = ModelDownloadProgress(
      model: .base,
      error: "Network unavailable"
    )

    XCTAssertFalse(progress.isComplete)
    XCTAssertEqual(progress.error, "Network unavailable")
  }
}
