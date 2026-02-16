import Foundation

public struct AppStoragePaths: Sendable {
  public let baseDirectory: URL
  public let databaseURL: URL
  public let audioDirectory: URL
  public let exportsDirectory: URL

  public init(fileManager: FileManager = .default) {
    let appSupport =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
        "Library/Application Support", isDirectory: true)

    self.baseDirectory = appSupport.appendingPathComponent("Carla", isDirectory: true)
    self.databaseURL = baseDirectory.appendingPathComponent("carla.sqlite", isDirectory: false)
    self.audioDirectory = baseDirectory.appendingPathComponent("Audio", isDirectory: true)
    self.exportsDirectory = baseDirectory.appendingPathComponent("Exports", isDirectory: true)
  }

  public func ensureDirectoriesExist(fileManager: FileManager = .default) throws {
    try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: exportsDirectory, withIntermediateDirectories: true)
  }
}
