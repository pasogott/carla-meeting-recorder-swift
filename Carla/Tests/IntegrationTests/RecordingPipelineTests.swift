import CarlaModels
import XCTest

@testable import CarlaStorage
@testable import CarlaTranscription

/// Integration tests for the recording pipeline.
/// These tests verify the full workflow without requiring actual audio hardware.
/// They test: transcription → storage → search flow.
final class RecordingPipelineTests: XCTestCase {
  private var database: CarlaDatabase!
  private var repository: GRDBMeetingRepository!

  override func setUpWithError() throws {
    database = try CarlaDatabase(inMemory: true)
    repository = GRDBMeetingRepository(dbWriter: database.dbQueue)
  }

  override func tearDownWithError() throws {
    database = nil
    repository = nil
  }

  // MARK: - Transcription Pipeline Tests

  /// Test: Start transcription job → ingest audio packets → verify transcript segments produced
  func testTranscriptionPipelineProducesSegments() async throws {
    // Setup mock transcription engine with predictable output
    let mockEngine = MockWhisperEngine(
      mode: .custom(
        stream: { chunk, _, _ in
          WhisperTranscriptionResult(
            segments: [
              WhisperSegment(
                startTime: 0,
                endTime: chunk.endTime - chunk.startTime,
                text: "Hello, this is a test meeting transcript.",
                confidence: 0.95
              )
            ],
            detectedLanguageCode: "en"
          )
        },
        file: { _, _, _ in
          WhisperTranscriptionResult(segments: [], detectedLanguageCode: "en")
        }
      ))

    let orchestrator = TranscriptionJobOrchestrator(engine: mockEngine)
    let config = RealtimeTranscriptionJobConfiguration(
      model: .base,
      chunkDuration: 1.0,
      language: TranscriptionLanguageConfiguration(primaryLanguageCode: "en")
    )

    // Start a realtime transcription job
    let jobID = await orchestrator.startRealtimeJob(configuration: config)

    // Ingest audio packets (simulating 2 seconds of audio)
    let sampleRate: Double = 16_000
    let samplesPerChunk = Int(sampleRate * 1.0)  // 1 second worth
    let samples = Array(repeating: Float(0.5), count: samplesPerChunk)

    // First packet
    let packet1 = AudioPacket(
      startTime: 0,
      sampleRate: sampleRate,
      samples: samples,
      source: .microphone
    )
    let segments1 = try await orchestrator.ingest(packet1, for: jobID)
    XCTAssertFalse(segments1.isEmpty, "Should produce segments after ingesting audio")

    // Second packet
    let packet2 = AudioPacket(
      startTime: 1.0,
      sampleRate: sampleRate,
      samples: samples,
      source: .microphone
    )
    let segments2 = try await orchestrator.ingest(packet2, for: jobID)
    XCTAssertFalse(segments2.isEmpty, "Should have accumulated segments")

    // Finish the job
    let finalSegments = try await orchestrator.finishRealtimeJob(jobID)

    XCTAssertFalse(finalSegments.isEmpty, "Should have final segments")
    XCTAssertTrue(finalSegments.first?.text.contains("test meeting") ?? false)
    XCTAssertEqual(finalSegments.first?.speaker, "You")  // microphone = local speaker
  }

  /// Test: Transcription with system audio (remote speaker)
  func testTranscriptionIdentifiesRemoteSpeaker() async throws {
    let mockEngine = MockWhisperEngine(
      mode: .custom(
        stream: { _, _, _ in
          WhisperTranscriptionResult(
            segments: [
              WhisperSegment(
                startTime: 0, endTime: 1, text: "Remote speaker talking", confidence: 0.9)
            ],
            detectedLanguageCode: "en"
          )
        },
        file: { _, _, _ in
          WhisperTranscriptionResult(segments: [], detectedLanguageCode: "en")
        }
      ))

    let orchestrator = TranscriptionJobOrchestrator(engine: mockEngine)
    let config = RealtimeTranscriptionJobConfiguration(
      model: .base,
      chunkDuration: 1.0,
      language: TranscriptionLanguageConfiguration(primaryLanguageCode: "en")
    )

    let jobID = await orchestrator.startRealtimeJob(configuration: config)

    let packet = AudioPacket(
      startTime: 0,
      sampleRate: 16_000,
      samples: Array(repeating: Float(0.5), count: 16_000),
      source: .systemAudio  // System audio = remote speaker
    )

    let segments = try await orchestrator.ingest(packet, for: jobID)
    _ = try await orchestrator.finishRealtimeJob(jobID)

    XCTAssertEqual(segments.first?.speaker, "Others")  // system audio = remote speaker
  }

