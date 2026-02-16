import AppKit
import CarlaTranscription
import SwiftUI

struct MeetingsView: View {
  @ObservedObject var appState: AppState

  var body: some View {
    NavigationSplitView {
      List(selection: $appState.selectedMeetingID) {
        ForEach(appState.filteredMeetings) { meeting in
          MeetingRowView(meeting: meeting)
            .tag(meeting.id)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
              Button(role: .destructive) {
                appState.prepareDeleteMeeting(id: meeting.id)
              } label: {
                Label("Delete", systemImage: "trash")
              }
            }
            .contextMenu {
              Button(role: .destructive) {
                appState.prepareDeleteMeeting(id: meeting.id)
              } label: {
                Label("Delete Meeting", systemImage: "trash")
              }
            }
        }
      }
      .searchable(text: $appState.searchQuery, prompt: "Search title or transcript")
      .navigationTitle("Meetings")
      .onChange(of: appState.selectedMeetingID) { _, newID in
        guard let newID else { return }
        appState.selectMeeting(newID)
      }
    } detail: {
      TranscriptViewerView(appState: appState)
    }
    .confirmationDialog(
      "Delete Meeting",
      isPresented: Binding(
        get: { appState.deleteConfirmation != nil },
        set: { if !$0 { appState.cancelDeleteMeeting() } }
      ),
      presenting: appState.deleteConfirmation
    ) { _ in
      Button("Delete Meeting and Audio", role: .destructive) {
        appState.confirmDeleteMeeting(deleteAudioFile: true)
      }
      Button("Delete Meeting Only", role: .destructive) {
        appState.confirmDeleteMeeting(deleteAudioFile: false)
      }
      Button("Cancel", role: .cancel) {
        appState.cancelDeleteMeeting()
      }
    } message: { confirmation in
      Text(
        "Are you sure you want to delete \"\(confirmation.meetingTitle)\"? This action cannot be undone."
      )
    }
  }
}

/// Row view for a single meeting in the list.
private struct MeetingRowView: View {
  let meeting: MeetingUI

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(meeting.title)
        .font(.headline)
      Text(
        "\(meeting.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(durationLabel(meeting.duration)) · \(meeting.platform.rawValue.capitalized)"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private func durationLabel(_ duration: TimeInterval) -> String {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.minute, .second]
    formatter.zeroFormattingBehavior = .pad
    return formatter.string(from: duration) ?? "00:00"
  }
}

struct TranscriptViewerView: View {
  @ObservedObject var appState: AppState

  var body: some View {
    VStack(spacing: 0) {
      if let meeting = appState.selectedMeeting {
        VStack(alignment: .leading, spacing: 8) {
          TextField(
            "Meeting title",
            text: Binding(
              get: { meeting.title },
              set: { appState.updateSelectedMeetingTitle($0) }
            )
          )
          .textFieldStyle(.roundedBorder)
          .font(.title3.weight(.semibold))

          HStack {
            // Play/Pause button - disabled if no audio file
            Button {
              appState.togglePlayback()
            } label: {
              Label(
                appState.playbackIsPlaying ? "Pause" : "Play",
                systemImage: appState.playbackIsPlaying ? "pause.fill" : "play.fill"
              )
            }
            .disabled(meeting.audioFilePath == nil)
            .help(meeting.audioFilePath == nil ? "No audio file available" : "")

            // Playback time display
            if meeting.audioFilePath != nil {
              Text(
                "\(timeLabel(appState.playbackCurrentTime)) / \(timeLabel(appState.playbackDuration))"
              )
              .font(.caption)
              .foregroundStyle(.secondary)
              .monospacedDigit()
            } else {
              Text("No audio")
                .font(.caption)
                .foregroundStyle(.tertiary)
            }

            // Show playback error if any
            if let error = appState.playbackError {
              Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help(error)
            }

            Spacer()

            Button("Copy Transcript") {
              let text = meeting.segments
                .map { "[\(timeLabel($0.startTime))] \($0.speakerLabel): \($0.text)" }
                .joined(separator: "\n")

              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(text, forType: .string)
            }
          }
        }
        .padding()

        Divider()

        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(meeting.segments) { segment in
              let isCurrentSegment =
                appState.playbackIsPlaying
                && appState.playbackCurrentTime >= segment.startTime
                && appState.playbackCurrentTime < segment.endTime

              HStack(alignment: .top, spacing: 12) {
                Button(timeLabel(segment.startTime)) {
                  appState.jumpToTimestamp(segment.startTime)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(meeting.audioFilePath == nil)

                VStack(alignment: .leading, spacing: 3) {
                  Text(segment.speakerLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                  Text(segment.text)
                }
                Spacer()
              }
              .padding(10)
              .background(
                isCurrentSegment
                  ? Color.accentColor.opacity(0.15)
                  : Color(NSColor.textBackgroundColor)
              )
              .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
              .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                  .strokeBorder(
                    isCurrentSegment ? Color.accentColor : Color.clear,
                    lineWidth: 2
                  )
              )
              .animation(.easeInOut(duration: 0.2), value: isCurrentSegment)
            }
          }
          .padding()
        }
      } else {
        ContentUnavailableView("No Meeting Selected", systemImage: "waveform")
      }
    }
  }

  private func timeLabel(_ time: TimeInterval) -> String {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.minute, .second]
    formatter.zeroFormattingBehavior = .pad
    return formatter.string(from: time) ?? "00:00"
  }
}

struct OnboardingView: View {
  @ObservedObject var appState: AppState

  @State private var requestingMicrophone = false
  @State private var requestingScreenRecording = false

  private var micStatus: PermissionStatus {
    appState.permissionManager.microphoneStatus
  }

