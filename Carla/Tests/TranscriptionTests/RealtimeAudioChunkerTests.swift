import XCTest

@testable import CarlaTranscription

final class RealtimeAudioChunkerTests: XCTestCase {
  func testChunkerProducesExpectedChunkBoundariesAndFinalFlush() {
    var chunker = RealtimeAudioChunker(chunkDuration: 1.0)

    let packetA = AudioPacket(
      startTime: 0,
      sampleRate: 4,
      samples: [0.1, 0.2, 0.3],
      source: .microphone
    )
    let packetB = AudioPacket(
      startTime: 0.75,
      sampleRate: 4,
      samples: [0.4, 0.5, 0.6],
      source: .microphone
    )

    let firstOutput = chunker.append(packet: packetA)
    XCTAssertEqual(firstOutput.count, 0)

    let secondOutput = chunker.append(packet: packetB)
    XCTAssertEqual(secondOutput.count, 1)
    XCTAssertEqual(secondOutput[0].startTime, 0, accuracy: 0.0001)
    XCTAssertEqual(secondOutput[0].endTime, 1.0, accuracy: 0.0001)
    XCTAssertFalse(secondOutput[0].isFinal)
    XCTAssertEqual(secondOutput[0].samples.count, 4)

    let flushed = chunker.flushFinal()
    XCTAssertEqual(flushed.count, 1)
    XCTAssertEqual(flushed[0].startTime, 1.0, accuracy: 0.0001)
    XCTAssertEqual(flushed[0].endTime, 1.5, accuracy: 0.0001)
    XCTAssertTrue(flushed[0].isFinal)
    XCTAssertEqual(flushed[0].samples.count, 2)
  }
}
