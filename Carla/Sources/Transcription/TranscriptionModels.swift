import Foundation

/// The source track for audio used during transcription.
public enum TranscriptionTrackSource: Sendable, Equatable {
  case microphone
  case systemAudio
}

/// Whisper model tier used for a transcription pass.
public enum WhisperModel: String, Sendable {
  case base
  case small
  case medium
  case large
}

/// Language hint strategy used for Whisper calls.
public enum WhisperLanguageHint: Sendable, Equatable {
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

/// Chunk unit delivered to Whisper for realtime transcription.
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

/// Native whisper segment, relative to the request-local audio input.
public struct WhisperSegment: Sendable, Equatable {
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

/// Native whisper transcription output.
public struct WhisperTranscriptionResult: Sendable, Equatable {
  public let segments: [WhisperSegment]
  public let detectedLanguageCode: String?

  public init(segments: [WhisperSegment], detectedLanguageCode: String?) {
    self.segments = segments
    self.detectedLanguageCode = detectedLanguageCode
  }
}

/// App-facing transcript segment mapped from whisper output.
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
