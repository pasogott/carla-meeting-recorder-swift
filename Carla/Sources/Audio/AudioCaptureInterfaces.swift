import AVFoundation
import Foundation

public enum AudioSource: Sendable {
  case microphone
  case system
}

public struct CapturedAudioFrame: @unchecked Sendable {
  public let source: AudioSource
  public let buffer: AVAudioPCMBuffer
  public let timestamp: AVAudioTime?

  public init(source: AudioSource, buffer: AVAudioPCMBuffer, timestamp: AVAudioTime?) {
    self.source = source
    self.buffer = buffer
    self.timestamp = timestamp
  }
}

public enum AudioCaptureError: LocalizedError {
  case microphoneUnavailable
  case screenCaptureUnavailable
  case missingScreenCapturePermission
  case failedToStartCapture(String)

  public var errorDescription: String? {
    switch self {
    case .microphoneUnavailable:
      return "Microphone input is unavailable."
    case .screenCaptureUnavailable:
      return "System audio capture is unavailable."
    case .missingScreenCapturePermission:
      return "Screen Recording permission is required for system audio capture."
    case .failedToStartCapture(let reason):
      return "Failed to start audio capture: \(reason)"
    }
  }
}

public protocol AudioCapturing: AnyObject {
  /// Called for each captured audio frame. Executed on capture-specific threads/queues.
  ///
  /// Note: `CapturedAudioFrame` is declared `@unchecked Sendable` to allow cross-thread delivery.
  /// Consumers must treat buffers as immutable (or copy) once delivered.
  var onFrame: (@Sendable (CapturedAudioFrame) -> Void)? { get set }

  /// Called for audio level updates (RMS/peak). Executed on capture-specific threads/queues.
  var onLevel: (@Sendable (AudioLevelUpdate) -> Void)? { get set }

  func start() async throws
  func stop()
}

public struct AudioLevelUpdate: Sendable, Equatable {
  public let source: AudioSource
  public let rms: Float
  public let peak: Float

  public init(source: AudioSource, rms: Float, peak: Float) {
    self.source = source
    self.rms = rms
    self.peak = peak
  }
}
