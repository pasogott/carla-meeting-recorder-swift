# Carla — Current Status / TODO

## Current Status (as of now)

### Core implementation
- [x] MLX Whisper integration and binding layer
- [x] model management + download progress flow
- [x] real permission handling (microphone + screen recording)
- [x] end-to-end recording coordinator flow wired to app state
- [x] meeting list connected to real database
- [x] delete confirmation + meeting deletion service
- [x] audio playback with timestamp jump/seek
- [x] menu bar audio level meters
- [x] integration tests for recording/transcription/storage pipeline

### Recent hardening
- [x] strict linting enabled in CI and Release workflows
- [x] release workflow builds DMG and uploads release assets
- [x] release workflow configured for Developer ID signing
- [x] meeting deletion hardened (safe-path checks + directory cleanup)

### Verified locally
- [x] `swift test` passing
- [x] Xcode Debug build passing

## Open TODO

### Release quality
- [ ] Add notarization + stapling to release workflow
- [ ] Add update feed contract/check (if auto-updater will consume release artifacts)
- [ ] Decide whether to keep `Carla-latest.dmg` as stable update channel artifact

### Security / signing
- [ ] Confirm release secrets are set in GitHub Actions:
  - [ ] `APPLE_DEVELOPER_ID_CERT` (base64 `.p12` preferred; `.cer` also supported)
  - [ ] `APPLE_DEVELOPER_ID_PASSWORD`
  - [ ] `APPLE_DEVELOPER_ID_PRIVATE_KEY` (required when cert secret is `.cer`)
  - [ ] `APPLE_DEVELOPER_ID`
  - [ ] `APPLE_TEAM_ID` (optional)
- [ ] Validate signed release on a clean macOS machine

### Product / UX polish
- [ ] Improve onboarding copy and error states
- [ ] Add clearer recovery guidance for denied permissions
- [ ] Add transcript empty-state and failed-transcription UX handling

### Engineering quality
- [ ] Add more tests around playback and permissions edge cases
- [ ] Add dedicated tests for release artifact naming/checksums
- [ ] Decide lint baseline strategy (fix all remaining style drift vs. enforce only changed files)

### Operations
- [ ] Document release procedure (tag -> release -> verify DMG)
- [ ] Add troubleshooting section for CI signing failures

## Suggested next step (highest impact)
1. Implement notarization + stapling in `.github/workflows/release.yml`.
2. Run one full tagged release dry run.
3. Verify install on a clean Mac (Gatekeeper + launch).
