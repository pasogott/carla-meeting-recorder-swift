import Foundation

/// Runtime quality profile used to balance throughput, latency, and fidelity.
public enum ASRQualityProfile: String, Sendable, Codable, Equatable {
  case quality
  case balanced
  case realtimeSafe
}

/// Decode aggressiveness selected by the quality governor.
public enum ASRDecodePolicy: String, Sendable, Codable, Equatable {
  case accurate
  case balanced
  case fast
}

/// Effective runtime decision produced by the quality governor.
public struct ASRQualityDecision: Sendable, Equatable {
  public let profile: ASRQualityProfile
  public let model: ASRModelProfile
  public let chunkDuration: TimeInterval
  public let decodePolicy: ASRDecodePolicy

  public init(
    profile: ASRQualityProfile,
    model: ASRModelProfile,
    chunkDuration: TimeInterval,
    decodePolicy: ASRDecodePolicy
  ) {
    self.profile = profile
    self.model = model
    self.chunkDuration = chunkDuration
    self.decodePolicy = decodePolicy
  }
}

/// Runtime signals consumed by the quality governor.
public struct ASRQualitySignals: Sendable, Equatable {
  public let latencySLABreached: Bool
  public let queueDepth: Int
  public let thermalState: ProcessInfo.ThermalState
  public let memoryPressure: Bool
  public let lowPowerModeEnabled: Bool

  public init(
    latencySLABreached: Bool,
    queueDepth: Int,
    thermalState: ProcessInfo.ThermalState,
    memoryPressure: Bool,
    lowPowerModeEnabled: Bool
  ) {
    self.latencySLABreached = latencySLABreached
    self.queueDepth = queueDepth
    self.thermalState = thermalState
    self.memoryPressure = memoryPressure
    self.lowPowerModeEnabled = lowPowerModeEnabled
  }
}

/// Transition emitted when profile changes.
public struct ASRQualityTransition: Sendable, Equatable {
  public let from: ASRQualityProfile
  public let to: ASRQualityProfile
  public let reason: String
  public let decision: ASRQualityDecision
  public let timestamp: Date

  public init(
    from: ASRQualityProfile,
    to: ASRQualityProfile,
    reason: String,
    decision: ASRQualityDecision,
    timestamp: Date = Date()
  ) {
    self.from = from
    self.to = to
    self.reason = reason
    self.decision = decision
    self.timestamp = timestamp
  }
}

/// Tunables for hysteresis/cooldown and pressure thresholds.
public struct ASRQualityGovernorConfiguration: Sendable, Equatable {
  public let latencySLAMs: Double
  public let highQueueDepthThreshold: Int
  public let mediumQueueDepthThreshold: Int
  public let memoryPressureRatioThreshold: Double
  public let pressureConsecutiveEvaluations: Int
  public let stableConsecutiveEvaluations: Int
  public let cooldownEvaluations: Int

  public init(
    latencySLAMs: Double = 2_500,
    highQueueDepthThreshold: Int = 3,
    mediumQueueDepthThreshold: Int = 1,
    memoryPressureRatioThreshold: Double = 0.70,
    pressureConsecutiveEvaluations: Int = 2,
    stableConsecutiveEvaluations: Int = 3,
    cooldownEvaluations: Int = 2
  ) {
    self.latencySLAMs = (latencySLAMs.isFinite && latencySLAMs > 0) ? latencySLAMs : 2_500
    self.highQueueDepthThreshold = max(1, highQueueDepthThreshold)
    self.mediumQueueDepthThreshold = max(0, mediumQueueDepthThreshold)
    if memoryPressureRatioThreshold.isFinite {
      self.memoryPressureRatioThreshold = min(max(memoryPressureRatioThreshold, 0.1), 0.95)
    } else {
      self.memoryPressureRatioThreshold = 0.70
    }
    self.pressureConsecutiveEvaluations = max(1, pressureConsecutiveEvaluations)
    self.stableConsecutiveEvaluations = max(1, stableConsecutiveEvaluations)
    self.cooldownEvaluations = max(0, cooldownEvaluations)
  }
}

/// Stateful runtime governor that provides a single adaptive control plane.
public struct RuntimeASRQualityGovernor: Sendable {
  private let preferredModel: ASRModelProfile
  private let preferredChunkDuration: TimeInterval
  private let configuration: ASRQualityGovernorConfiguration

  private(set) public var currentDecision: ASRQualityDecision

  private var consecutivePressure = 0
  private var consecutiveStable = 0
  private var evaluationsSinceTransition = 0

  public init(
    preferredModel: ASRModelProfile,
    preferredChunkDuration: TimeInterval,
    configuration: ASRQualityGovernorConfiguration = ASRQualityGovernorConfiguration(),
    initialSignals: ASRQualitySignals? = nil
  ) {
    self.preferredModel = preferredModel
    self.preferredChunkDuration =
      (preferredChunkDuration.isFinite && preferredChunkDuration > 0)
      ? max(1.0, preferredChunkDuration)
      : 1.0
    self.configuration = configuration

    let initialProfile: ASRQualityProfile
    if let initialSignals {
      let selected = Self.selectProfile(
        signals: initialSignals,
        queueHighThreshold: configuration.highQueueDepthThreshold,
        queueMediumThreshold: configuration.mediumQueueDepthThreshold
      )
      // Cold-start in balanced mode unless pressure already warrants safety mode.
      initialProfile = selected == .realtimeSafe ? .realtimeSafe : .balanced
    } else {
      initialProfile = .balanced
    }

    self.currentDecision = RuntimeASRQualityGovernor.decision(
      for: initialProfile,
      preferredModel: preferredModel,
      preferredChunkDuration: self.preferredChunkDuration
    )
  }

