import CarlaAudio
import CarlaCoreTypes
import CarlaModels
import CarlaStorage
import CarlaTranscription
import Foundation

/// Error type for recording coordinator operations.
public enum RecordingError: LocalizedError {
  case alreadyRecording
  case notRecording
  case audioSessionFailed(Error)
  case storageFailed(Error)

  public var errorDescription: String? {
    switch self {
    case .alreadyRecording:
      return "A recording is already in progress."
    case .notRecording:
      return "No recording is currently active."
    case .audioSessionFailed(let error):
      return "Audio capture failed: \(error.localizedDescription)"
    case .storageFailed(let error):
      return "Failed to save meeting: \(error.localizedDescription)"
    }
  }
}

/// Configuration for the recording coordinator.
public struct RecordingConfiguration: Sendable {
  public let whisperModel: WhisperModel
  public let chunkDuration: TimeInterval
  public let primaryLanguageCode: String?
  public let autoDetectFallback: Bool
  public let compressToM4A: Bool
  public let deleteWAVAfterCompression: Bool

  public init(
    whisperModel: WhisperModel = .base,
    chunkDuration: TimeInterval = 2.0,
    primaryLanguageCode: String? = nil,
    autoDetectFallback: Bool = true,
    compressToM4A: Bool = true,
    deleteWAVAfterCompression: Bool = true
  ) {
    self.whisperModel = whisperModel
    self.chunkDuration = chunkDuration
    self.primaryLanguageCode = primaryLanguageCode
    self.autoDetectFallback = autoDetectFallback
    self.compressToM4A = compressToM4A
    self.deleteWAVAfterCompression = deleteWAVAfterCompression
  }
}

private struct ActiveRecording {
  let meetingID: UUID
  let startedAt: Date
  let audioSession: MeetingAudioSession

  let microphoneJobID: UUID
  let systemJobID: UUID

  var microphoneSegments: [CarlaTranscription.TranscriptSegment]
  var systemSegments: [CarlaTranscription.TranscriptSegment]
}

