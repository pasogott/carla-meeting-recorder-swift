import SwiftUI

struct MenuBarMenuView: View {
  @Environment(\.openWindow) private var openWindow

  @ObservedObject var appState: AppState

  var body: some View {
    VStack(spacing: 16) {
      // 1. Status Header
      HStack {
        HStack(spacing: 8) {
          Circle()
            .fill(appState.recordingState == .recording ? Color.red : Color.green)
            .frame(width: 8, height: 8)
            .shadow(
              color: appState.recordingState == .recording ? .red.opacity(0.5) : .clear, radius: 4)

          Text(appState.recordingState == .recording ? "Recording" : "Ready")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.primary)
        }

        Spacer()

        if appState.recordingState == .recording {
          Text(formatDuration(appState.currentRecordingDuration))
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
      }

      // 2. Audio Meters (Conditional)
      if appState.recordingState == .recording {
        VStack(spacing: 10) {
          DualAudioLevelMetersView(
            microphoneLevel: appState.microphoneLevel,
            systemAudioLevel: appState.systemAudioLevel,
            segmented: false  // Continuous looks cleaner in this context
          )
        }
        .padding(12)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8))
      }

      // 3. Primary Action
      Button {
        appState.toggleRecording()
      } label: {
        HStack {
          Image(systemName: appState.recordingState == .recording ? "stop.fill" : "circle.fill")
            .font(.system(size: 12))
          Text(appState.recordingState == .recording ? "Stop Recording" : "Start Recording")
        }
        .fontWeight(.medium)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
      }
      .buttonStyle(.borderedProminent)
      .tint(appState.recordingState == .recording ? .red : .accentColor)
      .controlSize(.large)
      .disabled(appState.recordingState == .starting || appState.recordingState == .stopping)

      Divider()

      // 4. Secondary Actions
      VStack(spacing: 2) {
        MenuActionButton(title: "Meetings", icon: "list.bullet.rectangle") {
          openAppWindow(WindowID.meetings)
        }

        MenuActionButton(title: "Transcript", icon: "text.bubble") {
          openAppWindow(WindowID.transcript)
        }

        MenuActionButton(title: "Settings", icon: "gearshape") {
          openAppWindow(WindowID.settings)
        }
      }

      // 5. Contextual Actions
      if appState.canCheckForUpdates || appState.showOnboarding {
        Divider()
        VStack(spacing: 2) {
          if appState.canCheckForUpdates {
            MenuActionButton(title: "Check for Updates…", icon: "arrow.triangle.2.circlepath") {
              appState.checkForUpdates()
            }
          }
          if appState.showOnboarding {
            MenuActionButton(title: "Finish Setup", icon: "sparkles") {
              openAppWindow(WindowID.settings)
            }
            .foregroundStyle(.blue)
          }
        }
      }

      Divider()

      // 6. Footer
      HStack {
        Text("Carla")
          .font(.caption)
          .foregroundStyle(.tertiary)
        Spacer()
        Button("Quit") {
          NSApp.terminate(nil)
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
        .keyboardShortcut("q")
      }
    }
    .padding(16)
    .frame(width: 280)
    .onAppear {
      if appState.consumeShouldAutoOpenOnboardingWindow() {
        openAppWindow(WindowID.settings)
      }
    }
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

private struct MenuActionButton: View {
  let title: String
  let icon: String
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Image(systemName: icon)
          .font(.system(size: 14))
          .frame(width: 20, alignment: .center)
          .foregroundStyle(.secondary)

        Text(title)
          .font(.system(size: 13))

        Spacer()
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .background(isHovering ? Color.primary.opacity(0.05) : Color.clear)
      .clipShape(RoundedRectangle(cornerRadius: 6))
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
  }
}
