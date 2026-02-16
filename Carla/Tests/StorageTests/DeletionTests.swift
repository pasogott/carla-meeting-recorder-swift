import CarlaModels
import Foundation
import XCTest

@testable import CarlaStorage

final class DeletionTests: XCTestCase {
  func testDeleteRequiresValidConfirmationToken() async throws {
    let database = try CarlaDatabase(inMemory: true)
    let repository = GRDBMeetingRepository(dbWriter: database.dbQueue)
    let service = MeetingDeletionService(repository: repository)

    let meeting = Meeting(
      title: "Delete Me", startedAt: Date(), audioFilePath: "/tmp/delete-me.wav")
    try repository.saveMeeting(meeting)

    let confirmation = try await service.prepareDeleteMeeting(id: meeting.id)
    XCTAssertEqual(confirmation.meetingID, meeting.id)

    do {
      try await service.confirmDeleteMeeting(
        MeetingDeletionRequest(
          meetingID: meeting.id, confirmationID: UUID(), deleteAudioFile: false)
      )
      XCTFail("Expected invalidDeleteConfirmation")
    } catch StorageError.invalidDeleteConfirmation {
      // expected
    }

    try await service.confirmDeleteMeeting(
      MeetingDeletionRequest(
        meetingID: meeting.id,
        confirmationID: confirmation.confirmationID,
        deleteAudioFile: false
      )
    )

    do {
      _ = try repository.fetchMeetingDetails(id: meeting.id)
      XCTFail("Expected meetingNotFound")
    } catch StorageError.meetingNotFound {
      // expected
    }
  }

  func testDeleteDoesNotRemoveAudioOutsideAllowedDirectory() async throws {
    let database = try CarlaDatabase(inMemory: true)
    let repository = GRDBMeetingRepository(dbWriter: database.dbQueue)

    let allowedAudioDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("carla-audio-allowed-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: allowedAudioDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: allowedAudioDirectory) }

    let outsideAudioURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("carla-outside-\(UUID().uuidString).wav")
    try Data("test".utf8).write(to: outsideAudioURL)
    defer { try? FileManager.default.removeItem(at: outsideAudioURL) }

    let meeting = Meeting(
      title: "Outside Audio", startedAt: Date(), audioFilePath: outsideAudioURL.path)
    try repository.saveMeeting(meeting)

    let service = MeetingDeletionService(
      repository: repository, allowedAudioDirectory: allowedAudioDirectory)
    let confirmation = try await service.prepareDeleteMeeting(id: meeting.id)

    try await service.confirmDeleteMeeting(
      MeetingDeletionRequest(
        meetingID: meeting.id,
        confirmationID: confirmation.confirmationID,
        deleteAudioFile: true
      )
    )

    XCTAssertTrue(FileManager.default.fileExists(atPath: outsideAudioURL.path))
  }

  func testDeleteRemovesMeetingAudioDirectoryWhenPresent() async throws {
    let database = try CarlaDatabase(inMemory: true)
    let repository = GRDBMeetingRepository(dbWriter: database.dbQueue)

    let allowedAudioDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("carla-audio-allowed-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: allowedAudioDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: allowedAudioDirectory) }

    let meetingID = UUID()
    let meetingDirectory = allowedAudioDirectory.appendingPathComponent(
      meetingID.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: meetingDirectory, withIntermediateDirectories: true)

    let stereoURL = meetingDirectory.appendingPathComponent("\(meetingID.uuidString)-stereo.wav")
    try Data("test".utf8).write(to: stereoURL)

    let meeting = Meeting(
      id: meetingID, title: "With Directory", startedAt: Date(), audioFilePath: stereoURL.path)
    try repository.saveMeeting(meeting)

    let service = MeetingDeletionService(
      repository: repository, allowedAudioDirectory: allowedAudioDirectory)
    let confirmation = try await service.prepareDeleteMeeting(id: meetingID)

    try await service.confirmDeleteMeeting(
      MeetingDeletionRequest(
        meetingID: meetingID,
        confirmationID: confirmation.confirmationID,
        deleteAudioFile: true
      )
    )

    var isDir: ObjCBool = false
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: meetingDirectory.path, isDirectory: &isDir))
  }
}
