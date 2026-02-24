import Foundation
import XCTest

@testable import CarlaTranscription

final class ShadowTranscriptionHarnessTests: XCTestCase {
  func testCaptureWritesJsonlAndSummaryCsvWithExpectedSchema() async throws {
    let artifactsDir = try makeTempDirectory(name: "shadow-harness-schema")
    defer { try? FileManager.default.removeItem(at: artifactsDir) }

    let harness = ShadowTranscriptionHarness(
      configuration: ShadowTranscriptionHarnessConfiguration(
        artifactsDirectory: artifactsDir,
        retention: ShadowTranscriptionRetentionPolicy(maxArtifactAge: 60 * 60, maxTotalBytes: 10 * 1024 * 1024),
        redaction: ShadowTranscriptionRedactionPolicy(redactTranscriptText: true)
      ))

    let jobID = UUID()
    let chunkID = UUID()
    await harness.capture(
      ShadowTranscriptionAttemptCapture(
        operation: .streamChunk,
        request: ShadowTranscriptionRequestMetadata(
          jobID: jobID,
          chunkID: chunkID,
          source: .microphone,
          model: .small,
          languageHint: .fixed(code: "en"),
          queueDepth: 2,
          droppedItems: 1,
          audioFileName: nil
        ),
        attempt: 1,
        retried: false,
        retryReason: nil,
        primaryResult: ASRTranscriptionResult(
          segments: [ASRSegment(startTime: 0, endTime: 1, text: "hello world", confidence: 0.9)],
          detectedLanguageCode: "en"
        ),
        shadowResult: ASRTranscriptionResult(
          segments: [ASRSegment(startTime: 0, endTime: 1, text: "hullo world", confidence: 0.8)],
          detectedLanguageCode: "de"
        ),
        primaryError: nil,
        shadowError: ASREngineError.decodingFailed,
        primaryLatencyMs: 11,
        shadowLatencyMs: 17,
        endToEndLatencyMs: 25
      ))

    let jobDir = artifactsDir.appendingPathComponent(jobID.uuidString)
    let jsonlURL = jobDir.appendingPathComponent("events.jsonl")
    let csvURL = jobDir.appendingPathComponent("summary.csv")

    XCTAssertTrue(FileManager.default.fileExists(atPath: jsonlURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: csvURL.path))

    let jsonLine = try XCTUnwrap(try String(contentsOf: jsonlURL).split(separator: "\n").first)
    let data = Data(jsonLine.utf8)
    let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

    XCTAssertEqual(parsed["operation"] as? String, "streamChunk")
    XCTAssertEqual(parsed["jobID"] as? String, jobID.uuidString)
    XCTAssertEqual(parsed["chunkID"] as? String, chunkID.uuidString)
    XCTAssertEqual(parsed["queueDepth"] as? Int, 2)
    XCTAssertEqual(parsed["droppedItems"] as? Int, 1)
    XCTAssertEqual(parsed["tokenAlignmentDrift"] as? Int, 1)
    XCTAssertEqual(parsed["languageMismatch"] as? Bool, true)
    XCTAssertEqual(parsed["shadowErrorTaxonomy"] as? String, "decoding_failed")

    let primaryPreview = try XCTUnwrap(parsed["primaryTranscriptPreview"] as? [String])
    XCTAssertEqual(primaryPreview.first, "redacted-len=11")

    let csv = try String(contentsOf: csvURL)
    XCTAssertTrue(csv.contains("timestamp,operation,job_id"))
    XCTAssertTrue(csv.contains("\"streamChunk\""))
    XCTAssertTrue(csv.contains("\"true\""))
  }

  func testRetentionPrunesOldArtifactsAndBoundsTotalSize() async throws {
    let artifactsDir = try makeTempDirectory(name: "shadow-harness-retention")
    defer { try? FileManager.default.removeItem(at: artifactsDir) }

    let oldJob = artifactsDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let freshJob = artifactsDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: oldJob, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: freshJob, withIntermediateDirectories: true)

    let oldFile = oldJob.appendingPathComponent("events.jsonl")
    let freshFile = freshJob.appendingPathComponent("events.jsonl")

    try Data(repeating: 65, count: 4096).write(to: oldFile)
    try Data(repeating: 66, count: 4096).write(to: freshFile)

    let veryOldDate = Date(timeIntervalSinceNow: -3600)
    try FileManager.default.setAttributes([.modificationDate: veryOldDate], ofItemAtPath: oldJob.path)

    let harness = ShadowTranscriptionHarness(
      configuration: ShadowTranscriptionHarnessConfiguration(
        artifactsDirectory: artifactsDir,
        retention: ShadowTranscriptionRetentionPolicy(maxArtifactAge: 60, maxTotalBytes: 4096),
        redaction: ShadowTranscriptionRedactionPolicy(redactTranscriptText: false)
      ))

    await harness.capture(
      ShadowTranscriptionAttemptCapture(
        operation: .transcribeFile,
        request: ShadowTranscriptionRequestMetadata(
          jobID: UUID(),
          chunkID: nil,
          source: .systemAudio,
          model: .base,
          languageHint: .autoDetect,
          queueDepth: 0,
          droppedItems: 0,
          audioFileName: "meeting.wav"
        ),
        attempt: 1,
        retried: false,
        retryReason: nil,
        primaryResult: ASRTranscriptionResult(segments: [], detectedLanguageCode: "en"),
        shadowResult: nil,
        primaryError: nil,
        shadowError: nil,
        primaryLatencyMs: 10,
        shadowLatencyMs: nil,
        endToEndLatencyMs: 10
      ))

    XCTAssertFalse(FileManager.default.fileExists(atPath: oldJob.path), "Old artifact folder should be removed by age retention")

    let urls = try FileManager.default.contentsOfDirectory(
      at: artifactsDir,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )
    XCTAssertLessThanOrEqual(urls.count, 1, "Retention should keep bounded storage")
  }

  private func makeTempDirectory(name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
