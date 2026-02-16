import XCTest

@testable import CarlaAudio

final class AudioPCMUtilitiesTests: XCTestCase {
  func testRMSAndPeak() {
    let samples: [Float] = [0.0, 0.5, -0.5, 1.0]

    let rms = AudioPCMUtilities.rms(samples)
    let peak = AudioPCMUtilities.peak(samples)

    XCTAssertEqual(peak, 1.0, accuracy: 0.0001)
    XCTAssertEqual(rms, 0.61237, accuracy: 0.0001)
  }

}
