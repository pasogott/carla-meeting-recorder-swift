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

  private let engine: ASRTranscribingEngine
  private let merger: TranscriptSegmentMerger
  private let metricsHook: ASRMetricsHook
  private var realtimeJobs: [UUID: RealtimeState] = [:]

  public init(
    engine: ASRTranscribingEngine,
    merger: TranscriptSegmentMerger = TranscriptSegmentMerger(),
    metricsHook: ASRMetricsHook = NoopASRMetricsHook()
  ) {
    self.engine = engine
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

    let incoming = try await transcribeChunks(chunks, configuration: state.configuration)
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

    let incoming = try await transcribeChunks(chunks, configuration: state.configuration)
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
      url: request.audioFileURL,
      model: request.model,
      language: request.language,
      hint: hint
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
    configuration: RealtimeTranscriptionJobConfiguration
  ) async throws -> [TranscriptSegment] {
    guard !chunks.isEmpty else { return [] }
    var mapped: [TranscriptSegment] = []

    for chunk in chunks {
      let hint = configuration.language.primaryHint()
      let response = try await transcribeChunkWithFallback(
        chunk,
        model: configuration.model,
        language: configuration.language,
        hint: hint
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
    hint: ASRLanguageHint?
  ) async throws -> ASRTranscriptionResult {
    let start = ProcessInfo.processInfo.systemUptime
    do {
      let result = try await engine.transcribeStreamingChunk(chunk, model: model, languageHint: hint)
      let durationMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
      metricsHook.record(.latency(operation: .streamChunk, durationMs: durationMs, success: true))
      return result
    } catch {
      guard let fallback = language.fallbackHint(after: error, previousHint: hint) else {
        let durationMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
        metricsHook.record(.latency(operation: .streamChunk, durationMs: durationMs, success: false))
        throw error
      }
      metricsHook.record(.retry(operation: .streamChunk, attempt: 2, reason: "language-fallback"))
      let result = try await engine.transcribeStreamingChunk(chunk, model: model, languageHint: fallback)
      let durationMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
      metricsHook.record(.latency(operation: .streamChunk, durationMs: durationMs, success: true))
      return result
    }
  }

  private func transcribeFileWithFallback(
    url: URL,
    model: ASRModelProfile,
    language: TranscriptionLanguageConfiguration,
    hint: ASRLanguageHint?
  ) async throws -> ASRTranscriptionResult {
    let start = ProcessInfo.processInfo.systemUptime
    do {
      let result = try await engine.transcribeAudioFile(at: url, model: model, languageHint: hint)
      let durationMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
      metricsHook.record(.latency(operation: .transcribeFile, durationMs: durationMs, success: true))
      return result
    } catch {
      guard let fallback = language.fallbackHint(after: error, previousHint: hint) else {
        let durationMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
        metricsHook.record(.latency(operation: .transcribeFile, durationMs: durationMs, success: false))
        throw error
      }
      metricsHook.record(.retry(operation: .transcribeFile, attempt: 2, reason: "language-fallback"))
      let result = try await engine.transcribeAudioFile(at: url, model: model, languageHint: fallback)
      let durationMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
      metricsHook.record(.latency(operation: .transcribeFile, durationMs: durationMs, success: true))
      return result
    }
  }
}
