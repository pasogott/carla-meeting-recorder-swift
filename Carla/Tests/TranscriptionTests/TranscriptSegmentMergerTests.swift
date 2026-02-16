import XCTest

@testable import CarlaTranscription

final class TranscriptSegmentMergerTests: XCTestCase {
  func testMergerDeDuplicatesOverlappingBoundarySegments() {
    let merger = TranscriptSegmentMerger(boundaryTolerance: 0.3)

    let existing = [
      TranscriptSegment(
        startTime: 0,
        endTime: 1,
        text: "Hello world",
        speaker: "You",
        confidence: 0.8,
        language: "en",
        source: .microphone
      )
    ]

    let incoming = [
      TranscriptSegment(
        startTime: 0.95,
        endTime: 1.8,
        text: "hello world",
        speaker: "You",
        confidence: 0.9,
        language: "en",
        source: .microphone
      )
    ]

    let merged = merger.merge(existing: existing, incoming: incoming)
    XCTAssertEqual(merged.count, 1)
    XCTAssertEqual(merged[0].startTime, 0, accuracy: 0.0001)
    XCTAssertEqual(merged[0].endTime, 1.8, accuracy: 0.0001)
    XCTAssertEqual(merged[0].text, "Hello world")
  }

  func testMergerCombinesAdjacentSameSpeakerSegments() {
    let merger = TranscriptSegmentMerger(boundaryTolerance: 0.3)

    let existing = [
      TranscriptSegment(
        startTime: 0,
        endTime: 1,
        text: "Need to",
        speaker: "Others",
        confidence: 0.8,
        language: "en",
        source: .systemAudio
      )
    ]

    let incoming = [
      TranscriptSegment(
        startTime: 1.1,
        endTime: 2,
        text: "ship this today",
        speaker: "Others",
        confidence: 0.88,
        language: "en",
        source: .systemAudio
      )
    ]

    let merged = merger.merge(existing: existing, incoming: incoming)
    XCTAssertEqual(merged.count, 1)
    XCTAssertEqual(merged[0].text, "Need to ship this today")
    XCTAssertEqual(merged[0].endTime, 2, accuracy: 0.0001)
  }
}
