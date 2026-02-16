import XCTest

@testable import CarlaTranscription

final class WhisperCPPBindingTests: XCTestCase {

  // MARK: - Model Loader Tests

  func testModelLoaderReturnsCorrectFilenames() async {
    let loader = WhisperModelLoader()

    let baseName = await loader.modelFileName(for: .base)
    let smallName = await loader.modelFileName(for: .small)
    let mediumName = await loader.modelFileName(for: .medium)
    let largeName = await loader.modelFileName(for: .large)

    XCTAssertEqual(baseName, "ggml-base.bin")
    XCTAssertEqual(smallName, "ggml-small.bin")
    XCTAssertEqual(mediumName, "ggml-medium.bin")
    XCTAssertEqual(largeName, "ggml-large.bin")
  }

  func testModelLoaderDirectoryIsInApplicationSupport() async {
    let dir = WhisperModelLoader.defaultModelsDirectory
    XCTAssertTrue(dir.path.contains("Application Support"))
    XCTAssertTrue(dir.path.contains("Carla"))
  }

  func testModelLoaderReportsUnavailableModel() async {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let loader = WhisperModelLoader(modelsDirectory: tempDir)

    let available = await loader.isModelAvailable(.base)
    XCTAssertFalse(available)

    let info = await loader.modelInfo(for: .base)
    XCTAssertFalse(info.isAvailable)
    XCTAssertNil(info.sizeBytes)
  }

  func testModelLoaderThrowsWhenModelNotFound() async {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let loader = WhisperModelLoader(modelsDirectory: tempDir)

    do {
      _ = try await loader.requireModelPath(for: .base)
      XCTFail("Expected error")
    } catch let error as WhisperModelLoader.ModelLoaderError {
      if case .modelNotFound(let model) = error {
        XCTAssertEqual(model, .base)
      } else {
        XCTFail("Unexpected error type: \(error)")
      }
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testModelLoaderDownloadURLsPointToHuggingFace() async {
    let loader = WhisperModelLoader()

    let url = await loader.downloadURL(for: .base)
    XCTAssertTrue(url.absoluteString.contains("huggingface.co"))
    XCTAssertTrue(url.absoluteString.contains("ggml-base.bin"))
  }

  // MARK: - Binding Error Tests

  func testBindingThrowsOnMissingModel() async {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let loader = WhisperModelLoader(modelsDirectory: tempDir)
    let binding = WhisperCPPBindingImpl(modelLoader: loader)

    do {
      _ = try await binding.transcribePCM(
        samples: [0.1, 0.2, 0.3],
        sampleRate: 16000,
        model: .base,
        languageHint: nil
      )
      XCTFail("Expected error")
    } catch let error as WhisperModelLoader.ModelLoaderError {
      if case .modelNotFound = error {
        // Expected
      } else {
        XCTFail("Unexpected error type: \(error)")
      }
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testBindingThrowsOnMissingFile() async {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let loader = WhisperModelLoader(modelsDirectory: tempDir)
    let binding = WhisperCPPBindingImpl(modelLoader: loader)

    let nonExistentURL = URL(fileURLWithPath: "/nonexistent/audio.wav")

    do {
      _ = try await binding.transcribeFile(
        fileURL: nonExistentURL,
        model: .base,
        languageHint: nil
      )
      XCTFail("Expected error")
    } catch let error as WhisperBindingError {
      if case .fileNotFound = error {
        // Expected
      } else {
        XCTFail("Unexpected error type: \(error)")
      }
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  // MARK: - Integration Tests (Gated)

  /// This test requires a real whisper model to be installed.
  /// Run with: swift test --filter testRealTranscriptionWithModel
  /// After downloading a model to ~/Library/Application Support/Carla/Models/ggml-base.bin
  func testRealTranscriptionWithModel() async throws {
    let loader = WhisperModelLoader()

    // Skip if model not available
    let available = await loader.isModelAvailable(.base)
    guard available else {
      throw XCTSkip("Whisper base model not installed - download from HuggingFace to run this test")
    }

    let binding = WhisperCPPBindingImpl(modelLoader: loader)

    // Generate 1 second of silence at 16kHz
    let samples = [Float](repeating: 0, count: 16000)

    let result = try await binding.transcribePCM(
      samples: samples,
      sampleRate: 16000,
      model: .base,
      languageHint: .autoDetect
    )

    // Silence should produce no or very few segments
    XCTAssertTrue(result.segments.count <= 1, "Expected minimal segments for silence")
  }
}
