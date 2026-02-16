import CarlaModels
import XCTest

@testable import CarlaStorage

final class SearchTests: XCTestCase {
  func testFTSSearchReturnsMatchingSegments() throws {
    let database = try CarlaDatabase(inMemory: true)
    let repository = GRDBMeetingRepository(dbWriter: database.dbQueue)

    let meeting = Meeting(title: "Weekly Sync", startedAt: Date(), audioFilePath: "/tmp/audio.wav")
    try repository.saveMeeting(meeting)

    let segment1 = TranscriptSegment(
      meetingID: meeting.id,
      startTime: 0,
      endTime: 4,
      text: "We discussed the budget and hiring plan.",
      confidence: 0.9,
      language: "en"
    )

    let segment2 = TranscriptSegment(
      meetingID: meeting.id,
      startTime: 5,
      endTime: 8,
      text: "Next sprint starts Monday.",
      confidence: 0.88,
      language: "en"
    )

    try repository.saveTranscriptSegments([segment1, segment2])

    let results = try repository.searchTranscript(query: "budget", limit: 10)

    XCTAssertEqual(results.count, 1)
    XCTAssertEqual(results.first?.meetingID, meeting.id)
    XCTAssertEqual(results.first?.segmentID, segment1.id)
    XCTAssertEqual(results.first?.text, segment1.text)
  }
}
