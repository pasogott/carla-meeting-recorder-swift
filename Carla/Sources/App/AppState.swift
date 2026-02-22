import CarlaAudio
import CarlaRecording
import CarlaStorage
import CarlaTranscription
import Combine
import Foundation
import SwiftUI
#if canImport(Sparkle)
  import Sparkle
#endif

// MARK: - Recording State

enum RecordingState: Equatable {
  case idle
  case starting
  case recording
  case stopping
}

enum MeetingPlatform: String, CaseIterable {
  case zoom
  case meet
  case teams
  case facetime
  case unknown
}

// MARK: - UI Models

struct TranscriptSegmentUI: Identifiable, Hashable {
  let id: UUID
  let startTime: TimeInterval
  let endTime: TimeInterval
  let text: String
  let speakerLabel: String
}

struct MeetingUI: Identifiable, Hashable {
  let id: UUID
  var title: String
  let startedAt: Date
  let duration: TimeInterval
  let platform: MeetingPlatform
  let segments: [TranscriptSegmentUI]
  let audioFilePath: String?
}

// MARK: - Settings

struct AppSettings: Equatable {
  var selectedInputDevice: String
  var selectedOutputDevice: String
  var selectedModel: String
  var storagePath: String
  var launchAtLogin: Bool
  var primaryLanguage: String

  static let `default` = AppSettings(
    selectedInputDevice: "System Default Microphone",
    selectedOutputDevice: "System Default Output",
    selectedModel: "base",
    storagePath: "~/Library/Application Support/Carla",
    launchAtLogin: false,
    primaryLanguage: "en"
  )
}

// MARK: - Onboarding State

struct OnboardingState {
  var legalAccepted: Bool = false
  var modelsReady: Bool = false
}

// MARK: - Model Download State

enum ModelDownloadStatus: Equatable {
  case idle
  case checking
  case downloading
  case completed
  case failed
}

struct ModelDownloadState: Equatable {
  var status: ModelDownloadStatus = .idle
  var currentModel: WhisperModel? = nil
  var progress: Double = 0
  var progressText: String = ""
  var errorMessage: String? = nil

  var isDownloading: Bool {
    if case .downloading = status { return true }
    return false
  }

  var isComplete: Bool {
    status == .completed
  }
}

// MARK: - Alert

/// Alert information for user-visible errors.
struct RecordingAlert: Identifiable {
  let id = UUID()
  let title: String
  let message: String
}

// MARK: - Delete Confirmation

/// State for meeting deletion confirmation dialog.
struct DeleteConfirmationState: Identifiable, Equatable {
  var id: UUID { meetingID }
  let meetingID: UUID
  let confirmationID: UUID
  let meetingTitle: String
  let audioFilePath: String
  var deleteAudioFile: Bool = true
}

// MARK: - AppState

@MainActor
final class AppState: ObservableObject {
  // MARK: - Recording State

  @Published var recordingState: RecordingState = .idle
  @Published var liveTranscriptSegments: [TranscriptSegmentUI] = []
  @Published var currentRecordingDuration: TimeInterval = 0
  @Published var microphoneLevel: Float = 0
  @Published var systemAudioLevel: Float = 0

  // MARK: - Meetings

  @Published var meetings: [MeetingUI] = []
  @Published var selectedMeetingID: UUID?
  @Published var searchQuery: String = ""
  @Published var searchResultMeetingIDs: Set<UUID>?

  // MARK: - Settings & Onboarding

  @Published var settings: AppSettings = .default
  @Published var onboarding = OnboardingState()
  @Published var showOnboarding: Bool = true

  // MARK: - Model Download

  @Published var modelDownload = ModelDownloadState()

  // MARK: - Alerts

  @Published var currentAlert: RecordingAlert?

  // MARK: - Delete Confirmation

  @Published var deleteConfirmation: DeleteConfirmationState?
  @Published var isDeleting: Bool = false

  // MARK: - Playback State

  @Published var playbackCurrentTime: TimeInterval = 0
  @Published var playbackIsPlaying: Bool = false
  @Published var playbackDuration: TimeInterval = 0
  @Published var playbackError: String?

  /// Manages macOS permissions for microphone and screen recording
  let permissionManager: PermissionManager

  /// Audio playback service for meeting recordings
  let playbackService: AudioPlaybackService

  // MARK: - Private Dependencies

  private let storage: CarlaStorage?
  private let recordingCoordinator: RecordingCoordinator?
  private let whisperModelManager: WhisperModelManager
  private var cancellables = Set<AnyCancellable>()
  private var durationTimer: Timer?
  private var downloadTask: Task<Void, Never>?

