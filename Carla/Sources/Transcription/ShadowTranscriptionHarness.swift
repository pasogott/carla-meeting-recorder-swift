import Foundation
import Darwin.Mach

public struct ShadowTranscriptionRedactionPolicy: Sendable, Equatable {
  public let redactTranscriptText: Bool

  public init(redactTranscriptText: Bool = true) {
    self.redactTranscriptText = redactTranscriptText
  }
}

public struct ShadowTranscriptionRetentionPolicy: Sendable, Equatable {
  public let maxArtifactAge: TimeInterval
  public let maxTotalBytes: UInt64

  public init(maxArtifactAge: TimeInterval = 60 * 60 * 24 * 14, maxTotalBytes: UInt64 = 100 * 1024 * 1024) {
    self.maxArtifactAge = maxArtifactAge
    self.maxTotalBytes = maxTotalBytes
  }
}

public struct ShadowTranscriptionHarnessConfiguration: Sendable, Equatable {
  public let artifactsDirectory: URL
  public let retention: ShadowTranscriptionRetentionPolicy
  public let redaction: ShadowTranscriptionRedactionPolicy

  public init(
    artifactsDirectory: URL,
    retention: ShadowTranscriptionRetentionPolicy = ShadowTranscriptionRetentionPolicy(),
    redaction: ShadowTranscriptionRedactionPolicy = ShadowTranscriptionRedactionPolicy()
  ) {
    self.artifactsDirectory = artifactsDirectory
    self.retention = retention
    self.redaction = redaction
  }
}

public enum ShadowTranscriptionOperation: String, Sendable, Codable {
  case streamChunk
  case transcribeFile
}

public struct ShadowTranscriptionRequestMetadata: Sendable {
  public let jobID: UUID
  public let chunkID: UUID?
  public let source: TranscriptionTrackSource
  public let model: ASRModelProfile
  public let languageHint: ASRLanguageHint?
  public let queueDepth: Int
  public let droppedItems: Int
  public let audioFileName: String?
  public let qualityProfile: ASRQualityProfile?
  public let decodePolicy: ASRDecodePolicy?
  public let chunkDuration: TimeInterval?

  public init(
    jobID: UUID,
    chunkID: UUID?,
    source: TranscriptionTrackSource,
    model: ASRModelProfile,
    languageHint: ASRLanguageHint?,
    queueDepth: Int,
    droppedItems: Int,
    audioFileName: String?,
    qualityProfile: ASRQualityProfile? = nil,
    decodePolicy: ASRDecodePolicy? = nil,
    chunkDuration: TimeInterval? = nil
  ) {
    self.jobID = jobID
    self.chunkID = chunkID
    self.source = source
    self.model = model
    self.languageHint = languageHint
    self.queueDepth = queueDepth
    self.droppedItems = droppedItems
    self.audioFileName = audioFileName
    self.qualityProfile = qualityProfile
    self.decodePolicy = decodePolicy
    self.chunkDuration = chunkDuration
  }
}

public struct ShadowTranscriptionAttemptCapture: Sendable {
  public let operation: ShadowTranscriptionOperation
  public let request: ShadowTranscriptionRequestMetadata
  public let attempt: Int
  public let retried: Bool
  public let retryReason: String?
  public let primaryResult: ASRTranscriptionResult?
  public let shadowResult: ASRTranscriptionResult?
  public let primaryError: Error?
  public let shadowError: Error?
  public let primaryLatencyMs: Double
  public let shadowLatencyMs: Double?
  public let endToEndLatencyMs: Double

