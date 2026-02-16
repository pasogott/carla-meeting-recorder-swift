import Foundation
import GRDB

public enum Platform: String, Codable, CaseIterable, Sendable {
  case zoom
  case meet
  case teams
  case facetime
  case unknown
}

private enum JSONCoding {
  static func encodeStringArray(_ value: [String]) -> String {
    let data = (try? JSONEncoder().encode(value)) ?? Data("[]".utf8)
    return String(decoding: data, as: UTF8.self)
  }

  static func decodeStringArray(_ value: String?) -> [String] {
    guard let value else { return [] }
    guard let data = value.data(using: .utf8) else { return [] }
    return (try? JSONDecoder().decode([String].self, from: data)) ?? []
  }
}

public struct Meeting: FetchableRecord, MutablePersistableRecord, Identifiable, Sendable, Equatable,
  Codable
{
  public static let databaseTableName = "meeting"

  public var id: UUID
  public var title: String
  public var startedAt: Date
  public var endedAt: Date?
  public var duration: TimeInterval
  public var audioFilePath: String
  public var platform: Platform?
  public var calendarEventID: String?
  public var tags: [String]
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    title: String,
    startedAt: Date,
    endedAt: Date? = nil,
    duration: TimeInterval = 0,
    audioFilePath: String,
    platform: Platform? = nil,
    calendarEventID: String? = nil,
    tags: [String] = [],
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.title = title
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.duration = duration
    self.audioFilePath = audioFilePath
    self.platform = platform
    self.calendarEventID = calendarEventID
    self.tags = tags
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public init(row: Row) {
    id = UUID(uuidString: row["id"]) ?? UUID()
    title = row["title"]
    startedAt = row["started_at"]
    endedAt = row["ended_at"]
    duration = row["duration"]
    audioFilePath = row["audio_file_path"]
    let platformValue: String? = row["platform"]
    platform = platformValue.flatMap(Platform.init(rawValue:))
    calendarEventID = row["calendar_event_id"]
    tags = JSONCoding.decodeStringArray(row["tags"])
    createdAt = row["created_at"]
    updatedAt = row["updated_at"]
  }

  public func encode(to container: inout PersistenceContainer) {
    container["id"] = id.uuidString
    container["title"] = title
    container["started_at"] = startedAt
    container["ended_at"] = endedAt
    container["duration"] = duration
    container["audio_file_path"] = audioFilePath
    container["platform"] = platform?.rawValue
    container["calendar_event_id"] = calendarEventID
    container["tags"] = JSONCoding.encodeStringArray(tags)
    container["created_at"] = createdAt
    container["updated_at"] = updatedAt
  }
}

public struct Speaker: FetchableRecord, MutablePersistableRecord, Identifiable, Sendable, Equatable,
  Codable
{
  public static let databaseTableName = "speaker"

  public var id: UUID
  public var meetingID: UUID
  public var label: String
  public var isLocal: Bool
  public var embedding: Data?

  public init(
    id: UUID = UUID(),
    meetingID: UUID,
    label: String,
    isLocal: Bool,
    embedding: Data? = nil
  ) {
    self.id = id
    self.meetingID = meetingID
    self.label = label
    self.isLocal = isLocal
    self.embedding = embedding
  }

  public init(row: Row) {
    id = UUID(uuidString: row["id"]) ?? UUID()
    meetingID = UUID(uuidString: row["meeting_id"]) ?? UUID()
    label = row["label"]
    isLocal = row["is_local"]
    embedding = row["embedding"]
  }

  public func encode(to container: inout PersistenceContainer) {
    container["id"] = id.uuidString
    container["meeting_id"] = meetingID.uuidString
    container["label"] = label
    container["is_local"] = isLocal
    container["embedding"] = embedding
  }
}

public struct TranscriptSegment: FetchableRecord, MutablePersistableRecord, Identifiable, Sendable,
  Equatable, Codable
{
  public static let databaseTableName = "transcript_segment"

  public var id: UUID
  public var meetingID: UUID
  public var speakerID: UUID?
  public var startTime: TimeInterval
  public var endTime: TimeInterval
  public var text: String
  public var confidence: Float
  public var language: String

  public init(
    id: UUID = UUID(),
    meetingID: UUID,
    speakerID: UUID? = nil,
    startTime: TimeInterval,
    endTime: TimeInterval,
    text: String,
    confidence: Float,
    language: String
  ) {
    self.id = id
    self.meetingID = meetingID
    self.speakerID = speakerID
    self.startTime = startTime
    self.endTime = endTime
    self.text = text
    self.confidence = confidence
    self.language = language
  }

  public init(row: Row) {
    id = UUID(uuidString: row["id"]) ?? UUID()
    meetingID = UUID(uuidString: row["meeting_id"]) ?? UUID()
    let speakerRaw: String? = row["speaker_id"]
    speakerID = speakerRaw.flatMap(UUID.init(uuidString:))
    startTime = row["start_time"]
    endTime = row["end_time"]
    text = row["text"]
    confidence = row["confidence"]
    language = row["language"]
  }

  public func encode(to container: inout PersistenceContainer) {
    container["id"] = id.uuidString
    container["meeting_id"] = meetingID.uuidString
    container["speaker_id"] = speakerID?.uuidString
    container["start_time"] = startTime
    container["end_time"] = endTime
    container["text"] = text
    container["confidence"] = confidence
    container["language"] = language
  }
}

