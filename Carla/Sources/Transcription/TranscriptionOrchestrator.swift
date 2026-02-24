import Foundation

/// Input configuration for realtime transcription jobs.
public struct RealtimeTranscriptionJobConfiguration: Sendable {
  public let model: ASRModelProfile
  public let chunkDuration: TimeInterval
  public let language: TranscriptionLanguageConfiguration
  public let speakerMapper: SpeakerMapper

  public init(
    model: ASRModelProfile = .base,
    chunkDuration: TimeInterval = 2.0,
    language: TranscriptionLanguageConfiguration,
    speakerMapper: SpeakerMapper = SpeakerMapper()
  ) {
    self.model = model
    self.chunkDuration = chunkDuration
    self.language = language
    self.speakerMapper = speakerMapper
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
  }

  private struct EngineCallOutcome: Sendable {
    let result: ASRTranscriptionResult?
    let error: Error?
    let latencyMs: Double
  }

  private let engine: ASRTranscribingEngine
  private let shadowEngine: ASRTranscribingEngine?
  private let shadowHarness: ShadowTranscriptionHarness?
  private let merger: TranscriptSegmentMerger
  private let metricsHook: ASRMetricsHook
  private var realtimeJobs: [UUID: RealtimeState] = [:]

  public init(
    engine: ASRTranscribingEngine,
    shadowEngine: ASRTranscribingEngine? = nil,
    shadowHarness: ShadowTranscriptionHarness? = nil,
    merger: TranscriptSegmentMerger = TranscriptSegmentMerger(),
    metricsHook: ASRMetricsHook = NoopASRMetricsHook()
  ) {
    self.engine = engine
    self.shadowEngine = shadowEngine
    self.shadowHarness = shadowHarness
    self.merger = merger
    self.metricsHook = metricsHook
  }

  /// Starts a realtime transcription job and returns its handle.
  public func startRealtimeJob(configuration: RealtimeTranscriptionJobConfiguration) -> UUID {
    let id = UUID()
    realtimeJobs[id] = RealtimeState(
      chunker: RealtimeAudioChunker(chunkDuration: configuration.chunkDuration),
      configuration: configuration,
      mergedSegments: [],
      startedUptime: ProcessInfo.processInfo.systemUptime
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

    let incoming = try await transcribeChunks(chunks, jobID: jobID, configuration: state.configuration)
    state.mergedSegments = merger.merge(existing: state.mergedSegments, incoming: incoming)
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

    let incoming = try await transcribeChunks(chunks, jobID: jobID, configuration: state.configuration)
    state.mergedSegments = merger.merge(existing: state.mergedSegments, incoming: incoming)
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
    configuration: RealtimeTranscriptionJobConfiguration
  ) async throws -> [TranscriptSegment] {
    guard !chunks.isEmpty else { return [] }
    var mapped: [TranscriptSegment] = []

    for (index, chunk) in chunks.enumerated() {
      let hint = configuration.language.primaryHint()
      let response = try await transcribeChunkWithFallback(
        chunk,
        model: configuration.model,
        language: configuration.language,
        hint: hint,
        jobID: jobID,
        queueDepth: chunks.count - index - 1,
        droppedItems: 0
      )

      let newSegments = response.segments.map {
        TranscriptSegment(
          startTime: chunk.startTime + $0.startTime,
          endTime: chunk.startTime + $0.endTime,
          text: $0.text,
          speaker: configuration.speakerMapper.speaker(for: chunk.source),
          confidence: $0.confidence,
          language: response.detectedLanguageCode,
          source: chunk.source
        )
      }
      mapped.append(contentsOf: newSegments)
    }

    return mapped
  }

  private func transcribeChunkWithFallback(
    _ chunk: AudioChunk,
    model: ASRModelProfile,
    language: TranscriptionLanguageConfiguration,
    hint: ASRLanguageHint?,
    jobID: UUID,
    queueDepth: Int,
    droppedItems: Int
  ) async throws -> ASRTranscriptionResult {
    let requestMetadata = ShadowTranscriptionRequestMetadata(
      jobID: jobID,
      chunkID: chunk.id,
      source: chunk.source,
      model: model,
      languageHint: hint,
      queueDepth: queueDepth,
      droppedItems: droppedItems,
      audioFileName: nil
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
      return result
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
      audioFileName: nil
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
      return result
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
    guard let shadowEngine else { return nil }
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
    guard let shadowEngine else { return nil }
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
