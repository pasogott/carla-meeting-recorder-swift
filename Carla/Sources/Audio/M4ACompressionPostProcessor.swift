@preconcurrency import AVFoundation
import CarlaCoreTypes
import Foundation

public struct M4ACompressionPostProcessor: AudioPostProcessing {
  public init() {}

  public func process(_ artifacts: RecordingArtifacts) async throws {
    try await compress(artifacts.microphoneWAV)
    try await compress(artifacts.systemWAV)
    try await compress(artifacts.stereoMixWAV)
  }

  private func compress(_ wavURL: URL) async throws {
    let m4aURL = wavURL.deletingPathExtension().appendingPathExtension("m4a")
    if FileManager.default.fileExists(atPath: m4aURL.path) {
      try FileManager.default.removeItem(at: m4aURL)
    }

    let asset = AVURLAsset(url: wavURL)
    guard
      let exportSession = AVAssetExportSession(
        asset: asset, presetName: AVAssetExportPresetAppleM4A)
    else {
      throw AudioCaptureError.failedToStartCapture(
        "Unable to create M4A export session for \(wavURL.lastPathComponent)")
    }

    exportSession.outputURL = m4aURL
    exportSession.outputFileType = .m4a

    try await exportSession.exportAndWait()
  }
}

private final class ExportSessionBox: @unchecked Sendable {
  let session: AVAssetExportSession

  init(_ session: AVAssetExportSession) {
    self.session = session
  }
}

extension AVAssetExportSession {
  fileprivate func exportAndWait() async throws {
    let box = ExportSessionBox(self)
    try await withCheckedThrowingContinuation { continuation in
      box.session.exportAsynchronously {
        switch box.session.status {
        case .completed:
          continuation.resume()
        case .failed:
          continuation.resume(
            throwing: box.session.error
              ?? AudioCaptureError.failedToStartCapture("M4A export failed"))
        case .cancelled:
          continuation.resume(
            throwing: AudioCaptureError.failedToStartCapture("M4A export cancelled"))
        default:
          continuation.resume(
            throwing: AudioCaptureError.failedToStartCapture("M4A export incomplete"))
        }
      }
    }
  }
}