  // MARK: - Storage Integration Tests

  /// Test: Save meeting with transcript segments → verify data persisted correctly
  func testMeetingSavedWithTranscriptSegments() throws {
    let meetingID = UUID()

    // Create meeting
    let meeting = Meeting(
      id: meetingID,
      title: "Integration Test Meeting",
      startedAt: Date(),
      endedAt: Date().addingTimeInterval(1800),
      duration: 1800,
      audioFilePath: "/tmp/test-meeting.m4a"
    )
    try repository.saveMeeting(meeting)

    // Save transcript segments (simulating what RecordingCoordinator does)
    let segments = [
      CarlaModels.TranscriptSegment(
        meetingID: meetingID,
        startTime: 0,
        endTime: 5,
        text: "Welcome to the meeting.",
        confidence: 0.95,
        language: "en"
      ),
      CarlaModels.TranscriptSegment(
        meetingID: meetingID,
        startTime: 6,
        endTime: 15,
        text: "Today we'll discuss the quarterly budget review.",
        confidence: 0.92,
        language: "en"
      ),
      CarlaModels.TranscriptSegment(
        meetingID: meetingID,
        startTime: 16,
        endTime: 30,
        text: "Let's start with the revenue numbers.",
        confidence: 0.88,
        language: "en"
      ),
    ]
    try repository.saveTranscriptSegments(segments)

    // Verify meeting was saved
    let savedDetails = try repository.fetchMeetingDetails(id: meetingID)
    XCTAssertEqual(savedDetails.meeting.id, meetingID)
    XCTAssertEqual(savedDetails.meeting.title, "Integration Test Meeting")
    XCTAssertEqual(savedDetails.meeting.duration, 1800)

    // Verify segments were saved
    XCTAssertEqual(savedDetails.segments.count, 3)
    XCTAssertEqual(savedDetails.segments[0].text, "Welcome to the meeting.")
    XCTAssertEqual(
      savedDetails.segments[1].text, "Today we'll discuss the quarterly budget review.")
    XCTAssertEqual(savedDetails.segments[2].text, "Let's start with the revenue numbers.")
  }

  /// Test: Verify FTS5 search finds saved transcript text
  func testFTS5SearchFindsTranscriptText() throws {
    let meetingID = UUID()
    let searchableText = "quarterly budget review discussion"

    // Create meeting
    let meeting = Meeting(
      id: meetingID,
      title: "Q4 Planning Meeting",
      startedAt: Date(),
      duration: 300,
      audioFilePath: "/tmp/test-audio.m4a"
    )
    try repository.saveMeeting(meeting)

    // Save transcript segments with searchable text
    let segments = [
      CarlaModels.TranscriptSegment(
        meetingID: meetingID,
        startTime: 0,
        endTime: 5,
        text: "Welcome to the \(searchableText) for this quarter.",
        confidence: 0.95,
        language: "en"
      ),
      CarlaModels.TranscriptSegment(
        meetingID: meetingID,
        startTime: 6,
        endTime: 12,
        text: "Let's look at the revenue numbers.",
        confidence: 0.92,
        language: "en"
      ),
    ]
    try repository.saveTranscriptSegments(segments)

    // Search for "budget"
    let results = try repository.searchTranscript(query: "budget", limit: 10)
    XCTAssertEqual(results.count, 1, "Should find exactly one segment with 'budget'")
    XCTAssertEqual(results.first?.meetingID, meetingID)
    XCTAssertTrue(results.first?.text.contains("budget") ?? false)

    // Search for "revenue"
    let revenueResults = try repository.searchTranscript(query: "revenue", limit: 10)
    XCTAssertEqual(revenueResults.count, 1)
    XCTAssertEqual(revenueResults.first?.meetingID, meetingID)

    // Search for non-existent term
    let noResults = try repository.searchTranscript(query: "nonexistentterm", limit: 10)
    XCTAssertTrue(noResults.isEmpty)
  }

