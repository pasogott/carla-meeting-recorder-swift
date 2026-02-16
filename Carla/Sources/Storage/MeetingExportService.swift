import CarlaModels
import Foundation

public enum TranscriptExportFormat: String, Sendable, CaseIterable {
  case markdown = "md"
  case txt
  case srt
  case json
}

public protocol MeetingExporting {
  func exportMeeting(_ meetingID: UUID, format: TranscriptExportFormat, destination: URL?) throws
    -> URL
}

public final class MeetingExportService: MeetingExporting {
  private let repository: MeetingRepository
  private let paths: AppStoragePaths
  private let fileManager: FileManager

  public init(
    repository: MeetingRepository, paths: AppStoragePaths, fileManager: FileManager = .default
  ) {
    self.repository = repository
    self.paths = paths
    self.fileManager = fileManager
  }

  public func exportMeeting(
    _ meetingID: UUID, format: TranscriptExportFormat, destination: URL? = nil
  ) throws -> URL {
    let details = try repository.fetchMeetingDetails(id: meetingID)
    let outputDirectory = destination ?? paths.exportsDirectory
    try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

    let baseName = sanitizedFileName(from: details.meeting.title)
    let fileURL = outputDirectory.appendingPathComponent(
      "\(baseName)-\(meetingID.uuidString).\(format.rawValue)")

    let content: String
    switch format {
    case .markdown:
      content = renderMarkdown(details: details)
    case .txt:
      content = renderTXT(details: details)
    case .srt:
      content = renderSRT(details: details)
    case .json:
      content = try renderJSON(details: details)
    }

    do {
      try content.write(to: fileURL, atomically: true, encoding: .utf8)
      return fileURL
    } catch {
      throw StorageError.exportFailed(error.localizedDescription)
    }
  }

  private func renderMarkdown(details: MeetingDetails) -> String {
    var output: [String] = [
      "# \(details.meeting.title)",
      "",
      "- **Meeting ID:** \(details.meeting.id.uuidString)",
      "- **Started:** \(details.meeting.startedAt.formatted(date: .abbreviated, time: .standard))",
      "- **Duration:** \(Int(details.meeting.duration)) seconds",
      "",
    ]

    if let summary = details.summary {
      output.append("## Summary")
      output.append(summary.summary)
      output.append("")

      if !summary.keyDecisions.isEmpty {
        output.append("### Key Decisions")
        output.append(contentsOf: summary.keyDecisions.map { "- \($0)" })
        output.append("")
      }

      if !details.actionItems.isEmpty {
        output.append("### Action Items")
        output.append(
          contentsOf: details.actionItems.map { item in
            let assignee = item.assignee ?? "Unassigned"
            return "- [\(item.completed ? "x" : " ")] \(item.description) _(\(assignee))_"
          })
        output.append("")
      }
    }

    output.append("## Transcript")
    output.append(
      contentsOf: details.segments.map { segment in
        "- [\(formatTimestamp(segment.startTime))] \(segment.text)"
      })

    return output.joined(separator: "\n")
  }

  private func renderTXT(details: MeetingDetails) -> String {
    details.segments
      .map { "[\(formatTimestamp($0.startTime))] \($0.text)" }
      .joined(separator: "\n")
  }

  private func renderSRT(details: MeetingDetails) -> String {
    details.segments.enumerated().map { index, segment in
      """
      \(index + 1)
      \(formatSRTTimestamp(segment.startTime)) --> \(formatSRTTimestamp(segment.endTime))
      \(segment.text)
      """
    }
    .joined(separator: "\n\n")
  }

  private func renderJSON(details: MeetingDetails) throws -> String {
    struct ExportPayload: Encodable {
      let meeting: Meeting
      let speakers: [Speaker]
      let segments: [TranscriptSegment]
      let summary: MeetingSummary?
      let actionItems: [ActionItem]

      enum CodingKeys: String, CodingKey {
        case meeting
        case speakers
        case segments
        case summary
        case actionItems
      }

      func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(meeting, forKey: .meeting)
        try container.encode(speakers, forKey: .speakers)
        try container.encode(segments, forKey: .segments)

        if let summary {
          try container.encode(summary, forKey: .summary)
        } else {
          try container.encodeNil(forKey: .summary)
        }

        try container.encode(actionItems, forKey: .actionItems)
      }
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601

    let data = try encoder.encode(
      ExportPayload(
        meeting: details.meeting,
        speakers: details.speakers,
        segments: details.segments,
        summary: details.summary,
        actionItems: details.actionItems
      )
    )

    return String(decoding: data, as: UTF8.self)
  }

  private func formatTimestamp(_ value: TimeInterval) -> String {
    let totalSeconds = Int(value.rounded())
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let seconds = totalSeconds % 60
    return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
  }

  private func formatSRTTimestamp(_ value: TimeInterval) -> String {
    let milliseconds = Int((value * 1000).rounded())
    let hours = milliseconds / 3_600_000
    let minutes = (milliseconds % 3_600_000) / 60_000
    let seconds = (milliseconds % 60_000) / 1000
    let millis = milliseconds % 1000
    return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, millis)
  }

  private func sanitizedFileName(from value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    let compact =
      value
      .replacingOccurrences(of: " ", with: "-")
      .unicodeScalars
      .map { allowed.contains($0) ? Character($0) : "-" }
    return String(compact).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
  }
}