/// Coordinates the end-to-end recording flow: audio capture, realtime transcription, storage.
///
/// Design notes:
/// - Uses **two realtime transcription jobs** (mic + system) so chunking and speaker/source mapping remain correct.
/// - Exposes state via `AsyncStream` instead of Combine to avoid Sendable/concurrency footguns.
public actor RecordingCoordinator {
  public struct Streams: Sendable {
    public let liveSegments: AsyncStream<[CarlaTranscription.TranscriptSegment]>
    public let audioLevels: AsyncStream<AudioLevelUpdate>
  }

  public nonisolated let streams: Streams

  private let transcriptionOrchestrator: TranscriptionJobOrchestrator
  private let repository: MeetingRepository
  private let paths: AppStoragePaths
  private let configuration: RecordingConfiguration

  private let liveSegmentsContinuation:
    AsyncStream<[CarlaTranscription.TranscriptSegment]>.Continuation
  private let audioLevelsContinuation: AsyncStream<AudioLevelUpdate>.Continuation

  private var activeRecording: ActiveRecording?

  private var frameContinuation: AsyncStream<(CapturedAudioFrame, TimeInterval)>.Continuation?
  private var frameProcessingTask: Task<Void, Never>?

  public init(
    transcriptionOrchestrator: TranscriptionJobOrchestrator,
    repository: MeetingRepository,
    paths: AppStoragePaths = AppStoragePaths(),
    configuration: RecordingConfiguration = RecordingConfiguration()
  ) {
    self.transcriptionOrchestrator = transcriptionOrchestrator
    self.repository = repository
    self.paths = paths
    self.configuration = configuration

    var segmentsCont: AsyncStream<[CarlaTranscription.TranscriptSegment]>.Continuation!
    let segments = AsyncStream<[CarlaTranscription.TranscriptSegment]> { continuation in
      segmentsCont = continuation
    }

    var levelsCont: AsyncStream<AudioLevelUpdate>.Continuation!
    let levels = AsyncStream<AudioLevelUpdate> { continuation in
      levelsCont = continuation
    }

    self.streams = Streams(liveSegments: segments, audioLevels: levels)
    self.liveSegmentsContinuation = segmentsCont
    self.audioLevelsContinuation = levelsCont
  }

  public var isRecording: Bool {
    activeRecording != nil
  }

  /// Starts a new recording session.
  public func startRecording() async throws -> UUID {
    guard activeRecording == nil else {
      throw RecordingError.alreadyRecording
    }

    let meetingID = UUID()
    let startedAt = Date()

    try paths.ensureDirectoriesExist()
    let outputDirectory = paths.audioDirectory.appendingPathComponent(
      meetingID.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

    // For crash recovery, persist the WAV path up-front.
    // If compression succeeds on stop, we update the meeting to point at the M4A.
    let expectedAudioPath =
      outputDirectory
      .appendingPathComponent("\(meetingID.uuidString)-stereo.wav")
      .path

    // Persist an initial meeting record immediately for crash recovery.
    do {
      try repository.saveMeeting(
        Meeting(
          id: meetingID,
          title: Self.defaultMeetingTitle(for: startedAt),
          startedAt: startedAt,
          duration: 0,
          audioFilePath: expectedAudioPath
        )
      )
    } catch {
      throw RecordingError.storageFailed(error)
    }

    // Audio capture + recorder.
    let postProcessor: AudioPostProcessing =
      configuration.compressToM4A
      ? M4ACompressionPostProcessor()
      : NoOpAudioPostProcessor()

    let recorder = WAVMeetingRecorder(postProcessor: postProcessor)
    let micCapturer = MicrophoneAudioCapturer()

    #if canImport(ScreenCaptureKit)
      let systemCapturer: AudioCapturing
      if #available(macOS 13.0, *) {
        systemCapturer = ScreenCaptureKitSystemAudioCapturer()
      } else {
        systemCapturer = StubSystemAudioCapturer()
      }
    #else
      let systemCapturer = StubSystemAudioCapturer()
    #endif

    let audioSession = MeetingAudioSession(
      microphone: micCapturer,
      systemAudio: systemCapturer,
      recorder: recorder
    )

    // Start transcription jobs (separate chunkers per source).
    let language = TranscriptionLanguageConfiguration(
      primaryLanguageCode: configuration.primaryLanguageCode,
      autoDetectFallback: configuration.autoDetectFallback
    )

    let baseConfig = RealtimeTranscriptionJobConfiguration(
      model: configuration.whisperModel,
      chunkDuration: configuration.chunkDuration,
      language: language
    )

    let microphoneJobID = await transcriptionOrchestrator.startRealtimeJob(
      configuration: baseConfig)
    let systemJobID = await transcriptionOrchestrator.startRealtimeJob(configuration: baseConfig)

    // Wire session events.
    let levelsContinuation = audioLevelsContinuation
    audioSession.onLevel = { update in
      levelsContinuation.yield(update)
    }

    let timelineStartUptime = ProcessInfo.processInfo.systemUptime

    var framesContinuation: AsyncStream<(CapturedAudioFrame, TimeInterval)>.Continuation?
    let frames = AsyncStream<(CapturedAudioFrame, TimeInterval)> { continuation in
      framesContinuation = continuation
    }

    let framesCont = framesContinuation!
    frameContinuation = framesCont

    frameProcessingTask = Task { [weak self] in
      guard let self else { return }
      for await (frame, packetStartTime) in frames {
        await self.handleAudioFrame(
          frame,
          meetingID: meetingID,
          packetStartTime: packetStartTime
        )
      }
    }

    audioSession.onFrame = { frame in
      let elapsed = ProcessInfo.processInfo.systemUptime - timelineStartUptime
      framesCont.yield((frame, elapsed))
    }

    do {
      try await audioSession.start(outputDirectory: outputDirectory, meetingID: meetingID)
    } catch {
      // Cleanup on failure.
      audioSession.onFrame = nil
      framesCont.finish()
      frameContinuation = nil
      frameProcessingTask?.cancel()
      frameProcessingTask = nil

      _ = await transcriptionOrchestrator.cancelRealtimeJob(microphoneJobID)
      _ = await transcriptionOrchestrator.cancelRealtimeJob(systemJobID)
      try? repository.deleteMeeting(id: meetingID)
      throw RecordingError.audioSessionFailed(error)
    }

    activeRecording = ActiveRecording(
      meetingID: meetingID,
      startedAt: startedAt,
      audioSession: audioSession,
      microphoneJobID: microphoneJobID,
      systemJobID: systemJobID,
      microphoneSegments: [],
      systemSegments: []
    )

    return meetingID
  }

  /// Stops the current recording session.
  public func stopRecording() async throws -> UUID {
    guard let recording = activeRecording else {
      throw RecordingError.notRecording
    }

    // Stop producing new frames for ingestion.
    recording.audioSession.onFrame = nil

    let artifacts: RecordingArtifacts
    do {
      artifacts = try await recording.audioSession.stop()
    } catch {
      throw RecordingError.audioSessionFailed(error)
    }

    // Drain any frames that were already enqueued before stop.
    frameContinuation?.finish()
    frameContinuation = nil
    if let task = frameProcessingTask {
      _ = await task.value
    }
    frameProcessingTask = nil

    let finalRecording = activeRecording ?? recording
    activeRecording = nil

    // Finalize transcription (both sources).
    let microphoneSegments: [CarlaTranscription.TranscriptSegment]
    let systemSegments: [CarlaTranscription.TranscriptSegment]

    do {
      microphoneSegments = try await transcriptionOrchestrator.finishRealtimeJob(
        finalRecording.microphoneJobID)
    } catch {
      let best = await transcriptionOrchestrator.cancelRealtimeJob(finalRecording.microphoneJobID)
      microphoneSegments = best.isEmpty ? finalRecording.microphoneSegments : best
    }

    do {
      systemSegments = try await transcriptionOrchestrator.finishRealtimeJob(
        finalRecording.systemJobID)
    } catch {
      let best = await transcriptionOrchestrator.cancelRealtimeJob(finalRecording.systemJobID)
      systemSegments = best.isEmpty ? finalRecording.systemSegments : best
    }

    let mergedSegments = Self.mergeSegments(
      microphoneSegments: microphoneSegments, systemSegments: systemSegments)

    // Update meeting metadata + final stereo file path.
    let endedAt = Date()
    let duration = endedAt.timeIntervalSince(finalRecording.startedAt)

    let stereoWAV = artifacts.stereoMixWAV
    let stereoM4AURL = stereoWAV.deletingPathExtension().appendingPathExtension("m4a")

    let audioFilePath: String
    if configuration.compressToM4A, FileManager.default.fileExists(atPath: stereoM4AURL.path) {
      audioFilePath = stereoM4AURL.path
    } else {
      audioFilePath = stereoWAV.path
    }

    var meeting = Meeting(
      id: finalRecording.meetingID,
      title: Self.defaultMeetingTitle(for: finalRecording.startedAt),
      startedAt: finalRecording.startedAt,
      endedAt: endedAt,
      duration: duration,
      audioFilePath: audioFilePath
    )
    meeting.updatedAt = Date()

    do {
      try repository.saveMeeting(meeting)
    } catch {
      throw RecordingError.storageFailed(error)
    }

    // Persist speakers + segments (best effort; storage errors here should not crash stop flow).
    persistSpeakersAndSegments(meetingID: finalRecording.meetingID, segments: mergedSegments)

    // Cleanup WAVs only if compression succeeded and we actually reference the M4A.
    if configuration.compressToM4A,
      configuration.deleteWAVAfterCompression,
      audioFilePath == stereoM4AURL.path
    {
      let fileManager = FileManager.default
      try? fileManager.removeItem(at: artifacts.microphoneWAV)
      try? fileManager.removeItem(at: artifacts.systemWAV)
      try? fileManager.removeItem(at: artifacts.stereoMixWAV)
    }

    return finalRecording.meetingID
  }

  // MARK: - Private

  private func handleAudioFrame(
    _ frame: CapturedAudioFrame,
    meetingID: UUID,
    packetStartTime: TimeInterval
  ) async {
    guard var recording = activeRecording, recording.meetingID == meetingID else { return }

    let source: TranscriptionTrackSource = frame.source == .microphone ? .microphone : .systemAudio

    let packet = AudioPacket(
      startTime: packetStartTime,
      sampleRate: frame.buffer.format.sampleRate,
      samples: AudioPCMUtilities.samples(from: frame.buffer),
      source: source
    )

    do {
      switch source {
      case .microphone:
        let updated = try await transcriptionOrchestrator.ingest(
          packet, for: recording.microphoneJobID)
        recording.microphoneSegments = updated
      case .systemAudio:
        let updated = try await transcriptionOrchestrator.ingest(packet, for: recording.systemJobID)
        recording.systemSegments = updated
      }

      let merged = Self.mergeSegments(
        microphoneSegments: recording.microphoneSegments,
        systemSegments: recording.systemSegments
      )

      activeRecording = recording
      liveSegmentsContinuation.yield(merged)

    } catch {
      // Best-effort: do not interrupt recording.
      // Consider surfacing to UI via a separate error stream if we want user-visible errors.
    }
  }

  private func persistSpeakersAndSegments(
    meetingID: UUID,
    segments: [CarlaTranscription.TranscriptSegment]
  ) {
    let you = Speaker(meetingID: meetingID, label: "You", isLocal: true)
    let others = Speaker(meetingID: meetingID, label: "Others", isLocal: false)

    do {
      try repository.saveSpeakers([you, others])
    } catch {
      return
    }

    let dbSegments: [CarlaModels.TranscriptSegment] = segments.map { segment in
      let speakerID = segment.source == .microphone ? you.id : others.id
      return CarlaModels.TranscriptSegment(
        meetingID: meetingID,
        speakerID: speakerID,
        startTime: segment.startTime,
        endTime: segment.endTime,
        text: segment.text,
        confidence: segment.confidence,
        language: segment.language ?? "en"
      )
    }

    try? repository.saveTranscriptSegments(dbSegments)
  }

  private static func mergeSegments(
    microphoneSegments: [CarlaTranscription.TranscriptSegment],
    systemSegments: [CarlaTranscription.TranscriptSegment]
  ) -> [CarlaTranscription.TranscriptSegment] {
    var all = microphoneSegments + systemSegments
    all.sort {
      if abs($0.startTime - $1.startTime) > 0.0001 {
        return $0.startTime < $1.startTime
      }
      return $0.endTime < $1.endTime
    }
    return all
  }

  private static func defaultMeetingTitle(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d, yyyy h:mm a"
    return "Meeting – \(formatter.string(from: date))"
  }
}
