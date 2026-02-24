import CarlaAudio
import CarlaRecording
import CarlaStorage
import CarlaTranscription
import Combine
import Foundation
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

enum SettingsTab: Hashable {
  case general
  case audio
  case transcription
  case storage
  case onboarding
}

struct AppSettings: Equatable {
  var selectedInputDevice: String
  var selectedOutputDevice: String
  /// Persisted model selection. Accepts MLX model IDs and legacy profile aliases.
  var selectedModel: String
  var storagePath: String
  var launchAtLogin: Bool
  var showNotchOverlay: Bool
  var primaryLanguage: String

  static let `default` = AppSettings(
    selectedInputDevice: "System Default Microphone",
    selectedOutputDevice: "System Default Output",
    selectedModel: "mlx-community/whisper-medium",
    storagePath: "~/Library/Application Support/Carla",
    launchAtLogin: false,
    showNotchOverlay: false,
    primaryLanguage: "en"
  )
}

struct MLXModelOption: Equatable, Hashable, Identifiable {
  let id: String
  let label: String
  let profile: ASRModelProfile
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
  var currentModel: ASRModelProfile? = nil
  var progress: Double = 0
  var progressText: String = ""
  var errorTitle: String? = nil
  var errorMessage: String? = nil
  var recoverySuggestion: String? = nil

  var isDownloading: Bool {
    status == .downloading
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
  @Published var selectedSettingsTab: SettingsTab = .general
  @Published var onboarding = OnboardingState()
  @Published var showOnboarding: Bool = true

  // MARK: - Model Download

  @Published var modelDownload = ModelDownloadState()

  // MARK: - Alerts

  @Published var currentAlert: RecordingAlert?

  // MARK: - Delete Confirmation

  @Published var deleteConfirmation: DeleteConfirmationState?

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
  private let modelManager: MLXModelManager
  private var cancellables = Set<AnyCancellable>()
  private var durationTimer: Timer?
  private var downloadTask: Task<Void, Never>?
  private var downloadOperationID: UUID?

  private var coordinatorSegmentsTask: Task<Void, Never>?
  private var coordinatorLevelsTask: Task<Void, Never>?
  private var didAutoOpenSetupWindow = false

  private enum DefaultsKey {
    static let onboardingCompleted = "at.cyberheld.carla.onboarding_completed"
  }

  private struct ASRRolloutConfiguration {
    let rollbackEnabled: Bool
    let shadowEnabled: Bool
    let shadowSampleRate: Double
    let burnInEndDate: Date?

    static func fromEnvironment(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
      let rollbackEnabled = parseBool(environment["CARLA_ASR_ROLLBACK_ENABLE"])
      let sampleRate = min(max(Double(environment["CARLA_ASR_SHADOW_SAMPLE_RATE"] ?? "0.10") ?? 0.10, 0), 1)
      let burnInEndDate = parseDate(environment["CARLA_ASR_BURN_IN_END"])

      let insideBurnInWindow: Bool = {
        guard let burnInEndDate else { return true }
        return Date() <= burnInEndDate
      }()

      let shadowEnabled = !rollbackEnabled && insideBurnInWindow && sampleRate > 0
      return Self(
        rollbackEnabled: rollbackEnabled,
        shadowEnabled: shadowEnabled,
        shadowSampleRate: sampleRate,
        burnInEndDate: burnInEndDate
      )
    }

    func shouldSampleShadowRequest(random: Double = Double.random(in: 0...1)) -> Bool {
      guard shadowEnabled else { return false }
      return random <= shadowSampleRate
    }

    private static func parseBool(_ rawValue: String?) -> Bool {
      guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
        return false
      }
      return ["1", "true", "yes", "on"].contains(value)
    }

    private static func parseDate(_ rawValue: String?) -> Date? {
      guard let rawValue else { return nil }
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = formatter.date(from: rawValue) {
        return date
      }
      formatter.formatOptions = [.withInternetDateTime]
      return formatter.date(from: rawValue)
    }
  }

  static let availableMLXModels: [MLXModelOption] = {
    let orderedPolicy: [MLXModelPolicyTier] = [
      .requiredDefault,
      .optionalQuality,
      .pressureFallback,
    ]

    return MLXModelManager.availableModels
      .filter { $0.policyTier != .legacyCompatibility }
      .sorted { lhs, rhs in
        let lhsIndex = orderedPolicy.firstIndex(of: lhs.policyTier) ?? orderedPolicy.count
        let rhsIndex = orderedPolicy.firstIndex(of: rhs.policyTier) ?? orderedPolicy.count
        if lhsIndex != rhsIndex {
          return lhsIndex < rhsIndex
        }
        return lhs.displayName < rhs.displayName
      }
      .map {
        MLXModelOption(
          id: $0.modelID,
          label: "Whisper \($0.displayName) (MLX)",
          profile: $0.profile
        )
      }
  }()

