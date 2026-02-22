import AppKit
import Combine
import SwiftUI

@main
struct CarlaApp: App {
  @StateObject private var appState: AppState
  private let notchOverlayController: NotchOverlayController

  init() {
    NSApplication.shared.setActivationPolicy(.accessory)

    let state = AppState()
    _appState = StateObject(wrappedValue: state)
    notchOverlayController = NotchOverlayController(appState: state)
  }

  var body: some Scene {
    MenuBarExtra {
      MenuBarMenuView(appState: appState)
    } label: {
      Image(systemName: appState.menuBarIconName)
        .symbolRenderingMode(.monochrome)
    }
    .menuBarExtraStyle(.window)

    Window("Meetings", id: WindowID.meetings) {
      MeetingsView(appState: appState)
        .frame(minWidth: 760, minHeight: 500)
    }

    Window("Transcript", id: WindowID.transcript) {
      TranscriptViewerView(appState: appState)
        .frame(minWidth: 860, minHeight: 540)
    }

    Window("Settings", id: WindowID.settings) {
      SettingsView(coordinator: appState)
        .frame(minWidth: 560, minHeight: 420)
    }

    Window("Welcome", id: WindowID.onboarding) {
      OnboardingView(appState: appState)
        .frame(minWidth: 580, minHeight: 500)
    }
  }
}

@MainActor
private final class NotchOverlayController {
  private weak var appState: AppState?
  private let panel: NSPanel
  private var cancellables = Set<AnyCancellable>()

  init(appState: AppState) {
    self.appState = appState

    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 360, height: 56),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.level = .statusBar
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.isOpaque = false
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    panel.ignoresMouseEvents = false
    panel.contentView = NSHostingView(rootView: NotchOverlayView(appState: appState))
    panel.orderOut(nil)

    self.panel = panel

    bind()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleScreenChange),
      name: NSApplication.didChangeScreenParametersNotification,
      object: nil
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  @objc private func handleScreenChange() {
    updateVisibilityAndPosition()
  }

  private func bind() {
    guard let appState else { return }

    appState.$recordingState
      .sink { [weak self] _ in self?.updateVisibilityAndPosition() }
      .store(in: &cancellables)

    appState.$settings
      .sink { [weak self] _ in self?.updateVisibilityAndPosition() }
      .store(in: &cancellables)

    updateVisibilityAndPosition()
  }

  private func updateVisibilityAndPosition() {
    guard let appState else {
      panel.orderOut(nil)
      return
    }

    let shouldShow = appState.settings.showNotchOverlay
      && (appState.recordingState == .recording
        || appState.recordingState == .starting
        || appState.recordingState == .stopping)

    guard shouldShow else {
      panel.orderOut(nil)
      return
    }

    positionPanel()
    panel.orderFrontRegardless()
  }

  private func positionPanel() {
    let targetScreen = NSScreen.main ?? NSScreen.screens.first
    guard let screen = targetScreen else { return }

    let panelSize = panel.frame.size
    let x = screen.frame.midX - panelSize.width / 2
    let y = screen.visibleFrame.maxY - panelSize.height - 8
    panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: panelSize), display: true)
  }
}

private struct NotchOverlayView: View {
  @ObservedObject var appState: AppState

  private var level: CGFloat {
    CGFloat(max(appState.microphoneLevel, appState.systemAudioLevel))
  }

  var body: some View {
    HStack(spacing: 10) {
      NotchWaveBars(level: level, active: appState.recordingState == .recording)

      Text(statusText)
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.9))

      if appState.recordingState == .recording {
        Text(formatDuration(appState.currentRecordingDuration))
          .font(.system(size: 12, weight: .regular, design: .monospaced))
          .foregroundStyle(.white.opacity(0.65))
      }

      Spacer(minLength: 8)

      Button(appState.recordingState == .recording ? "Stop" : "Start") {
        appState.toggleRecording()
      }
      .font(.system(size: 11, weight: .semibold))
      .buttonStyle(.plain)
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(appState.recordingState == .recording ? Color.red.opacity(0.9) : Color.white.opacity(0.14), in: Capsule())
      .overlay {
        Capsule().stroke(.white.opacity(0.18), lineWidth: 0.8)
      }
      .disabled(appState.recordingState == .starting || appState.recordingState == .stopping)
      .opacity(appState.recordingState == .starting || appState.recordingState == .stopping ? 0.5 : 1)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .frame(width: 360, height: 56)
    .background(Color.black.opacity(0.96), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(
          LinearGradient(
            colors: [.white.opacity(0.16), .white.opacity(0.05)],
            startPoint: .top,
            endPoint: .bottom
          ),
          lineWidth: 0.9
        )
    }
  }

  private var statusText: String {
    switch appState.recordingState {
    case .idle:
      return "Idle"
    case .starting:
      return "Starting…"
    case .recording:
      return "Recording"
    case .stopping:
      return "Stopping…"
    }
  }

  private func formatDuration(_ duration: TimeInterval) -> String {
    let hours = Int(duration) / 3600
    let minutes = (Int(duration) % 3600) / 60
    let seconds = Int(duration) % 60

    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%d:%02d", minutes, seconds)
  }
}

private struct NotchWaveBars: View {
  let level: CGFloat
  let active: Bool

  var body: some View {
    HStack(spacing: 3) {
      ForEach(0..<7, id: \.self) { idx in
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
          .fill(active ? Color.red.opacity(0.95) : Color.white.opacity(0.35))
          .frame(width: 3, height: barHeight(for: idx))
      }
    }
    .frame(width: 34, height: 20)
  }

  private func barHeight(for index: Int) -> CGFloat {
    guard active else { return 4 }
    let clamped = min(max(level, 0), 1)
    let centerDistance = abs(CGFloat(index) - 3)
    let centerFactor = 1 - (centerDistance / 3) * 0.35
    return max(4, 4 + 14 * clamped * centerFactor)
  }
}
