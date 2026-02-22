import SwiftUI

struct MenuBarMenuView: View {
  @Environment(\.openWindow) private var openWindow

  @ObservedObject var appState: AppState

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      // Recording status header
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

      // Audio level meters (visible only when recording)
      if appState.recordingState == .recording {
        DualAudioLevelMetersView(
          microphoneLevel: appState.microphoneLevel,
          systemAudioLevel: appState.systemAudioLevel,
          segmented: true
        )
        .padding(.vertical, 4)
      }

      Button(appState.recordingState == .recording ? "Stop Recording" : "Start Recording") {
        appState.toggleRecording()
      }

      Divider()

      Button("View Meetings") {
        openWindow(id: WindowID.meetings)
        openWindow(id: WindowID.transcript)
      }

      Button("Open Transcript Viewer") {
        openWindow(id: WindowID.transcript)
      }

      Button("Settings") {
        openWindow(id: WindowID.settings)
      }

      Button("Check for Updates…") {
        appState.checkForUpdates()
      }
      .disabled(!appState.canCheckForUpdates)

      if appState.showOnboarding {
        Button("Finish Onboarding") {
          openWindow(id: WindowID.onboarding)
        }
      }

      Divider()

      Button("Quit Carla") {
        NSApp.terminate(nil)
      }
      .keyboardShortcut("q")
    }
    .padding(12)
    .frame(minWidth: 240)
    .onAppear {
      if appState.showOnboarding {
        openWindow(id: WindowID.onboarding)
      }
    }
  }

  // MARK: - Helpers

  private func formatDuration(_ duration: TimeInterval) -> String {
    let hours = Int(duration) / 3600
    let minutes = (Int(duration) % 3600) / 60
    let seconds = Int(duration) % 60

    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    } else {
      return String(format: "%d:%02d", minutes, seconds)
    }
  }
}
