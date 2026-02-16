import Foundation

public struct CarlaStorage {
  public let database: CarlaDatabase
  public let repository: GRDBMeetingRepository
  public let exportService: MeetingExportService
  public let deletionService: MeetingDeletionService

  public init(paths: AppStoragePaths = AppStoragePaths()) throws {
    let database = try CarlaDatabase(paths: paths)
    let repository = GRDBMeetingRepository(dbWriter: database.dbQueue)

    self.database = database
    self.repository = repository
    self.exportService = MeetingExportService(repository: repository, paths: paths)
    self.deletionService = MeetingDeletionService(
      repository: repository,
      allowedAudioDirectory: paths.audioDirectory
    )
  }
}