  /// Test: FTS5 search works across multiple meetings
  func testFTS5SearchAcrossMultipleMeetings() throws {
    let meeting1ID = UUID()
    let meeting2ID = UUID()

    // Create two meetings
    let meeting1 = Meeting(
      id: meeting1ID,
      title: "Product Roadmap",
      startedAt: Date().addingTimeInterval(-3600),
      duration: 1800,
      audioFilePath: "/tmp/meeting1.m4a"
    )
    let meeting2 = Meeting(
      id: meeting2ID,
      title: "Engineering Sync",
      startedAt: Date(),
      duration: 900,
      audioFilePath: "/tmp/meeting2.m4a"
    )
    try repository.saveMeeting(meeting1)
    try repository.saveMeeting(meeting2)

    // Add segments to both meetings
    try repository.saveTranscriptSegments([
      CarlaModels.TranscriptSegment(
        meetingID: meeting1ID,
        startTime: 0,
        endTime: 5,
        text: "We need to discuss the API integration timeline.",
        confidence: 0.9,
        language: "en"
      ),
      CarlaModels.TranscriptSegment(
        meetingID: meeting2ID,
        startTime: 0,
        endTime: 5,
        text: "The API performance needs optimization.",
        confidence: 0.88,
        language: "en"
      ),
    ])

    // Search should find both meetings
    let apiResults = try repository.searchTranscript(query: "API", limit: 10)
    XCTAssertEqual(apiResults.count, 2)

    let meetingIDs = Set(apiResults.map { $0.meetingID })
    XCTAssertTrue(meetingIDs.contains(meeting1ID))
    XCTAssertTrue(meetingIDs.contains(meeting2ID))

    // Search for meeting-specific term
    let timelineResults = try repository.searchTranscript(query: "timeline", limit: 10)
    XCTAssertEqual(timelineResults.count, 1)
    XCTAssertEqual(timelineResults.first?.meetingID, meeting1ID)
  }

  /// Test: Meeting audio path reflects M4A after compression
  func testMeetingAudioPathReflectsCompression() throws {
    let meetingID = UUID()

    // Initially save with WAV path (before compression)
    var meeting = Meeting(
      id: meetingID,
      title: "Compression Test Meeting",
      startedAt: Date(),
      duration: 600,
      audioFilePath: "/tmp/audio/\(meetingID.uuidString)-stereo.wav"
    )
    try repository.saveMeeting(meeting)

    // Update to M4A path (after compression) - this simulates what RecordingCoordinator does
    meeting.audioFilePath = "/tmp/audio/\(meetingID.uuidString)-stereo.m4a"
    meeting.updatedAt = Date()
    try repository.saveMeeting(meeting)

    // Verify the audio path was updated
    let savedDetails = try repository.fetchMeetingDetails(id: meetingID)
    XCTAssertTrue(
      savedDetails.meeting.audioFilePath.hasSuffix(".m4a"),
      "Audio path should be M4A after compression update"
    )
  }

  // MARK: - End-to-End Pipeline Tests

  /// Test: Full pipeline - transcribe → save meeting → save segments → search
  func testFullPipelineTranscribeToSearch() async throws {
    // 1. Transcription phase
    let mockEngine = MockWhisperEngine(
      mode: .custom(
        stream: { chunk, _, _ in
          // Simulate realistic transcription output
          let text: String
          if chunk.startTime < 5 {
            text = "Welcome everyone to the project kickoff meeting."
          } else {
            text = "Let's discuss the machine learning integration timeline."
          }
          return WhisperTranscriptionResult(
            segments: [
              WhisperSegment(
                startTime: 0, endTime: chunk.endTime - chunk.startTime, text: text, confidence: 0.92
              )
            ],
            detectedLanguageCode: "en"
          )
        },
        file: { _, _, _ in
          WhisperTranscriptionResult(segments: [], detectedLanguageCode: "en")
        }
      ))

    let orchestrator = TranscriptionJobOrchestrator(engine: mockEngine)
    let config = RealtimeTranscriptionJobConfiguration(
      model: .base,
      chunkDuration: 2.0,
      language: TranscriptionLanguageConfiguration(primaryLanguageCode: "en")
    )

    let jobID = await orchestrator.startRealtimeJob(configuration: config)

    // Ingest audio (8 seconds total). Ensure at least one chunk starts after 5s
    // so the mock produces the "machine learning" text.
    for i in 0..<4 {
      let packet = AudioPacket(
        startTime: TimeInterval(i * 2),
        sampleRate: 16_000,
        samples: Array(repeating: Float(0.3), count: 32_000),
        source: .microphone
      )
      _ = try await orchestrator.ingest(packet, for: jobID)
    }

    let transcribedSegments = try await orchestrator.finishRealtimeJob(jobID)
    XCTAssertFalse(transcribedSegments.isEmpty)

    // 2. Storage phase - save meeting
    let meetingID = UUID()
    let meeting = Meeting(
      id: meetingID,
      title: "Project Kickoff",
      startedAt: Date(),
      duration: 8,
      audioFilePath: "/tmp/kickoff.m4a"
    )
    try repository.saveMeeting(meeting)

    // Convert transcribed segments to storage format
    let dbSegments = transcribedSegments.map { segment in
      CarlaModels.TranscriptSegment(
        meetingID: meetingID,
        startTime: segment.startTime,
        endTime: segment.endTime,
        text: segment.text,
        confidence: segment.confidence,
        language: segment.language ?? "en"
      )
    }
    try repository.saveTranscriptSegments(dbSegments)

    // 3. Search phase - verify FTS5 works
    let kickoffResults = try repository.searchTranscript(query: "kickoff", limit: 10)
    XCTAssertFalse(kickoffResults.isEmpty, "Should find 'kickoff' in transcript")
    XCTAssertEqual(kickoffResults.first?.meetingID, meetingID)

    let mlResults = try repository.searchTranscript(query: "machine learning", limit: 10)
    XCTAssertFalse(mlResults.isEmpty, "Should find 'machine learning' in transcript")
  }

