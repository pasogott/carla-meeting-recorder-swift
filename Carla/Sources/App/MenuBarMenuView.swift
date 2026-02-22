import SwiftUI

struct MenuBarMenuView: View {
  @Environment(\.openWindow) private var openWindow

  @ObservedObject var appState: AppState

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label(
          appState.recordingState == .recording ? "Recording" : "Idle",
          systemImage: appState.recordingState == .recording ? "record.circle.fill" : "pause.circle"
        )
        .foregroundStyle(appState.recordingState == .recording ? .red : .secondary)

        if appState.recordingState == .recording {
          Spacer()
          Text(formatDuration(appState.currentRecordingDuration))
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(.secondary)
        }
      }

      if appState.recordingState == .recording {
        DualAudioLevelMetersView(
          microphoneLevel: appState.microphoneLevel,
          systemAudioLevel: appState.systemAudioLevel,
          segmented: true
        )
        .padding(.vertical, 2)
      }

      Button(appState.recordingState == .recording ? "Stop Recording" : "Start Recording") {
        appState.toggleRecording()
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.small)

      Divider()

      menuAction("View Meetings", systemImage: "list.bullet.rectangle") {
        openAppWindow(WindowID.meetings)
        openAppWindow(WindowID.transcript)
      }

      menuAction("Open Transcript Viewer", systemImage: "text.bubble") {
        openAppWindow(WindowID.transcript)
      }

      menuAction("Settings", systemImage: "gearshape") {
        openAppWindow(WindowID.settings)
      }

      menuAction("Check for Updates…", systemImage: "arrow.triangle.2.circlepath") {
        appState.checkForUpdates()
      }
      .disabled(!appState.canCheckForUpdates)

      if appState.showOnboarding {
        menuAction("Finish Onboarding", systemImage: "sparkles") {
          openAppWindow(WindowID.onboarding)
        }
      }

      Divider()

      menuAction("Quit Carla", systemImage: "power") {
        NSApp.terminate(nil)
      }
      .keyboardShortcut("q")
    }
    .padding(12)
    .frame(minWidth: 260)
    .onAppear {
      if appState.consumeShouldAutoOpenOnboardingWindow() {
        openAppWindow(WindowID.onboarding)
      }
    }
  }

  private func menuAction(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func openAppWindow(_ id: String) {
    NSApp.activate(ignoringOtherApps: true)
    openWindow(id: id)
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
