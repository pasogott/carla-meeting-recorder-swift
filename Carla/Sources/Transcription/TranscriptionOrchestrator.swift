import Foundation

/// Input configuration for realtime transcription jobs.
public struct RealtimeTranscriptionJobConfiguration: Sendable {
  public let model: WhisperModel
  public let chunkDuration: TimeInterval
  public let language: TranscriptionLanguageConfiguration
  public let speakerMapper: SpeakerMapper

  public init(
    model: WhisperModel = .base,
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
  public let model: WhisperModel
  public let language: TranscriptionLanguageConfiguration
  public let speakerMapper: SpeakerMapper

  public init(
    audioFileURL: URL,
    source: TranscriptionTrackSource,
    model: WhisperModel = .small,
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
  }

  private let engine: WhisperTranscribingEngine
  private let merger: TranscriptSegmentMerger
  private var realtimeJobs: [UUID: RealtimeState] = [:]

  public init(
    engine: WhisperTranscribingEngine,
    merger: TranscriptSegmentMerger = TranscriptSegmentMerger()
  ) {
    self.engine = engine
    self.merger = merger
  }

  /// Starts a realtime transcription job and returns its handle.
  public func startRealtimeJob(configuration: RealtimeTranscriptionJobConfiguration) -> UUID {
    let id = UUID()
    realtimeJobs[id] = RealtimeState(
      chunker: RealtimeAudioChunker(chunkDuration: configuration.chunkDuration),
      configuration: configuration,
      mergedSegments: []
    )
    return id
  }

  /// Ingests packet data and returns latest merged transcript state.
  public func ingest(_ packet: AudioPacket, for jobID: UUID) async throws -> [TranscriptSegment] {
    guard var state = realtimeJobs[jobID] else {
      throw WhisperEngineError.runtimeFailure("unknown realtime job id")
    }

    let chunks = state.chunker.append(packet: packet)
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
      throw WhisperEngineError.runtimeFailure("unknown realtime job id")
    }

    let chunks = state.chunker.flushFinal()
    let incoming = try await transcribeChunks(chunks, configuration: state.configuration)
    state.mergedSegments = merger.merge(existing: state.mergedSegments, incoming: incoming)
    realtimeJobs.removeValue(forKey: jobID)
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
    model: WhisperModel,
    language: TranscriptionLanguageConfiguration,
    hint: WhisperLanguageHint?
  ) async throws -> WhisperTranscriptionResult {
    do {
      return try await engine.transcribeStreamingChunk(chunk, model: model, languageHint: hint)
    } catch {
      guard let fallback = language.fallbackHint(after: error, previousHint: hint) else {
        throw error
      }
      return try await engine.transcribeStreamingChunk(chunk, model: model, languageHint: fallback)
    }
  }

  private func transcribeFileWithFallback(
    url: URL,
    model: WhisperModel,
    language: TranscriptionLanguageConfiguration,
    hint: WhisperLanguageHint?
  ) async throws -> WhisperTranscriptionResult {
    do {
      return try await engine.transcribeAudioFile(at: url, model: model, languageHint: hint)
    } catch {
      guard let fallback = language.fallbackHint(after: error, previousHint: hint) else {
        throw error
      }
      return try await engine.transcribeAudioFile(at: url, model: model, languageHint: fallback)
    }
  }
}
