import Foundation
import Darwin.Mach

/// Input configuration for realtime transcription jobs.
public struct RealtimeTranscriptionJobConfiguration: Sendable {
  public let model: ASRModelProfile
  public let chunkDuration: TimeInterval
  public let language: TranscriptionLanguageConfiguration
  public let speakerMapper: SpeakerMapper
  public let qualityGovernor: ASRQualityGovernorConfiguration

  public init(
    model: ASRModelProfile = .base,
    chunkDuration: TimeInterval = 2.0,
    language: TranscriptionLanguageConfiguration,
    speakerMapper: SpeakerMapper = SpeakerMapper(),
    qualityGovernor: ASRQualityGovernorConfiguration = ASRQualityGovernorConfiguration()
  ) {
    self.model = model
    self.chunkDuration = chunkDuration
    self.language = language
    self.speakerMapper = speakerMapper
    self.qualityGovernor = qualityGovernor
  }
}

/// Request payload for post-recording polishing pass.
public struct PostRecordingPolishRequest: Sendable {
  public let audioFileURL: URL
  public let source: TranscriptionTrackSource
  public let model: ASRModelProfile
  public let language: TranscriptionLanguageConfiguration
  public let speakerMapper: SpeakerMapper

  public init(
    audioFileURL: URL,
    source: TranscriptionTrackSource,
    model: ASRModelProfile = .small,
    language: TranscriptionLanguageConfiguration,
    speakerMapper: SpeakerMapper = SpeakerMapper()
  ) {
    self.audioFileURL = audioFileURL
    self.source = source
    self.model = model
    self.language = language
    self.speakerMapper = speakerMapper
  }
}