  private var coordinatorSegmentsTask: Task<Void, Never>?
  private var coordinatorLevelsTask: Task<Void, Never>?

  #if canImport(Sparkle)
    private var updaterController: SPUStandardUpdaterController?
  #endif

  // MARK: - Initialization

  init(
    permissionManager: PermissionManager? = nil,
    storage: CarlaStorage? = nil,
    recordingCoordinator: RecordingCoordinator? = nil,
    whisperModelManager: WhisperModelManager? = nil,
    playbackService: AudioPlaybackService? = nil
  ) {
    self.permissionManager = permissionManager ?? PermissionManager()
    self.whisperModelManager = whisperModelManager ?? WhisperModelManager()
    self.playbackService = playbackService ?? AudioPlaybackService()

    // Initialize storage and coordinator
    if let storage {
      self.storage = storage
      self.recordingCoordinator = recordingCoordinator
    } else {
      // Try to initialize real storage
      do {
        let realStorage = try CarlaStorage()
        self.storage = realStorage

        // Create transcription engine and orchestrator (whisper.cpp)
        let binding = WhisperCPPBindingImpl(modelLoader: WhisperModelLoader())
        let whisperEngine = WhisperCPPEngine(binding: binding)
        let transcriptionOrchestrator = TranscriptionJobOrchestrator(engine: whisperEngine)

        // Create recording coordinator
        let coordinator = RecordingCoordinator(
          transcriptionOrchestrator: transcriptionOrchestrator,
          repository: realStorage.repository,
          paths: AppStoragePaths(),
          configuration: RecordingConfiguration()
        )
        self.recordingCoordinator = coordinator
      } catch {
        print("Failed to initialize storage: \(error)")
        self.storage = nil
        self.recordingCoordinator = nil
      }
    }

    // Load meetings from database or use mock data
    if let storage = self.storage {
      loadMeetingsFromDatabase(storage: storage)
    } else {
      self.meetings = Self.mockMeetings()
    }

    self.selectedMeetingID = meetings.first?.id

    setupUpdater()

    // Subscribe to recording coordinator events
    setupCoordinatorSubscriptions()

    // Subscribe to playback service state
    setupPlaybackSubscriptions()

    // Subscribe to search query changes for FTS5 search
    setupSearchSubscription()
  }

  // MARK: - Computed Properties

  var menuBarIconName: String {
    switch recordingState {
    case .idle:
      return "mic"
    case .starting, .stopping:
      return "mic.badge.ellipsis"
    case .recording:
      return "mic.fill"
    }
  }

  var menuBarIconColor: Color {
    switch recordingState {
    case .recording:
      return .red
    case .starting, .stopping:
      return .orange
    case .idle:
      return .primary
    }
  }

  var filteredMeetings: [MeetingUI] {
    guard !searchQuery.isEmpty else {
      return meetings
    }

    // Use FTS5 search results if available
    if let matchingIDs = searchResultMeetingIDs {
      return meetings.filter { matchingIDs.contains($0.id) }
    }

    // Fallback to local filtering for title matches
    return meetings.filter {
      $0.title.localizedCaseInsensitiveContains(searchQuery)
    }
  }

  var selectedMeeting: MeetingUI? {
    meetings.first(where: { $0.id == selectedMeetingID })
  }

  /// Whether onboarding can be completed (all steps done and permissions granted)
  var canCompleteOnboarding: Bool {
    onboarding.legalAccepted
      && onboarding.modelsReady
      && permissionManager.allPermissionsGranted
  }

  var isRecordingActive: Bool {
    recordingState == .recording
  }

  // MARK: - Recording Actions

  func toggleRecording() {
    Task {
      await toggleRecordingAsync()
    }
  }

  private func toggleRecordingAsync() async {
    switch recordingState {
    case .idle:
      await startRecording()
    case .recording:
      await stopRecording()
    case .starting, .stopping:
      // Ignore toggle while transitioning
      break
    }
  }

  private func startRecording() async {
    guard let coordinator = recordingCoordinator else {
      showAlert(title: "Recording Unavailable", message: "Storage is not initialized.")
      return
    }

    recordingState = .starting
    liveTranscriptSegments = []
    currentRecordingDuration = 0

    do {
      _ = try await coordinator.startRecording()
      recordingState = .recording
      startDurationTimer()
    } catch {
      recordingState = .idle
      showAlert(title: "Failed to Start Recording", message: error.localizedDescription)
    }
  }

