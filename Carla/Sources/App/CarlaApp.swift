import SwiftUI

@main
struct CarlaApp: App {
  @StateObject private var appState = AppState()

  var body: some Scene {
    MenuBarExtra {
      MenuBarMenuView(appState: appState)
    } label: {
      Label("Carla", systemImage: appState.menuBarIconName)
        .foregroundStyle(appState.menuBarIconColor)
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
