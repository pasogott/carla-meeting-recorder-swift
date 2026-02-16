import Foundation

/// Tracks download progress for a single model.
public struct ModelDownloadProgress: Sendable, Equatable {
  public let model: WhisperModel
  public let bytesDownloaded: Int64
  public let totalBytes: Int64?
  public let isComplete: Bool
  public let error: String?

  public var fractionComplete: Double {
    guard let total = totalBytes, total > 0 else { return 0 }
    return Double(bytesDownloaded) / Double(total)
  }

  public var formattedProgress: String {
    let downloaded = ByteCountFormatter.string(fromByteCount: bytesDownloaded, countStyle: .file)
    if let totalBytes {
      let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
      return "\(downloaded) / \(total)"
    }
    return downloaded
  }

  public init(
    model: WhisperModel,
    bytesDownloaded: Int64 = 0,
    totalBytes: Int64? = nil,
    isComplete: Bool = false,
    error: String? = nil
  ) {
    self.model = model
    self.bytesDownloaded = bytesDownloaded
    self.totalBytes = totalBytes
    self.isComplete = isComplete
    self.error = error
  }
}

/// Manages downloading and validating Whisper models.
public actor WhisperModelManager {
  /// Expected sizes for validation (approximate, in bytes).
  private static let expectedSizes: [WhisperModel: ClosedRange<Int64>] = [
    .base: 140_000_000...160_000_000,  // ~148MB
    .small: 450_000_000...520_000_000,  // ~488MB
    .medium: 1_400_000_000...1_600_000_000,  // ~1.5GB
    .large: 2_800_000_000...3_200_000_000,  // ~3GB
  ]

  private let modelLoader: WhisperModelLoader

  /// Per-model producer tasks. Cancelling these cancels the underlying URLSession async download.
  private var downloadTasks: [WhisperModel: Task<Void, Never>] = [:]

  public init(modelLoader: WhisperModelLoader = WhisperModelLoader()) {
    self.modelLoader = modelLoader
  }

  /// Required models that must be downloaded for the app to function.
  public static var requiredModels: [WhisperModel] {
    [.base]  // Start with base; user can download more later.
  }

  /// Optional models that can be downloaded for better quality.
  public static var optionalModels: [WhisperModel] {
    [.small, .medium, .large]
  }

  // MARK: - Model Availability

  /// Checks which required models are missing.
  public func checkMissingModels() async -> [WhisperModel] {
    var missing: [WhisperModel] = []
    for model in Self.requiredModels {
      if await !modelLoader.isModelAvailable(model) {
        missing.append(model)
      }
    }
    return missing
  }

  /// Checks if all required models are available.
  public func areRequiredModelsAvailable() async -> Bool {
    await checkMissingModels().isEmpty
  }

  /// Returns info about all models.
  public func getAllModelInfo() async -> [WhisperModelLoader.ModelFile] {
    await modelLoader.allModels()
  }

  // MARK: - Download with Progress Stream

  /// Downloads a model and returns an `AsyncStream` of progress updates.
  ///
  /// Cancellation:
  /// - Ending iteration of the returned stream cancels the underlying download.
  /// - `cancelDownload(_:)` cancels a running download for that model.
  public func downloadModel(_ model: WhisperModel) -> AsyncStream<ModelDownloadProgress> {
    AsyncStream { continuation in
      // Cancel any previous attempt.
      downloadTasks[model]?.cancel()

      let producer = Task {
        await self.performDownload(model, continuation: continuation)
      }

      downloadTasks[model] = producer

      continuation.onTermination = { @Sendable _ in
        Task { await self.cancelDownload(model) }
      }
    }
  }

  private func performDownload(
    _ model: WhisperModel,
    continuation: AsyncStream<ModelDownloadProgress>.Continuation
  ) async {
    defer { downloadTasks.removeValue(forKey: model) }

    continuation.yield(ModelDownloadProgress(model: model))

    do {
      try Task.checkCancellation()

      let downloadURL = await modelLoader.downloadURL(for: model)
      try await modelLoader.ensureModelsDirectoryExists()

      let delegate = DownloadProgressDelegate(model: model, continuation: continuation)

      let configuration = URLSessionConfiguration.default
      configuration.timeoutIntervalForResource = 3600  // 1 hour for large models

      let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
      defer { session.finishTasksAndInvalidate() }

      let (tempURL, response) = try await withTaskCancellationHandler {
        try await session.download(from: downloadURL, delegate: delegate)
      } onCancel: {
        session.invalidateAndCancel()
      }

      try Task.checkCancellation()

      guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        continuation.yield(ModelDownloadProgress(model: model, error: "HTTP error: \(statusCode)"))
        continuation.finish()
        return
      }

      let attributes = try FileManager.default.attributesOfItem(atPath: tempURL.path)
      let fileSize = attributes[.size] as? Int64 ?? 0

      if let expectedRange = Self.expectedSizes[model], !expectedRange.contains(fileSize) {
        continuation.yield(
          ModelDownloadProgress(
            model: model,
            bytesDownloaded: fileSize,
            totalBytes: fileSize,
            error: "Downloaded file size (\(fileSize)) outside expected range"
          )
        )
        continuation.finish()
        return
      }

      try await modelLoader.registerModel(model, from: tempURL, copy: false)

      continuation.yield(
        ModelDownloadProgress(
          model: model,
          bytesDownloaded: fileSize,
          totalBytes: fileSize,
          isComplete: true
        )
      )
      continuation.finish()

    } catch is CancellationError {
      continuation.finish()
    } catch let urlError as URLError where urlError.code == .cancelled {
      continuation.finish()
    } catch {
      continuation.yield(ModelDownloadProgress(model: model, error: error.localizedDescription))
      continuation.finish()
    }
  }

  /// Downloads all missing required models sequentially and reports progress.
  public func downloadRequiredModels() -> AsyncStream<ModelDownloadProgress> {
    AsyncStream { continuation in
      let task = Task {
        let missing = await self.checkMissingModels()

        for model in missing {
          if Task.isCancelled {
            continuation.finish()
            return
          }

          for await progress in self.downloadModel(model) {
            continuation.yield(progress)
            if progress.error != nil {
              continuation.finish()
              return
            }
          }
        }

        continuation.finish()
      }

      continuation.onTermination = { @Sendable _ in
        task.cancel()
      }
    }
  }

  // MARK: - Cancellation

  /// Cancels any in-progress download for a model.
  public func cancelDownload(_ model: WhisperModel) {
    downloadTasks[model]?.cancel()
    downloadTasks.removeValue(forKey: model)
  }

  /// Cancels all in-progress downloads.
  public func cancelAllDownloads() {
    for task in downloadTasks.values {
      task.cancel()
    }
    downloadTasks.removeAll()
  }

  // MARK: - Validation

  /// Validates that a downloaded model file is correct.
  public func validateModel(_ model: WhisperModel) async -> Bool {
    let info = await modelLoader.modelInfo(for: model)
    guard info.isAvailable else { return false }

    if let size = info.sizeBytes, let expectedRange = Self.expectedSizes[model] {
      return expectedRange.contains(size)
    }

    return true
  }

  /// Removes a downloaded model.
  public func removeModel(_ model: WhisperModel) async throws {
    try await modelLoader.removeModel(model)
  }
}

// MARK: - Download Progress Delegate

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
  private let model: WhisperModel
  private let continuation: AsyncStream<ModelDownloadProgress>.Continuation

  init(model: WhisperModel, continuation: AsyncStream<ModelDownloadProgress>.Continuation) {
    self.model = model
    self.continuation = continuation
    super.init()
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
    continuation.yield(
      ModelDownloadProgress(
        model: model,
        bytesDownloaded: totalBytesWritten,
        totalBytes: expected
      )
    )
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    // Completion is handled by the async `URLSession.download` call.
  }
}
