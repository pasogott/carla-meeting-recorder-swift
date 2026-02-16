import Foundation

/// Stable output paths produced by the audio module for one meeting recording.
public struct RecordingArtifacts: Sendable, Equatable {
  public let microphoneWAV: URL
  public let systemWAV: URL
  public let stereoMixWAV: URL

  public init(microphoneWAV: URL, systemWAV: URL, stereoMixWAV: URL) {
    self.microphoneWAV = microphoneWAV
    self.systemWAV = systemWAV
    self.stereoMixWAV = stereoMixWAV
  }
}
