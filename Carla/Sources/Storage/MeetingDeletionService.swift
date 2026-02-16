import CarlaModels
import Foundation

public struct MeetingDeletionConfirmation: Sendable, Equatable {
  public let meetingID: UUID
  public let confirmationID: UUID
  public let meetingTitle: String
  public let audioFilePath: String

  public init(meetingID: UUID, confirmationID: UUID, meetingTitle: String, audioFilePath: String) {
    self.meetingID = meetingID
    self.confirmationID = confirmationID
    self.meetingTitle = meetingTitle
    self.audioFilePath = audioFilePath
  }
}

public struct MeetingDeletionRequest: Sendable, Equatable {
  public let meetingID: UUID
  public let confirmationID: UUID
  public let deleteAudioFile: Bool

  public init(meetingID: UUID, confirmationID: UUID, deleteAudioFile: Bool) {
    self.meetingID = meetingID
    self.confirmationID = confirmationID
    self.deleteAudioFile = deleteAudioFile
  }
}

public protocol MeetingDeleting {
  func prepareDeleteMeeting(id: UUID) async throws -> MeetingDeletionConfirmation
  func confirmDeleteMeeting(_ request: MeetingDeletionRequest) async throws
}

public actor MeetingDeletionService: MeetingDeleting {
  private let repository: MeetingRepository
  private let fileManager: FileManager
  private let allowedAudioDirectory: URL
  private var pendingConfirmations: [UUID: UUID] = [:]

  public init(
    repository: MeetingRepository,
    allowedAudioDirectory: URL = AppStoragePaths().audioDirectory,
    fileManager: FileManager = .default
  ) {
    self.repository = repository
    self.allowedAudioDirectory = allowedAudioDirectory
    self.fileManager = fileManager
  }

  public func prepareDeleteMeeting(id: UUID) async throws -> MeetingDeletionConfirmation {
    let details = try repository.fetchMeetingDetails(id: id)
    let confirmationID = UUID()
    pendingConfirmations[id] = confirmationID
    return MeetingDeletionConfirmation(
      meetingID: id,
      confirmationID: confirmationID,
      meetingTitle: details.meeting.title,
      audioFilePath: details.meeting.audioFilePath
    )
  }

  public func confirmDeleteMeeting(_ request: MeetingDeletionRequest) async throws {
    guard pendingConfirmations[request.meetingID] == request.confirmationID else {
      throw StorageError.invalidDeleteConfirmation
    }

    let details = try repository.fetchMeetingDetails(id: request.meetingID)
    try repository.deleteMeeting(id: request.meetingID)
    pendingConfirmations.removeValue(forKey: request.meetingID)

    guard request.deleteAudioFile else {
      return
    }

    // Prefer deleting the entire meeting directory (removes mic/system/stereo artifacts).
    let meetingDirectory = allowedAudioDirectory.appendingPathComponent(
      request.meetingID.uuidString, isDirectory: true)
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: meetingDirectory.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    {
      try? fileManager.removeItem(at: meetingDirectory)
      return
    }

    // Fall back to deleting only the referenced audio file.
    let audioURL = URL(fileURLWithPath: details.meeting.audioFilePath)
    guard isDeletableAudioFile(audioURL) else {
      return
    }

    // Best-effort: meeting DB record is already removed.
    try? fileManager.removeItem(at: audioURL)
  }

  private func isDeletableAudioFile(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else {
      return false
    }

    // Safety net: only delete known audio file types.
    let ext = url.pathExtension.lowercased()
    guard ext == "m4a" || ext == "wav" else {
      return false
    }

    return urlIsContainedInAllowedDirectory(url)
  }

  private func urlIsContainedInAllowedDirectory(_ url: URL) -> Bool {
    let directory = allowedAudioDirectory.resolvingSymlinksInPath().standardizedFileURL
    let candidate = url.resolvingSymlinksInPath().standardizedFileURL

    let directoryPath = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
    return candidate.path.hasPrefix(directoryPath)
  }
}
