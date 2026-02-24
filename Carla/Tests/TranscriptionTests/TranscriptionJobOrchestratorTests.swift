import XCTest

@testable import CarlaTranscription

final class TranscriptionJobOrchestratorTests: XCTestCase {
  func testRealtimeJobFallsBackToAutoDetectLanguage() async throws {
    let engine = MockWhisperEngine(
      mode: .custom(
        stream: { chunk, _, languageHint in
          if case .fixed = languageHint {
            throw WhisperEngineError.unsupportedLanguage("de")
          }
          return WhisperTranscriptionResult(
            segments: [
              WhisperSegment(
                startTime: 0, endTime: chunk.endTime - chunk.startTime, text: "ok", confidence: 0.9)
            ],
            detectedLanguageCode: "en"
          )
        },
        file: { _, _, _ in
          WhisperTranscriptionResult(segments: [], detectedLanguageCode: "en")
        }
      ))

    let orchestrator = TranscriptionJobOrchestrator(engine: engine)
    let config = RealtimeTranscriptionJobConfiguration(
      model: .base,
      chunkDuration: 1.0,
      language: TranscriptionLanguageConfiguration(
        primaryLanguageCode: "de", autoDetectFallback: true)
    )

    let jobID = await orchestrator.startRealtimeJob(configuration: config)
    let packet = AudioPacket(
      startTime: 0, sampleRate: 4, samples: [0.1, 0.2, 0.3, 0.4], source: .microphone)

    let segments = try await orchestrator.ingest(packet, for: jobID)
    XCTAssertEqual(segments.count, 1)
    XCTAssertEqual(segments[0].language, "en")
    XCTAssertEqual(segments[0].speaker, "You")
  }

  func testShadowEngineReceivesIdenticalStreamAndFileRequests() async throws {
    let primaryCapture = RequestCapture()
    let shadowCapture = RequestCapture()

    let primary = buildCapturingEngine(capture: primaryCapture, transcriptLabel: "primary")
    let shadow = buildCapturingEngine(capture: shadowCapture, transcriptLabel: "shadow")

    let orchestrator = TranscriptionJobOrchestrator(engine: primary, shadowEngine: shadow)
    let config = RealtimeTranscriptionJobConfiguration(
      model: .small,
      chunkDuration: 1.0,
      language: TranscriptionLanguageConfiguration(primaryLanguageCode: "en", autoDetectFallback: true)
    )

    let jobID = await orchestrator.startRealtimeJob(configuration: config)
    let packet = AudioPacket(
      startTime: 0,
      sampleRate: 4,
      samples: [0.1, 0.2, 0.3, 0.4],
      source: .systemAudio
    )
    _ = try await orchestrator.ingest(packet, for: jobID)

    let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("shadow-parity.wav")
    try Data([1, 2, 3]).write(to: tempFile)
    _ = try await orchestrator.runPolishJob(
      PostRecordingPolishRequest(
        audioFileURL: tempFile,
        source: .microphone,
        model: .medium,
        language: TranscriptionLanguageConfiguration(primaryLanguageCode: "en")
      ))

    let primaryStream = await primaryCapture.streamRequests
    let shadowStream = await shadowCapture.streamRequests
    XCTAssertEqual(primaryStream.count, 1)
    XCTAssertEqual(shadowStream.count, 1)
    XCTAssertEqual(primaryStream[0].chunk, shadowStream[0].chunk)
    XCTAssertEqual(primaryStream[0].model, shadowStream[0].model)
    XCTAssertEqual(primaryStream[0].hint, shadowStream[0].hint)

    let primaryFile = await primaryCapture.fileRequests
    let shadowFile = await shadowCapture.fileRequests
    XCTAssertEqual(primaryFile.count, 1)
    XCTAssertEqual(shadowFile.count, 1)
    XCTAssertEqual(primaryFile[0].url.lastPathComponent, shadowFile[0].url.lastPathComponent)
    XCTAssertEqual(primaryFile[0].model, shadowFile[0].model)
    XCTAssertEqual(primaryFile[0].hint, shadowFile[0].hint)

    try? FileManager.default.removeItem(at: tempFile)
  }

  private func buildCapturingEngine(capture: RequestCapture, transcriptLabel: String) -> MockASREngine {
    MockASREngine(
      mode: .custom(
        stream: { chunk, model, hint in
          await capture.recordStream(chunk: chunk, model: model, hint: hint)
          return ASRTranscriptionResult(
            segments: [
              ASRSegment(startTime: 0, endTime: chunk.endTime - chunk.startTime, text: transcriptLabel, confidence: 0.9)
            ],
            detectedLanguageCode: "en"
          )
        },
        file: { url, model, hint in
          await capture.recordFile(url: url, model: model, hint: hint)
          return ASRTranscriptionResult(
            segments: [ASRSegment(startTime: 0, endTime: 1.0, text: transcriptLabel, confidence: 0.9)],
            detectedLanguageCode: "en"
          )
        }
      ))
  }
}

private actor RequestCapture {
  struct StreamRequest: Equatable {
    let chunk: AudioChunk
    let model: ASRModelProfile
    let hint: ASRLanguageHint?
  }

  struct FileRequest: Equatable {
    let url: URL
    let model: ASRModelProfile
    let hint: ASRLanguageHint?
  }

  private(set) var streamRequests: [StreamRequest] = []
  private(set) var fileRequests: [FileRequest] = []

  func recordStream(chunk: AudioChunk, model: ASRModelProfile, hint: ASRLanguageHint?) {
    streamRequests.append(StreamRequest(chunk: chunk, model: model, hint: hint))
  }

  func recordFile(url: URL, model: ASRModelProfile, hint: ASRLanguageHint?) {
    fileRequests.append(FileRequest(url: url, model: model, hint: hint))
  }
}
