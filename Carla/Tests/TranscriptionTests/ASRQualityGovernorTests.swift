import XCTest

@testable import CarlaTranscription

final class ASRQualityGovernorTests: XCTestCase {
  func testGovernorMovesToRealtimeSafeAfterSustainedPressure() {
    var governor = RuntimeASRQualityGovernor(
      preferredModel: .medium,
      preferredChunkDuration: 2.0,
      configuration: ASRQualityGovernorConfiguration(
        pressureConsecutiveEvaluations: 2,
        stableConsecutiveEvaluations: 2,
        cooldownEvaluations: 0
      )
    )

    let pressure = ASRQualitySignals(
      latencySLABreached: true,
      queueDepth: 5,
      thermalState: .serious,
      memoryPressure: false,
      lowPowerModeEnabled: false
    )

    XCTAssertNil(governor.evaluate(signals: pressure))
    let transition = governor.evaluate(signals: pressure)

    XCTAssertEqual(transition?.to, .realtimeSafe)
    XCTAssertEqual(governor.currentDecision.profile, .realtimeSafe)
    XCTAssertEqual(governor.currentDecision.decodePolicy, .fast)
  }

  func testGovernorReturnsToBalancedAfterStableCooldown() {
    var governor = RuntimeASRQualityGovernor(
      preferredModel: .base,
      preferredChunkDuration: 2.0,
      configuration: ASRQualityGovernorConfiguration(
        pressureConsecutiveEvaluations: 1,
        stableConsecutiveEvaluations: 2,
        cooldownEvaluations: 1
      )
    )

    let pressure = ASRQualitySignals(
      latencySLABreached: true,
      queueDepth: 3,
      thermalState: .serious,
      memoryPressure: false,
      lowPowerModeEnabled: false
    )

    _ = governor.evaluate(signals: pressure)
    XCTAssertEqual(governor.currentDecision.profile, .realtimeSafe)

    let stable = ASRQualitySignals(
      latencySLABreached: false,
      queueDepth: 0,
      thermalState: .nominal,
      memoryPressure: false,
      lowPowerModeEnabled: false
    )

    XCTAssertNil(governor.evaluate(signals: stable))
    let transition = governor.evaluate(signals: stable)

    XCTAssertEqual(transition?.to, .balanced)
    XCTAssertEqual(governor.currentDecision.profile, .balanced)
  }

  func testGovernorConfigurationSanitizesNonFiniteInputs() {
    let configuration = ASRQualityGovernorConfiguration(
      latencySLAMs: .nan,
      memoryPressureRatioThreshold: .infinity
    )
    XCTAssertEqual(configuration.latencySLAMs, 2_500, accuracy: 0.0001)
    XCTAssertEqual(configuration.memoryPressureRatioThreshold, 0.70, accuracy: 0.0001)

    let governor = RuntimeASRQualityGovernor(
      preferredModel: .base,
      preferredChunkDuration: .nan,
      configuration: configuration
    )
    XCTAssertEqual(governor.currentDecision.chunkDuration, 1.0, accuracy: 0.0001)
  }
}
