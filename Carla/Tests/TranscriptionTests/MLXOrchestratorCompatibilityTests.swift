import Foundation
import XCTest

@testable import CarlaTranscription

final class MLXOrchestratorCompatibilityTests: XCTestCase {
  func testOrchestratorRunsRealtimeAndPolishWithMLXEngine() async throws {
    let binding = OrchestratorMLXBinding()
    let engine = MLXWhisperEngine(binding: binding)
    let orchestrator = TranscriptionJobOrchestrator(engine: engine)

    let config = RealtimeTranscriptionJobConfiguration(
      model: .base,
      chunkDuration: 2.0,
      language: TranscriptionLanguageConfiguration(primaryLanguageCode: "en", autoDetectFallback: true)
    )

    let jobID = await orchestrator.startRealtimeJob(configuration: config)
    let packet = AudioPacket(
      startTime: 0,
      sampleRate: 4,
      samples: [0.2, 0.2, 0.2, 0.2],
      source: .microphone
    )

    let partial = try await orchestrator.ingest(packet, for: jobID)
    XCTAssertEqual(partial.count, 0)

    let finalized = try await orchestrator.finishRealtimeJob(jobID)
    XCTAssertEqual(finalized.count, 1)
    XCTAssertEqual(finalized[0].text, "mlx-stream")
    XCTAssertEqual(finalized[0].language, "en")

    let polishURL = URL(fileURLWithPath: "/tmp/meeting.wav")
    let polished = try await orchestrator.runPolishJob(
      PostRecordingPolishRequest(
        audioFileURL: polishURL,
        source: .systemAudio,
        model: .small,
        language: TranscriptionLanguageConfiguration(primaryLanguageCode: nil, autoDetectFallback: true)
      )
    )

    XCTAssertEqual(polished.count, 1)
    XCTAssertEqual(polished[0].speaker, "Others")
    XCTAssertEqual(polished[0].text, "mlx-file")

    let callLog = await binding.calls()
    XCTAssertEqual(callLog.streamModelIDs, ["mlx-community/whisper-base"])
    XCTAssertEqual(callLog.fileModelIDs, ["mlx-community/whisper-small"])
  }

  func testOrchestratorReceivesMappedMLXError() async {
    let binding = OrchestratorMLXBinding(
      streamError: .unsupportedLanguage("xx")
    )
    let orchestrator = TranscriptionJobOrchestrator(engine: MLXWhisperEngine(binding: binding))

    let config = RealtimeTranscriptionJobConfiguration(
      model: .base,
      chunkDuration: 1.0,
      language: TranscriptionLanguageConfiguration(primaryLanguageCode: "xx", autoDetectFallback: false)
    )
    let jobID = await orchestrator.startRealtimeJob(configuration: config)

    let packet = AudioPacket(
      startTime: 0,
      sampleRate: 4,
      samples: [0.1, 0.1, 0.1, 0.1],
      source: .microphone
    )

    do {
      _ = try await orchestrator.ingest(packet, for: jobID)
      XCTFail("Expected unsupported language failure")
    } catch let error as ASREngineError {
      XCTAssertEqual(error, .unsupportedLanguage("xx"))
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }
}

private actor OrchestratorMLXBinding: MLXWhisperBinding {
  struct CallLog: Equatable {
    var streamModelIDs: [String] = []
    var fileModelIDs: [String] = []
  }

  private var log = CallLog()
  private let streamError: MLXWhisperLibraryError?

  init(streamError: MLXWhisperLibraryError? = nil) {
    self.streamError = streamError
  }

  func transcribePCM(
    samples: [Float],
    sampleRate: Double,
    modelID: String,
    languageCode: String?
  ) async throws -> MLXTranscriptionPayload {
    _ = (samples, sampleRate, languageCode)
    log.streamModelIDs.append(modelID)

    if let streamError {
      throw streamError
    }

    return MLXTranscriptionPayload(
      segments: [MLXSegmentPayload(startMs: 0, endMs: 1000, text: "mlx-stream", confidence: 0.95)],
      detectedLanguageCode: "en"
    )
  }

  func transcribeFile(
    fileURL: URL,
    modelID: String,
    languageCode: String?
  ) async throws -> MLXTranscriptionPayload {
    _ = (fileURL, languageCode)
    log.fileModelIDs.append(modelID)

    return MLXTranscriptionPayload(
      segments: [MLXSegmentPayload(startMs: 0, endMs: 1500, text: "mlx-file", confidence: 0.9)],
      detectedLanguageCode: "en"
    )
  }

  func calls() -> CallLog {
    log
  }
}
