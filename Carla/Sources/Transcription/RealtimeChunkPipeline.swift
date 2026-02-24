import Foundation

/// Splits incoming audio packets into fixed-size realtime chunks.
public struct RealtimeAudioChunker: Sendable {
  public private(set) var chunkDuration: TimeInterval

  private var pendingSamples: [Float] = []
  private var currentChunkStart: TimeInterval?
  private var sampleRate: Double?
  private var source: TranscriptionTrackSource?

  public init(chunkDuration: TimeInterval) {
    self.chunkDuration = Self.normalizedChunkDuration(chunkDuration)
  }

  /// Updates chunk duration for future chunk boundary calculations.
  public mutating func updateChunkDuration(_ duration: TimeInterval) {
    chunkDuration = Self.normalizedChunkDuration(duration)
  }

  /// Appends a packet and returns any completed chunks.
  public mutating func append(packet: AudioPacket) -> [AudioChunk] {
    guard packet.sampleRate.isFinite, packet.sampleRate > 0, !packet.samples.isEmpty else {
      return []
    }

    var output: [AudioChunk] = []

    if let activeSampleRate = sampleRate, let activeSource = source,
      activeSampleRate != packet.sampleRate || activeSource != packet.source
    {
      if let carryOver = flushPendingChunk(isFinal: false) {
        output.append(carryOver)
      }
    }

    if currentChunkStart == nil {
      currentChunkStart = packet.startTime
    }
    if sampleRate == nil {
      sampleRate = packet.sampleRate
    }
    if source == nil {
      source = packet.source
    }

    pendingSamples.append(contentsOf: packet.samples)
    output.append(contentsOf: drainChunks())
    return output
  }

  /// Flushes remaining data as a final chunk.
  public mutating func flushFinal() -> [AudioChunk] {
    var chunks = drainChunks()
    if let final = flushPendingChunk(isFinal: true) {
      chunks.append(final)
    }
    return chunks
  }

  private mutating func flushPendingChunk(isFinal: Bool) -> AudioChunk? {
    guard
      !pendingSamples.isEmpty,
      let chunkStart = currentChunkStart,
      let sampleRate,
      let source
    else {
      return nil
    }

    let duration = Double(pendingSamples.count) / sampleRate
    let chunk = AudioChunk(
      startTime: chunkStart,
      endTime: chunkStart + duration,
      sampleRate: sampleRate,
      samples: pendingSamples,
      source: source,
      isFinal: isFinal
    )

    pendingSamples.removeAll(keepingCapacity: false)
    currentChunkStart = nil
    self.sampleRate = nil
    self.source = nil

    return chunk
  }

  private static func normalizedChunkDuration(_ duration: TimeInterval) -> TimeInterval {
    guard duration.isFinite, duration > 0 else { return 0.25 }
    return max(0.25, duration)
  }

  private mutating func drainChunks() -> [AudioChunk] {
    guard let sampleRate, let source, sampleRate.isFinite else { return [] }
    let targetSamples = Int((chunkDuration * sampleRate).rounded(.toNearestOrAwayFromZero))
    guard targetSamples > 0, let chunkStartBase = currentChunkStart else { return [] }

    var chunks: [AudioChunk] = []
    var chunkStart = chunkStartBase

    while pendingSamples.count >= targetSamples {
      let chunkSamples = Array(pendingSamples.prefix(targetSamples))
      pendingSamples.removeFirst(targetSamples)
      let duration = Double(chunkSamples.count) / sampleRate
      let chunk = AudioChunk(
        startTime: chunkStart,
        endTime: chunkStart + duration,
        sampleRate: sampleRate,
        samples: chunkSamples,
        source: source,
        isFinal: false
      )
      chunks.append(chunk)
      chunkStart += duration
    }

    currentChunkStart = chunkStart
    return chunks
  }
}

/// Merge policy for incremental transcript updates.
public struct TranscriptSegmentMerger: Sendable {
  public let boundaryTolerance: TimeInterval

  public init(boundaryTolerance: TimeInterval = 0.25) {
    self.boundaryTolerance = boundaryTolerance
  }

  /// Merges incoming segments into a stable ordered transcript.
  public func merge(existing: [TranscriptSegment], incoming: [TranscriptSegment])
    -> [TranscriptSegment]
  {
    var all = existing + incoming
    all.sort {
      if abs($0.startTime - $1.startTime) > 0.0001 {
        return $0.startTime < $1.startTime
      }
      return $0.endTime < $1.endTime
    }

    var merged: [TranscriptSegment] = []
    for segment in all {
      if let last = merged.last, shouldMerge(lhs: last, rhs: segment) {
        let combinedText = mergeText(last.text, segment.text)
        merged[merged.count - 1] = TranscriptSegment(
          id: last.id,
          startTime: min(last.startTime, segment.startTime),
          endTime: max(last.endTime, segment.endTime),
          text: combinedText,
          speaker: last.speaker,
          confidence: max(last.confidence, segment.confidence),
          language: last.language ?? segment.language,
          source: last.source
        )
      } else {
        merged.append(segment)
      }
    }

    return merged
  }

  private func shouldMerge(lhs: TranscriptSegment, rhs: TranscriptSegment) -> Bool {
    guard lhs.speaker == rhs.speaker, lhs.source == rhs.source else { return false }
    guard (lhs.language ?? "") == (rhs.language ?? "") else { return false }

    let normalizedL = normalize(lhs.text)
    let normalizedR = normalize(rhs.text)

    if normalizedL == normalizedR {
      return true
    }

    let gap = rhs.startTime - lhs.endTime
    return gap >= -boundaryTolerance && gap <= boundaryTolerance
  }

  private func normalize(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private func mergeText(_ left: String, _ right: String) -> String {
    let normalizedL = normalize(left)
    let normalizedR = normalize(right)

    if normalizedL == normalizedR {
      return left
    }

    let leftTrimmed = left.trimmingCharacters(in: .whitespacesAndNewlines)
    let rightTrimmed = right.trimmingCharacters(in: .whitespacesAndNewlines)

    if leftTrimmed.isEmpty { return rightTrimmed }
    if rightTrimmed.isEmpty { return leftTrimmed }

    return "\(leftTrimmed) \(rightTrimmed)"
  }
}
