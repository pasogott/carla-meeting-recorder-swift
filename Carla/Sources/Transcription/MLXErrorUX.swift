import Foundation

public enum MLXErrorCategory: String, Sendable, Equatable {
  case network
  case http
  case diskFull
  case corruptArtifacts
  case permissionDenied
  case unsupportedHardware
  case unknown
}

public struct MLXErrorGuidance: Sendable, Equatable {
  public let category: MLXErrorCategory
  public let title: String
  public let recovery: String

  public init(category: MLXErrorCategory, title: String, recovery: String) {
    self.category = category
    self.title = title
    self.recovery = recovery
  }
}

public enum MLXErrorUX {
  public static func guidance(for message: String) -> MLXErrorGuidance {
    let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    if normalized.contains("intel")
      || normalized.contains("apple silicon")
      || normalized.contains("unsupported hardware")
      || normalized.contains("metal is not supported")
    {
      return MLXErrorGuidance(
        category: .unsupportedHardware,
        title: "Unsupported hardware",
        recovery: "MLX requires Apple Silicon. Use a supported Mac or disable MLX transcription."
      )
    }

    if normalized.contains("permission")
      || normalized.contains("operation not permitted")
      || normalized.contains("not authorized")
      || normalized.contains("eacces")
      || normalized.contains("eprem")
    {
      return MLXErrorGuidance(
        category: .permissionDenied,
        title: "Permission denied",
        recovery: "Grant file/network permissions and retry. If needed, reopen System Settings and allow Carla access."
      )
    }

    if normalized.contains("no space left")
      || normalized.contains("disk full")
      || normalized.contains("enospc")
    {
      return MLXErrorGuidance(
        category: .diskFull,
        title: "Disk is full",
        recovery: "Free disk space, then retry the model download. Keep at least 5 GB free for MLX models."
      )
    }

    if normalized.contains("checksum")
      || normalized.contains("hash mismatch")
      || normalized.contains("corrupt")
      || normalized.contains("invalid artifact")
      || normalized.contains("artifact contract")
    {
      return MLXErrorGuidance(
        category: .corruptArtifacts,
        title: "Model files are corrupted",
        recovery: "Remove the affected model files and download again. If this repeats, check network stability."
      )
    }

    if normalized.contains("http error")
      || normalized.contains("status code")
      || normalized.contains("4xx")
      || normalized.contains("5xx")
      || normalized.contains("404")
      || normalized.contains("403")
    {
      return MLXErrorGuidance(
        category: .http,
        title: "Model server error",
        recovery: "The model server returned an HTTP error. Retry in a few minutes or verify the model URL/version."
      )
    }

    if normalized.contains("network")
      || normalized.contains("offline")
      || normalized.contains("timed out")
      || normalized.contains("cannot connect")
      || normalized.contains("dns")
      || normalized.contains("host unreachable")
    {
      return MLXErrorGuidance(
        category: .network,
        title: "Network unavailable",
        recovery: "Check internet connection, VPN/firewall settings, and retry the download."
      )
    }

    return MLXErrorGuidance(
      category: .unknown,
      title: "MLX operation failed",
      recovery: "Retry once. If the issue persists, restart Carla and re-download required models."
    )
  }

  public static func guidance(for error: Error) -> MLXErrorGuidance {
    if case MLXWhisperLibraryError.modelNotFound = error {
      return MLXErrorGuidance(
        category: .corruptArtifacts,
        title: "Model files missing",
        recovery: "Required model artifacts are missing. Re-download the selected MLX model."
      )
    }

    if case MLXWhisperLibraryError.modelNotLoaded = error {
      return MLXErrorGuidance(
        category: .corruptArtifacts,
        title: "Model could not be loaded",
        recovery: "Model artifacts may be incomplete or corrupted. Remove and re-download models."
      )
    }

    if case MLXWhisperLibraryError.libraryFailure(_, let message) = error {
      return guidance(for: message)
    }

    if case MLXWhisperLibraryError.runtimeFailure(let message) = error {
      return guidance(for: message)
    }

    return guidance(for: (error as NSError).localizedDescription)
  }
}
