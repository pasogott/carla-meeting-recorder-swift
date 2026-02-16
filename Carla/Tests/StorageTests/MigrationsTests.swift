import GRDB
import XCTest

@testable import CarlaStorage

final class MigrationsTests: XCTestCase {
  func testInitialSchemaCreatesAllTablesAndFTS() throws {
    let database = try CarlaDatabase(inMemory: true)

    let tableNames = try database.dbQueue.read { db in
      try String.fetchAll(
        db,
        sql: "SELECT name FROM sqlite_master WHERE type IN ('table', 'virtual table')"
      )
    }

    XCTAssertTrue(tableNames.contains("meeting"))
    XCTAssertTrue(tableNames.contains("speaker"))
    XCTAssertTrue(tableNames.contains("transcript_segment"))
    XCTAssertTrue(tableNames.contains("meeting_summary"))
    XCTAssertTrue(tableNames.contains("action_item"))
    XCTAssertTrue(tableNames.contains("transcript_segment_fts"))
  }
}
