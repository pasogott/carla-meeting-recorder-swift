import CarlaModels
import Foundation
import GRDB

public protocol MeetingRepository: Sendable {
  func saveMeeting(_ meeting: Meeting) throws
  func saveSpeakers(_ speakers: [Speaker]) throws
  func saveTranscriptSegments(_ segments: [TranscriptSegment]) throws
  func saveSummary(_ summary: MeetingSummary, actionItems: [ActionItem]) throws
  func fetchMeetingDetails(id: UUID) throws -> MeetingDetails
  func listMeetings(limit: Int?, offset: Int?) throws -> [Meeting]
  func searchTranscript(query: String, limit: Int) throws -> [TranscriptSearchResult]
  func deleteMeeting(id: UUID) throws
}

public final class GRDBMeetingRepository: MeetingRepository {
  private let dbWriter: any DatabaseWriter

  public init(dbWriter: any DatabaseWriter) {
    self.dbWriter = dbWriter
  }

  public func saveMeeting(_ meeting: Meeting) throws {
    try dbWriter.write { db in
      var mutableMeeting = meeting
      mutableMeeting.updatedAt = Date()
      try mutableMeeting.save(db)
    }
  }

  public func saveSpeakers(_ speakers: [Speaker]) throws {
    try dbWriter.write { db in
      for var speaker in speakers {
        try speaker.save(db)
      }
    }
  }

  public func saveTranscriptSegments(_ segments: [TranscriptSegment]) throws {
    try dbWriter.write { db in
      for var segment in segments {
        try segment.save(db)
      }
    }
  }

  public func saveSummary(_ summary: MeetingSummary, actionItems: [ActionItem]) throws {
    try dbWriter.write { db in
      var mutableSummary = summary
      try mutableSummary.save(db)

      try ActionItem.filter(Column("meeting_id") == summary.meetingID.uuidString).deleteAll(db)
      for var actionItem in actionItems {
        try actionItem.save(db)
      }
    }
  }

  public func fetchMeetingDetails(id: UUID) throws -> MeetingDetails {
    try dbWriter.read { db in
      guard let meeting = try Meeting.fetchOne(db, key: id.uuidString) else {
        throw StorageError.meetingNotFound(id)
      }

      let speakers =
        try Speaker
        .filter(Column("meeting_id") == id.uuidString)
        .order(Column("label"))
        .fetchAll(db)

      let segments =
        try TranscriptSegment
        .filter(Column("meeting_id") == id.uuidString)
        .order(Column("start_time"))
        .fetchAll(db)

      let summary = try MeetingSummary.fetchOne(db, key: id.uuidString)
      let actionItems =
        try ActionItem
        .filter(Column("meeting_id") == id.uuidString)
        .order(Column("completed"), Column("deadline"))
        .fetchAll(db)

      return MeetingDetails(
        meeting: meeting,
        speakers: speakers,
        segments: segments,
        summary: summary,
        actionItems: actionItems
      )
    }
  }

  public func listMeetings(limit: Int? = nil, offset: Int? = nil) throws -> [Meeting] {
    try dbWriter.read { db in
      var request = Meeting.order(Column("started_at").desc)
      if let limit {
        request = request.limit(limit, offset: offset ?? 0)
      }
      return try request.fetchAll(db)
    }
  }

  public func searchTranscript(query: String, limit: Int = 30) throws -> [TranscriptSearchResult] {
    try dbWriter.read { db in
      struct RowResult: FetchableRecord, Decodable {
        let meetingID: String
        let meetingTitle: String
        let segmentID: String
        let startTime: Double
        let endTime: Double
        let text: String
        let language: String
        let rank: Double
      }

      let rows = try RowResult.fetchAll(
        db,
        sql: """
          SELECT
            m.id AS meetingID,
            m.title AS meetingTitle,
            ts.id AS segmentID,
            ts.start_time AS startTime,
            ts.end_time AS endTime,
            ts.text AS text,
            ts.language AS language,
            bm25(transcript_segment_fts) AS rank
          FROM transcript_segment_fts
          JOIN transcript_segment ts ON ts.rowid = transcript_segment_fts.rowid
          JOIN meeting m ON m.id = ts.meeting_id
          WHERE transcript_segment_fts MATCH ?
          ORDER BY rank ASC
          LIMIT ?
          """,
        arguments: [query, limit]
      )

      return rows.compactMap { row in
        guard let meetingID = UUID(uuidString: row.meetingID),
          let segmentID = UUID(uuidString: row.segmentID)
        else {
          return nil
        }
        return TranscriptSearchResult(
          meetingID: meetingID,
          meetingTitle: row.meetingTitle,
          segmentID: segmentID,
          startTime: row.startTime,
          endTime: row.endTime,
          text: row.text,
          language: row.language,
          rank: row.rank
        )
      }
    }
  }

  public func deleteMeeting(id: UUID) throws {
    try dbWriter.write { db in
      let deletedCount = try Meeting.filter(Column("id") == id.uuidString).deleteAll(db)
      guard deletedCount > 0 else {
        throw StorageError.meetingNotFound(id)
      }
    }
  }
}