  private func stopRecording() async {
    guard let coordinator = recordingCoordinator else {
      recordingState = .idle
      return
    }

    recordingState = .stopping
    stopDurationTimer()

    do {
      let meetingID = try await coordinator.stopRecording()
      recordingState = .idle
      liveTranscriptSegments = []

      // Reload meetings to show the new one
      if let storage {
        loadMeetingsFromDatabase(storage: storage)
      }

      // Select the newly created meeting
      selectedMeetingID = meetingID
    } catch {
      recordingState = .idle
      showAlert(title: "Failed to Stop Recording", message: error.localizedDescription)
    }
  }

  // MARK: - Model Download Actions

  /// Checks if required Whisper models are available locally.
  func checkModelAvailability() async {
    modelDownload.status = .checking
    modelDownload.progressText = "Checking model availability..."

    let modelsAvailable = await whisperModelManager.areRequiredModelsAvailable()

    if modelsAvailable {
      modelDownload.status = .completed
      modelDownload.progressText = "Models ready"
      onboarding.modelsReady = true
    } else {
      modelDownload.status = .idle
      modelDownload.progressText = ""
    }
  }

  /// Downloads required Whisper models with progress updates.
  func downloadRequiredModels() async {
    // Cancel any existing download
    downloadTask?.cancel()

    modelDownload.status = .downloading
    modelDownload.progress = 0
    modelDownload.errorMessage = nil

    downloadTask = Task {
      let stream = await whisperModelManager.downloadRequiredModels()
      for await progress in stream {
        // Check for cancellation
        if Task.isCancelled { break }

        await MainActor.run {
          modelDownload.currentModel = progress.model
          modelDownload.progress = progress.fractionComplete
          modelDownload.progressText = progress.formattedProgress

          if let error = progress.error {
            modelDownload.status = .failed
            modelDownload.errorMessage = error
            modelDownload.progressText = "Download failed"
          } else if progress.isComplete {
            // Model downloaded successfully, continue to next or finish
          }
        }
      }

      // Check final status after all downloads
      if !Task.isCancelled {
        let allReady = await whisperModelManager.areRequiredModelsAvailable()
        await MainActor.run {
          if allReady {
            modelDownload.status = .completed
            modelDownload.progressText = "Models ready"
            modelDownload.currentModel = nil
            onboarding.modelsReady = true
          } else if modelDownload.errorMessage == nil {
            modelDownload.status = .failed
            modelDownload.errorMessage = "Download incomplete"
          }
        }
      }
    }

    await downloadTask?.value
    downloadTask = nil
  }

  /// Cancels any in-progress model download.
  func cancelModelDownload() async {
    downloadTask?.cancel()
    downloadTask = nil
    await whisperModelManager.cancelAllDownloads()
    modelDownload.status = .idle
    modelDownload.currentModel = nil
    modelDownload.progress = 0
    modelDownload.progressText = ""
  }

  // MARK: - Meeting Actions

  func selectMeeting(_ id: UUID) {
    // Stop any current playback
    playbackService.stop()
    playbackError = nil

    selectedMeetingID = id

    // Load audio for the selected meeting
    if let meeting = meetings.first(where: { $0.id == id }),
      let audioPath = meeting.audioFilePath
    {
      loadAudioForPlayback(path: audioPath)
    }
  }

  func updateSelectedMeetingTitle(_ title: String) {
    guard let id = selectedMeetingID, let index = meetings.firstIndex(where: { $0.id == id }) else {
      return
    }
    meetings[index].title = title

    // Persist to database
    if let storage {
      do {
        var meeting = try storage.repository.fetchMeetingDetails(id: id).meeting
        meeting.title = title
        try storage.repository.saveMeeting(meeting)
      } catch {
        print("Failed to update meeting title: \(error)")
      }
    }
  }

  func jumpToTimestamp(_ seconds: TimeInterval) {
    playbackService.seek(to: seconds)
    // If not playing, start playback from the new position
    if !playbackIsPlaying {
      playbackService.play()
    }
  }

  func togglePlayback() {
    // If no audio is loaded, try to load from selected meeting
    if playbackService.loadedFilePath == nil,
      let meeting = selectedMeeting,
      let audioPath = meeting.audioFilePath
    {
      loadAudioForPlayback(path: audioPath)
    }

    playbackService.togglePlayback()
  }

  /// Load audio file for playback, handling errors gracefully.
  private func loadAudioForPlayback(path: String) {
    do {
      try playbackService.loadAudio(filePath: path)
      playbackError = nil
    } catch let error as AudioPlaybackError {
      playbackError = error.localizedDescription
      print("Failed to load audio: \(error)")
    } catch {
      playbackError = "Failed to load audio file"
      print("Failed to load audio: \(error)")
    }
  }

