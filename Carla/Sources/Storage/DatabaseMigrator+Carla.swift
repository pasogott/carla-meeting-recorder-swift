import Foundation
import GRDB

public enum CarlaDatabaseMigrations {
  public static func migrator() -> DatabaseMigrator {
    var migrator = DatabaseMigrator()

    migrator.registerMigration("v1_initial_schema") { db in
      try db.create(table: "meeting") { table in
        table.column("id", .text).notNull().primaryKey()
        table.column("title", .text).notNull()
        table.column("started_at", .datetime).notNull()
        table.column("ended_at", .datetime)
        table.column("duration", .double).notNull().defaults(to: 0)
        table.column("audio_file_path", .text).notNull()
        table.column("platform", .text)
        table.column("calendar_event_id", .text)
        table.column("tags", .text).notNull().defaults(to: "[]")
        table.column("created_at", .datetime).notNull()
        table.column("updated_at", .datetime).notNull()
      }

      try db.create(table: "speaker") { table in
        table.column("id", .text).notNull().primaryKey()
        table.column("meeting_id", .text).notNull().indexed().references(
          "meeting", onDelete: .cascade)
        table.column("label", .text).notNull()
        table.column("is_local", .boolean).notNull()
        table.column("embedding", .blob)
      }

      try db.create(table: "transcript_segment") { table in
        table.column("id", .text).notNull().primaryKey()
        table.column("meeting_id", .text).notNull().indexed().references(
          "meeting", onDelete: .cascade)
        table.column("speaker_id", .text).references("speaker", onDelete: .setNull)
        table.column("start_time", .double).notNull().indexed()
        table.column("end_time", .double).notNull()
        table.column("text", .text).notNull()
        table.column("confidence", .double).notNull().defaults(to: 0)
        table.column("language", .text).notNull().defaults(to: "en")
      }

      try db.create(table: "meeting_summary") { table in
        table.column("meeting_id", .text).notNull().primaryKey().references(
          "meeting", onDelete: .cascade)
        table.column("summary", .text).notNull()
        table.column("key_decisions", .text).notNull().defaults(to: "[]")
        table.column("follow_ups", .text).notNull().defaults(to: "[]")
        table.column("generated_at", .datetime).notNull()
      }

      try db.create(table: "action_item") { table in
        table.column("id", .text).notNull().primaryKey()
        table.column("meeting_id", .text).notNull().indexed().references(
          "meeting", onDelete: .cascade)
        table.column("description", .text).notNull()
        table.column("assignee", .text)
        table.column("deadline", .datetime)
        table.column("completed", .boolean).notNull().defaults(to: false)
      }

      try db.execute(
        sql: """
          CREATE VIRTUAL TABLE transcript_segment_fts USING fts5(
              text,
              language,
              content='transcript_segment',
              content_rowid='rowid',
              tokenize='unicode61 remove_diacritics 2'
          );
          """)

      try db.execute(
        sql: """
          CREATE TRIGGER transcript_segment_ai AFTER INSERT ON transcript_segment BEGIN
            INSERT INTO transcript_segment_fts(rowid, text, language)
            VALUES (new.rowid, new.text, new.language);
          END;
          """)

      try db.execute(
        sql: """
          CREATE TRIGGER transcript_segment_ad AFTER DELETE ON transcript_segment BEGIN
            INSERT INTO transcript_segment_fts(transcript_segment_fts, rowid, text, language)
            VALUES('delete', old.rowid, old.text, old.language);
          END;
          """)

      try db.execute(
        sql: """
          CREATE TRIGGER transcript_segment_au AFTER UPDATE ON transcript_segment BEGIN
            INSERT INTO transcript_segment_fts(transcript_segment_fts, rowid, text, language)
            VALUES('delete', old.rowid, old.text, old.language);
            INSERT INTO transcript_segment_fts(rowid, text, language)
            VALUES (new.rowid, new.text, new.language);
          END;
          """)
    }

    return migrator
  }
}
