import SwiftUI

// MARK: - Audio Level Meter View

/// A reusable SwiftUI component that displays an audio level meter.
/// Uses smooth animations with minimal CPU impact (throttled rendering).
struct AudioLevelMeterView: View {
  /// The audio level to display (0.0 to 1.0)
  let level: Float

  /// Label displayed next to the meter
  let label: String

  /// Icon to display (SF Symbol name)
  let icon: String

  /// Number of segments in the meter
  var segmentCount: Int = 10

  /// Width of the entire meter bar
  var meterWidth: CGFloat = 120

  /// Height of the meter bar
  var meterHeight: CGFloat = 8

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: icon)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(width: 14)

      Text(label)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(width: 48, alignment: .leading)

      // Segmented level meter
      HStack(spacing: 2) {
        ForEach(0..<segmentCount, id: \.self) { index in
          segmentView(at: index)
        }
      }
      .frame(width: meterWidth, height: meterHeight)
    }
  }

  // MARK: - Private Views

  @ViewBuilder
  private func segmentView(at index: Int) -> some View {
    let threshold = Float(index + 1) / Float(segmentCount)
    let isActive = level >= threshold

    RoundedRectangle(cornerRadius: 1.5)
      .fill(segmentColor(at: index, isActive: isActive))
      .animation(.linear(duration: 0.05), value: isActive)
  }

  private func segmentColor(at index: Int, isActive: Bool) -> Color {
    guard isActive else {
      return Color.primary.opacity(0.15)
    }

    // Color gradient: green -> yellow -> red
    let position = Float(index) / Float(segmentCount - 1)

    if position < 0.6 {
      return .green
    } else if position < 0.8 {
      return .yellow
    } else {
      return .red
    }
  }
}

// MARK: - Continuous Level Meter (Alternative Style)

/// A continuous bar-style audio level meter.
struct ContinuousLevelMeterView: View {
  /// The audio level to display (0.0 to 1.0)
  let level: Float

  /// Label displayed next to the meter
  let label: String

  /// Icon to display (SF Symbol name)
  let icon: String

  /// Width of the meter bar
  var meterWidth: CGFloat = 120

  /// Height of the meter bar
  var meterHeight: CGFloat = 6

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: icon)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(width: 14)

      Text(label)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(width: 48, alignment: .leading)

      // Continuous level bar with gradient
      GeometryReader { geometry in
        ZStack(alignment: .leading) {
          // Background track
          RoundedRectangle(cornerRadius: 3)
            .fill(Color.primary.opacity(0.1))

          // Active level bar
          RoundedRectangle(cornerRadius: 3)
            .fill(levelGradient)
            .frame(width: max(0, CGFloat(level) * geometry.size.width))
            .animation(.linear(duration: 0.05), value: level)
        }
      }
      .frame(width: meterWidth, height: meterHeight)
    }
  }

  private var levelGradient: LinearGradient {
    LinearGradient(
      colors: [.green, .yellow, .orange, .red],
      startPoint: .leading,
      endPoint: .trailing
    )
  }
}

// MARK: - Dual Level Meters Container

/// A container view for displaying both microphone and system audio level meters.
struct DualAudioLevelMetersView: View {
  /// Microphone audio level (0.0 to 1.0)
  let microphoneLevel: Float

  /// System audio level (0.0 to 1.0)
  let systemAudioLevel: Float

  /// Whether to use segmented style (true) or continuous bar style (false)
  var segmented: Bool = true

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if segmented {
        AudioLevelMeterView(
          level: microphoneLevel,
          label: "Mic",
          icon: "mic.fill"
        )

        AudioLevelMeterView(
          level: systemAudioLevel,
          label: "System",
          icon: "speaker.wave.2.fill"
        )
      } else {
        ContinuousLevelMeterView(
          level: microphoneLevel,
          label: "Mic",
          icon: "mic.fill"
        )

        ContinuousLevelMeterView(
          level: systemAudioLevel,
          label: "System",
          icon: "speaker.wave.2.fill"
        )
      }
    }
  }
}

// MARK: - Preview

#Preview("Segmented Meter") {
  VStack(spacing: 20) {
    AudioLevelMeterView(level: 0.0, label: "Silent", icon: "mic.fill")
    AudioLevelMeterView(level: 0.3, label: "Low", icon: "mic.fill")
    AudioLevelMeterView(level: 0.6, label: "Medium", icon: "mic.fill")
    AudioLevelMeterView(level: 0.85, label: "High", icon: "mic.fill")
    AudioLevelMeterView(level: 1.0, label: "Peak", icon: "mic.fill")
  }
  .padding()
  .frame(width: 240)
}

#Preview("Continuous Meter") {
  VStack(spacing: 20) {
    ContinuousLevelMeterView(level: 0.0, label: "Silent", icon: "speaker.wave.2.fill")
    ContinuousLevelMeterView(level: 0.3, label: "Low", icon: "speaker.wave.2.fill")
    ContinuousLevelMeterView(level: 0.6, label: "Medium", icon: "speaker.wave.2.fill")
    ContinuousLevelMeterView(level: 0.85, label: "High", icon: "speaker.wave.2.fill")
    ContinuousLevelMeterView(level: 1.0, label: "Peak", icon: "speaker.wave.2.fill")
  }
  .padding()
  .frame(width: 240)
}

#Preview("Dual Meters") {
  VStack(spacing: 20) {
    Text("Segmented Style")
      .font(.headline)
    DualAudioLevelMetersView(microphoneLevel: 0.6, systemAudioLevel: 0.4, segmented: true)

    Divider()

    Text("Continuous Style")
      .font(.headline)
    DualAudioLevelMetersView(microphoneLevel: 0.6, systemAudioLevel: 0.4, segmented: false)
  }
  .padding()
  .frame(width: 260)
}
