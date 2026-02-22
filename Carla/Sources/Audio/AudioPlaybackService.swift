import AVFoundation
import Combine
import Foundation

/// Errors that can occur during audio playback.
public enum AudioPlaybackError: Error, LocalizedError {
  case fileNotFound(path: String)
  case failedToLoad(Error)

  public var errorDescription: String? {
    switch self {
    case .fileNotFound(let path):
      return "Audio file not found: \(path)"
    case .failedToLoad(let error):
      return "Failed to load audio: \(error.localizedDescription)"

    }
  }
}

/// Service for playing back meeting audio files with seek capability.
@MainActor
public final class AudioPlaybackService: NSObject, ObservableObject {
  // MARK: - Published State

  /// Current playback time in seconds
  @Published public private(set) var currentTime: TimeInterval = 0

  /// Whether audio is currently playing
  @Published public private(set) var isPlaying: Bool = false

  /// Total duration of the loaded audio
  @Published public private(set) var duration: TimeInterval = 0

  /// Path of the currently loaded audio file
  @Published public private(set) var loadedFilePath: String?

  /// Last playback error, if any
  @Published public private(set) var lastError: AudioPlaybackError?

  // MARK: - Private Properties

  private var audioPlayer: AVAudioPlayer?
  private var updateTimer: Timer?

  // MARK: - Initialization

  public override init() {
    super.init()
  }

  // MARK: - Public Methods

  /// Load an audio file for playback.
  /// - Parameter filePath: Path to the M4A or WAV audio file
  /// - Throws: `AudioPlaybackError` if the file cannot be loaded
  public func loadAudio(filePath: String) throws {
    // Fully unload current playback state before loading a new file.
    unload()

    let fileURL = URL(fileURLWithPath: filePath)
    let fileManager = FileManager.default

    guard fileManager.fileExists(atPath: filePath) else {
      let error = AudioPlaybackError.fileNotFound(path: filePath)
      lastError = error
      throw error
    }

    do {
      let player = try AVAudioPlayer(contentsOf: fileURL)
      player.delegate = self
      player.prepareToPlay()

      audioPlayer = player
      duration = player.duration
      currentTime = 0
      loadedFilePath = filePath
      lastError = nil
    } catch {
      let playbackError = AudioPlaybackError.failedToLoad(error)
      lastError = playbackError
      throw playbackError
    }
  }

  /// Start or resume playback.
  public func play() {
    guard let player = audioPlayer else { return }

    guard player.play() else {
      isPlaying = false
      stopUpdateTimer()
      lastError = .failedToLoad(
        NSError(
          domain: "AudioPlaybackService",
          code: -1,
          userInfo: [NSLocalizedDescriptionKey: "Playback failed to start."]
        )
      )
      return
    }

    isPlaying = true
    lastError = nil
    startUpdateTimer()
  }

  /// Pause playback.
  public func pause() {
    guard let player = audioPlayer else { return }
    player.pause()
    isPlaying = false
    stopUpdateTimer()
  }

  /// Toggle between play and pause.
  public func togglePlayback() {
    if isPlaying {
      pause()
    } else {
      play()
    }
  }

  /// Stop playback and reset to the beginning.
  public func stop() {
    audioPlayer?.stop()
    audioPlayer?.currentTime = 0
    isPlaying = false
    currentTime = 0
    stopUpdateTimer()
  }

  /// Seek to a specific time in the audio.
  /// - Parameter time: Time in seconds to seek to
  public func seek(to time: TimeInterval) {
    guard let player = audioPlayer else { return }
    let clampedTime = max(0, min(time, player.duration))
    player.currentTime = clampedTime
    currentTime = clampedTime
  }

  /// Unload the current audio file.
  public func unload() {
    stop()
    audioPlayer = nil
    duration = 0
    loadedFilePath = nil
    lastError = nil
  }

  // MARK: - Private Methods

  private func startUpdateTimer() {
    stopUpdateTimer()
    // Update approximately 10 times per second for smooth UI updates.
    // Use a MainActor hop to keep actor isolation correct under Swift 6.
    updateTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
      guard let self else {
        timer.invalidate()
        return
      }

      Task { @MainActor in
        self.updateCurrentTime()
      }
    }
  }

  private func stopUpdateTimer() {
    updateTimer?.invalidate()
    updateTimer = nil
  }

  private func updateCurrentTime() {
    guard let player = audioPlayer else { return }
    currentTime = player.currentTime
  }
}

// MARK: - AVAudioPlayerDelegate

extension AudioPlaybackService: AVAudioPlayerDelegate {
  nonisolated public func audioPlayerDidFinishPlaying(
    _ player: AVAudioPlayer,
    successfully flag: Bool
  ) {
    let finishedPlayerID = ObjectIdentifier(player)
    Task { @MainActor in
      guard let currentPlayer = audioPlayer,
        ObjectIdentifier(currentPlayer) == finishedPlayerID
      else {
        return
      }

      if flag {
        lastError = nil
      } else {
        lastError = .failedToLoad(
          NSError(
            domain: "AudioPlaybackService",
            code: -2,
            userInfo: [NSLocalizedDescriptionKey: "Playback stopped unexpectedly."]
          )
        )
      }

      currentPlayer.currentTime = 0
      isPlaying = false
      currentTime = 0
      stopUpdateTimer()
    }
  }

  nonisolated public func audioPlayerDecodeErrorDidOccur(
    _ player: AVAudioPlayer,
    error: Error?
  ) {
    let failedPlayerID = ObjectIdentifier(player)
    Task { @MainActor in
      guard let currentPlayer = audioPlayer,
        ObjectIdentifier(currentPlayer) == failedPlayerID
      else {
        return
      }

      isPlaying = false
      stopUpdateTimer()
      if let error {
        lastError = .failedToLoad(error)
      } else {
        lastError = .failedToLoad(
          NSError(
            domain: "AudioPlaybackService",
            code: -3,
            userInfo: [NSLocalizedDescriptionKey: "Audio decoding failed."]
          )
        )
      }
      currentPlayer.currentTime = 0
      currentTime = 0
    }
  }
}
