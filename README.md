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
  - preferred: base64 of a `.p12` that contains **certificate + private key**
  - alternative: base64 of `.cer` certificate (requires `APPLE_DEVELOPER_ID_PRIVATE_KEY`)
- `APPLE_DEVELOPER_ID_PASSWORD` (password for `.p12` / private key, if set)
- `APPLE_DEVELOPER_ID_PRIVATE_KEY` (optional; base64 `.p12` or `.key` when cert secret is `.cer`)
- `APPLE_DEVELOPER_ID` (e.g. `Developer ID Application: Pascal Schott (TEAMID)`)
- optional: `APPLE_TEAM_ID`
- `SPARKLE_PUBLIC_ED_KEY` (public EdDSA key embedded in app `Info.plist`)
- `SPARKLE_PRIVATE_ED_KEY` (private EdDSA key used to sign Sparkle update archive)

### Sparkle auto-updates
Carla now includes Sparkle and exposes `Check for Updates…` in the menu.

Before publishing a release, ensure:
- `appcast.xml` is uploaded at: `https://github.com/pasogott/carla/releases/latest/download/appcast.xml`
- release artifacts referenced by the appcast are signed and notarized
- Sparkle signatures are generated for update archives

## Notes

- Product scope and roadmap: `PRD.md`
- Architecture and workflow decisions: `DECISIONS.md`
- Agent/development conventions: `AGENTS.md`
