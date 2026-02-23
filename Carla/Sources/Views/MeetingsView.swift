import AppKit
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
    TimeLabelFormatter.mmss(duration)
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
    TimeLabelFormatter.mmss(time)
  }
}

private enum TimeLabelFormatter {
  private static let formatter: DateComponentsFormatter = {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.minute, .second]
    formatter.zeroFormattingBehavior = .pad
    return formatter
  }()

  static func mmss(_ value: TimeInterval) -> String {
    formatter.string(from: value) ?? "00:00"
  }
}
