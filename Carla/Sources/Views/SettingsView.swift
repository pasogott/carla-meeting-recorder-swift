import SwiftUI

struct SettingsView: View {
  @ObservedObject var coordinator: AppState

  // Mock data for dropdowns (in a real app these might come from a provider)
  private let inputDevices = [
    "System Default Microphone", "MacBook Microphone", "External USB Microphone",
  ]
  private let outputDevices = ["System Default Output", "MacBook Speakers", "AirPods Pro"]
  private let whisperModels = ["base", "small", "medium", "large"]
  private let languages = ["en", "de", "fr", "es", "it"]

  var body: some View {
    TabView {
      GeneralSettingsTab(settings: $coordinator.settings)
        .tabItem {
          Label("General", systemImage: "gear")
        }
        .tag("general")

      AudioSettingsTab(
        settings: $coordinator.settings,
        inputDevices: inputDevices,
        outputDevices: outputDevices
      )
      .tabItem {
        Label("Audio", systemImage: "mic.fill")
      }
      .tag("audio")

      TranscriptionSettingsTab(
        settings: $coordinator.settings,
        models: whisperModels,
        languages: languages
      )
      .tabItem {
        Label("Transcription", systemImage: "waveform.badge.magnifyingglass")
      }
      .tag("transcription")

      StorageSettingsTab(settings: $coordinator.settings)
        .tabItem {
          Label("Storage", systemImage: "externaldrive.fill")
        }
        .tag("storage")

      OnboardingSettingsTab(appState: coordinator)
        .tabItem {
          Label("Onboarding", systemImage: "checkmark.seal")
        }
        .tag("onboarding")
    }
    .padding(20)
    .frame(width: 500)  // Standard width for macOS settings windows
  }
}

// MARK: - Settings Tabs

private struct GeneralSettingsTab: View {
  @Binding var settings: AppSettings

  var body: some View {
    Form {
      Section {
        Toggle(isOn: $settings.launchAtLogin) {
          Text("Launch at login (coming soon)")
          Text("This option is not implemented yet.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .disabled(true)

        Toggle(isOn: $settings.showNotchOverlay) {
          Text("Show notch overlay")
          Text("Display a recording indicator and controls at the top of the screen.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .scrollDisabled(true)
  }
}

private struct AudioSettingsTab: View {
  @Binding var settings: AppSettings
  let inputDevices: [String]
  let outputDevices: [String]

  var body: some View {
    Form {
      Section("Input") {
        Picker("Microphone", selection: $settings.selectedInputDevice) {
          ForEach(inputDevices, id: \.self) { Text($0).tag($0) }
        }
        .pickerStyle(.menu)
      }

      Section("Output") {
        Picker("Speaker", selection: $settings.selectedOutputDevice) {
          ForEach(outputDevices, id: \.self) { Text($0).tag($0) }
        }
        .pickerStyle(.menu)

        Text("Carla records system audio from this device.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .scrollDisabled(true)
  }
}

private struct TranscriptionSettingsTab: View {
  @Binding var settings: AppSettings
  let models: [String]
  let languages: [String]

  var body: some View {
    Form {
      Section("Model") {
        Picker("Whisper Model", selection: $settings.selectedModel) {
          ForEach(models, id: \.self) { Text($0.capitalized).tag($0) }
        }
        .pickerStyle(.menu)

        Text("Larger models are more accurate but slower.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Language") {
        Picker("Primary Language", selection: $settings.primaryLanguage) {
          ForEach(languages, id: \.self) { Text($0.uppercased()).tag($0) }
        }
        .pickerStyle(.menu)

        Text("Used for initial detection. Auto-detect is used as fallback.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .scrollDisabled(true)
  }
}

private struct StorageSettingsTab: View {
  @Binding var settings: AppSettings

  var body: some View {
    Form {
      Section("Location") {
        TextField("Path", text: $settings.storagePath)
          .textFieldStyle(.roundedBorder)

        Text("Audio files and transcripts are stored here.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .scrollDisabled(true)
  }
}

private struct OnboardingSettingsTab: View {
  @ObservedObject var appState: AppState

  var body: some View {
    Form {
      Section("Consent") {
        Toggle(
          "I am responsible for recording consent in my jurisdiction",
          isOn: $appState.onboarding.legalAccepted
        )
      }

      Section("Permissions") {
        HStack {
          Label("Microphone", systemImage: "mic")
          Spacer()
          Text(label(for: appState.permissionManager.microphoneStatus))
            .foregroundStyle(color(for: appState.permissionManager.microphoneStatus))
        }

        HStack {
          Button("Request Microphone") {
            Task { @MainActor in
              await appState.requestMicrophonePermission()
            }
          }
          .buttonStyle(.bordered)

          Button("Open Microphone Settings") {
            appState.permissionManager.openSystemSettingsForMicrophone()
          }
          .buttonStyle(.bordered)
        }

        Divider()

        HStack {
          Label("Screen Recording", systemImage: "display")
          Spacer()
          Text(label(for: appState.permissionManager.screenRecordingStatus))
            .foregroundStyle(color(for: appState.permissionManager.screenRecordingStatus))
        }

        HStack {
          Button("Request Screen Recording") {
            Task { @MainActor in
              await appState.requestScreenRecordingPermission()
            }
          }
          .buttonStyle(.bordered)

          Button("Open Screen Recording Settings") {
            appState.permissionManager.openSystemSettingsForScreenRecording()
          }
          .buttonStyle(.bordered)
        }

        Button("Refresh Permission Status") {
          Task { @MainActor in
            await appState.recheckPermissions()
          }
        }
        .buttonStyle(.bordered)
      }

      Section("Models") {
        HStack {
          Text("Status")
          Spacer()
          Text(modelStatusText)
            .foregroundStyle(modelStatusColor)
        }

        HStack {
          Button("Check Models") {
            Task { @MainActor in
              await appState.checkModelAvailability()
            }
          }
          .buttonStyle(.bordered)

          Button("Download Models") {
            Task { @MainActor in
              await appState.downloadRequiredModels()
            }
          }
          .buttonStyle(.bordered)
          .disabled(appState.modelDownload.isDownloading)
        }
      }

      Section("Completion") {
        HStack {
          Text("Onboarding")
          Spacer()
          Text(appState.showOnboarding ? "Open" : "Completed")
            .foregroundStyle(appState.showOnboarding ? .orange : .green)
        }

        Button("Complete Setup") {
          appState.completeOnboarding()
        }
        .buttonStyle(.borderedProminent)
        .disabled(!appState.canCompleteOnboarding)
      }
    }
    .formStyle(.grouped)
  }

  private var modelStatusText: String {
    if appState.modelDownload.isDownloading {
      return "Downloading"
    }
    if appState.modelDownload.isComplete {
      return "Ready"
    }
    if appState.modelDownload.errorMessage != nil {
      return "Failed"
    }
    return "Not ready"
  }

  private var modelStatusColor: Color {
    if appState.modelDownload.isDownloading {
      return .blue
    }
    if appState.modelDownload.isComplete {
      return .green
    }
    if appState.modelDownload.errorMessage != nil {
      return .red
    }
    return .secondary
  }

  private func label(for status: PermissionStatus) -> String {
    switch status {
    case .granted: return "Granted"
    case .denied: return "Denied"
    case .restricted: return "Restricted"
    case .notDetermined: return "Not Determined"
    }
  }

  private func color(for status: PermissionStatus) -> Color {
    switch status {
    case .granted: return .green
    case .denied: return .orange
    case .restricted: return .red
    case .notDetermined: return .secondary
    }
  }
}