/// Primary transcription coordinator for realtime and post-recording jobs.
public actor TranscriptionJobOrchestrator {
  private struct RealtimeState: Sendable {
    var chunker: RealtimeAudioChunker
    let configuration: RealtimeTranscriptionJobConfiguration
    var mergedSegments: [TranscriptSegment]
    let startedUptime: TimeInterval
    var qualityGovernor: RuntimeASRQualityGovernor
    var currentDecision: ASRQualityDecision
    var lastLatencySLABreached: Bool
  }

  private struct EngineCallOutcome: Sendable {
    let result: ASRTranscriptionResult?
    let error: Error?
    let latencyMs: Double
  }

  private struct ChunkTranscriptionResult: Sendable {
    let segments: [TranscriptSegment]
    let latencySLABreached: Bool
  }

  private let engine: ASRTranscribingEngine
  private let shadowEngine: ASRTranscribingEngine?
  private let shadowHarness: ShadowTranscriptionHarness?
  private let shouldRunShadow: @Sendable () -> Bool
  private let merger: TranscriptSegmentMerger
  private let metricsHook: ASRMetricsHook
  private var realtimeJobs: [UUID: RealtimeState] = [:]

  public init(
    engine: ASRTranscribingEngine,
    shadowEngine: ASRTranscribingEngine? = nil,
    shadowHarness: ShadowTranscriptionHarness? = nil,
    shouldRunShadow: @escaping @Sendable () -> Bool = { true },
    merger: TranscriptSegmentMerger = TranscriptSegmentMerger(),
    metricsHook: ASRMetricsHook = NoopASRMetricsHook()
  ) {
    self.engine = engine
    self.shadowEngine = shadowEngine
    self.shadowHarness = shadowHarness
    self.shouldRunShadow = shouldRunShadow
    self.merger = merger
    self.metricsHook = metricsHook
  }

  /// Starts a realtime transcription job and returns its handle.
  public func startRealtimeJob(configuration: RealtimeTranscriptionJobConfiguration) -> UUID {
    let id = UUID()
    let initialSignals = ASRQualitySignals(
      latencySLABreached: false,
      queueDepth: 0,
      thermalState: ProcessInfo.processInfo.thermalState,
      memoryPressure: currentMemoryPressure(threshold: configuration.qualityGovernor.memoryPressureRatioThreshold),
      lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
    )
    let governor = RuntimeASRQualityGovernor(
      preferredModel: configuration.model,
      preferredChunkDuration: configuration.chunkDuration,
      configuration: configuration.qualityGovernor,
      initialSignals: initialSignals
    )
    let initialDecision = governor.currentDecision

    realtimeJobs[id] = RealtimeState(
      chunker: RealtimeAudioChunker(chunkDuration: initialDecision.chunkDuration),
      configuration: configuration,
      mergedSegments: [],
      startedUptime: ProcessInfo.processInfo.systemUptime,
      qualityGovernor: governor,
      currentDecision: initialDecision,
      lastLatencySLABreached: false
    )
    return id
  }

  /// Ingests packet data and returns latest merged transcript state.
  public func ingest(_ packet: AudioPacket, for jobID: UUID) async throws -> [TranscriptSegment] {
    guard var state = realtimeJobs[jobID] else {
      throw ASREngineError.runtimeFailure("unknown realtime job id")
    }

    let chunks = state.chunker.append(packet: packet)
    metricsHook.record(
      .queueBackpressure(operation: .streamChunk, queuedItems: chunks.count, droppedItems: 0))

    let preSignals = ASRQualitySignals(
      latencySLABreached: state.lastLatencySLABreached,
      queueDepth: chunks.count,
      thermalState: ProcessInfo.processInfo.thermalState,
      memoryPressure: currentMemoryPressure(threshold: state.configuration.qualityGovernor.memoryPressureRatioThreshold),
      lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
    )

    if let transition = state.qualityGovernor.evaluate(signals: preSignals) {
      state.currentDecision = transition.decision
      state.chunker.updateChunkDuration(transition.decision.chunkDuration)
      await shadowHarness?.captureQualityTransition(jobID: jobID, transition: transition)
    }

    let transcription = try await transcribeChunks(
      chunks,
      jobID: jobID,
      configuration: state.configuration,
      quality: state.currentDecision
    )

    state.lastLatencySLABreached = transcription.latencySLABreached
    state.mergedSegments = merger.merge(existing: state.mergedSegments, incoming: transcription.segments)
    realtimeJobs[jobID] = state
    return state.mergedSegments
  }

  /// Finalizes a realtime job and returns final merged transcript.
  ///
  /// On success, the job is removed.
  /// On failure, the job is retained so callers can decide whether to retry or cancel.
  public func finishRealtimeJob(_ jobID: UUID) async throws -> [TranscriptSegment] {
    guard var state = realtimeJobs[jobID] else {
      throw ASREngineError.runtimeFailure("unknown realtime job id")
    }

    let finishStart = ProcessInfo.processInfo.systemUptime
    let chunks = state.chunker.flushFinal()
    metricsHook.record(
      .queueBackpressure(operation: .finishRealtimeJob, queuedItems: chunks.count, droppedItems: 0))

    let transcription = try await transcribeChunks(
      chunks,
      jobID: jobID,
      configuration: state.configuration,
      quality: state.currentDecision
    )
    state.mergedSegments = merger.merge(existing: state.mergedSegments, incoming: transcription.segments)
    realtimeJobs.removeValue(forKey: jobID)

    let finishDurationMs = (ProcessInfo.processInfo.systemUptime - finishStart) * 1000
    metricsHook.record(.latency(operation: .finishRealtimeJob, durationMs: finishDurationMs, success: true))

    let stopToFinalMs = (ProcessInfo.processInfo.systemUptime - state.startedUptime) * 1000
    metricsHook.record(.stopToFinal(durationMs: stopToFinalMs))

    return state.mergedSegments
  }

  /// Cancels a realtime job and removes it from memory, returning the best-known merged segments.
  public func cancelRealtimeJob(_ jobID: UUID) -> [TranscriptSegment] {
    let state = realtimeJobs.removeValue(forKey: jobID)
    return state?.mergedSegments ?? []
  }

  /// Runs a post-recording polish pass over a completed audio file.
  public func runPolishJob(_ request: PostRecordingPolishRequest) async throws
    -> [TranscriptSegment]
  {
    let hint = request.language.primaryHint()
    let response = try await transcribeFileWithFallback(
      request: request,
      hint: hint,
      jobID: UUID()
    )

    return response.segments.map {
      TranscriptSegment(
        startTime: $0.startTime,
        endTime: $0.endTime,
        text: $0.text,
        speaker: request.speakerMapper.speaker(for: request.source),
        confidence: $0.confidence,
        language: response.detectedLanguageCode,
        source: request.source
      )
    }
  }

  private func transcribeChunks(
    _ chunks: [AudioChunk],
    jobID: UUID,
    configuration: RealtimeTranscriptionJobConfiguration,
    quality: ASRQualityDecision
  ) async throws -> ChunkTranscriptionResult {
    guard !chunks.isEmpty else { return ChunkTranscriptionResult(segments: [], latencySLABreached: false) }
    var mapped: [TranscriptSegment] = []
    var latencySLABreached = false

    for (index, chunk) in chunks.enumerated() {
      let hint = configuration.language.primaryHint()
      let response = try await transcribeChunkWithFallback(
        chunk,
        model: quality.model,
        language: configuration.language,
        hint: hint,
        jobID: jobID,
        queueDepth: chunks.count - index - 1,
        droppedItems: 0,
        quality: quality,
        latencySLAMs: configuration.qualityGovernor.latencySLAMs
      )

      latencySLABreached = latencySLABreached || response.latencySLABreached

      let newSegments = response.result.segments.map {
        TranscriptSegment(
          startTime: chunk.startTime + $0.startTime,
          endTime: chunk.startTime + $0.endTime,
          text: $0.text,
          speaker: configuration.speakerMapper.speaker(for: chunk.source),
          confidence: $0.confidence,
          language: response.result.detectedLanguageCode,
          source: chunk.source
        )
      }
      mapped.append(contentsOf: newSegments)
    }

    return ChunkTranscriptionResult(segments: mapped, latencySLABreached: latencySLABreached)
  }

  private func transcribeChunkWithFallback(
    _ chunk: AudioChunk,
    model: ASRModelProfile,
    language: TranscriptionLanguageConfiguration,
    hint: ASRLanguageHint?,
    jobID: UUID,
    queueDepth: Int,
    droppedItems: Int,
    quality: ASRQualityDecision,
    latencySLAMs: Double
  ) async throws -> (result: ASRTranscriptionResult, latencySLABreached: Bool) {
    let requestMetadata = ShadowTranscriptionRequestMetadata(
      jobID: jobID,
      chunkID: chunk.id,
      source: chunk.source,
      model: model,
      languageHint: hint,
      queueDepth: queueDepth,
      droppedItems: droppedItems,
      audioFileName: nil,
      qualityProfile: quality.profile,
      decodePolicy: quality.decodePolicy,
      chunkDuration: quality.chunkDuration
    )

    let requestStart = ProcessInfo.processInfo.systemUptime
    let firstPrimary = await callPrimaryChunk(chunk, model: model, hint: hint)
    let firstShadow = await callShadowChunk(chunk, model: model, hint: hint)

    if let result = firstPrimary.result {
      metricsHook.record(.latency(operation: .streamChunk, durationMs: firstPrimary.latencyMs, success: true))
      await captureShadow(
        operation: .streamChunk,
        request: requestMetadata,
        attempt: 1,
        retried: false,
        retryReason: nil,
        primary: firstPrimary,
        shadow: firstShadow,
        requestStartUptime: requestStart
      )
      return (result: result, latencySLABreached: firstPrimary.latencyMs > latencySLAMs)
    }

    guard let firstError = firstPrimary.error else {
      throw ASREngineError.runtimeFailure("missing primary result and error")
    }

    guard let fallback = language.fallbackHint(after: firstError, previousHint: hint) else {
      metricsHook.record(
        .latency(operation: .streamChunk, durationMs: firstPrimary.latencyMs, success: false))
      await captureShadow(
        operation: .streamChunk,
        request: requestMetadata,
        attempt: 1,
        retried: false,
        retryReason: nil,
        primary: firstPrimary,
        shadow: firstShadow,
        requestStartUptime: requestStart
      )
      throw firstError
    }

    metricsHook.record(.retry(operation: .streamChunk, attempt: 2, reason: "language-fallback"))
    await captureShadow(
      operation: .streamChunk,
      request: requestMetadata,
      attempt: 1,
      retried: true,
      retryReason: "language-fallback",
      primary: firstPrimary,
      shadow: firstShadow,
      requestStartUptime: requestStart
    )

    let retryRequest = ShadowTranscriptionRequestMetadata(
      jobID: jobID,
      chunkID: chunk.id,
      source: chunk.source,
      model: model,
      languageHint: fallback,
      queueDepth: queueDepth,
      droppedItems: droppedItems,
      audioFileName: nil,
      qualityProfile: quality.profile,
      decodePolicy: quality.decodePolicy,
      chunkDuration: quality.chunkDuration
    )

    let secondPrimary = await callPrimaryChunk(chunk, model: model, hint: fallback)
    let secondShadow = await callShadowChunk(chunk, model: model, hint: fallback)

    if let result = secondPrimary.result {
      metricsHook.record(.latency(operation: .streamChunk, durationMs: secondPrimary.latencyMs, success: true))
      await captureShadow(
        operation: .streamChunk,
        request: retryRequest,
        attempt: 2,
        retried: false,
        retryReason: nil,
        primary: secondPrimary,
        shadow: secondShadow,
        requestStartUptime: requestStart
      )
      return (result: result, latencySLABreached: secondPrimary.latencyMs > latencySLAMs)
    }

    metricsHook.record(.latency(operation: .streamChunk, durationMs: secondPrimary.latencyMs, success: false))
    await captureShadow(
      operation: .streamChunk,
      request: retryRequest,
      attempt: 2,
      retried: false,
      retryReason: nil,
      primary: secondPrimary,
      shadow: secondShadow,
      requestStartUptime: requestStart
    )

    throw secondPrimary.error ?? ASREngineError.runtimeFailure("unknown stream chunk failure")
  }

  private func transcribeFileWithFallback(
    request: PostRecordingPolishRequest,
    hint: ASRLanguageHint?,
    jobID: UUID
  ) async throws -> ASRTranscriptionResult {
    let requestMetadata = ShadowTranscriptionRequestMetadata(
      jobID: jobID,
      chunkID: nil,
      source: request.source,
      model: request.model,
      languageHint: hint,
      queueDepth: 0,
      droppedItems: 0,
      audioFileName: request.audioFileURL.lastPathComponent
    )

    let requestStart = ProcessInfo.processInfo.systemUptime
    let firstPrimary = await callPrimaryFile(request.audioFileURL, model: request.model, hint: hint)
    let firstShadow = await callShadowFile(request.audioFileURL, model: request.model, hint: hint)

    if let result = firstPrimary.result {
      metricsHook.record(
        .latency(operation: .transcribeFile, durationMs: firstPrimary.latencyMs, success: true))
      await captureShadow(
        operation: .transcribeFile,
        request: requestMetadata,
        attempt: 1,
        retried: false,
        retryReason: nil,
        primary: firstPrimary,
        shadow: firstShadow,
        requestStartUptime: requestStart
      )
      return result
    }

    guard let firstError = firstPrimary.error else {
      throw ASREngineError.runtimeFailure("missing primary result and error")
    }

    guard let fallback = request.language.fallbackHint(after: firstError, previousHint: hint) else {
      metricsHook.record(
        .latency(operation: .transcribeFile, durationMs: firstPrimary.latencyMs, success: false))
      await captureShadow(
        operation: .transcribeFile,
        request: requestMetadata,
        attempt: 1,
        retried: false,
        retryReason: nil,
        primary: firstPrimary,
        shadow: firstShadow,
        requestStartUptime: requestStart
      )
      throw firstError
    }

    metricsHook.record(.retry(operation: .transcribeFile, attempt: 2, reason: "language-fallback"))
    await captureShadow(
      operation: .transcribeFile,
      request: requestMetadata,
      attempt: 1,
      retried: true,
      retryReason: "language-fallback",
      primary: firstPrimary,
      shadow: firstShadow,
      requestStartUptime: requestStart
    )

    let retryRequest = ShadowTranscriptionRequestMetadata(
      jobID: jobID,
      chunkID: nil,
      source: request.source,
      model: request.model,
      languageHint: fallback,
      queueDepth: 0,
      droppedItems: 0,
      audioFileName: request.audioFileURL.lastPathComponent
    )

    let secondPrimary = await callPrimaryFile(request.audioFileURL, model: request.model, hint: fallback)
    let secondShadow = await callShadowFile(request.audioFileURL, model: request.model, hint: fallback)

    if let result = secondPrimary.result {
      metricsHook.record(
        .latency(operation: .transcribeFile, durationMs: secondPrimary.latencyMs, success: true))
      await captureShadow(
        operation: .transcribeFile,
        request: retryRequest,
        attempt: 2,
        retried: false,
        retryReason: nil,
        primary: secondPrimary,
        shadow: secondShadow,
        requestStartUptime: requestStart
      )
      return result
    }

    metricsHook.record(
      .latency(operation: .transcribeFile, durationMs: secondPrimary.latencyMs, success: false))
    await captureShadow(
      operation: .transcribeFile,
      request: retryRequest,
      attempt: 2,
      retried: false,
      retryReason: nil,
      primary: secondPrimary,
      shadow: secondShadow,
      requestStartUptime: requestStart
    )

    throw secondPrimary.error ?? ASREngineError.runtimeFailure("unknown file transcription failure")
  }

  private func callPrimaryChunk(_ chunk: AudioChunk, model: ASRModelProfile, hint: ASRLanguageHint?) async
    -> EngineCallOutcome
  {
    let started = ProcessInfo.processInfo.systemUptime
    do {
      let result = try await engine.transcribeStreamingChunk(chunk, model: model, languageHint: hint)
      return EngineCallOutcome(
        result: result,
        error: nil,
        latencyMs: (ProcessInfo.processInfo.systemUptime - started) * 1000
      )
    } catch {
      return EngineCallOutcome(
        result: nil,
        error: error,
        latencyMs: (ProcessInfo.processInfo.systemUptime - started) * 1000
      )
    }
  }

  private func callShadowChunk(_ chunk: AudioChunk, model: ASRModelProfile, hint: ASRLanguageHint?) async
    -> EngineCallOutcome?
  {
    guard let shadowEngine, shouldRunShadow() else { return nil }
    let started = ProcessInfo.processInfo.systemUptime
    do {
      let result = try await shadowEngine.transcribeStreamingChunk(chunk, model: model, languageHint: hint)
      return EngineCallOutcome(
        result: result,
        error: nil,
        latencyMs: (ProcessInfo.processInfo.systemUptime - started) * 1000
      )
    } catch {
      return EngineCallOutcome(
        result: nil,
        error: error,
        latencyMs: (ProcessInfo.processInfo.systemUptime - started) * 1000
      )
    }
  }

  private func callPrimaryFile(_ url: URL, model: ASRModelProfile, hint: ASRLanguageHint?) async
    -> EngineCallOutcome
  {
    let started = ProcessInfo.processInfo.systemUptime
    do {
      let result = try await engine.transcribeAudioFile(at: url, model: model, languageHint: hint)
      return EngineCallOutcome(
        result: result,
        error: nil,
        latencyMs: (ProcessInfo.processInfo.systemUptime - started) * 1000
      )
    } catch {
      return EngineCallOutcome(
        result: nil,
        error: error,
        latencyMs: (ProcessInfo.processInfo.systemUptime - started) * 1000
      )
    }
  }

  private func callShadowFile(_ url: URL, model: ASRModelProfile, hint: ASRLanguageHint?) async
    -> EngineCallOutcome?
  {
    guard let shadowEngine, shouldRunShadow() else { return nil }
    let started = ProcessInfo.processInfo.systemUptime
    do {
      let result = try await shadowEngine.transcribeAudioFile(at: url, model: model, languageHint: hint)
      return EngineCallOutcome(
        result: result,
        error: nil,
        latencyMs: (ProcessInfo.processInfo.systemUptime - started) * 1000
      )
    } catch {
      return EngineCallOutcome(
        result: nil,
        error: error,
        latencyMs: (ProcessInfo.processInfo.systemUptime - started) * 1000
      )
    }
  }

  private func currentMemoryPressure(threshold: Double) -> Bool {
    let total = Double(ProcessInfo.processInfo.physicalMemory)
    guard total > 0, let resident = residentMemoryBytes() else { return false }
    let ratio = Double(resident) / total
    return ratio >= threshold
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

  private func captureShadow(
    operation: ShadowTranscriptionOperation,
    request: ShadowTranscriptionRequestMetadata,
    attempt: Int,
    retried: Bool,
    retryReason: String?,
    primary: EngineCallOutcome,
    shadow: EngineCallOutcome?,
    requestStartUptime: TimeInterval
  ) async {
    guard let shadowHarness else { return }
    await shadowHarness.capture(
      ShadowTranscriptionAttemptCapture(
        operation: operation,
        request: request,
        attempt: attempt,
        retried: retried,
        retryReason: retryReason,
        primaryResult: primary.result,
        shadowResult: shadow?.result,
        primaryError: primary.error,
        shadowError: shadow?.error,
        primaryLatencyMs: primary.latencyMs,
        shadowLatencyMs: shadow?.latencyMs,
        endToEndLatencyMs: (ProcessInfo.processInfo.systemUptime - requestStartUptime) * 1000
      ))
  }
}
