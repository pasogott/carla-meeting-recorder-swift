import Foundation

/// The source track for audio used during transcription.
public enum TranscriptionTrackSource: Sendable, Equatable {
  case microphone
  case systemAudio
}

/// Backend-neutral model profile used for a transcription pass.
public enum ASRModelProfile: String, Sendable {
  case base
  case small
  case medium
  case large
}

/// Language hint strategy used for ASR calls.
public enum ASRLanguageHint: Sendable, Equatable {
  case fixed(code: String)
  case autoDetect
}

/// Raw audio packet pushed into the realtime pipeline.
public struct AudioPacket: Sendable, Equatable {
  public let startTime: TimeInterval
  public let sampleRate: Double
  public let samples: [Float]
  public let source: TranscriptionTrackSource

  public init(
    startTime: TimeInterval,
    sampleRate: Double,
    samples: [Float],
    source: TranscriptionTrackSource
  ) {
    self.startTime = startTime
    self.sampleRate = sampleRate
    self.samples = samples
    self.source = source
  }
}

/// Chunk unit delivered to the ASR backend for realtime transcription.
public struct AudioChunk: Sendable, Equatable {
  public let id: UUID
  public let startTime: TimeInterval
  public let endTime: TimeInterval
  public let sampleRate: Double
  public let samples: [Float]
  public let source: TranscriptionTrackSource
  public let isFinal: Bool

  public init(
    id: UUID = UUID(),
    startTime: TimeInterval,
    endTime: TimeInterval,
    sampleRate: Double,
    samples: [Float],
    source: TranscriptionTrackSource,
    isFinal: Bool = false
  ) {
    self.id = id
    self.startTime = startTime
    self.endTime = endTime
    self.sampleRate = sampleRate
    self.samples = samples
    self.source = source
    self.isFinal = isFinal
  }
}

/// Backend-native segment, relative to request-local audio input.
public struct ASRSegment: Sendable, Equatable {
  public let startTime: TimeInterval
  public let endTime: TimeInterval
  public let text: String
  public let confidence: Float

  public init(
    startTime: TimeInterval,
    endTime: TimeInterval,
    text: String,
    confidence: Float
  ) {
    self.startTime = startTime
    self.endTime = endTime
    self.text = text
    self.confidence = confidence
  }
}

/// Backend-neutral transcription output.
public struct ASRTranscriptionResult: Sendable, Equatable {
  public let segments: [ASRSegment]
  public let detectedLanguageCode: String?

  public init(segments: [ASRSegment], detectedLanguageCode: String?) {
    self.segments = segments
    self.detectedLanguageCode = detectedLanguageCode
  }
}

/// App-facing transcript segment mapped from backend output.
public struct TranscriptSegment: Sendable, Equatable, Identifiable {
  public let id: UUID
  public let startTime: TimeInterval
  public let endTime: TimeInterval
  public let text: String
  public let speaker: String
  public let confidence: Float
  public let language: String?
  public let source: TranscriptionTrackSource

  public init(
    id: UUID = UUID(),
    startTime: TimeInterval,
    endTime: TimeInterval,
    text: String,
    speaker: String,
    confidence: Float,
    language: String?,
    source: TranscriptionTrackSource
  ) {
    self.id = id
    self.startTime = startTime
    self.endTime = endTime
    self.text = text
    self.speaker = speaker
    self.confidence = confidence
    self.language = language
    self.source = source
  }
}

/// Mapping strategy from track source to user-facing speaker label.
public struct SpeakerMapper: Sendable {
  public var localSpeakerLabel: String
  public var remoteSpeakerLabel: String

  public init(localSpeakerLabel: String = "You", remoteSpeakerLabel: String = "Others") {
    self.localSpeakerLabel = localSpeakerLabel
    self.remoteSpeakerLabel = remoteSpeakerLabel
  }

  /// Maps the track source to a speaker label.
  public func speaker(for source: TranscriptionTrackSource) -> String {
    switch source {
    case .microphone:
      return localSpeakerLabel
    case .systemAudio:
      return remoteSpeakerLabel
    }
  }
}

// MARK: - Backward compatibility aliases

public typealias WhisperModel = ASRModelProfile
public typealias WhisperLanguageHint = ASRLanguageHint
public typealias WhisperSegment = ASRSegment
public typealias WhisperTranscriptionResult = ASRTranscriptionResult
