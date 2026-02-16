@preconcurrency import AVFoundation
import Foundation

public enum AudioPCMUtilities {
  public static func rms(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    let power = samples.reduce(0) { $0 + ($1 * $1) }
    return sqrt(power / Float(samples.count))
  }

  public static func peak(_ samples: [Float]) -> Float {
    samples.map { abs($0) }.max() ?? 0
  }

  /// Returns mono samples as `Float` in the range [-1, 1].
  ///
  /// If the buffer has multiple channels, this averages across channels.
  public static func samples(from buffer: AVAudioPCMBuffer) -> [Float] {
    let frameLength = Int(buffer.frameLength)
    guard frameLength > 0 else { return [] }

    let channels = Int(buffer.format.channelCount)
    guard channels > 0 else { return [] }

    // Non-interleaved float32.
    if let data = buffer.floatChannelData {
      if channels == 1 {
        return Array(UnsafeBufferPointer(start: data[0], count: frameLength))
      }

      var output = [Float](repeating: 0, count: frameLength)
      for ch in 0..<channels {
        let ptr = data[ch]
        for i in 0..<frameLength {
          output[i] += ptr[i]
        }
      }
      let scale = 1.0 / Float(channels)
      for i in 0..<frameLength {
        output[i] *= scale
      }
      return output
    }

    // Non-interleaved int16.
    if let int16Data = buffer.int16ChannelData {
      if channels == 1 {
        let values = Array(UnsafeBufferPointer(start: int16Data[0], count: frameLength))
        return values.map { Float($0) / 32768.0 }
      }

      var output = [Float](repeating: 0, count: frameLength)
      for ch in 0..<channels {
        let ptr = int16Data[ch]
        for i in 0..<frameLength {
          output[i] += Float(ptr[i]) / 32768.0
        }
      }
      let scale = 1.0 / Float(channels)
      for i in 0..<frameLength {
        output[i] *= scale
      }
      return output
    }

    // Interleaved fallback.
    let ablPointer = UnsafeMutablePointer<AudioBufferList>(mutating: buffer.audioBufferList)
    let abl = UnsafeMutableAudioBufferListPointer(ablPointer)
    guard let mData = abl.first?.mData else { return [] }
    let bytesPerFrame = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)

    // Only support interleaved float32 and int16 in this fallback.
    if bytesPerFrame == channels * MemoryLayout<Float>.size {
      let src = mData.bindMemory(to: Float.self, capacity: frameLength * channels)
      var output = [Float](repeating: 0, count: frameLength)
      let scale = 1.0 / Float(channels)
      for i in 0..<frameLength {
        var sum: Float = 0
        let base = i * channels
        for ch in 0..<channels {
          sum += src[base + ch]
        }
        output[i] = sum * scale
      }
      return output
    }

    if bytesPerFrame == channels * MemoryLayout<Int16>.size {
      let src = mData.bindMemory(to: Int16.self, capacity: frameLength * channels)
      var output = [Float](repeating: 0, count: frameLength)
      let scale = 1.0 / Float(channels)
      for i in 0..<frameLength {
        var sum: Float = 0
        let base = i * channels
        for ch in 0..<channels {
          sum += Float(src[base + ch]) / 32768.0
        }
        output[i] = sum * scale
      }
      return output
    }

    return []
  }
}