public struct MeetingSummary: FetchableRecord, MutablePersistableRecord, Sendable, Equatable,
  Codable
{
  public static let databaseTableName = "meeting_summary"

  public var meetingID: UUID
  public var summary: String
  public var keyDecisions: [String]
  public var followUps: [String]
  public var generatedAt: Date

  public init(
    meetingID: UUID,
    summary: String,
    keyDecisions: [String],
    followUps: [String],
    generatedAt: Date = Date()
  ) {
    self.meetingID = meetingID
    self.summary = summary
    self.keyDecisions = keyDecisions
    self.followUps = followUps
    self.generatedAt = generatedAt
  }

  public init(row: Row) {
    meetingID = UUID(uuidString: row["meeting_id"]) ?? UUID()
    summary = row["summary"]
    keyDecisions = JSONCoding.decodeStringArray(row["key_decisions"])
    followUps = JSONCoding.decodeStringArray(row["follow_ups"])
    generatedAt = row["generated_at"]
  }

  public func encode(to container: inout PersistenceContainer) {
    container["meeting_id"] = meetingID.uuidString
    container["summary"] = summary
    container["key_decisions"] = JSONCoding.encodeStringArray(keyDecisions)
    container["follow_ups"] = JSONCoding.encodeStringArray(followUps)
    container["generated_at"] = generatedAt
  }
}

public struct ActionItem: FetchableRecord, MutablePersistableRecord, Identifiable, Sendable,
  Equatable, Codable
{
  public static let databaseTableName = "action_item"

  public var id: UUID
  public var meetingID: UUID
  public var description: String
  public var assignee: String?
  public var deadline: Date?
  public var completed: Bool

  public init(
    id: UUID = UUID(),
    meetingID: UUID,
    description: String,
    assignee: String? = nil,
    deadline: Date? = nil,
    completed: Bool = false
  ) {
    self.id = id
    self.meetingID = meetingID
    self.description = description
    self.assignee = assignee
    self.deadline = deadline
    self.completed = completed
  }

  public init(row: Row) {
    id = UUID(uuidString: row["id"]) ?? UUID()
    meetingID = UUID(uuidString: row["meeting_id"]) ?? UUID()
    description = row["description"]
    assignee = row["assignee"]
    deadline = row["deadline"]
    completed = row["completed"]
  }

  public func encode(to container: inout PersistenceContainer) {
    container["id"] = id.uuidString
    container["meeting_id"] = meetingID.uuidString
    container["description"] = description
    container["assignee"] = assignee
    container["deadline"] = deadline
    container["completed"] = completed
  }
}

public struct TranscriptSearchResult: Sendable, Equatable {
  public let meetingID: UUID
  public let meetingTitle: String
  public let segmentID: UUID
  public let startTime: TimeInterval
  public let endTime: TimeInterval
  public let text: String
  public let language: String
  public let rank: Double

  public init(
    meetingID: UUID,
    meetingTitle: String,
    segmentID: UUID,
    startTime: TimeInterval,
    endTime: TimeInterval,
    text: String,
    language: String,
    rank: Double
  ) {
    self.meetingID = meetingID
    self.meetingTitle = meetingTitle
    self.segmentID = segmentID
    self.startTime = startTime
    self.endTime = endTime
    self.text = text
    self.language = language
    self.rank = rank
  }
}

public struct MeetingDetails: Sendable, Equatable {
  public let meeting: Meeting
  public let speakers: [Speaker]
  public let segments: [TranscriptSegment]
  public let summary: MeetingSummary?
  public let actionItems: [ActionItem]

  public init(
    meeting: Meeting,
    speakers: [Speaker],
    segments: [TranscriptSegment],
    summary: MeetingSummary?,
    actionItems: [ActionItem]
  ) {
    self.meeting = meeting
    self.speakers = speakers
    self.segments = segments
    self.summary = summary
    self.actionItems = actionItems
  }
}
