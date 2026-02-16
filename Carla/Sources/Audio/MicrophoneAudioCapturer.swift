@preconcurrency import AVFoundation
import Foundation

public final class MicrophoneAudioCapturer: AudioCapturing {
  public var onFrame: (@Sendable (CapturedAudioFrame) -> Void)?
  public var onLevel: (@Sendable (AudioLevelUpdate) -> Void)?

  private let engine: AVAudioEngine
  private let queue = DispatchQueue(label: "carla.audio.mic.capture")
  private let tapBufferSize: AVAudioFrameCount

  public init(engine: AVAudioEngine = AVAudioEngine(), tapBufferSize: AVAudioFrameCount = 2_048) {
    self.engine = engine
    self.tapBufferSize = tapBufferSize
  }

  public func start() async throws {
    let inputNode = engine.inputNode
    let format = inputNode.inputFormat(forBus: 0)

    guard format.channelCount > 0 else {
      throw AudioCaptureError.microphoneUnavailable
    }

    inputNode.removeTap(onBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: format) {
      [weak self] buffer, time in
      guard let self else { return }
      guard let copied = Self.copyPCMBuffer(buffer) else { return }

      // Capture callbacks to avoid capturing `self` in the queue closure.
      let onLevel = self.onLevel
      let onFrame = self.onFrame

      self.queue.async {
        let samples = AudioPCMUtilities.samples(from: copied)
        let level = AudioLevelUpdate(
          source: .microphone,
          rms: AudioPCMUtilities.rms(samples),
          peak: AudioPCMUtilities.peak(samples)
        )
        onLevel?(level)
        onFrame?(CapturedAudioFrame(source: .microphone, buffer: copied, timestamp: time))
      }
    }

    do {
      try engine.start()
    } catch {
      throw AudioCaptureError.failedToStartCapture(error.localizedDescription)
    }
  }

  public func stop() {
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
  }

  private static func copyPCMBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity)
    else {
      return nil
    }
    copy.frameLength = buffer.frameLength

    if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
      for ch in 0..<Int(buffer.format.channelCount) {
        dst[ch].update(from: src[ch], count: Int(buffer.frameLength))
      }
      return copy
    }

    if let src = buffer.int16ChannelData, let dst = copy.int16ChannelData {
      for ch in 0..<Int(buffer.format.channelCount) {
        dst[ch].update(from: src[ch], count: Int(buffer.frameLength))
      }
      return copy
    }

    return nil
  }
}
