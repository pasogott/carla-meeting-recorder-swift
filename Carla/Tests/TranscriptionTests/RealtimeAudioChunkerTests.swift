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

  func testChunkerIgnoresInvalidOrEmptyPackets() {
    var chunker = RealtimeAudioChunker(chunkDuration: 1.0)

    let invalidRate = AudioPacket(
      startTime: 0,
      sampleRate: 0,
      samples: [0.1, 0.2],
      source: .microphone
    )
    let empty = AudioPacket(
      startTime: 0.5,
      sampleRate: 4,
      samples: [],
      source: .microphone
    )

    XCTAssertTrue(chunker.append(packet: invalidRate).isEmpty)
    XCTAssertTrue(chunker.append(packet: empty).isEmpty)
    XCTAssertTrue(chunker.flushFinal().isEmpty)
  }

  func testChunkerFlushesCarryOverWhenFormatChanges() {
    var chunker = RealtimeAudioChunker(chunkDuration: 1.0)

    let first = AudioPacket(
      startTime: 0,
      sampleRate: 4,
      samples: [0.1, 0.2, 0.3],
      source: .microphone
    )
    let second = AudioPacket(
      startTime: 1.0,
      sampleRate: 8,
      samples: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8],
      source: .microphone
    )

    XCTAssertTrue(chunker.append(packet: first).isEmpty)

    let output = chunker.append(packet: second)
    XCTAssertEqual(output.count, 2)

    XCTAssertEqual(output[0].startTime, 0, accuracy: 0.0001)
    XCTAssertEqual(output[0].endTime, 0.75, accuracy: 0.0001)
    XCTAssertFalse(output[0].isFinal)
    XCTAssertEqual(output[0].sampleRate, 4, accuracy: 0.0001)

    XCTAssertEqual(output[1].startTime, 1.0, accuracy: 0.0001)
    XCTAssertEqual(output[1].endTime, 2.0, accuracy: 0.0001)
    XCTAssertFalse(output[1].isFinal)
    XCTAssertEqual(output[1].sampleRate, 8, accuracy: 0.0001)
  }

  func testChunkerSanitizesNonFiniteDurationsAndSampleRates() {
    var chunker = RealtimeAudioChunker(chunkDuration: .infinity)
    XCTAssertEqual(chunker.chunkDuration, 0.25, accuracy: 0.0001)

    chunker.updateChunkDuration(.nan)
    XCTAssertEqual(chunker.chunkDuration, 0.25, accuracy: 0.0001)

    let invalid = AudioPacket(
      startTime: 0,
      sampleRate: .infinity,
      samples: [0.1, 0.2],
      source: .microphone
    )
    XCTAssertTrue(chunker.append(packet: invalid).isEmpty)
  }
}