  public mutating func evaluate(signals: ASRQualitySignals) -> ASRQualityTransition? {
    evaluationsSinceTransition += 1

    let rawTarget = Self.selectProfile(
      signals: signals,
      queueHighThreshold: configuration.highQueueDepthThreshold,
      queueMediumThreshold: configuration.mediumQueueDepthThreshold
    )

    let target: ASRQualityProfile
    if currentDecision.profile == .realtimeSafe, rawTarget == .quality {
      // Recover in steps to avoid aggressive oscillation from safe -> quality.
      target = .balanced
    } else {
      target = rawTarget
    }

    if target == currentDecision.profile {
      consecutivePressure = 0
      consecutiveStable += 1
      return nil
    }

    let isPressureMove = target == .realtimeSafe || (target == .balanced && currentDecision.profile == .quality)

    if isPressureMove {
      consecutivePressure += 1
      consecutiveStable = 0
      guard consecutivePressure >= configuration.pressureConsecutiveEvaluations else { return nil }
    } else {
      consecutiveStable += 1
      consecutivePressure = 0
      guard consecutiveStable >= configuration.stableConsecutiveEvaluations else { return nil }
    }

    guard evaluationsSinceTransition >= configuration.cooldownEvaluations else { return nil }

    let from = currentDecision.profile
    currentDecision = Self.decision(
      for: target,
      preferredModel: preferredModel,
      preferredChunkDuration: preferredChunkDuration
    )

    evaluationsSinceTransition = 0
    consecutivePressure = 0
    consecutiveStable = 0

    return ASRQualityTransition(
      from: from,
      to: target,
      reason: Self.transitionReason(from: from, to: target, signals: signals),
      decision: currentDecision
    )
  }

  private static func selectProfile(
    signals: ASRQualitySignals,
    queueHighThreshold: Int,
    queueMediumThreshold: Int
  ) -> ASRQualityProfile {
    let highPressure =
      signals.latencySLABreached
      || signals.queueDepth >= queueHighThreshold
      || signals.memoryPressure
      || signals.lowPowerModeEnabled
      || signals.thermalState == .serious
      || signals.thermalState == .critical

    if highPressure { return .realtimeSafe }

    let moderatePressure =
      signals.queueDepth >= queueMediumThreshold
      || signals.thermalState == .fair

    if moderatePressure { return .balanced }

    return .quality
  }

  private static func decision(
    for profile: ASRQualityProfile,
    preferredModel: ASRModelProfile,
    preferredChunkDuration: TimeInterval
  ) -> ASRQualityDecision {
    switch profile {
    case .quality:
      return ASRQualityDecision(
        profile: .quality,
        model: maxModel(preferredModel, .medium),
        chunkDuration: max(preferredChunkDuration, 2.5),
        decodePolicy: .accurate
      )
    case .balanced:
      return ASRQualityDecision(
        profile: .balanced,
        model: preferredModel,
        chunkDuration: max(1.0, preferredChunkDuration),
        decodePolicy: .balanced
      )
    case .realtimeSafe:
      return ASRQualityDecision(
        profile: .realtimeSafe,
        model: minModel(preferredModel, .small),
        chunkDuration: max(preferredChunkDuration, 3.5),
        decodePolicy: .fast
      )
    }
  }

  private static func transitionReason(
    from: ASRQualityProfile,
    to: ASRQualityProfile,
    signals: ASRQualitySignals
  ) -> String {
    let reasons: [String] = [
      signals.latencySLABreached ? "latency-sla" : nil,
      signals.queueDepth > 0 ? "queue-depth=\(signals.queueDepth)" : nil,
      signals.memoryPressure ? "memory-pressure" : nil,
      signals.lowPowerModeEnabled ? "low-power" : nil,
      signals.thermalState == .fair ? "thermal-fair" : nil,
      signals.thermalState == .serious ? "thermal-serious" : nil,
      signals.thermalState == .critical ? "thermal-critical" : nil,
    ].compactMap { $0 }

    if reasons.isEmpty {
      return "\(from.rawValue)->\(to.rawValue):stabilized"
    }

    return "\(from.rawValue)->\(to.rawValue):" + reasons.joined(separator: "+")
  }

  private static func rank(_ model: ASRModelProfile) -> Int {
    switch model {
    case .base: return 0
    case .small: return 1
    case .medium: return 2
    case .large: return 3
    }
  }

  private static func maxModel(_ lhs: ASRModelProfile, _ rhs: ASRModelProfile) -> ASRModelProfile {
    rank(lhs) >= rank(rhs) ? lhs : rhs
  }

  private static func minModel(_ lhs: ASRModelProfile, _ rhs: ASRModelProfile) -> ASRModelProfile {
    rank(lhs) <= rank(rhs) ? lhs : rhs
  }
}
