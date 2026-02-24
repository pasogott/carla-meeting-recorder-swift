import Foundation
import XCTest

@testable import CarlaTranscription

final class MLXWhisperEngineTests: XCTestCase {
  func testNormalizeClampsTimestampsConfidenceAndLanguage() {
    let payload = MLXTranscriptionPayload(
      segments: [
        MLXSegmentPayload(startMs: -50, endMs: 500, text: "  Hello  ", confidence: 1.4),
        MLXSegmentPayload(startMs: 1500, endMs: 1300, text: "World", confidence: -0.3),
        MLXSegmentPayload(startMs: 2000, endMs: 2500, text: "   ", confidence: 0.4)
      ],
      detectedLanguageCode: " EN "
    )

    let normalized = MLXWhisperEngine.normalize(payload)

    XCTAssertEqual(normalized.detectedLanguageCode, "en")
    XCTAssertEqual(normalized.segments.count, 2)
    XCTAssertEqual(normalized.segments[0], ASRSegment(startTime: 0, endTime: 0.5, text: "Hello", confidence: 1.0))
    XCTAssertEqual(normalized.segments[1], ASRSegment(startTime: 1.5, endTime: 1.5, text: "World", confidence: 0.0))
  }

  func testResolveLanguageCodeHonorsFixedAndAutoDetect() {
    XCTAssertEqual(MLXWhisperEngine.resolveLanguageCode(from: .fixed(code: " DE ")), "de")
    XCTAssertNil(MLXWhisperEngine.resolveLanguageCode(from: .fixed(code: "  ")))
    XCTAssertNil(MLXWhisperEngine.resolveLanguageCode(from: .autoDetect))
    XCTAssertNil(MLXWhisperEngine.resolveLanguageCode(from: nil))
  }

  func testMapErrorDeterministicallyMapsLibraryCases() {
    XCTAssertEqual(
      MLXWhisperEngine.mapError(
        MLXWhisperLibraryError.unsupportedLanguage("fr"),
        model: .small
      ),
      .unsupportedLanguage("fr")
    )

    XCTAssertEqual(
      MLXWhisperEngine.mapError(
        MLXWhisperLibraryError.modelNotFound("mlx-community/whisper-small"),
        model: .small
      ),
      .modelUnavailable(.small)
    )

    XCTAssertEqual(
      MLXWhisperEngine.mapError(
        MLXWhisperLibraryError.decodeFailure("decode"),
        model: .base
      ),
      .decodingFailed
    )

    XCTAssertEqual(
      MLXWhisperEngine.mapError(
        MLXWhisperLibraryError.libraryFailure(code: 77, message: "core failed"),
        model: .medium
      ),
      .runtimeFailure("mlx-library(77): core failed")
    )
  }

  func testMapErrorMapsCocoaFileMissingToModelUnavailable() {
    let error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
    XCTAssertEqual(MLXWhisperEngine.mapError(error, model: .large), .modelUnavailable(.large))
  }

  func testTranscribeStreamingChunkUsesBindingAndMapsFailures() async throws {
    let binding = StubMLXBinding(
      streamPayload: MLXTranscriptionPayload(
        segments: [MLXSegmentPayload(startMs: 0, endMs: 1000, text: "ok", confidence: 0.9)],
        detectedLanguageCode: "en"
      ),
      filePayload: MLXTranscriptionPayload(segments: [], detectedLanguageCode: nil)
    )

    let engine = MLXWhisperEngine(binding: binding)
    let chunk = AudioChunk(
      startTime: 0,
      endTime: 1,
      sampleRate: 16_000,
      samples: [0.1, 0.2],
      source: .microphone
    )

    let result = try await engine.transcribeStreamingChunk(
      chunk,
      model: .base,
      languageHint: .fixed(code: " EN ")
    )

    XCTAssertEqual(result.segments.count, 1)

    let streamCall = await binding.lastStreamCall()
    XCTAssertEqual(streamCall?.modelID, "mlx-community/whisper-base")
    XCTAssertEqual(streamCall?.languageCode, "en")
    XCTAssertEqual(streamCall?.sampleRate, 16_000)

    await binding.setStreamError(.decodeFailure("bad pcm"))

    do {
      _ = try await engine.transcribeStreamingChunk(chunk, model: .small, languageHint: nil)
      XCTFail("Expected decodingFailed error")
    } catch let error as ASREngineError {
      XCTAssertEqual(error, .decodingFailed)
    }
  }
}

private actor StubMLXBinding: MLXWhisperBinding {
  struct StreamCall: Equatable {
    let modelID: String
    let languageCode: String?
    let sampleRate: Double
  }

  private var streamError: MLXWhisperLibraryError?
  private var lastStream: StreamCall?
  private let streamPayload: MLXTranscriptionPayload
  private let filePayload: MLXTranscriptionPayload

  init(streamPayload: MLXTranscriptionPayload, filePayload: MLXTranscriptionPayload) {
    self.streamPayload = streamPayload
    self.filePayload = filePayload
  }

  func transcribePCM(
    samples: [Float],
    sampleRate: Double,
    modelID: String,
    languageCode: String?
  ) async throws -> MLXTranscriptionPayload {
    _ = samples
    if let streamError {
      throw streamError
    }
    lastStream = StreamCall(modelID: modelID, languageCode: languageCode, sampleRate: sampleRate)
    return streamPayload
  }

  func transcribeFile(
    fileURL: URL,
    modelID: String,
    languageCode: String?
  ) async throws -> MLXTranscriptionPayload {
    _ = (fileURL, modelID, languageCode)
    return filePayload
  }

  func lastStreamCall() -> StreamCall? {
    lastStream
  }

  func setStreamError(_ error: MLXWhisperLibraryError?) {
    streamError = error
  }
}
