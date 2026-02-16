# Carla

Carla is a macOS menu bar app that records meetings locally and privately.

It captures:
- your microphone audio
- system audio (e.g., Zoom/Meet/Teams output)

Then it can:
- persist recordings in a local SQLite database
- run on-device transcription with whisper.cpp
- browse/search meetings and transcript segments
- play back audio with timestamp navigation

> Privacy-first: no cloud recording pipeline is required for the core flow.

## Repository Structure

```text
carla/
├── PRD.md
├── DECISIONS.md
├── AGENTS.md
├── Carla/
│   ├── Package.swift
│   ├── Carla.xcodeproj
│   ├── Sources/
│   └── Tests/
└── .github/workflows/
```

## Requirements

- macOS 14+
- Xcode 16+
- Swift Package Manager
- Homebrew (for CI/local lint tooling)

## Local Development

### 1) Build and run from Xcode

```bash
cd Carla
open Carla.xcodeproj
```

Run scheme: **Carla**

### 2) Run package tests

```bash
cd Carla
swift test
```

### 3) Build from CLI

```bash
xcodebuild \
  -project Carla/Carla.xcodeproj \
  -scheme Carla \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

## Permissions (first run)

Carla needs:
- Microphone permission
- Screen Recording permission (for system audio capture)

If you changed permissions and want to retest:

```bash
tccutil reset Microphone at.cyberheld.carla
tccutil reset ScreenCapture at.cyberheld.carla
```

## CI / Release

### CI
`.github/workflows/ci.yml`
- strict linting via `swift-format --strict`
- `swift test`
- Xcode Debug build

### Release
`.github/workflows/release.yml`
- strict lint + tests
- signed Release build
- DMG creation
- upload release artifacts (`Carla-<tag>.dmg`, `Carla-latest.dmg`, checksums)

Required GitHub secrets for signing:
- `APPLE_DEVELOPER_ID_CERT`
- `APPLE_DEVELOPER_ID_PASSWORD`
- `APPLE_DEVELOPER_ID`
- optional: `APPLE_TEAM_ID`

## Notes

- Product scope and roadmap: `PRD.md`
- Architecture and workflow decisions: `DECISIONS.md`
- Agent/development conventions: `AGENTS.md`
