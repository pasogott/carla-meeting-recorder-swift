import CarlaCoreTypes
import CarlaModels
import XCTest

@testable import CarlaRecording
@testable import CarlaStorage
@testable import CarlaTranscription

final class RecordingCoordinatorStopRecordingTests: XCTestCase {
  func testFinalizeStopFlowRunsPolishAfterRealtimeFinalization() async throws {
    let eventLog = EventLog()

    let engine = MockWhisperEngine(
      mode: .custom(
        stream: { chunk, _, _ in
          await eventLog.append("stream-\(chunk.source)")
          return WhisperTranscriptionResult(
            segments: [
              WhisperSegment(
                startTime: 0,
                endTime: chunk.endTime - chunk.startTime,
                text: "rt-\(chunk.source)",
                confidence: 0.9
              )
            ],
            detectedLanguageCode: "en"
          )
        },
        file: { _, _, _ in
          await eventLog.append("file")
          return WhisperTranscriptionResult(
            segments: [
              WhisperSegment(startTime: 0, endTime: 1, text: "polished", confidence: 0.95)
            ],
            detectedLanguageCode: "en"
          )
        }
      )
    )

    let orchestrator = TranscriptionJobOrchestrator(engine: engine)
    let repository = RecordingCoordinatorRepositoryMock()
    let coordinator = RecordingCoordinator(
      transcriptionOrchestrator: orchestrator,
      repository: repository,
      configuration: RecordingConfiguration(compressToM4A: false)
    )

    let jobs = await makeRealtimeJobs(orchestrator: orchestrator)
    let meetingID = UUID()

    let context = RecordingCoordinator.StopFinalizationContext(
      meetingID: meetingID,
      startedAt: Date().addingTimeInterval(-5),
      microphoneJobID: jobs.microphone,
      systemJobID: jobs.system,
      fallbackMicrophoneSegments: [],
      fallbackSystemSegments: []
    )

    let artifacts = makeArtifacts(for: meetingID)
    let completedMeetingID = try await coordinator.finalizeStopFlow(context: context, artifacts: artifacts)

    XCTAssertEqual(completedMeetingID, meetingID)

    let events = await eventLog.snapshot()
    XCTAssertEqual(events, ["stream-microphone", "stream-systemAudio", "file"])
    XCTAssertEqual(repository.savedTranscriptSegments.map(\.text), ["polished"])
  }

  func testFinalizeStopFlowFallsBackToRealtimeWhenPolishFails() async throws {
    let engine = MockWhisperEngine(
      mode: .custom(
        stream: { chunk, _, _ in
          let text = chunk.source == .microphone ? "rt-mic" : "rt-system"
          return WhisperTranscriptionResult(
            segments: [
              WhisperSegment(
                startTime: 0,
                endTime: chunk.endTime - chunk.startTime,
                text: text,
                confidence: 0.9
              )
            ],
            detectedLanguageCode: "en"
          )
        },
        file: { _, _, _ in
          throw NSError(domain: "test", code: 42)
        }
      )
    )

    let orchestrator = TranscriptionJobOrchestrator(engine: engine)
    let repository = RecordingCoordinatorRepositoryMock()
    let coordinator = RecordingCoordinator(
      transcriptionOrchestrator: orchestrator,
      repository: repository,
      configuration: RecordingConfiguration(compressToM4A: false)
    )

    let jobs = await makeRealtimeJobs(orchestrator: orchestrator)
    let meetingID = UUID()

    let context = RecordingCoordinator.StopFinalizationContext(
      meetingID: meetingID,
      startedAt: Date().addingTimeInterval(-5),
      microphoneJobID: jobs.microphone,
      systemJobID: jobs.system,
      fallbackMicrophoneSegments: [],
      fallbackSystemSegments: []
    )

    let artifacts = makeArtifacts(for: meetingID)
    _ = try await coordinator.finalizeStopFlow(context: context, artifacts: artifacts)

    XCTAssertEqual(repository.savedMeetings.last?.id, meetingID)
    XCTAssertEqual(repository.savedTranscriptSegments.map(\.text).sorted(), ["rt-mic", "rt-system"])
  }

  private func makeRealtimeJobs(orchestrator: TranscriptionJobOrchestrator) async -> (
    microphone: UUID,
    system: UUID
  ) {
    let config = RealtimeTranscriptionJobConfiguration(
      model: .base,
      chunkDuration: 10,
      language: TranscriptionLanguageConfiguration(primaryLanguageCode: "en")
    )

    let microphoneJob = await orchestrator.startRealtimeJob(configuration: config)
    let systemJob = await orchestrator.startRealtimeJob(configuration: config)

    let micPacket = AudioPacket(
      startTime: 0,
      sampleRate: 16_000,
      samples: Array(repeating: 0.1, count: 8_000),
      source: .microphone
    )
    let systemPacket = AudioPacket(
      startTime: 0,
      sampleRate: 16_000,
      samples: Array(repeating: 0.1, count: 8_000),
      source: .systemAudio
    )

    _ = try? await orchestrator.ingest(micPacket, for: microphoneJob)
    _ = try? await orchestrator.ingest(systemPacket, for: systemJob)

    return (microphoneJob, systemJob)
  }

  private func makeArtifacts(for meetingID: UUID) -> RecordingArtifacts {
    let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("recording-coordinator-stop-tests", isDirectory: true)
      .appendingPathComponent(meetingID.uuidString, isDirectory: true)

    return RecordingArtifacts(
      microphoneWAV: base.appendingPathComponent("mic.wav"),
      systemWAV: base.appendingPathComponent("system.wav"),
      stereoMixWAV: base.appendingPathComponent("stereo.wav")
    )
  }
}

private actor EventLog {
  private var values: [String] = []

  func append(_ value: String) {
    values.append(value)
  }

  func snapshot() -> [String] {
    values
  }
}

private final class RecordingCoordinatorRepositoryMock: MeetingRepository, @unchecked Sendable {
  private(set) var savedMeetings: [Meeting] = []
  private(set) var savedTranscriptSegments: [CarlaModels.TranscriptSegment] = []

  func saveMeeting(_ meeting: Meeting) throws {
    savedMeetings.append(meeting)
  }

  func saveSpeakers(_ speakers: [Speaker]) throws {}

  func saveTranscriptSegments(_ segments: [CarlaModels.TranscriptSegment]) throws {
    savedTranscriptSegments = segments
  }

  func saveSummary(_ summary: MeetingSummary, actionItems: [ActionItem]) throws {}

  func fetchMeetingDetails(id: UUID) throws -> MeetingDetails {
    throw StorageError.meetingNotFound(id)
  }

  func listMeetings(limit: Int?, offset: Int?) throws -> [Meeting] {
    []
  }

  func searchTranscript(query: String, limit: Int) throws -> [TranscriptSearchResult] {
    []
  }

  func deleteMeeting(id: UUID) throws {}
}
