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
}