  public init(
    operation: ShadowTranscriptionOperation,
    request: ShadowTranscriptionRequestMetadata,
    attempt: Int,
    retried: Bool,
    retryReason: String?,
    primaryResult: ASRTranscriptionResult?,
    shadowResult: ASRTranscriptionResult?,
    primaryError: Error?,
    shadowError: Error?,
    primaryLatencyMs: Double,
    shadowLatencyMs: Double?,
    endToEndLatencyMs: Double
  ) {
    self.operation = operation
    self.request = request
    self.attempt = attempt
    self.retried = retried
    self.retryReason = retryReason
    self.primaryResult = primaryResult
    self.shadowResult = shadowResult
    self.primaryError = primaryError
    self.shadowError = shadowError
    self.primaryLatencyMs = primaryLatencyMs
    self.shadowLatencyMs = shadowLatencyMs
    self.endToEndLatencyMs = endToEndLatencyMs
  }
}

private struct ShadowArtifactRecord: Codable {
  let timestamp: String
  let operation: String
  let jobID: String
  let chunkID: String?
  let source: String
  let model: String
  let languageHint: String?
  let queueDepth: Int
  let droppedItems: Int
  let audioFileName: String?
  let qualityProfile: String?
  let decodePolicy: String?
  let chunkDuration: Double?

  let attempt: Int
  let retried: Bool
  let retryReason: String?

  let primaryLatencyMs: Double
  let shadowLatencyMs: Double?
  let endToEndLatencyMs: Double

  let primarySegmentCount: Int?
  let shadowSegmentCount: Int?
  let primaryTokenCount: Int?
  let shadowTokenCount: Int?
  let tokenAlignmentDrift: Int?
  let languageMismatch: Bool
  let primaryLanguage: String?
  let shadowLanguage: String?

  let primaryErrorTaxonomy: String?
  let shadowErrorTaxonomy: String?

  let thermalState: String
  let lowPowerModeEnabled: Bool
  let physicalMemoryBytes: UInt64
  let residentMemoryBytes: UInt64?

  let primaryTranscriptPreview: [String]?
  let shadowTranscriptPreview: [String]?
}

private struct ShadowQualityTransitionRecord: Codable {
  let timestamp: String
  let type: String
  let jobID: String
  let fromProfile: String
  let toProfile: String
  let reason: String
  let model: String
  let chunkDuration: Double
  let decodePolicy: String
}

