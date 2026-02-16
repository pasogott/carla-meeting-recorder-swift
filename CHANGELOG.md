# Changelog

All notable changes to this project will be documented in this file.

The release tag format is:

- `carla-YYYY.MM.DD-00`
- Increment patch counter per day (`-01`, `-02`, ...)

## [Unreleased]

### Added
- GitHub Actions CI workflow for strict linting, tests, and macOS build checks.
- GitHub Actions release workflow for macOS DMG creation and release asset upload.
- English project `README.md` and `Todo.md` status tracker.

### Changed
- Open-source onboarding flow (removed in-app license/payment activation).
- Recording pipeline wiring and permission handling updates.
- Audio capture/playback pipeline cleanup and simplification.
- Transcription stack updates (Whisper integration and model download handling).
- Storage and deletion hardening (safer meeting/audio deletion behavior).

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
