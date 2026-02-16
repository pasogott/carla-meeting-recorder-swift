import Foundation
import GRDB

public final class CarlaDatabase: @unchecked Sendable {
  public let paths: AppStoragePaths
  public let dbQueue: DatabaseQueue

  public init(paths: AppStoragePaths = AppStoragePaths(), fileManager: FileManager = .default)
    throws
  {
    self.paths = paths
    try paths.ensureDirectoriesExist(fileManager: fileManager)

    var configuration = Configuration()
    configuration.foreignKeysEnabled = true

    self.dbQueue = try DatabaseQueue(path: paths.databaseURL.path, configuration: configuration)
    try CarlaDatabaseMigrations.migrator().migrate(dbQueue)
  }

  public init(inMemory: Bool) throws {
    self.paths = AppStoragePaths()
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    self.dbQueue = try DatabaseQueue(path: ":memory:", configuration: configuration)
    try CarlaDatabaseMigrations.migrator().migrate(dbQueue)
  }
}