  private var screenStatus: PermissionStatus {
    appState.permissionManager.screenRecordingStatus
  }

  private var canComplete: Bool {
    appState.canCompleteOnboarding
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Welcome to Carla")
        .font(.largeTitle.weight(.semibold))

      Text("Everything runs locally on your Mac.")
        .foregroundStyle(.secondary)

      GroupBox("Legal Disclaimer") {
        Toggle(
          "I am responsible for recording consent in my jurisdiction",
          isOn: $appState.onboarding.legalAccepted
        )
      }

      GroupBox("Permissions") {
        VStack(alignment: .leading, spacing: 12) {
          // Microphone permission row
          PermissionRow(
            title: "Microphone",
            status: micStatus,
            grantedIcon: "checkmark.circle.fill",
            pendingIcon: "mic",
            isRequesting: requestingMicrophone,
            onRequest: {
              requestingMicrophone = true
              Task {
                await appState.requestMicrophonePermission()
                requestingMicrophone = false
              }
            },
            onOpenSettings: {
              appState.permissionManager.openSystemSettingsForMicrophone()
            }
          )

          Divider()

          // Screen Recording permission row
          PermissionRow(
            title: "Screen Recording",
            status: screenStatus,
            grantedIcon: "checkmark.circle.fill",
            pendingIcon: "display",
            isRequesting: requestingScreenRecording,
            onRequest: {
              requestingScreenRecording = true
              Task {
                await appState.requestScreenRecordingPermission()
                requestingScreenRecording = false
              }
            },
            onOpenSettings: {
              appState.permissionManager.openSystemSettingsForScreenRecording()
            }
          )
        }
      }

      // Model Download Section
      GroupBox("AI Transcription Models") {
        ModelDownloadSection(appState: appState)
      }

      GroupBox("Primary Language") {
        Picker("Language", selection: $appState.settings.primaryLanguage) {
          Text("EN").tag("en")
          Text("DE").tag("de")
          Text("FR").tag("fr")
        }
        .pickerStyle(.segmented)
      }

      HStack {
        Spacer()
        Button("Complete Setup") {
          appState.completeOnboarding()
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canComplete)
      }
    }
    .padding(20)
    .onAppear {
      // Re-check permissions when view appears (e.g., returning from System Settings)
      Task {
        await appState.recheckPermissions()
        // Check model availability on appear
        await appState.checkModelAvailability()
      }
    }
  }
}

/// Section for downloading AI transcription models.
private struct ModelDownloadSection: View {
  @ObservedObject var appState: AppState

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      // Status header
      HStack {
        if appState.modelDownload.isComplete {
          Label("Models Ready", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        } else if appState.modelDownload.isDownloading {
          Label("Downloading...", systemImage: "arrow.down.circle")
            .foregroundStyle(.blue)
        } else if appState.modelDownload.errorMessage != nil {
          Label("Download Failed", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
        } else {
          Label("Models Required", systemImage: "arrow.down.circle")
            .foregroundStyle(.secondary)
        }

        Spacer()

        if !appState.modelDownload.isComplete && !appState.modelDownload.isDownloading {
          Button("Download") {
            Task {
              await appState.downloadRequiredModels()
            }
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
      }

      // Progress bar when downloading
      if appState.modelDownload.isDownloading {
        VStack(alignment: .leading, spacing: 4) {
          if let model = appState.modelDownload.currentModel {
            Text("Downloading \(modelDisplayName(model))")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          ProgressView(value: appState.modelDownload.progress)
            .progressViewStyle(.linear)

          Text(appState.modelDownload.progressText)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }

      // Error message
      if let error = appState.modelDownload.errorMessage {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)

        Button("Retry") {
          Task {
            await appState.downloadRequiredModels()
          }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }

      // Info text
      if !appState.modelDownload.isComplete && !appState.modelDownload.isDownloading {
        Text(
          "Carla needs to download AI models (~150MB) for transcription. Models are stored locally and never sent to the cloud."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }

  private func modelDisplayName(_ model: WhisperModel) -> String {
    switch model {
    case .base: return "Base Model (~150MB)"
    case .small: return "Small Model (~500MB)"
    case .medium: return "Medium Model (~1.5GB)"
    case .large: return "Large Model (~3GB)"
    }
  }
}

/// A reusable row for displaying permission status with request/settings buttons
private struct PermissionRow: View {
  let title: String
  let status: PermissionStatus
  let grantedIcon: String
  let pendingIcon: String
  let isRequesting: Bool
  let onRequest: () -> Void
  let onOpenSettings: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Label(statusLabel, systemImage: iconName)
          .foregroundStyle(iconColor)

        Spacer()

        if isRequesting {
          ProgressView()
            .controlSize(.small)
        } else {
          switch status {
          case .granted:
            Image(systemName: "checkmark")
              .foregroundStyle(.green)

          case .denied, .restricted:
            Button("Open System Settings") {
              onOpenSettings()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

          case .notDetermined:
            Button("Grant") {
              onRequest()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
          }
        }
      }

      if status == .denied {
        Text("Permission was denied. Please enable in System Settings and return here.")
          .font(.caption)
          .foregroundStyle(.orange)
      } else if status == .restricted {
        Text("Permission is restricted by system policy.")
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
  }

  private var statusLabel: String {
    switch status {
    case .granted:
      return "\(title) Granted"
    case .denied:
      return "\(title) Denied"
    case .restricted:
      return "\(title) Restricted"
    case .notDetermined:
      return title
    }
  }

  private var iconName: String {
    status == .granted ? grantedIcon : pendingIcon
  }

  private var iconColor: Color {
    switch status {
    case .granted: return .green
    case .denied: return .orange
    case .restricted: return .red
    case .notDetermined: return .primary
    }
  }
}
