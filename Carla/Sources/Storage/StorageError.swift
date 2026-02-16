import Foundation

public enum StorageError: Error, LocalizedError, Sendable {
  case meetingNotFound(UUID)
  case invalidDeleteConfirmation
  case exportFailed(String)

  public var errorDescription: String? {
    switch self {
    case .meetingNotFound(let id):
      return "Meeting not found: \(id.uuidString)"
    case .invalidDeleteConfirmation:
      return "Delete confirmation is invalid or expired."
    case .exportFailed(let message):
      return "Export failed: \(message)"
    }
  }
}
