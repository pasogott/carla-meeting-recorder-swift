# Changelog

All notable changes to this project will be documented in this file.

The release tag format is:

- `carla-YYYY.MM.DD-00`
- Increment patch counter per day (`-01`, `-02`, ...)

## [Unreleased]

### Added
- Local release tooling (`scripts/release.sh`, `scripts/sign-and-notarize.sh`, `scripts/make_appcast.sh`) for reliable signed/notarized Sparkle releases.

### Changed
- Local signing now supports `APPLE_DEVELOPER_ID_CERT_FILE` as a direct `.p12` path fallback.

## [carla-2026.02.22-02] - 2026-02-22

### Added
- GitHub Actions CI workflow for strict linting, tests, and macOS build checks.
- GitHub Actions release workflow for macOS DMG creation and release asset upload.
- English project `README.md` and `Todo.md` status tracker.
- Sparkle auto-update integration with a menu action for `Check for Updates…`.
- Sparkle release automation that generates a signed update `.zip` and `appcast.xml` during release builds.
- Sparkle release artifacts are now attached to GitHub releases together with checksums.

### Changed
- Open-source onboarding flow (removed in-app license/payment activation).
- Recording pipeline wiring and permission handling updates.
- Audio capture/playback pipeline cleanup and simplification.
- Transcription stack updates (Whisper integration and model download handling).
- Storage and deletion hardening (safer meeting/audio deletion behavior).
- Release automation now runs the full CI job before DMG build/signing to prevent shipping unverified builds.
- Release signing flow now builds unsigned first, then applies Developer ID signing with explicit identity resolution.
- Developer ID certificate import in CI now supports both `.p12` and `.cer` + private key inputs with clearer password/key errors.

## [carla-2026.02.16-00] - 2026-02-16

### Added
- Initial public snapshot of Carla on GitHub.
- Core flows for:
  - recording
  - transcription
  - local storage/search
  - playback and timestamp navigation
- Baseline CI/release automation.

### Notes
- This is the first tagged release in the `carla-YYYY.MM.DD-XX` scheme.