  /// Test: Multiple concurrent transcription jobs don't interfere
  func testMultipleConcurrentTranscriptionJobs() async throws {
    let mockEngine = MockWhisperEngine()
    let orchestrator = TranscriptionJobOrchestrator(engine: mockEngine)

    // Start two concurrent jobs
    let config1 = RealtimeTranscriptionJobConfiguration(
      model: .base,
      chunkDuration: 1.0,
      language: TranscriptionLanguageConfiguration(primaryLanguageCode: "en"),
      speakerMapper: SpeakerMapper(localSpeakerLabel: "Alice", remoteSpeakerLabel: "Others")
    )
    let config2 = RealtimeTranscriptionJobConfiguration(
      model: .base,
      chunkDuration: 1.0,
      language: TranscriptionLanguageConfiguration(primaryLanguageCode: "de"),
      speakerMapper: SpeakerMapper(localSpeakerLabel: "Bob", remoteSpeakerLabel: "Others")
    )

    let job1 = await orchestrator.startRealtimeJob(configuration: config1)
    let job2 = await orchestrator.startRealtimeJob(configuration: config2)

    // Ingest to both jobs
    let packet = AudioPacket(
      startTime: 0,
      sampleRate: 16_000,
      samples: Array(repeating: Float(0.5), count: 16_000),
      source: .microphone
    )

    let segments1 = try await orchestrator.ingest(packet, for: job1)
    let segments2 = try await orchestrator.ingest(packet, for: job2)

    // Jobs should have different speaker labels
    XCTAssertEqual(segments1.first?.speaker, "Alice")
    XCTAssertEqual(segments2.first?.speaker, "Bob")

    // Finish both
    _ = try await orchestrator.finishRealtimeJob(job1)
    _ = try await orchestrator.finishRealtimeJob(job2)
  }

  // MARK: - Error Handling Tests

  /// Test: Accessing non-existent meeting throws appropriate error
  func testAccessingNonExistentMeetingThrows() throws {
    let nonExistentID = UUID()

    do {
      _ = try repository.fetchMeetingDetails(id: nonExistentID)
      XCTFail("Should throw for non-existent meeting")
    } catch let error as StorageError {
      if case .meetingNotFound(let id) = error {
        XCTAssertEqual(id, nonExistentID)
      } else {
        XCTFail("Expected meetingNotFound error, got: \(error)")
      }
    }
  }

  /// Test: Deleting meeting removes segments via cascade
  func testDeletingMeetingRemovesSegments() throws {
    let meetingID = UUID()

    // Create meeting with segments
    let meeting = Meeting(
      id: meetingID,
      title: "To Be Deleted",
      startedAt: Date(),
      duration: 60,
      audioFilePath: "/tmp/delete-me.m4a"
    )
    try repository.saveMeeting(meeting)

    try repository.saveTranscriptSegments([
      CarlaModels.TranscriptSegment(
        meetingID: meetingID,
        startTime: 0,
        endTime: 5,
        text: "This will be deleted.",
        confidence: 0.9,
        language: "en"
      )
    ])

    // Verify data exists
    let detailsBefore = try repository.fetchMeetingDetails(id: meetingID)
    XCTAssertEqual(detailsBefore.segments.count, 1)

    // Delete meeting
    try repository.deleteMeeting(id: meetingID)

    // Meeting should not exist
    do {
      _ = try repository.fetchMeetingDetails(id: meetingID)
      XCTFail("Should throw after deletion")
    } catch is StorageError {
      // Expected
    }

    // Search should not find deleted content
    let results = try repository.searchTranscript(query: "deleted", limit: 10)
    XCTAssertTrue(results.isEmpty)
  }
}