  // MARK: - Meeting Deletion

  /// Prepare to delete a meeting - shows confirmation dialog.
  func prepareDeleteMeeting(id: UUID) {
    guard let storage else {
      showAlert(title: "Delete Unavailable", message: "Storage is not initialized.")
      return
    }

    Task {
      do {
        let confirmation = try await storage.deletionService.prepareDeleteMeeting(id: id)
        deleteConfirmation = DeleteConfirmationState(
          meetingID: confirmation.meetingID,
          confirmationID: confirmation.confirmationID,
          meetingTitle: confirmation.meetingTitle,
          audioFilePath: confirmation.audioFilePath,
          deleteAudioFile: true
        )
      } catch {
        showAlert(title: "Delete Failed", message: error.localizedDescription)
      }
    }
  }

  /// Confirm and execute the meeting deletion.
  /// - Parameter deleteAudioFile: Whether to also delete the associated audio file.
  func confirmDeleteMeeting(deleteAudioFile: Bool = true) {
    guard let confirmation = deleteConfirmation, let storage else {
      deleteConfirmation = nil
      return
    }

    isDeleting = true

    Task {
      do {
        let request = MeetingDeletionRequest(
          meetingID: confirmation.meetingID,
          confirmationID: confirmation.confirmationID,
          deleteAudioFile: deleteAudioFile
        )
        try await storage.deletionService.confirmDeleteMeeting(request)

        // Stop playback if we're deleting the currently playing meeting
        if selectedMeetingID == confirmation.meetingID {
          playbackService.stop()
          selectedMeetingID = nil
        }

        // Refresh the meetings list
        reloadMeetings()

        deleteConfirmation = nil
        isDeleting = false
      } catch {
        isDeleting = false
        deleteConfirmation = nil
        showAlert(title: "Delete Failed", message: error.localizedDescription)
      }
    }
  }

  /// Cancel the pending deletion.
  func cancelDeleteMeeting() {
    deleteConfirmation = nil
  }

  /// Reload meetings from the database.
  func reloadMeetings() {
    if let storage {
      loadMeetingsFromDatabase(storage: storage)
    }
  }

  // MARK: - Search

  /// Perform FTS5 search on transcript text.
  func performSearch() {
    guard let storage, !searchQuery.isEmpty else {
      searchResultMeetingIDs = nil
      return
    }

    do {
      let results = try storage.repository.searchTranscript(query: searchQuery, limit: 100)
      searchResultMeetingIDs = Set(results.map { $0.meetingID })
    } catch {
      print("Search failed: \(error)")
      // Fall back to local filtering
      searchResultMeetingIDs = nil
    }
  }

  // MARK: - Permissions

  /// Request microphone permission using the real macOS permission system
  func requestMicrophonePermission() async {
    await permissionManager.requestMicrophonePermission()
  }

  /// Request screen recording permission using the real macOS permission system
  func requestScreenRecordingPermission() async {
    await permissionManager.requestScreenRecordingPermission()
  }

  /// Re-check all permissions (useful on app launch or when returning from System Settings)
  func recheckPermissions() async {
    await permissionManager.checkAllPermissions()
  }

  // MARK: - Settings

  func saveSettings(_ updated: AppSettings) {
    settings = updated
  }

  func completeOnboarding() {
    guard canCompleteOnboarding else { return }
    showOnboarding = false
  }

  var canCheckForUpdates: Bool {
    #if canImport(Sparkle)
      return updaterController != nil
    #else
      return false
    #endif
  }

  func checkForUpdates() {
    #if canImport(Sparkle)
      updaterController?.checkForUpdates(nil)
    #endif
  }

  // MARK: - Private Helpers

