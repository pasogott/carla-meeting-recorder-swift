import XCTest

@testable import CarlaTranscription

final class MLXErrorUXTests: XCTestCase {
  func testGuidanceCoversRequiredCategories() {
    XCTAssertEqual(MLXErrorUX.guidance(for: "network timeout while downloading").category, .network)
    XCTAssertEqual(MLXErrorUX.guidance(for: "HTTP error: 503").category, .http)
    XCTAssertEqual(MLXErrorUX.guidance(for: "No space left on device").category, .diskFull)
    XCTAssertEqual(MLXErrorUX.guidance(for: "checksum mismatch for model.bin").category, .corruptArtifacts)
    XCTAssertEqual(MLXErrorUX.guidance(for: "Operation not permitted writing cache").category, .permissionDenied)
    XCTAssertEqual(MLXErrorUX.guidance(for: "MLX transcription requires Apple Silicon").category, .unsupportedHardware)
  }

  func testGuidanceFromModelErrors() {
    let missing = MLXErrorUX.guidance(for: MLXWhisperLibraryError.modelNotFound("mlx-community/whisper-medium"))
    XCTAssertEqual(missing.category, .corruptArtifacts)

    let failed = MLXErrorUX.guidance(for: MLXWhisperLibraryError.runtimeFailure("network unavailable"))
    XCTAssertEqual(failed.category, .network)
  }
}
