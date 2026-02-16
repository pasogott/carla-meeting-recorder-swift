import CarlaModels
import XCTest

@testable import CarlaStorage

/// Integration tests for the export pipeline.
/// Verifies that the full recording → storage → export flow produces correct output.
final class ExportIntegrationTests: XCTestCase {
  private var database: CarlaDatabase!
  private var repository: GRDBMeetingRepository!
  private var exportService: MeetingExportService!
  private var tempExportDir: URL!

  override func setUpWithError() throws {
    database = try CarlaDatabase(inMemory: true)
    repository = GRDBMeetingRepository(dbWriter: database.dbQueue)

    tempExportDir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "carla-export-test-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: tempExportDir, withIntermediateDirectories: true)

    exportService = MeetingExportService(
      repository: repository,
      paths: AppStoragePaths()
    )
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: tempExportDir)
  }

  // MARK: - Markdown Export Tests

  /// Test: Verify export produces correct Markdown output
  func testMarkdownExportContainsAllRequiredSections() throws {
    // Create a complete meeting with all components
    let meetingID = UUID()
    let meeting = Meeting(
      id: meetingID,
      title: "Weekly Team Standup",
      startedAt: Date(timeIntervalSince1970: 1_700_000_000),
      duration: 1800,
      audioFilePath: "/tmp/standup.m4a"
    )
    try repository.saveMeeting(meeting)

    // Add transcript segments
    let segments = [
      TranscriptSegment(
        meetingID: meetingID,
        startTime: 0,
        endTime: 5.5,
        text: "Good morning everyone, let's start the standup.",
        confidence: 0.95,
        language: "en"
      ),
      TranscriptSegment(
        meetingID: meetingID,
        startTime: 6,
        endTime: 15,
        text: "Yesterday I completed the API integration for the payment module.",
        confidence: 0.92,
        language: "en"
      ),
      TranscriptSegment(
        meetingID: meetingID,
        startTime: 16,
        endTime: 25,
        text: "Today I'll be working on the unit tests for the same module.",
        confidence: 0.89,
        language: "en"
      ),
    ]
    try repository.saveTranscriptSegments(segments)

    // Add summary and action items
    let summary = MeetingSummary(
      meetingID: meetingID,
      summary: "Team discussed progress on payment integration and upcoming testing work.",
      keyDecisions: ["Focus testing on edge cases", "Deploy to staging by Friday"],
      followUps: ["Review test coverage report", "Update documentation"]
    )
    let actionItems = [
      ActionItem(
        meetingID: meetingID,
        description: "Write unit tests for payment module",
        assignee: "Alice"
      ),
      ActionItem(
        meetingID: meetingID,
        description: "Update API documentation",
        assignee: "Bob"
      ),
    ]
    try repository.saveSummary(summary, actionItems: actionItems)

    // Export to Markdown
    let exportedURL = try exportService.exportMeeting(
      meetingID, format: .markdown, destination: tempExportDir)
    XCTAssertTrue(FileManager.default.fileExists(atPath: exportedURL.path))

    let content = try String(contentsOf: exportedURL)

    // Verify title
    XCTAssertTrue(content.contains("# Weekly Team Standup"), "Should contain meeting title")

    // Verify metadata
    XCTAssertTrue(content.contains("**Meeting ID:**"), "Should contain meeting ID")
    XCTAssertTrue(content.contains("**Started:**"), "Should contain start time")
    XCTAssertTrue(content.contains("**Duration:**"), "Should contain duration")

    // Verify summary section
    XCTAssertTrue(content.contains("## Summary"), "Should contain summary section")
    XCTAssertTrue(content.contains("payment integration"), "Should contain summary content")

    // Verify key decisions
    XCTAssertTrue(content.contains("### Key Decisions"), "Should contain key decisions section")
    XCTAssertTrue(content.contains("Focus testing on edge cases"), "Should contain first decision")
    XCTAssertTrue(content.contains("Deploy to staging by Friday"), "Should contain second decision")

    // Verify action items
    XCTAssertTrue(content.contains("### Action Items"), "Should contain action items section")
    XCTAssertTrue(
      content.contains("Write unit tests for payment module"), "Should contain first action item")
    XCTAssertTrue(content.contains("Alice"), "Should contain assignee")
    XCTAssertTrue(content.contains("Update API documentation"), "Should contain second action item")

    // Verify transcript section
    XCTAssertTrue(content.contains("## Transcript"), "Should contain transcript section")
    XCTAssertTrue(content.contains("Good morning everyone"), "Should contain transcript text")
    XCTAssertTrue(content.contains("[00:00:00]"), "Should contain timestamp")
  }

  /// Test: Markdown export without summary (transcript only)
  func testMarkdownExportWithoutSummary() throws {
    let meetingID = UUID()
    let meeting = Meeting(
      id: meetingID,
      title: "Quick Sync",
      startedAt: Date(),
      duration: 300,
      audioFilePath: "/tmp/sync.m4a"
    )
    try repository.saveMeeting(meeting)

    let segments = [
      TranscriptSegment(
        meetingID: meetingID,
        startTime: 0,
        endTime: 10,
        text: "Let's quickly review the status.",
        confidence: 0.9,
        language: "en"
      )
    ]
    try repository.saveTranscriptSegments(segments)

    let exportedURL = try exportService.exportMeeting(
      meetingID, format: .markdown, destination: tempExportDir)
    let content = try String(contentsOf: exportedURL)

    XCTAssertTrue(content.contains("# Quick Sync"))
    XCTAssertTrue(content.contains("## Transcript"))
    XCTAssertTrue(content.contains("Let's quickly review"))
    // Should not have summary sections without summary data
    XCTAssertFalse(content.contains("## Summary"))
  }

  // MARK: - SRT Export Tests

  /// Test: Verify export produces correct SRT output
  func testSRTExportFormatIsCorrect() throws {
    let meetingID = UUID()
    let meeting = Meeting(
      id: meetingID,
      title: "Interview Recording",
      startedAt: Date(),
      duration: 60,
      audioFilePath: "/tmp/interview.m4a"
    )
    try repository.saveMeeting(meeting)

    let segments = [
      TranscriptSegment(
        meetingID: meetingID,
        startTime: 0,
        endTime: 2.5,
        text: "Hello and welcome.",
        confidence: 0.95,
        language: "en"
      ),
      TranscriptSegment(
        meetingID: meetingID,
        startTime: 3.0,
        endTime: 7.75,
        text: "Thank you for having me today.",
        confidence: 0.92,
        language: "en"
      ),
      TranscriptSegment(
        meetingID: meetingID,
        startTime: 8.0,
        endTime: 15.123,
        text: "Let's start with your background.",
        confidence: 0.88,
        language: "en"
      ),
    ]
    try repository.saveTranscriptSegments(segments)

    let exportedURL = try exportService.exportMeeting(
      meetingID, format: .srt, destination: tempExportDir)
    let content = try String(contentsOf: exportedURL)

    // SRT format validation:
    // 1
    // 00:00:00,000 --> 00:00:02,500
    // Hello and welcome.

    // Verify sequence numbers
    XCTAssertTrue(content.contains("1\n"), "Should start with sequence number 1")
    XCTAssertTrue(content.contains("2\n"), "Should have sequence number 2")
    XCTAssertTrue(content.contains("3\n"), "Should have sequence number 3")

    // Verify timestamp format (HH:MM:SS,mmm --> HH:MM:SS,mmm)
    XCTAssertTrue(
      content.contains("00:00:00,000 --> 00:00:02,500"), "Should have correct first timestamp")
    XCTAssertTrue(
      content.contains("00:00:03,000 --> 00:00:07,750"), "Should have correct second timestamp")
    XCTAssertTrue(
      content.contains("00:00:08,000 --> 00:00:15,123"), "Should have correct third timestamp")

    // Verify subtitle text
    XCTAssertTrue(content.contains("Hello and welcome."))
    XCTAssertTrue(content.contains("Thank you for having me today."))
    XCTAssertTrue(content.contains("Let's start with your background."))
  }

  /// Test: SRT export handles long timestamps correctly (over 1 hour)
  func testSRTExportHandlesLongTimestamps() throws {
    let meetingID = UUID()
    let meeting = Meeting(
      id: meetingID,
      title: "Long Meeting",
      startedAt: Date(),
      duration: 5400,
      audioFilePath: "/tmp/long.m4a"
    )
    try repository.saveMeeting(meeting)

    let segments = [
      TranscriptSegment(
        meetingID: meetingID,
        startTime: 3661.5,  // 1 hour, 1 minute, 1.5 seconds
        endTime: 3665.75,
        text: "We're still going strong.",
        confidence: 0.9,
        language: "en"
      )
    ]
    try repository.saveTranscriptSegments(segments)

    let exportedURL = try exportService.exportMeeting(
      meetingID, format: .srt, destination: tempExportDir)
    let content = try String(contentsOf: exportedURL)

    XCTAssertTrue(
      content.contains("01:01:01,500 --> 01:01:05,750"), "Should handle timestamps over 1 hour")
  }

  // MARK: - TXT Export Tests

  /// Test: TXT export produces simple timestamped transcript
  func testTXTExportFormat() throws {
    let meetingID = UUID()
    let meeting = Meeting(
      id: meetingID,
      title: "Notes Meeting",
      startedAt: Date(),
      duration: 120,
      audioFilePath: "/tmp/notes.m4a"
    )
    try repository.saveMeeting(meeting)

    let segments = [
      TranscriptSegment(
        meetingID: meetingID, startTime: 0, endTime: 5, text: "First point.", confidence: 0.9,
        language: "en"),
      TranscriptSegment(
        meetingID: meetingID, startTime: 10, endTime: 15, text: "Second point.", confidence: 0.9,
        language: "en"),
    ]
    try repository.saveTranscriptSegments(segments)

    let exportedURL = try exportService.exportMeeting(
      meetingID, format: .txt, destination: tempExportDir)
    let content = try String(contentsOf: exportedURL)

    XCTAssertTrue(content.contains("[00:00:00] First point."))
    XCTAssertTrue(content.contains("[00:00:10] Second point."))

    // TXT should be simple - no headers
    XCTAssertFalse(content.contains("#"))
  }

  // MARK: - JSON Export Tests

  /// Test: JSON export contains structured meeting data
  func testJSONExportStructure() throws {
    let meetingID = UUID()
    let meeting = Meeting(
      id: meetingID,
      title: "Data Export Test",
      startedAt: Date(timeIntervalSince1970: 1_700_000_000),
      duration: 600,
      audioFilePath: "/tmp/data.m4a"
    )
    try repository.saveMeeting(meeting)

    let speaker = Speaker(meetingID: meetingID, label: "Speaker 1", isLocal: true)
    try repository.saveSpeakers([speaker])

    let segment = TranscriptSegment(
      meetingID: meetingID,
      speakerID: speaker.id,
      startTime: 0,
      endTime: 10,
      text: "Structured data export test.",
      confidence: 0.95,
      language: "en"
    )
    try repository.saveTranscriptSegments([segment])

    let exportedURL = try exportService.exportMeeting(
      meetingID, format: .json, destination: tempExportDir)
    let content = try String(contentsOf: exportedURL)

    // Verify JSON structure
    XCTAssertTrue(content.contains("\"meeting\""), "Should have meeting object")
    XCTAssertTrue(content.contains("\"segments\""), "Should have segments array")
    XCTAssertTrue(content.contains("\"speakers\""), "Should have speakers array")
    XCTAssertTrue(content.contains("\"summary\""), "Should have summary field (even if null)")
    XCTAssertTrue(content.contains("\"actionItems\""), "Should have actionItems array")

    // Verify meeting data
    XCTAssertTrue(content.contains("Data Export Test"), "Should contain meeting title")
    XCTAssertTrue(content.contains(meetingID.uuidString), "Should contain meeting ID")

    // Verify JSON is valid
    let data = content.data(using: .utf8)!
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    XCTAssertNotNil(json)
    XCTAssertNotNil(json?["meeting"])
    XCTAssertNotNil(json?["segments"])
  }

  // MARK: - Export Error Handling

  /// Test: Export throws error for non-existent meeting
  func testExportThrowsForNonExistentMeeting() throws {
    let nonExistentID = UUID()

    do {
      _ = try exportService.exportMeeting(
        nonExistentID, format: .markdown, destination: tempExportDir)
      XCTFail("Should throw for non-existent meeting")
    } catch let error as StorageError {
      if case .meetingNotFound(let id) = error {
        XCTAssertEqual(id, nonExistentID)
      } else {
        XCTFail("Expected meetingNotFound error")
      }
    }
  }

  // MARK: - Export All Formats Test

  /// Test: All export formats work correctly for the same meeting
  func testAllExportFormatsForSameMeeting() throws {
    let meetingID = UUID()
    let meeting = Meeting(
      id: meetingID,
      title: "Multi-Format Export Test",
      startedAt: Date(timeIntervalSince1970: 1_700_000_000),
      duration: 120,
      audioFilePath: "/tmp/multi.m4a"
    )
    try repository.saveMeeting(meeting)

    let segments = [
      TranscriptSegment(
        meetingID: meetingID,
        startTime: 0,
        endTime: 5,
        text: "This is the test content.",
        confidence: 0.95,
        language: "en"
      )
    ]
    try repository.saveTranscriptSegments(segments)

    // Export in all formats
    for format in TranscriptExportFormat.allCases {
      let exportedURL = try exportService.exportMeeting(
        meetingID, format: format, destination: tempExportDir)

      XCTAssertTrue(
        FileManager.default.fileExists(atPath: exportedURL.path),
        "File should exist for format: \(format)"
      )

      let content = try String(contentsOf: exportedURL)
      XCTAssertFalse(content.isEmpty, "Content should not be empty for format: \(format)")

      // Verify file extension
      XCTAssertEqual(
        exportedURL.pathExtension,
        format.rawValue,
        "File extension should match format"
      )
    }
  }

  // MARK: - File Naming Tests

  /// Test: Export file names are sanitized correctly
  func testExportFileNameSanitization() throws {
    let meetingID = UUID()
    let meeting = Meeting(
      id: meetingID,
      title: "Meeting with/special:chars*and?more",
      startedAt: Date(),
      duration: 60,
      audioFilePath: "/tmp/test.m4a"
    )
    try repository.saveMeeting(meeting)

    try repository.saveTranscriptSegments([
      TranscriptSegment(
        meetingID: meetingID, startTime: 0, endTime: 1, text: "Test", confidence: 0.9,
        language: "en")
    ])

    let exportedURL = try exportService.exportMeeting(
      meetingID, format: .txt, destination: tempExportDir)

    // File should be created (no invalid characters)
    XCTAssertTrue(FileManager.default.fileExists(atPath: exportedURL.path))

    // File name should not contain problematic characters
    let fileName = exportedURL.lastPathComponent
    XCTAssertFalse(fileName.contains("/"))
    XCTAssertFalse(fileName.contains(":"))
    XCTAssertFalse(fileName.contains("*"))
    XCTAssertFalse(fileName.contains("?"))
  }

  /// Test: Export file name contains meeting ID for uniqueness
  func testExportFileNameContainsMeetingID() throws {
    let meetingID = UUID()
    let meeting = Meeting(
      id: meetingID,
      title: "Unique Meeting",
      startedAt: Date(),
      duration: 60,
      audioFilePath: "/tmp/unique.m4a"
    )
    try repository.saveMeeting(meeting)

    try repository.saveTranscriptSegments([
      TranscriptSegment(
        meetingID: meetingID, startTime: 0, endTime: 1, text: "Test", confidence: 0.9,
        language: "en")
    ])

    let exportedURL = try exportService.exportMeeting(
      meetingID, format: .markdown, destination: tempExportDir)

    XCTAssertTrue(
      exportedURL.lastPathComponent.contains(meetingID.uuidString),
      "File name should contain meeting ID"
    )
  }
}
