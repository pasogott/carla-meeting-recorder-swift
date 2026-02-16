import CarlaCoreTypes
import Foundation

/// Manages microphone + system audio capture and recording for one meeting.
///
/// This type is used across concurrent contexts (capture callbacks, coordinator tasks).
/// It internally serializes recording writes and does not expose mutable state for external mutation.
public final class MeetingAudioSession: @unchecked Sendable {
  public var onLevel: (@Sendable (AudioLevelUpdate) -> Void)?

  /// Optional fan-out for captured frames (in addition to recorder persistence).
  public var onFrame: (@Sendable (CapturedAudioFrame) -> Void)?

  private let microphone: AudioCapturing
  private let systemAudio: AudioCapturing
  private let recorder: WAVMeetingRecorder

  public init(
    microphone: AudioCapturing,
    systemAudio: AudioCapturing,
    recorder: WAVMeetingRecorder
  ) {
    self.microphone = microphone
    self.systemAudio = systemAudio
    self.recorder = recorder

    wireEvents()
  }

  public func start(outputDirectory: URL, meetingID: UUID) async throws {
    do {
      try recorder.start(outputDirectory: outputDirectory, meetingID: meetingID)
      try await microphone.start()
      try await systemAudio.start()
    } catch {
      // Best-effort cleanup if we fail mid-start.
      microphone.stop()
      systemAudio.stop()
      recorder.abort(deleteFiles: true)
      throw error
    }
  }

  public func stop() async throws -> RecordingArtifacts {
    // Prevent new work from being enqueued while stopping.
    onFrame = nil
    onLevel = nil

    microphone.onFrame = nil
    systemAudio.onFrame = nil
    microphone.onLevel = nil
    systemAudio.onLevel = nil

    microphone.stop()
    systemAudio.stop()

    do {
      return try await recorder.stop()
    } catch {
      // Post-processing (e.g. M4A compression) failures should not prevent access to the raw WAV artifacts.
      // If artifacts exist, return them and let the caller decide whether to fall back to WAV.
      if let artifacts = recorder.artifacts {
        return artifacts
      }
      throw error
    }
  }

  private func wireEvents() {
    microphone.onFrame = { [weak self] frame in
      self?.recorder.append(frame: frame)
      self?.onFrame?(frame)
    }

    systemAudio.onFrame = { [weak self] frame in
      self?.recorder.append(frame: frame)
      self?.onFrame?(frame)
    }

    microphone.onLevel = { [weak self] update in
      self?.onLevel?(update)
    }
    systemAudio.onLevel = { [weak self] update in
      self?.onLevel?(update)
    }
  }
}
