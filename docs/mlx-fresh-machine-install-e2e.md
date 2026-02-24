# MLX Fresh-Machine Install E2E Checklist (Recording + Transcription)

## Goal

Validate MVP first-run behavior on a fresh user environment:
1. Install app
2. Grant required permissions
3. Auto-download MLX models
4. Start recording
5. Stop recording
6. Verify non-empty transcript output

No manual Python/runtime dependency install is allowed.

## Acceptance Checklist

- [ ] **A1. Fresh state reset**
  - Remove previous Carla installs (`/Applications/Carla.app`, `~/Applications/Carla.app`)
  - Reset TCC permissions for bundle ID `at.cyberheld.carla`
  - Ensure no pre-existing `~/Library/Application Support/Carla/Models` cache
- [ ] **A2. Install/launch Carla from clean environment**
  - Install/open Carla build without manually installing Python/MLX tooling
- [ ] **A3. Grant permissions in-app**
  - Microphone = allowed
  - Screen Recording = allowed
- [ ] **A4. Trigger model bootstrap**
  - First-run model download starts automatically
  - Progress UI updates and completes
- [ ] **A5. Record a short sample (>=10s)**
  - Start recording from menu bar
  - Capture both local and system audio
- [ ] **A6. Stop recording and finalize transcript**
  - Stop action completes without crash/hang
  - Meeting is persisted
- [ ] **A7. Verify transcript output is non-empty**
  - Meeting has at least one transcript segment with non-whitespace text

## Verification Commands

```bash
# Fresh-run helper (reset + build + launch)
just run-fresh

# Focused pipeline assertion for non-empty transcription output
cd Carla && swift test --filter RecordingPipelineTests/testFullPipelineTranscribeToSearch

# Optional DB verification on a manual run
sqlite3 "$HOME/Library/Application Support/Carla/carla.sqlite" \
  "select count(*) from transcript_segment where trim(text) <> '';"
```

## Execution Log (2026-02-24)

Environment: local dev machine, task wave for `plan/mlx-whisper-required-work.md`.

- [x] Ran `cd Carla && swift test --filter RecordingPipelineTests/testFullPipelineTranscribeToSearch`
  - Result: **PASS**
  - Evidence: test asserts `XCTAssertFalse(transcribedSegments.isEmpty)` and searchable persisted transcript.
- [x] Attempted `just run-fresh`
  - Result: **BLOCKED by concurrent task integration state**
  - Build failed in `SettingsView.swift` with non-exhaustive switch (`.validationFailed` case missing).
  - This is external to checklist logic and tied to in-flight dependency work (`task-14`).
- [ ] Manual UI flow (`A3`..`A7`) on a truly fresh machine remains to be executed once `just run-fresh` is green again.

## Exit Criteria for Sign-off

Mark this checklist complete when a single clean run satisfies `A1`..`A7` end-to-end and records:
- command output for `just run-fresh`
- one screenshot/log of model download completion
- transcript non-empty proof (UI or sqlite query)
