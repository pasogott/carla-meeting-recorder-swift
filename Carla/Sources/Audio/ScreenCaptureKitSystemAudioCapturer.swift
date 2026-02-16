import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

#if canImport(ScreenCaptureKit)
  @preconcurrency import ScreenCaptureKit
#endif

public final class StubSystemAudioCapturer: AudioCapturing {
  public var onFrame: (@Sendable (CapturedAudioFrame) -> Void)?
  public var onLevel: (@Sendable (AudioLevelUpdate) -> Void)?

  public init() {}

  public func start() async throws {
    throw AudioCaptureError.screenCaptureUnavailable
  }

  public func stop() {}
}

#if canImport(ScreenCaptureKit)
  @available(macOS 13.0, *)
  public final class ScreenCaptureKitSystemAudioCapturer: NSObject, AudioCapturing {
    public var onFrame: (@Sendable (CapturedAudioFrame) -> Void)?
    public var onLevel: (@Sendable (AudioLevelUpdate) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "carla.audio.system.capture")

    public override init() {}

    public func start() async throws {
      guard CGPreflightScreenCaptureAccess() else {
        throw AudioCaptureError.missingScreenCapturePermission
      }

      let content: SCShareableContent
      do {
        content = try await SCShareableContent.current
      } catch {
        throw AudioCaptureError.missingScreenCapturePermission
      }

      guard let display = content.displays.first else {
        throw AudioCaptureError.screenCaptureUnavailable
      }

      let filter = SCContentFilter(
        display: display, excludingApplications: [], exceptingWindows: [])
      let config = SCStreamConfiguration()
      config.capturesAudio = true
      config.excludesCurrentProcessAudio = true
      config.minimumFrameInterval = CMTime(value: 1, timescale: 10)

      let stream = SCStream(filter: filter, configuration: config, delegate: nil)
      self.stream = stream

      do {
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
      } catch {
        throw AudioCaptureError.failedToStartCapture(error.localizedDescription)
      }
    }

    public func stop() {
      let current = stream
      stream = nil
      queue.async {
        Task {
          try? await current?.stopCapture()
        }
      }
    }
  }

  @available(macOS 13.0, *)
  extension ScreenCaptureKitSystemAudioCapturer: SCStreamOutput {
    public func stream(
      _ stream: SCStream,
      didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
      of outputType: SCStreamOutputType
    ) {
      guard outputType == .audio,
        let pcmBuffer = sampleBuffer.toPCMBuffer()
      else {
        return
      }

      let samples = AudioPCMUtilities.samples(from: pcmBuffer)
      let level = AudioLevelUpdate(
        source: .system,
        rms: AudioPCMUtilities.rms(samples),
        peak: AudioPCMUtilities.peak(samples))
      onLevel?(level)
      onFrame?(CapturedAudioFrame(source: .system, buffer: pcmBuffer, timestamp: nil))
    }
  }

  @available(macOS 13.0, *)
  extension CMSampleBuffer {
    fileprivate func toPCMBuffer() -> AVAudioPCMBuffer? {
      guard let formatDescription = CMSampleBufferGetFormatDescription(self),
        let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
      else {
        return nil
      }

      var asbd = streamDescription.pointee
      guard let format = AVAudioFormat(streamDescription: &asbd) else {
        return nil
      }

      let sampleCount = CMSampleBufferGetNumSamples(self)
      guard
        let pcmBuffer = AVAudioPCMBuffer(
          pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount))
      else {
        return nil
      }
      pcmBuffer.frameLength = pcmBuffer.frameCapacity

      // Fast path: allocate an AudioBufferList sized for the most likely layout.
      // If CoreMedia reports a larger size is needed, fall back to allocating the exact size.
      let guessedBufferCount = format.isInterleaved ? 1 : Int(format.channelCount)
      let guessedSize =
        MemoryLayout<AudioBufferList>.size
        + max(0, guessedBufferCount - 1) * MemoryLayout<AudioBuffer>.size

      var neededSize: Int = 0
      var blockBuffer: CMBlockBuffer?

      func loadAudioBufferList(into raw: UnsafeMutableRawPointer, size: Int) -> OSStatus {
        let abl = raw.assumingMemoryBound(to: AudioBufferList.self)
        return CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
          self,
          bufferListSizeNeededOut: &neededSize,
          bufferListOut: abl,
          bufferListSize: size,
          blockBufferAllocator: kCFAllocatorDefault,
          blockBufferMemoryAllocator: kCFAllocatorDefault,
          flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
          blockBufferOut: &blockBuffer
        )
      }

      var raw = UnsafeMutableRawPointer.allocate(
        byteCount: guessedSize,
        alignment: MemoryLayout<AudioBufferList>.alignment
      )

      var status = loadAudioBufferList(into: raw, size: guessedSize)

      if status != noErr, neededSize > guessedSize {
        raw.deallocate()
        raw = UnsafeMutableRawPointer.allocate(
          byteCount: neededSize,
          alignment: MemoryLayout<AudioBufferList>.alignment
        )
        status = loadAudioBufferList(into: raw, size: neededSize)
      }

      guard status == noErr else {
        raw.deallocate()
        return nil
      }

      defer { raw.deallocate() }
      let sourceABL = raw.assumingMemoryBound(to: AudioBufferList.self)

      // Copy buffers into the AVAudioPCMBuffer's own memory.
      let srcBuffers = UnsafeMutableAudioBufferListPointer(sourceABL)
      let dstBuffers = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)

      guard srcBuffers.count == dstBuffers.count else {
        return nil
      }

      for index in 0..<srcBuffers.count {
        let src = srcBuffers[index]
        guard let srcData = src.mData else { return nil }

        var dst = dstBuffers[index]
        guard let dstData = dst.mData else { return nil }

        let bytesToCopy = Int(src.mDataByteSize)
        guard bytesToCopy <= Int(dst.mDataByteSize) else { return nil }

        memcpy(dstData, srcData, bytesToCopy)
        dst.mDataByteSize = src.mDataByteSize
        dstBuffers[index] = dst
      }

      return pcmBuffer
    }
  }
#endif
