@preconcurrency import AVFoundation
import CarlaCoreTypes
import Foundation

public protocol AudioPostProcessing: Sendable {
  func process(_ artifacts: RecordingArtifacts) async throws
}

public struct NoOpAudioPostProcessor: AudioPostProcessing {
  public init() {}
  public func process(_ artifacts: RecordingArtifacts) async throws {}
}

public final class WAVMeetingRecorder: @unchecked Sendable {
  public private(set) var artifacts: RecordingArtifacts?

  private struct SampleFIFO {
    private var storage: [Float] = []
    private var headIndex: Int = 0

    var count: Int {
      storage.count - headIndex
    }

    mutating func reset() {
      storage.removeAll(keepingCapacity: true)
      headIndex = 0
    }

    mutating func append(_ samples: UnsafeBufferPointer<Float>) {
      storage.append(contentsOf: samples)
    }

    mutating func take(count requestedCount: Int) -> [Float] {
      guard requestedCount > 0 else { return [] }

      let available = min(requestedCount, count)
      let start = headIndex
      let end = headIndex + available
      var out = Array(storage[start..<end])
      headIndex = end

      compactIfNeeded()

      if out.count < requestedCount {
        out.append(contentsOf: repeatElement(0, count: requestedCount - out.count))
      }
      return out
    }

    private mutating func compactIfNeeded() {
      // Avoid O(n) shifts on every take; compact in larger chunks.
      guard headIndex > 0 else { return }
      if headIndex > 16_384 && headIndex > storage.count / 2 {
        storage.removeFirst(headIndex)
        headIndex = 0
      }
    }
  }

  private let queue = DispatchQueue(label: "carla.audio.recorder")
  private let postProcessor: AudioPostProcessing
  private let stereoBlockFrames: Int

  private var isAcceptingFrames = false

  private var micFile: AVAudioFile?
  private var systemFile: AVAudioFile?
  private var stereoFile: AVAudioFile?

  private var microphoneFIFO = SampleFIFO()
  private var systemFIFO = SampleFIFO()

  private let monoFormat: AVAudioFormat
  private let stereoFormat: AVAudioFormat

  public init(
    sampleRate: Double = 48_000,
    stereoBlockFrames: Int = 2_048,
    postProcessor: AudioPostProcessing = NoOpAudioPostProcessor()
  ) {
    self.stereoBlockFrames = max(256, stereoBlockFrames)
    self.postProcessor = postProcessor

    self.monoFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: sampleRate,
      channels: 1,
      interleaved: false
    )!
    self.stereoFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: sampleRate,
      channels: 2,
      interleaved: false
    )!
  }

  public func start(outputDirectory: URL, meetingID: UUID) throws {
    let micURL = outputDirectory.appendingPathComponent("\(meetingID.uuidString)-mic.wav")
    let systemURL = outputDirectory.appendingPathComponent("\(meetingID.uuidString)-system.wav")
    let stereoURL = outputDirectory.appendingPathComponent("\(meetingID.uuidString)-stereo.wav")

    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

    micFile = try AVAudioFile(forWriting: micURL, settings: monoFormat.settings)
    systemFile = try AVAudioFile(forWriting: systemURL, settings: monoFormat.settings)
    stereoFile = try AVAudioFile(forWriting: stereoURL, settings: stereoFormat.settings)
    artifacts = RecordingArtifacts(
      microphoneWAV: micURL, systemWAV: systemURL, stereoMixWAV: stereoURL)

    microphoneFIFO.reset()
    systemFIFO.reset()
    isAcceptingFrames = true
  }

  public func append(frame: CapturedAudioFrame) {
    queue.async { [weak self] in
      guard let self,
        self.isAcceptingFrames,
        let monoBuffer = self.convertToMono(buffer: frame.buffer),
        let channelData = monoBuffer.floatChannelData
      else {
        return
      }

      let ptr = UnsafeBufferPointer(start: channelData[0], count: Int(monoBuffer.frameLength))

      switch frame.source {
      case .microphone:
        try? self.micFile?.write(from: monoBuffer)
        self.microphoneFIFO.append(ptr)
      case .system:
        try? self.systemFile?.write(from: monoBuffer)
        self.systemFIFO.append(ptr)
      }

      self.drainStereoBlocks(final: false)
    }
  }

  /// Stops recording and runs any configured post-processing.
  public func stop() async throws -> RecordingArtifacts {
    queue.sync {
      isAcceptingFrames = false
      drainStereoBlocks(final: true)

      micFile = nil
      systemFile = nil
      stereoFile = nil

      microphoneFIFO.reset()
      systemFIFO.reset()
    }

    guard let artifacts else {
      throw AudioCaptureError.failedToStartCapture("No recording artifacts available.")
    }

    try await postProcessor.process(artifacts)
    return artifacts
  }

  /// Aborts a recording without post-processing.
  ///
  /// Intended for cleanup when capture setup fails mid-start.
  public func abort(deleteFiles: Bool = true) {
    let artifactsToDelete: RecordingArtifacts? = queue.sync {
      isAcceptingFrames = false

      micFile = nil
      systemFile = nil
      stereoFile = nil

      microphoneFIFO.reset()
      systemFIFO.reset()

      let current = artifacts
      artifacts = nil
      return current
    }

    guard deleteFiles, let artifactsToDelete else { return }
    let fileManager = FileManager.default
    try? fileManager.removeItem(at: artifactsToDelete.microphoneWAV)
    try? fileManager.removeItem(at: artifactsToDelete.systemWAV)
    try? fileManager.removeItem(at: artifactsToDelete.stereoMixWAV)
  }

  private func convertToMono(buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    if buffer.format == monoFormat {
      return buffer
    }

    guard let converter = AVAudioConverter(from: buffer.format, to: monoFormat),
      let output = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength)
    else {
      return nil
    }

    var error: NSError?
    let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
      outStatus.pointee = .haveData
      return buffer
    }

    converter.convert(to: output, error: &error, withInputFrom: inputBlock)
    return error == nil ? output : nil
  }

  private func drainStereoBlocks(final: Bool) {
    guard let stereoFile else { return }

    while max(microphoneFIFO.count, systemFIFO.count) >= stereoBlockFrames {
      let left = microphoneFIFO.take(count: stereoBlockFrames)
      let right = systemFIFO.take(count: stereoBlockFrames)
      writeStereoSamples(left: left, right: right, to: stereoFile)
    }

    if final {
      let remaining = max(microphoneFIFO.count, systemFIFO.count)
      guard remaining > 0 else { return }
      let left = microphoneFIFO.take(count: remaining)
      let right = systemFIFO.take(count: remaining)
      writeStereoSamples(left: left, right: right, to: stereoFile)
    }
  }

  private func writeStereoSamples(left: [Float], right: [Float], to file: AVAudioFile) {
    let frameCount = max(left.count, right.count)
    guard frameCount > 0,
      let buffer = AVAudioPCMBuffer(
        pcmFormat: stereoFormat,
        frameCapacity: AVAudioFrameCount(frameCount)
      ),
      let channels = buffer.floatChannelData
    else {
      return
    }

    buffer.frameLength = AVAudioFrameCount(frameCount)

    // Default silence.
    channels[0].update(repeating: 0, count: frameCount)
    channels[1].update(repeating: 0, count: frameCount)

    left.withUnsafeBufferPointer { ptr in
      guard let base = ptr.baseAddress else { return }
      channels[0].update(from: base, count: left.count)
    }
    right.withUnsafeBufferPointer { ptr in
      guard let base = ptr.baseAddress else { return }
      channels[1].update(from: base, count: right.count)
    }

    try? file.write(from: buffer)
  }
}
