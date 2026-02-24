---
description: "Extracted actionable work items required to reach MLX-only production readiness"
source: "plan/mlx-whisper-migration-plan.md"
owner: "carla-core"
status: "open"
updated: "2026-02-24"
---

# MLX-Only: Required Work (Extract)

## P0 — Blockers (must be done first)

- [ ] **Select and pin production MLX runtime**
  - [ ] Decide exact package/library
  - [ ] Pin version/commit
  - [ ] Record license + upgrade policy in `DECISIONS.md`

- [ ] **Replace MLX inference stub with real inference**
  - [ ] Implement real inference in `MLXWhisperBindingImpl.transcribePCM`
  - [ ] Implement real inference in `MLXWhisperBindingImpl.transcribeFile`
  - [ ] Ensure known-good fixtures produce non-empty segments
  - [ ] Keep deterministic error mapping to ASR error surface

- [ ] **Define model artifact contract (per model)**
  - [ ] Enumerate exact required files for each model
  - [ ] Define required directory layout + metadata
  - [ ] Document canonical source URLs

- [ ] **Harden model integrity + readiness**
  - [ ] Add checksum/hash validation for required artifacts
  - [ ] Fail readiness if any required artifact missing/invalid
  - [ ] Stop relying on single-file/size-only readiness checks

- [ ] **Downloader correctness for full artifact set**
  - [ ] Download all required artifacts, not only one file
  - [ ] Keep resumable behavior
  - [ ] Keep atomic commit to final model state

## P1 — Productionization (after P0)

- [ ] **Settings/onboarding migration**
  - [ ] Keep legacy setting values readable
  - [ ] Map legacy `base/small/medium/large` to MLX defaults
  - [ ] Source `modelsReady` from hardened MLX readiness check

- [ ] **Model policy (EN/DE)**
  - [ ] Default model: `medium`
  - [ ] Optional quality mode: `large-v3`
  - [ ] Pressure downgrade path: `small`

- [ ] **Quality governor consolidation**
  - [ ] Ensure governor is single control plane (no duplicated adaptive logic)
  - [ ] Emit transitions to diagnostics artifacts

- [ ] **Error UX hardening**
  - [ ] Replace generic "download failed" with actionable categories:
    - [ ] network unreachable
    - [ ] HTTP status failure
    - [ ] disk full / no space left
    - [ ] corrupted artifacts / checksum mismatch
    - [ ] permission issues
    - [ ] unsupported hardware
  - [ ] Add clear recovery actions for each category

- [ ] **Build/dependency cutover**
  - [ ] Add/finalize MLX dependencies in SPM/Xcode
  - [ ] Remove whisper.cpp dependency wiring
  - [ ] Ensure clean bootstrap on a fresh machine

- [ ] **Hard removal of whisper.cpp**
  - [ ] Remove whisper.cpp bindings/loaders/managers/legacy branches
  - [ ] Remove stale model paths and settings branches
  - [ ] Update docs/ADRs (`README.md`, `DECISIONS.md`)

## P2 — Validation + release gate

- [ ] **Performance/quality validation**
  - [ ] EN median WER <= 12%
  - [ ] DE median WER <= 15%
  - [ ] Realtime partial latency p95 <= 2.5s
  - [ ] Stop-to-final latency p95 <= 8s

- [ ] **Reliability validation**
  - [ ] No unbounded queue growth
  - [ ] Dropped-frame rate <= baseline
  - [ ] 60–120 min soak with no crash/OOM/deadlock
  - [ ] Burn-in: >= 100 internal sessions, no P0/P1 failures
  - [ ] Download reliability >= 99% (first or resumed retry path)

- [ ] **Release validation**
  - [ ] Signed/notarized pipeline green
  - [ ] Full regression for realtime + polish + export/search

## Mandatory constraints

- [ ] MLX-only path (no non-MLX fallback engine)
- [ ] Download required for onboarding (no bundled offline-first model)
- [ ] Apple Silicon only; Intel path must show explicit unsupported message

## Remaining open decisions

- [ ] Final runtime package/API/version pin
- [ ] Final artifact manifest + checksums per model
- [ ] Burn-in duration and shadow sampling rate
