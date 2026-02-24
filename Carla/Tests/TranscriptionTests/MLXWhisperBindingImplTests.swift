import Foundation
import XCTest

@testable import CarlaTranscription

final class MLXWhisperBindingImplTests: XCTestCase {
  private var tempDirectory: URL!
  private var modelLoader: MLXModelLoader!
  private var modelManager: MLXModelManager!

  override func setUp() async throws {
    try await super.setUp()
    tempDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("MLXWhisperBindingImplTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

    modelLoader = MLXModelLoader(modelsDirectory: tempDirectory)
    modelManager = MLXModelManager(modelLoader: modelLoader)
  }

  override func tearDown() async throws {
    if let tempDirectory {
      try? FileManager.default.removeItem(at: tempDirectory)
    }
    try await super.tearDown()
  }

  func testTranscribePCMReturnsNonEmptySegmentsFromRuntimeFixture() async throws {
    try await makeModelReady(modelID: "mlx-community/whisper-base")

    let runtime = FixtureRuntime(
      response: MLXRuntimeTranscription(
        detectedLanguageCode: "de",
        segments: [
          MLXRuntimeSegment(startSeconds: 0.12, endSeconds: 0.88, text: " Hallo Welt ", confidence: 0.92)
        ]
      )
    )

    let binding = MLXWhisperBindingImpl(modelManager: modelManager, runtime: runtime)
    let samples = (0..<1_600).map { i in sin(Float(i) * 0.05) * 0.2 }

    let payload = try await binding.transcribePCM(
      samples: samples,
      sampleRate: 16_000,
      modelID: "mlx-community/whisper-base",
      languageCode: "de"
    )

    XCTAssertEqual(payload.detectedLanguageCode, "de")
    XCTAssertFalse(payload.segments.isEmpty)
    XCTAssertEqual(payload.segments[0].text, " Hallo Welt ")

    let recorded = await runtime.recordedRequest()
    let request = try XCTUnwrap(recorded)
    XCTAssertEqual(request.modelID, "mlx-community/whisper-base")
    XCTAssertEqual(request.languageCode, "de")
    XCTAssertEqual(request.audioFileURL.pathExtension, "wav")
  }

  func testTranscribeFileReturnsFixtureSegments() async throws {
    try await makeModelReady(modelID: "mlx-community/whisper-small")

    let fixtureFile = tempDirectory.appendingPathComponent("fixture.wav")
    try Data([0x00, 0x01, 0x02]).write(to: fixtureFile)

    let runtime = FixtureRuntime(
      response: MLXRuntimeTranscription(
        detectedLanguageCode: "en",
        segments: [
          MLXRuntimeSegment(startSeconds: 0.0, endSeconds: 1.2, text: "fixture", confidence: nil)
        ]
      )
    )

    let binding = MLXWhisperBindingImpl(modelManager: modelManager, runtime: runtime)
    let payload = try await binding.transcribeFile(
      fileURL: fixtureFile,
      modelID: "mlx-community/whisper-small",
      languageCode: nil
    )

    XCTAssertEqual(payload.segments.count, 1)
    XCTAssertEqual(payload.segments[0].startMs, 0)
    XCTAssertEqual(payload.segments[0].endMs, 1200)
    XCTAssertEqual(payload.segments[0].text, "fixture")
  }

  func testTranscribeMapsUnsupportedLanguageDeterministically() async throws {
    try await makeModelReady(modelID: "mlx-community/whisper-base")

    let runtime = FixtureRuntime(
      error: MLXWhisperLibraryError.libraryFailure(code: 2, message: "Unsupported language: FR")
    )

    let binding = MLXWhisperBindingImpl(modelManager: modelManager, runtime: runtime)

    do {
      _ = try await binding.transcribePCM(
        samples: [0.0, 0.1, -0.1],
        sampleRate: 16_000,
        modelID: "mlx-community/whisper-base",
        languageCode: "fr"
      )
      XCTFail("Expected unsupported language error")
    } catch {
      XCTAssertEqual(error as? MLXWhisperLibraryError, .unsupportedLanguage("fr"))
    }
  }

  func testTranscribeFailsWhenModelNotReady() async {
    let runtime = FixtureRuntime(
      response: MLXRuntimeTranscription(detectedLanguageCode: "en", segments: [])
    )
    let binding = MLXWhisperBindingImpl(modelManager: modelManager, runtime: runtime)

    do {
      _ = try await binding.transcribePCM(
        samples: [0.0, 0.1],
        sampleRate: 16_000,
        modelID: "mlx-community/whisper-base",
        languageCode: "en"
      )
      XCTFail("Expected model not found error")
    } catch {
      XCTAssertEqual(error as? MLXWhisperLibraryError, .modelNotFound("mlx-community/whisper-base"))
    }
  }

  private func makeModelReady(modelID: String) async throws {
    let descriptor = try XCTUnwrap(MLXModelCatalog.descriptorByID[modelID])
    let modelURL = await modelLoader.modelFilePath(
      forModelID: descriptor.modelID,
      cacheFileName: descriptor.cacheFileName
    )

    FileManager.default.createFile(atPath: modelURL.path, contents: nil)
    let handle = try FileHandle(forWritingTo: modelURL)
    defer { try? handle.close() }
    try handle.truncate(atOffset: UInt64(descriptor.expectedSizeBytes.lowerBound))
  }
}

private actor FixtureRuntime: MLXWhisperRuntime {
  private var lastRequest: MLXRuntimeTranscriptionRequest?
  private let response: MLXRuntimeTranscription?
  private let error: Error?

  init(response: MLXRuntimeTranscription) {
    self.response = response
    self.error = nil
  }

  init(error: Error) {
    self.response = nil
    self.error = error
  }

  func transcribe(_ request: MLXRuntimeTranscriptionRequest) async throws -> MLXRuntimeTranscription {
    lastRequest = request
    if let error {
      throw error
    }
    return response ?? MLXRuntimeTranscription(detectedLanguageCode: nil, segments: [])
  }

  func recordedRequest() -> MLXRuntimeTranscriptionRequest? {
    lastRequest
  }
}
