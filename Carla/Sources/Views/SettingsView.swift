import SwiftUI

struct SettingsView: View {
  @ObservedObject var coordinator: AppState

  @State private var draft: AppSettings = .default

  private let inputDevices = [
    "System Default Microphone", "MacBook Microphone", "External USB Microphone",
  ]
  private let outputDevices = ["System Default Output", "MacBook Speakers", "AirPods Pro"]
  private let whisperModels = ["base", "small", "medium", "large"]
  private let languages = ["en", "de", "fr", "es", "it"]

  var body: some View {
    Form {
      Section("Audio Devices") {
        Picker("Input Device", selection: $draft.selectedInputDevice) {
          ForEach(inputDevices, id: \.self) { Text($0).tag($0) }
        }

        Picker("Output Device", selection: $draft.selectedOutputDevice) {
          ForEach(outputDevices, id: \.self) { Text($0).tag($0) }
        }
      }

      Section("Transcription") {
        Picker("Whisper Model", selection: $draft.selectedModel) {
          ForEach(whisperModels, id: \.self) { Text($0).tag($0) }
        }

        Picker("Primary Language", selection: $draft.primaryLanguage) {
          ForEach(languages, id: \.self) { Text($0.uppercased()).tag($0) }
        }
      }

      Section("Storage") {
        TextField("Storage Path", text: $draft.storagePath)
        Text("Audio and transcript artifacts will be stored locally.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("App") {
        Toggle("Launch at login", isOn: $draft.launchAtLogin)
        Toggle("Show Notch Overlay while recording", isOn: $draft.showNotchOverlay)
        Text("Launch-at-login toggle is currently a UI placeholder.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      HStack {
        Spacer()
        Button("Reset") {
          draft = .default
        }
        Button("Save") {
          coordinator.saveSettings(draft)
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .padding(16)
    .onAppear {
      draft = coordinator.settings
    }
  }
}
