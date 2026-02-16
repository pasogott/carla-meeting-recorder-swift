import CarlaModels
import XCTest

@testable import CarlaStorage

final class ExportTests: XCTestCase {
  func testExportsMarkdownTxtSrtAndJSON() throws {
    let database = try CarlaDatabase(inMemory: true)
    let repository = GRDBMeetingRepository(dbWriter: database.dbQueue)
    let exportService = MeetingExportService(repository: repository, paths: AppStoragePaths())

    let meeting = Meeting(
      title: "Client Call",
      startedAt: Date(timeIntervalSince1970: 1_700_000_000),
      duration: 120,
      audioFilePath: "/tmp/client-call.wav"
    )
    try repository.saveMeeting(meeting)

    try repository.saveTranscriptSegments([
      TranscriptSegment(
        meetingID: meeting.id, startTime: 0, endTime: 2.4, text: "Hello and welcome.",
        confidence: 0.95, language: "en"),
      TranscriptSegment(
        meetingID: meeting.id, startTime: 3, endTime: 5, text: "Let's review action items.",
        confidence: 0.92, language: "en"),
    ])

    let summary = MeetingSummary(
      meetingID: meeting.id,
      summary: "Discussed onboarding timeline.",
      keyDecisions: ["Kickoff next week"],
      followUps: ["Send contract draft"]
    )

    try repository.saveSummary(
      summary,
      actionItems: [
        ActionItem(meetingID: meeting.id, description: "Send proposal", assignee: "Pascal")
      ]
    )

    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    for format in TranscriptExportFormat.allCases {
      let fileURL = try exportService.exportMeeting(
        meeting.id, format: format, destination: tempDir)
      XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

      let content = try String(contentsOf: fileURL)
      XCTAssertFalse(content.isEmpty)

      if format == .srt {
        XCTAssertTrue(content.contains("00:00:00,000 --> 00:00:02,400"))
      }

      if format == .markdown {
        XCTAssertTrue(content.contains("# Client Call"))
      }

      if format == .json {
        XCTAssertTrue(content.contains("\"meeting\""))
        XCTAssertTrue(content.contains("\"segments\""))
      }
    }
  }
}
