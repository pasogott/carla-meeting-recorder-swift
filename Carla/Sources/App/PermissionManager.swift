import AVFoundation
import AppKit
import Combine
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Status of a macOS permission
enum PermissionStatus: Equatable {
  case notDetermined
  case granted
  case denied
  case restricted
}

/// Manages macOS permissions for microphone and screen recording
@MainActor
final class PermissionManager: ObservableObject {
  @Published private(set) var microphoneStatus: PermissionStatus = .notDetermined
  @Published private(set) var screenRecordingStatus: PermissionStatus = .notDetermined

  /// Whether all required permissions are granted
  var allPermissionsGranted: Bool {
    microphoneStatus == .granted && screenRecordingStatus == .granted
  }

  /// Whether any permission is denied (requires user to open System Settings)
  var hasAnyDeniedPermission: Bool {
    microphoneStatus == .denied || screenRecordingStatus == .denied
  }

  init(skipInitialCheck: Bool = false) {
    guard !skipInitialCheck else { return }
    // Check initial status on creation
    Task {
      await checkAllPermissions()
    }
  }

  // MARK: - Permission Checking

  /// Check all permissions and update published state
  func checkAllPermissions() async {
    checkMicrophoneStatus()
    await checkScreenRecordingStatus()
  }

  /// Check microphone permission status without prompting
  func checkMicrophoneStatus() {
    let status = AVCaptureDevice.authorizationStatus(for: .audio)
    microphoneStatus = mapAVAuthorizationStatus(status)
  }

  /// Check screen recording permission status
  /// Uses CGPreflightScreenCaptureAccess() which doesn't prompt
  func checkScreenRecordingStatus() async {
    // CGPreflightScreenCaptureAccess returns true if access is granted,
    // false if denied or not determined
    let hasAccess = CGPreflightScreenCaptureAccess()

    if hasAccess {
      screenRecordingStatus = .granted
    } else {
      // Try to enumerate shareable content to check if we have permission
      // This is a more reliable check than CGPreflight alone
      do {
        _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        screenRecordingStatus = .granted
      } catch {
        // If we get an error, we likely don't have permission
        // Could be not determined or denied
        screenRecordingStatus = .denied
      }
    }
  }

  // MARK: - Permission Requests

  /// Request microphone permission
  /// - Returns: true if granted, false if denied
  @discardableResult
  func requestMicrophonePermission() async -> Bool {
    let currentStatus = AVCaptureDevice.authorizationStatus(for: .audio)

    switch currentStatus {
    case .authorized:
      microphoneStatus = .granted
      return true

    case .notDetermined:
      let granted = await AVCaptureDevice.requestAccess(for: .audio)
      microphoneStatus = granted ? .granted : .denied
      return granted

    case .denied, .restricted:
      microphoneStatus = currentStatus == .restricted ? .restricted : .denied
      return false

    @unknown default:
      microphoneStatus = .denied
      return false
    }
  }

  /// Request screen recording permission
  /// This will prompt the user if permission hasn't been determined
  /// - Returns: true if granted, false if denied
  @discardableResult
  func requestScreenRecordingPermission() async -> Bool {
    // First check if we already have permission
    let hasAccess = CGPreflightScreenCaptureAccess()

    if hasAccess {
      screenRecordingStatus = .granted
      return true
    }

    // Request access - this will show the system prompt
    let granted = CGRequestScreenCaptureAccess()

    if granted {
      screenRecordingStatus = .granted
      return true
    }

    // If CGRequestScreenCaptureAccess returned false, it could mean:
    // 1. User was prompted and denied
    // 2. User was previously denied and needs to enable in System Settings
    // We re-check via ScreenCaptureKit for a definitive answer
    await checkScreenRecordingStatus()

    return screenRecordingStatus == .granted
  }

  // MARK: - System Settings

  /// Open System Settings to the appropriate privacy pane
  func openSystemSettingsForMicrophone() {
    openSystemSettings(pane: "Privacy_Microphone")
  }

  /// Open System Settings to the screen recording privacy pane
  func openSystemSettingsForScreenRecording() {
    openSystemSettings(pane: "Privacy_ScreenCapture")
  }

  // MARK: - Private Helpers

  private func mapAVAuthorizationStatus(_ status: AVAuthorizationStatus) -> PermissionStatus {
    switch status {
    case .authorized: return .granted
    case .denied: return .denied
    case .restricted: return .restricted
    case .notDetermined: return .notDetermined
    @unknown default: return .denied
    }
  }

  private func openSystemSettings(pane: String) {
    // macOS 13+ uses x-apple.systempreferences URL scheme
    // Privacy settings are under "Privacy & Security"
    let urlString = "x-apple.systempreferences:com.apple.preference.security?\(pane)"

    if let url = URL(string: urlString) {
      NSWorkspace.shared.open(url)
    }
  }
}

// MARK: - Preview Support

#if DEBUG
  extension PermissionManager {
    /// Create a mock PermissionManager for previews
    static func mock(
      microphone: PermissionStatus = .granted, screenRecording: PermissionStatus = .granted
    ) -> PermissionManager {
      let manager = PermissionManager(skipInitialCheck: true)
      manager.microphoneStatus = microphone
      manager.screenRecordingStatus = screenRecording
      return manager
    }
  }
#endif