  #if canImport(Sparkle)
    private var updaterController: SPUStandardUpdaterController?
  #endif

  // MARK: - Initialization

  init(
    permissionManager: PermissionManager? = nil,
    storage: CarlaStorage? = nil,
    recordingCoordinator: RecordingCoordinator? = nil,
    modelManager: MLXModelManager? = nil,
    playbackService: AudioPlaybackService? = nil
  ) {
    self.permissionManager = permissionManager ?? PermissionManager()
    self.modelManager = modelManager ?? MLXModelManager()
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

        // Create transcription engine and orchestrator (MLX primary + optional burn-in shadow).
        let rollout = ASRRolloutConfiguration.fromEnvironment()
        let primaryBinding = MLXWhisperBindingImpl(modelManager: self.modelManager)
        let primaryEngine = MLXWhisperEngine(binding: primaryBinding)

        let shadowEngine: ASRTranscribingEngine? = rollout.shadowEnabled
          ? MLXWhisperEngine(binding: MLXWhisperBindingImpl(modelManager: self.modelManager))
          : nil

        let shadowHarness: ShadowTranscriptionHarness? = rollout.shadowEnabled
          ? ShadowTranscriptionHarness(
            configuration: ShadowTranscriptionHarnessConfiguration(
              artifactsDirectory: AppStoragePaths().baseDirectory
                .appendingPathComponent("Diagnostics/TranscriptionShadow", isDirectory: true)
            )
          )
          : nil

        let transcriptionOrchestrator = TranscriptionJobOrchestrator(
          engine: primaryEngine,
          shadowEngine: shadowEngine,
          shadowHarness: shadowHarness,
          shouldRunShadow: { rollout.shouldSampleShadowRequest() }
        )

        // Create recording coordinator
        let coordinator = RecordingCoordinator(
          transcriptionOrchestrator: transcriptionOrchestrator,
          repository: realStorage.repository,
          paths: AppStoragePaths(),
          configuration: Self.makeRecordingConfiguration(from: .default)
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

    let onboardingCompleted = UserDefaults.standard.bool(forKey: DefaultsKey.onboardingCompleted)
    showOnboarding = !onboardingCompleted

    setupUpdater()

    // Subscribe to recording coordinator events
    setupCoordinatorSubscriptions()

    // Subscribe to playback service state
    setupPlaybackSubscriptions()

    // Subscribe to search query changes for FTS5 search
    setupSearchSubscription()

    // Keep recording/transcription configuration in sync with settings.
    settings = Self.normalizedSettings(settings)
    setupSettingsSubscription()
    Task { [weak self] in
      guard let self else { return }
      await self.applyRecordingConfiguration(self.settings)
    }

    // Forward permission updates so AppState-driven views refresh.
    self.permissionManager.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
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

  var filteredMeetings: [MeetingUI] {
    let normalizedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedQuery.isEmpty else {
      return meetings
    }

    // Use FTS5 search results if available
    if let matchingIDs = searchResultMeetingIDs {
      return meetings.filter { matchingIDs.contains($0.id) }
    }

    // Fallback to local filtering for title matches
    return meetings.filter {
      $0.title.localizedCaseInsensitiveContains(normalizedQuery)
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

  var isMLXSupportedHardware: Bool {
    Self.isMLXSupportedHardware
  }

  var mlxUnsupportedMessage: String {
    "MLX transcription requires Apple Silicon. Intel Macs are currently unsupported."
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

  /// Checks if required MLX models are available locally.
  func checkModelAvailability() async {
    guard isMLXSupportedHardware else {
      let guidance = MLXErrorUX.guidance(for: mlxUnsupportedMessage)
      modelDownload.status = .failed
      modelDownload.currentModel = nil
      modelDownload.progress = 0
      modelDownload.progressText = "Unavailable on Intel"
      modelDownload.errorTitle = guidance.title
      modelDownload.errorMessage = mlxUnsupportedMessage
      modelDownload.recoverySuggestion = guidance.recovery
      onboarding.modelsReady = false
      return
    }

    modelDownload.status = .checking
    modelDownload.progressText = "Checking model availability..."
    modelDownload.errorTitle = nil
    modelDownload.errorMessage = nil
    modelDownload.recoverySuggestion = nil

    let modelsAvailable = await areRequiredModelsReadyForOnboarding()

    if modelsAvailable {
      modelDownload.status = .completed
      modelDownload.currentModel = nil
      modelDownload.progress = 1
      modelDownload.progressText = "Models ready"
      modelDownload.errorTitle = nil
      modelDownload.errorMessage = nil
      modelDownload.recoverySuggestion = nil
      onboarding.modelsReady = true
    } else {
      let message = "Required MLX model artifacts are missing or invalid."
      let guidance = MLXErrorUX.guidance(for: message)
      modelDownload.status = .failed
      modelDownload.currentModel = nil
      modelDownload.progress = 0
      modelDownload.progressText = "Models not ready"
      modelDownload.errorTitle = guidance.title
      modelDownload.errorMessage = message
      modelDownload.recoverySuggestion = guidance.recovery
      onboarding.modelsReady = false
    }
  }

  /// Downloads required MLX models with progress updates.
  func downloadRequiredModels() async {
    guard isMLXSupportedHardware else {
      let guidance = MLXErrorUX.guidance(for: mlxUnsupportedMessage)
      modelDownload.status = .failed
      modelDownload.currentModel = nil
      modelDownload.progress = 0
      modelDownload.progressText = "Unavailable on Intel"
      modelDownload.errorTitle = guidance.title
      modelDownload.errorMessage = mlxUnsupportedMessage
      modelDownload.recoverySuggestion = guidance.recovery
      onboarding.modelsReady = false
      return
    }

    // Cancel any existing download
    downloadTask?.cancel()

    let operationID = UUID()
    downloadOperationID = operationID

    modelDownload.status = .downloading
    modelDownload.currentModel = nil
    modelDownload.progress = 0
    modelDownload.progressText = ""
    modelDownload.errorTitle = nil
    modelDownload.errorMessage = nil
    modelDownload.recoverySuggestion = nil
    onboarding.modelsReady = false

    downloadTask = Task {
      let stream = await modelManager.downloadRequiredModels()
      for await progress in stream {
        // Check for cancellation or superseded operation
        if Task.isCancelled { break }
        let isCurrentOperation = await MainActor.run { self.downloadOperationID == operationID }
        if !isCurrentOperation { return }

        if let error = progress.error {
          let guidance = MLXErrorUX.guidance(for: error)
          await MainActor.run {
            guard self.downloadOperationID == operationID else { return }
            modelDownload.status = .failed
            modelDownload.errorTitle = guidance.title
            modelDownload.errorMessage = error
            modelDownload.recoverySuggestion = guidance.recovery
            modelDownload.progressText = "Download failed"
            onboarding.modelsReady = false
          }
          return
        }

        await MainActor.run {
          guard self.downloadOperationID == operationID else { return }
          modelDownload.currentModel = progress.model
          modelDownload.progress = progress.fractionComplete
          modelDownload.progressText = progress.formattedProgress
        }
      }

      // Check final status after all downloads
      if !Task.isCancelled {
        let isCurrentOperation = await MainActor.run { self.downloadOperationID == operationID }
        guard isCurrentOperation else { return }

        let allReady = await self.areRequiredModelsReadyForOnboarding()
        await MainActor.run {
          guard self.downloadOperationID == operationID else { return }
          if allReady {
            modelDownload.status = .completed
            modelDownload.progress = 1
            modelDownload.progressText = "Models ready"
            modelDownload.currentModel = nil
            modelDownload.errorTitle = nil
            modelDownload.errorMessage = nil
            modelDownload.recoverySuggestion = nil
            onboarding.modelsReady = true
          } else if modelDownload.errorMessage == nil {
            let fallbackMessage = "Download incomplete"
            let guidance = MLXErrorUX.guidance(for: fallbackMessage)
            modelDownload.status = .failed
            modelDownload.errorTitle = guidance.title
            modelDownload.errorMessage = fallbackMessage
            modelDownload.recoverySuggestion = guidance.recovery
            onboarding.modelsReady = false
          }
        }
      }
    }

    let currentTask = downloadTask
    await currentTask?.value

    if downloadOperationID == operationID {
      downloadTask = nil
      downloadOperationID = nil
    }
  }

  // MARK: - Meeting Actions

  func selectMeeting(_ id: UUID) {
    // Reset playback state when switching meetings.
    playbackService.unload()
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
    guard meetings[index].title != title else { return }

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
          meetingTitle: confirmation.meetingTitle
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

    Task {
      do {
        let request = MeetingDeletionRequest(
          meetingID: confirmation.meetingID,
          confirmationID: confirmation.confirmationID,
          deleteAudioFile: deleteAudioFile
        )
        try await storage.deletionService.confirmDeleteMeeting(request)

        // Reset playback if we're deleting the currently selected meeting
        let deletedSelectedMeeting = selectedMeetingID == confirmation.meetingID
        if deletedSelectedMeeting {
          playbackService.unload()
          selectedMeetingID = nil
        }

        // Refresh the meetings list
        reloadMeetings()

        // Keep transcript view usable after deleting selected meeting.
        if deletedSelectedMeeting, let firstMeetingID = meetings.first?.id {
          selectMeeting(firstMeetingID)
        }

        deleteConfirmation = nil
      } catch {
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
    let normalizedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let storage, !normalizedQuery.isEmpty else {
      searchResultMeetingIDs = nil
      return
    }

    do {
      let results = try storage.repository.searchTranscript(query: normalizedQuery, limit: 100)
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

  func showOnboardingInSettings() {
    selectedSettingsTab = .onboarding
  }

  func completeOnboarding() {
    guard canCompleteOnboarding else { return }
    showOnboarding = false
    selectedSettingsTab = .general
    UserDefaults.standard.set(true, forKey: DefaultsKey.onboardingCompleted)
  }

  func consumeShouldAutoOpenSetupWindow() -> Bool {
    guard showOnboarding, !didAutoOpenSetupWindow else { return false }
    didAutoOpenSetupWindow = true
    return true
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

  private func areRequiredModelsReadyForOnboarding() async -> Bool {
    for modelID in MLXModelCatalog.requiredModelIDs {
      guard await modelManager.validateModelID(modelID) else {
        return false
      }
    }
    return true
  }

  private static let isMLXSupportedHardware: Bool = {
    #if arch(arm64)
      return true
    #else
      return false
    #endif
  }()

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
      var lastSegmentsUIUpdateUptime: TimeInterval = 0
      let minSegmentsUIUpdateInterval: TimeInterval = 0.20

      for await segments in coordinator.streams.liveSegments {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSegmentsUIUpdateUptime >= minSegmentsUIUpdateInterval else { continue }
        lastSegmentsUIUpdateUptime = now

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
      var lastLevelUIUpdateUptime: TimeInterval = 0
      let minLevelUIUpdateInterval: TimeInterval = 0.08

      for await level in coordinator.streams.audioLevels {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastLevelUIUpdateUptime >= minLevelUIUpdateInterval else { continue }
        lastLevelUIUpdateUptime = now

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

  private func setupSettingsSubscription() {
    $settings
      .removeDuplicates()
      .sink { [weak self] updatedSettings in
        guard let self else { return }

        let normalized = Self.normalizedSettings(updatedSettings)
        if normalized != updatedSettings {
          self.settings = normalized
          return
        }

        Task {
          await self.applyRecordingConfiguration(normalized)
        }
      }
      .store(in: &cancellables)
  }

  private func applyRecordingConfiguration(_ settings: AppSettings) async {
    guard let recordingCoordinator else { return }
    await recordingCoordinator.updateConfiguration(Self.makeRecordingConfiguration(from: settings))
  }

  private static func makeRecordingConfiguration(from settings: AppSettings) -> RecordingConfiguration {
    return RecordingConfiguration(
      whisperModel: asrModel(from: settings.selectedModel),
      primaryLanguageCode: canonicalLanguageCode(from: settings.primaryLanguage)
    )
  }

  private static func asrModel(from selectedModelValue: String) -> ASRModelProfile {
    let normalized = selectedModelValue
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()

    if let byModelID = availableMLXModels.first(where: { $0.id == normalized }) {
      return byModelID.profile
    }

    // Legacy fallback values kept for pre-MLX settings migration.
    switch normalized {
    case "base":
      return .medium
    case "small":
      return .small
    case "medium":
      return .medium
    case "large", "large-v3", "large_v3":
      return .large
    default:
      return .medium
    }
  }

  private static func canonicalLanguageCode(from rawLanguage: String) -> String? {
    let trimmed = rawLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let sanitized = trimmed.replacingOccurrences(of: "_", with: "-")
    let parts = sanitized.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 1 || parts.count == 2 else { return nil }

    let language = String(parts[0])
    guard language.count == 2, language.allSatisfy(\.isLetter) else { return nil }

    let canonicalLanguage = language.lowercased()

    if parts.count == 1 {
      return canonicalLanguage
    }

    let region = String(parts[1])
    guard region.count == 2, region.allSatisfy(\.isLetter) else { return nil }
    return "\(canonicalLanguage)-\(region.uppercased())"
  }

  private static func canonicalModelID(from rawModelValue: String) -> String {
    let normalized = rawModelValue
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()

    if availableMLXModels.contains(where: { $0.id == normalized }) {
      return normalized
    }

    switch normalized {
    case "base":
      return "mlx-community/whisper-medium"
    case "small":
      return "mlx-community/whisper-small"
    case "medium":
      return "mlx-community/whisper-medium"
    case "large", "large-v3", "large_v3":
      return "mlx-community/whisper-large-v3"
    default:
      return "mlx-community/whisper-medium"
    }
  }

  private static func normalizedSettings(_ settings: AppSettings) -> AppSettings {
    var normalized = settings
    normalized.selectedModel = canonicalModelID(from: settings.selectedModel)
    normalized.primaryLanguage = canonicalLanguageCode(from: settings.primaryLanguage) ?? ""
    return normalized
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
}