  private func setupUpdater() {
    #if canImport(Sparkle)
      guard
        let feedURLString = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
        URL(string: feedURLString) != nil,
        !feedURLString.isEmpty
      else {
        return
      }

      updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
      )
    #endif
  }

  private func setupCoordinatorSubscriptions() {
    guard let coordinator = recordingCoordinator else { return }

    coordinatorSegmentsTask?.cancel()
    coordinatorLevelsTask?.cancel()

    coordinatorSegmentsTask = Task { [weak self] in
      for await segments in coordinator.streams.liveSegments {
        await MainActor.run {
          self?.liveTranscriptSegments = segments.map { segment in
            TranscriptSegmentUI(
              id: segment.id,
              startTime: segment.startTime,
              endTime: segment.endTime,
              text: segment.text,
              speakerLabel: segment.speaker
            )
          }
        }
      }
    }

    coordinatorLevelsTask = Task { [weak self] in
      for await level in coordinator.streams.audioLevels {
        await MainActor.run {
          switch level.source {
          case .microphone:
            self?.microphoneLevel = level.rms
          case .system:
            self?.systemAudioLevel = level.rms
          }
        }
      }
    }
  }

  private func setupPlaybackSubscriptions() {
    // Bind playback service state to AppState published properties
    playbackService.$currentTime
      .receive(on: DispatchQueue.main)
      .assign(to: &$playbackCurrentTime)

    playbackService.$isPlaying
      .receive(on: DispatchQueue.main)
      .assign(to: &$playbackIsPlaying)

    playbackService.$duration
      .receive(on: DispatchQueue.main)
      .assign(to: &$playbackDuration)

    playbackService.$lastError
      .receive(on: DispatchQueue.main)
      .map { $0?.localizedDescription }
      .assign(to: &$playbackError)
  }

  private func setupSearchSubscription() {
    // Debounce search queries and perform FTS5 search
    $searchQuery
      .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
      .removeDuplicates()
      .sink { [weak self] _ in
        self?.performSearch()
      }
      .store(in: &cancellables)
  }

  private func startDurationTimer() {
    let startTime = Date()
    durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
      [weak self] timer in
      guard let self else {
        timer.invalidate()
        return
      }

      Task { @MainActor in
        self.currentRecordingDuration = Date().timeIntervalSince(startTime)
      }
    }
  }

  private func stopDurationTimer() {
    durationTimer?.invalidate()
    durationTimer = nil
  }

  private func showAlert(title: String, message: String) {
    currentAlert = RecordingAlert(title: title, message: message)
  }

  private func validatedAudioFilePath(_ path: String) -> String? {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else {
      return nil
    }

    let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
    guard ext == "m4a" || ext == "wav" else { return nil }
    return path
  }

  private func loadMeetingsFromDatabase(storage: CarlaStorage) {
    do {
      let dbMeetings = try storage.repository.listMeetings(limit: 100, offset: 0)
      meetings = dbMeetings.map { meeting in
        // Load segments for each meeting
        let details = try? storage.repository.fetchMeetingDetails(id: meeting.id)
        let speakerLabels: [UUID: String] = {
          guard let details else { return [:] }
          return Dictionary(uniqueKeysWithValues: details.speakers.map { ($0.id, $0.label) })
        }()

        let segments: [TranscriptSegmentUI] =
          details?.segments.map { segment in
            let label = segment.speakerID.flatMap { speakerLabels[$0] } ?? "Unknown"
            return TranscriptSegmentUI(
              id: segment.id,
              startTime: segment.startTime,
              endTime: segment.endTime,
              text: segment.text,
              speakerLabel: label
            )
          } ?? []

        return MeetingUI(
          id: meeting.id,
          title: meeting.title,
          startedAt: meeting.startedAt,
          duration: meeting.duration,
          platform: meeting.platform.map { MeetingPlatform(rawValue: $0.rawValue) ?? .unknown }
            ?? .unknown,
          segments: segments,
          audioFilePath: validatedAudioFilePath(meeting.audioFilePath)
        )
      }
    } catch {
      print("Failed to load meetings: \(error)")
      meetings = []
    }
  }

  private static func mockMeetings() -> [MeetingUI] {
    [
      MeetingUI(
        id: UUID(),
        title: "Weekly Product Sync",
        startedAt: .now.addingTimeInterval(-7200),
        duration: 1800,
        platform: .meet,
        segments: [
          .init(
            id: UUID(), startTime: 6, endTime: 14, text: "Let's finalize the release plan.",
            speakerLabel: "You"),
          .init(
            id: UUID(), startTime: 40, endTime: 51, text: "QA sign-off is expected Friday.",
            speakerLabel: "Others"),
        ],
        audioFilePath: nil
      ),
      MeetingUI(
        id: UUID(),
        title: "Sales Discovery Call",
        startedAt: .now.addingTimeInterval(-90_000),
        duration: 2100,
        platform: .zoom,
        segments: [
          .init(
            id: UUID(), startTime: 20, endTime: 35, text: "Customer pain point is onboarding time.",
            speakerLabel: "Others")
        ],
        audioFilePath: nil
      ),
    ]
  }

  deinit {
    coordinatorSegmentsTask?.cancel()
    coordinatorLevelsTask?.cancel()
    downloadTask?.cancel()
    durationTimer?.invalidate()
  }
}

// MARK: - Window IDs

enum WindowID {
  static let meetings = "meetings-window"
  static let transcript = "transcript-window"
  static let settings = "settings-window"
  static let onboarding = "onboarding-window"
}