public actor ShadowTranscriptionHarness {
  private let configuration: ShadowTranscriptionHarnessConfiguration
  private let fileManager: FileManager
  private let isoFormatter = ISO8601DateFormatter()
  private let jsonEncoder = JSONEncoder()

  public init(
    configuration: ShadowTranscriptionHarnessConfiguration,
    fileManager: FileManager = .default
  ) {
    self.configuration = configuration
    self.fileManager = fileManager
    self.jsonEncoder.outputFormatting = [.sortedKeys]
  }

  public func capture(_ attempt: ShadowTranscriptionAttemptCapture) {
    do {
      try fileManager.createDirectory(
        at: configuration.artifactsDirectory,
        withIntermediateDirectories: true
      )
      try pruneArtifactsIfNeeded()

      let jobDirectory = configuration.artifactsDirectory
        .appendingPathComponent(attempt.request.jobID.uuidString, isDirectory: true)
      try fileManager.createDirectory(at: jobDirectory, withIntermediateDirectories: true)

      let record = buildRecord(from: attempt)
      let jsonData = try jsonEncoder.encode(record)
      try append(data: jsonData + Data("\n".utf8), to: jobDirectory.appendingPathComponent("events.jsonl"))

      let summaryURL = jobDirectory.appendingPathComponent("summary.csv")
      if !fileManager.fileExists(atPath: summaryURL.path) {
        let header = csvHeader + "\n"
        try append(data: Data(header.utf8), to: summaryURL)
      }
      let row = csvRow(for: record) + "\n"
      try append(data: Data(row.utf8), to: summaryURL)

      try pruneArtifactsIfNeeded()
    } catch {
      // Artifact recording must never interrupt transcription flow.
    }
  }

  public func captureQualityTransition(jobID: UUID, transition: ASRQualityTransition) {
    do {
      try fileManager.createDirectory(
        at: configuration.artifactsDirectory,
        withIntermediateDirectories: true
      )
      try pruneArtifactsIfNeeded()

      let jobDirectory = configuration.artifactsDirectory
        .appendingPathComponent(jobID.uuidString, isDirectory: true)
      try fileManager.createDirectory(at: jobDirectory, withIntermediateDirectories: true)

      let record = ShadowQualityTransitionRecord(
        timestamp: isoFormatter.string(from: transition.timestamp),
        type: "quality-governor-transition",
        jobID: jobID.uuidString,
        fromProfile: transition.from.rawValue,
        toProfile: transition.to.rawValue,
        reason: transition.reason,
        model: transition.decision.model.rawValue,
        chunkDuration: transition.decision.chunkDuration,
        decodePolicy: transition.decision.decodePolicy.rawValue
      )

      let jsonData = try jsonEncoder.encode(record)
      try append(data: jsonData + Data("\n".utf8), to: jobDirectory.appendingPathComponent("events.jsonl"))

      let transitionsURL = jobDirectory.appendingPathComponent("quality-transitions.csv")
      if !fileManager.fileExists(atPath: transitionsURL.path) {
        let header = [
          "timestamp", "from_profile", "to_profile", "reason", "model", "chunk_duration", "decode_policy",
        ].joined(separator: ",") + "\n"
        try append(data: Data(header.utf8), to: transitionsURL)
      }

      let transitionValues = [
        record.timestamp,
        record.fromProfile,
        record.toProfile,
        record.reason,
        record.model,
        String(format: "%.2f", record.chunkDuration),
        record.decodePolicy,
      ]
      let transitionRow = transitionValues.map(csvEscape).joined(separator: ",") + "\n"
      try append(data: Data(transitionRow.utf8), to: transitionsURL)

      try pruneArtifactsIfNeeded()
    } catch {
      // Artifact recording must never interrupt transcription flow.
    }
  }

  private func buildRecord(from attempt: ShadowTranscriptionAttemptCapture) -> ShadowArtifactRecord {
    let drift = transcriptDrift(primary: attempt.primaryResult, shadow: attempt.shadowResult)
    return ShadowArtifactRecord(
      timestamp: isoFormatter.string(from: Date()),
      operation: attempt.operation.rawValue,
      jobID: attempt.request.jobID.uuidString,
      chunkID: attempt.request.chunkID?.uuidString,
      source: String(describing: attempt.request.source),
      model: attempt.request.model.rawValue,
      languageHint: renderLanguageHint(attempt.request.languageHint),
      queueDepth: attempt.request.queueDepth,
      droppedItems: attempt.request.droppedItems,
      audioFileName: attempt.request.audioFileName,
      qualityProfile: attempt.request.qualityProfile?.rawValue,
      decodePolicy: attempt.request.decodePolicy?.rawValue,
      chunkDuration: attempt.request.chunkDuration,
      attempt: attempt.attempt,
      retried: attempt.retried,
      retryReason: attempt.retryReason,
      primaryLatencyMs: attempt.primaryLatencyMs,
      shadowLatencyMs: attempt.shadowLatencyMs,
      endToEndLatencyMs: attempt.endToEndLatencyMs,
      primarySegmentCount: attempt.primaryResult?.segments.count,
      shadowSegmentCount: attempt.shadowResult?.segments.count,
      primaryTokenCount: drift?.primaryTokenCount,
      shadowTokenCount: drift?.shadowTokenCount,
      tokenAlignmentDrift: drift?.tokenAlignmentDrift,
      languageMismatch: languageMismatch(primary: attempt.primaryResult, shadow: attempt.shadowResult),
      primaryLanguage: attempt.primaryResult?.detectedLanguageCode,
      shadowLanguage: attempt.shadowResult?.detectedLanguageCode,
      primaryErrorTaxonomy: taxonomy(for: attempt.primaryError),
      shadowErrorTaxonomy: taxonomy(for: attempt.shadowError),
      thermalState: renderThermalState(ProcessInfo.processInfo.thermalState),
      lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
      physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
      residentMemoryBytes: residentMemoryBytes(),
      primaryTranscriptPreview: redactedPreview(for: attempt.primaryResult),
      shadowTranscriptPreview: redactedPreview(for: attempt.shadowResult)
    )
  }

  private func redactedPreview(for result: ASRTranscriptionResult?) -> [String]? {
    guard let result else { return nil }
    if configuration.redaction.redactTranscriptText {
      return result.segments.map { "redacted-len=\($0.text.count)" }
    }
    return result.segments.map { $0.text }
  }

  private func transcriptDrift(primary: ASRTranscriptionResult?, shadow: ASRTranscriptionResult?)
    -> (primaryTokenCount: Int, shadowTokenCount: Int, tokenAlignmentDrift: Int)?
  {
    guard let primary, let shadow else { return nil }
    let primaryTokens = tokenize(primary.segments)
    let shadowTokens = tokenize(shadow.segments)
    return (
      primaryTokens.count,
      shadowTokens.count,
      levenshteinDistance(primaryTokens, shadowTokens)
    )
  }

  private func tokenize(_ segments: [ASRSegment]) -> [String] {
    segments
      .flatMap { $0.text.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).map(String.init) }
  }

  private func languageMismatch(primary: ASRTranscriptionResult?, shadow: ASRTranscriptionResult?) -> Bool {
    guard let primaryLanguage = primary?.detectedLanguageCode,
      let shadowLanguage = shadow?.detectedLanguageCode
    else {
      return false
    }
    return primaryLanguage != shadowLanguage
  }

  private func renderLanguageHint(_ hint: ASRLanguageHint?) -> String? {
    switch hint {
    case .fixed(let code):
      return "fixed:\(code)"
    case .autoDetect:
      return "auto-detect"
    case .none:
      return nil
    }
  }

  private func taxonomy(for error: Error?) -> String? {
    guard let error else { return nil }
    if let asrError = error as? ASREngineError {
      switch asrError {
      case .unsupportedLanguage:
        return "unsupported_language"
      case .decodingFailed:
        return "decoding_failed"
      case .modelUnavailable:
        return "model_unavailable"
      case .runtimeFailure:
        return "runtime_failure"
      }
    }
    return "unknown"
  }

  private func renderThermalState(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
  }

  private func levenshteinDistance(_ left: [String], _ right: [String]) -> Int {
    if left.isEmpty { return right.count }
    if right.isEmpty { return left.count }

    var previous = Array(0...right.count)
    for (i, leftToken) in left.enumerated() {
      var current = [i + 1]
      current.reserveCapacity(right.count + 1)

      for (j, rightToken) in right.enumerated() {
        if leftToken == rightToken {
          current.append(previous[j])
        } else {
          let replace = previous[j]
          let insert = current[j]
          let delete = previous[j + 1]
          current.append(min(replace, insert, delete) + 1)
        }
      }
      previous = current
    }
    return previous[right.count]
  }

  private func append(data: Data, to url: URL) throws {
    if fileManager.fileExists(atPath: url.path) {
      let handle = try FileHandle(forWritingTo: url)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: data)
    } else {
      try data.write(to: url)
    }
  }

  private var csvHeader: String {
    [
      "timestamp", "operation", "job_id", "chunk_id", "source", "model", "language_hint",
      "queue_depth", "dropped_items", "audio_file", "quality_profile", "decode_policy", "chunk_duration", "attempt", "retried", "retry_reason",
      "primary_latency_ms", "shadow_latency_ms", "end_to_end_latency_ms",
      "primary_segments", "shadow_segments", "primary_tokens", "shadow_tokens", "token_alignment_drift",
      "language_mismatch", "primary_language", "shadow_language",
      "primary_error_taxonomy", "shadow_error_taxonomy", "thermal_state", "low_power_mode",
      "physical_memory_bytes", "resident_memory_bytes"
    ].joined(separator: ",")
  }

  private func csvRow(for record: ShadowArtifactRecord) -> String {
    let values: [String] = [
      record.timestamp,
      record.operation,
      record.jobID,
      record.chunkID ?? "",
      record.source,
      record.model,
      record.languageHint ?? "",
      String(record.queueDepth),
      String(record.droppedItems),
      record.audioFileName ?? "",
      record.qualityProfile ?? "",
      record.decodePolicy ?? "",
      formatOptionalDouble(record.chunkDuration),
      String(record.attempt),
      String(record.retried),
      record.retryReason ?? "",
      String(format: "%.2f", record.primaryLatencyMs),
      formatOptionalDouble(record.shadowLatencyMs),
      String(format: "%.2f", record.endToEndLatencyMs),
      formatOptionalInt(record.primarySegmentCount),
      formatOptionalInt(record.shadowSegmentCount),
      formatOptionalInt(record.primaryTokenCount),
      formatOptionalInt(record.shadowTokenCount),
      formatOptionalInt(record.tokenAlignmentDrift),
      String(record.languageMismatch),
      record.primaryLanguage ?? "",
      record.shadowLanguage ?? "",
      record.primaryErrorTaxonomy ?? "",
      record.shadowErrorTaxonomy ?? "",
      record.thermalState,
      String(record.lowPowerModeEnabled),
      String(record.physicalMemoryBytes),
      formatOptionalUInt64(record.residentMemoryBytes)
    ]

    return values.map(csvEscape).joined(separator: ",")
  }

  private func formatOptionalInt(_ value: Int?) -> String {
    guard let value else { return "" }
    return String(value)
  }

  private func formatOptionalUInt64(_ value: UInt64?) -> String {
    guard let value else { return "" }
    return String(value)
  }

  private func formatOptionalDouble(_ value: Double?) -> String {
    guard let value else { return "" }
    return String(format: "%.2f", value)
  }

  private func csvEscape(_ value: String) -> String {
    let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
    return "\"\(escaped)\""
  }

  private func pruneArtifactsIfNeeded() throws {
    guard fileManager.fileExists(atPath: configuration.artifactsDirectory.path) else { return }

    var directories: [(url: URL, date: Date, size: UInt64)] = []
    let urls = try fileManager.contentsOfDirectory(
      at: configuration.artifactsDirectory,
      includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
      options: [.skipsHiddenFiles]
    )

    for url in urls {
      let values = try url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
      guard values.isDirectory == true else { continue }
      let date = values.contentModificationDate ?? .distantPast
      let size = directorySize(url)
      directories.append((url, date, size))
    }

    let now = Date()
    for entry in directories where now.timeIntervalSince(entry.date) > configuration.retention.maxArtifactAge {
      try? fileManager.removeItem(at: entry.url)
    }

    directories = directories.filter { fileManager.fileExists(atPath: $0.url.path) }
    var totalBytes = directories.reduce(UInt64(0)) { $0 + $1.size }
    if totalBytes <= configuration.retention.maxTotalBytes { return }

    let sorted = directories.sorted { $0.date < $1.date }
    for entry in sorted {
      guard totalBytes > configuration.retention.maxTotalBytes else { break }
      try? fileManager.removeItem(at: entry.url)
      totalBytes = totalBytes > entry.size ? totalBytes - entry.size : 0
    }
  }

  private func directorySize(_ url: URL) -> UInt64 {
    var size: UInt64 = 0
    if let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
      for case let fileURL as URL in enumerator {
        if let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
          values.isRegularFile == true,
          let fileSize = values.fileSize
        {
          size += UInt64(fileSize)
        }
      }
    }
    return size
  }

  private func residentMemoryBytes() -> UInt64? {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<natural_t>.size)
    let result: kern_return_t = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPointer, &count)
      }
    }
    guard result == KERN_SUCCESS else { return nil }
    return UInt64(info.resident_size)
  }
}
