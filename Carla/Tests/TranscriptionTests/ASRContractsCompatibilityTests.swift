import Foundation
import XCTest

@testable import CarlaTranscription

final class ASRContractsCompatibilityTests: XCTestCase {
  func testWhisperTypealiasesRemainCompatible() async throws {
    struct StubBinding: WhisperCPPBinding {
      func transcribePCM(
        samples: [Float],
        sampleRate: Double,
        model: ASRModelProfile,
        languageHint: ASRLanguageHint?
      ) async throws -> ASRTranscriptionResult {
        _ = (samples, sampleRate, model, languageHint)
        return ASRTranscriptionResult(
          segments: [ASRSegment(startTime: 0, endTime: 1.0, text: "ok", confidence: 0.9)],
          detectedLanguageCode: "en"
        )
      }

      func transcribeFile(
        fileURL: URL,
        model: ASRModelProfile,
        languageHint: ASRLanguageHint?
      ) async throws -> ASRTranscriptionResult {
        _ = (fileURL, model, languageHint)
        return ASRTranscriptionResult(
          segments: [ASRSegment(startTime: 0, endTime: 1.0, text: "file", confidence: 0.9)],
          detectedLanguageCode: "en"
        )
      }
    }

    let engine: WhisperTranscribingEngine = WhisperCPPEngine(binding: StubBinding())
    let chunk = AudioChunk(
      startTime: 0,
      endTime: 1,
      sampleRate: 16_000,
      samples: Array(repeating: 0.1, count: 16_000),
      source: .microphone
    )

    let result = try await engine.transcribeStreamingChunk(
      chunk,
      model: .base,
      languageHint: .fixed(code: "en")
    )

    XCTAssertEqual(result.segments.count, 1)
    XCTAssertEqual(result.detectedLanguageCode, "en")
  }

  func testMetricsHookEmitsLatencyRetryQueueAndStopToFinal() async throws {
    final class TestMetricsHook: ASRMetricsHook, @unchecked Sendable {
      private var values: [ASRMetricEvent] = []
      private let lock = NSLock()

      func record(_ event: ASRMetricEvent) {
        lock.lock()
        values.append(event)
        lock.unlock()
      }

      func snapshot() -> [ASRMetricEvent] {
        lock.lock()
        defer { lock.unlock() }
        return values
      }
    }

    let hook = TestMetricsHook()
    let engine = MockASREngine(
      mode: .custom(
        stream: { chunk, _, languageHint in
          if case .fixed = languageHint {
            throw ASREngineError.unsupportedLanguage("de")
          }
          return ASRTranscriptionResult(
            segments: [
              ASRSegment(
                startTime: 0,
                endTime: chunk.endTime - chunk.startTime,
                text: "ok",
                confidence: 0.9
              )
            ],
            detectedLanguageCode: "en"
          )
        },
        file: { _, _, _ in
          ASRTranscriptionResult(
            segments: [ASRSegment(startTime: 0, endTime: 1, text: "polish", confidence: 0.9)],
            detectedLanguageCode: "en"
          )
        }
      )
    )

    let orchestrator = TranscriptionJobOrchestrator(engine: engine, metricsHook: hook)
    let config = RealtimeTranscriptionJobConfiguration(
      model: .base,
      chunkDuration: 1.0,
      language: TranscriptionLanguageConfiguration(primaryLanguageCode: "de", autoDetectFallback: true)
    )

    let jobID = await orchestrator.startRealtimeJob(configuration: config)
    let packet = AudioPacket(
      startTime: 0,
      sampleRate: 4,
      samples: [0.1, 0.2, 0.3, 0.4],
      source: .microphone
    )

    _ = try await orchestrator.ingest(packet, for: jobID)
    _ = try await orchestrator.finishRealtimeJob(jobID)

    let events = hook.snapshot()

    XCTAssertTrue(events.contains(where: {
      if case .queueBackpressure(operation: .streamChunk, queuedItems: _, droppedItems: _) = $0 {
        return true
      }
      return false
    }))
    XCTAssertTrue(events.contains(where: {
      if case .retry(operation: .streamChunk, attempt: 2, reason: "language-fallback") = $0 {
        return true
      }
      return false
    }))
    XCTAssertTrue(events.contains(where: {
      if case .latency(operation: .streamChunk, durationMs: let ms, success: true) = $0 {
        return ms >= 0
      }
      return false
    }))
    XCTAssertTrue(events.contains(where: {
      if case .stopToFinal(durationMs: let ms) = $0 {
        return ms >= 0
      }
      return false
    }))
  }
}
