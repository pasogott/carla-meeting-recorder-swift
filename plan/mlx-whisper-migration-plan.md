---
description: "Complete replacement plan for whisper.cpp with MLX Whisper, including shadow evaluation harness and adaptive quality governor for performance-safe, evidence-driven rollout."
owner: "carla-core"
status: "draft"
updated: "2026-02-24"
---

# MLX Whisper Migration Plan (Whisper.cpp Full Replacement)

## Goals
- Remove whisper.cpp entirely from Carla.
- Migrate all transcription paths to MLX Whisper.
- Improve reliability/performance on Apple Silicon.
- Preserve or improve transcript quality under real meeting load.
- Keep architecture backend-neutral so future ASR swaps are low-risk.

## Scope + Non-Goals
- In scope: realtime transcription, post-recording polish pass, model lifecycle, onboarding/settings, tests, CI/release, docs/ADR updates.
- Out of scope: cloud transcription fallback; new summarization features.

## Product Decisions (fixed)
- MLX-only path. No whisper.cpp fallback in production.
- No non-MLX ASR fallback engine during migration; failures must be explicit/actionable.
- Offline-first without model download is **not** required; onboarding requires model download.
- Target languages/priorities for validation: English + German.
- Default runtime model policy: `medium` default, `large-v3` optional high-quality mode, `small` only under pressure governor.

## Current-State Risks to Address (must be fixed by this plan)
- [ ] Transcription layer is Whisper-branded end-to-end (`WhisperModel`, `WhisperTranscribingEngine`, etc.), preventing clean backend swap.
- [ ] `RecordingCoordinator` currently finalizes realtime jobs but does not run the file-based polish pass in stop flow.
- [ ] Existing adaptive chunking logic (`effectiveChunkDuration`) is embedded in `RecordingCoordinator`; introducing a governor without consolidating this will create conflicting controls.
- [ ] Dependency migration is underspecified (SPM + Xcode project + CI + tests still reference `whisper.spm`/Whisper files).
- [ ] Model and settings migration is underspecified (legacy ggml files, model naming, language validation, backward compatibility).
- [ ] Shadow harness lacks data-contract detail and insertion points in the current pipeline.
- [ ] Exit criteria are non-numeric; rollout gate is ambiguous.
- [ ] `MLXWhisperBindingImpl` is currently a readiness stub returning empty segments, so downloaded models are not yet used for real inference.

## Implementation Checklist
- [ ] **Baseline + migration branch**
  - [ ] Create feature branch.
  - [ ] Capture baseline on representative corpus (short/long, quiet/noisy, multilingual, interruptions).
  - [ ] Collect: realtime latency p50/p95/p99, queue depth/backpressure events, memory peak, thermal-state time %, WER/CER, failure/retry rate, stop-to-final-transcript time.

- [ ] **Backend-neutral transcription contracts (no behavior change)**
  - [ ] Rename/replace Whisper-specific public contracts with backend-neutral equivalents.
  - [ ] Keep adapters so current whisper.cpp implementation still compiles/runs during this step.
  - [ ] Include all touched surfaces: `TranscriptionModels`, orchestrator config, `RecordingConfiguration`, settings mapping, tests.

- [ ] **Post-recording polish path correctness (no backend switch yet)**
  - [ ] Wire explicit polish step into `RecordingCoordinator.stopRecording()` using finalized stereo file (or track-aware approach if chosen).
  - [ ] Define failure semantics: if polish fails, keep best realtime transcript and surface non-fatal warning path.
  - [ ] Add tests to prevent regression of polish execution ordering.

- [ ] **Shadow Transcription Harness (mandatory, before cutover)**
  - [ ] Insert at orchestrator boundary so identical `AudioChunk`/file input is fed to primary + optional shadow backends.
  - [ ] Persist structured artifacts per meeting/chunk (JSONL + summary CSV).
  - [ ] Include metadata: request/job/source/chunk/model/language, latency, queue depth/drops, transcript drift, language mismatch, error taxonomy/retry, thermal/memory.
  - [ ] Add retention + redaction policy for artifacts (local-only, bounded size).

- [ ] **MLX engine implementation (P0 blocker)**
  - [ ] Replace `MLXWhisperBindingImpl` stub with real MLX inference for realtime chunks + file polish.
  - [ ] Ensure `transcribePCM` and `transcribeFile` emit non-empty segments on known-good fixtures.
  - [ ] Normalize timestamps/confidence/language outputs to current domain model.
  - [ ] Define deterministic error mapping to backend-neutral error enum.
  - [ ] Add warmup/loading lifecycle so first chunk latency is bounded and measurable.

- [ ] **Model management migration (MLX) (P0 blocker)**
  - [ ] Replace Whisper model loader/manager with MLX model manager (catalog, download/cache/validation, resumable downloads).
  - [ ] Define explicit artifact contract per model (required files, layout, metadata).
  - [ ] Validate artifacts with checksum/hash (not size-range only).
  - [ ] Make readiness verify complete artifact contract (not single-file existence).
  - [ ] Keep migration behavior: read old settings, map legacy values, remove stale ggml only after readiness success.

- [ ] **Settings + onboarding migration**
  - [ ] Replace Whisper model UI with MLX model IDs and labels.
  - [ ] Enforce strict language code validation + canonicalization.
  - [ ] Keep onboarding semantics unchanged, source readiness from MLX manager.

- [ ] **Quality Governor (mandatory, unified control plane)**
  - [ ] Introduce profile controller: `quality | balanced | realtime-safe`.
  - [ ] Inputs: latency SLA, queue depth, thermal, memory pressure, low-power mode.
  - [ ] Outputs: model tier/profile and chunk/decode adjustments with hysteresis + cooldown.
  - [ ] Remove duplicated adaptive logic so governor is single source of truth.
  - [ ] Emit profile transitions into shadow artifacts.

- [ ] **Build system + dependency cutover**
  - [ ] Update `Carla/Package.swift`, `Carla.xcodeproj`, CI scripts, tests.
  - [ ] Add MLX dependencies, remove `whisper.spm`, migrate/remove whisper-specific targets.
  - [ ] Ensure clean bootstrap on fresh machine without cached artifacts.

- [ ] **Primary backend switch + burn-in**
  - [ ] Make MLX primary backend.
  - [ ] Keep optional MLX-vs-MLX shadow comparison modes for burn-in/observability only.
  - [ ] Keep sampling rate configurable for burn-in diagnostics.

- [ ] **Hard removal of whisper.cpp**
  - [ ] Delete whisper.cpp bindings/loaders/managers/legacy branches.
  - [ ] Remove dead model paths, stale settings branches, obsolete docs references.
  - [ ] Update ADRs (`DECISIONS.md`) and user docs (`README.md`).

- [ ] **Validation + release hardening**
  - [ ] Full regression across realtime + polish + export/search flows.
  - [ ] Stress tests: 2h meeting, thermal pressure, low-power mode, constrained memory.
  - [ ] Validate release scripts/notarization/assets after dependency changes.
  - [ ] Add explicit user-facing error taxonomy (network/http/disk/corrupt artifacts/permission/unsupported hardware).
  - [ ] Ensure every hard failure state has actionable recovery text in UI.

## PR Slices Checklist
- [ ] **PR1:** Baseline instrumentation + backend-neutral contracts (no behavior change).
- [ ] **PR2:** Polish-path wiring + shadow harness data contract + artifact pipeline.
- [ ] **PR3:** Real MLX inference in `MLXWhisperBindingImpl` (remove empty-segment stub) + deterministic error mapping.
- [ ] **PR4:** MLX model manager artifact contract + checksum validation + readiness hardening + settings/onboarding migration.
- [ ] **PR5:** Quality governor + consolidation of adaptive logic.
- [ ] **PR6:** Build/dependency cutover + MLX primary switch + burn-in controls.
- [ ] **PR7:** Hard removal of whisper.cpp + docs/ADR updates + release hardening + error UX taxonomy.

## Quantitative Exit Criteria (ship gate)
- [ ] Zero whisper.cpp references in source, tests, SPM/Xcode config, CI/release scripts.
- [ ] Realtime partial transcript latency p95 <= 2.5s on Apple Silicon reference device.
- [ ] End-to-end stop-to-final-transcript latency p95 <= 8s on evaluation corpus.
- [ ] WER targets on evaluation corpus:
  - [ ] English median WER <= 12%
  - [ ] German median WER <= 15%
- [ ] No unbounded queue growth; dropped-frame rate <= baseline.
- [ ] Soak: 60–120 min session on reference device with no crash/OOM and no transcript pipeline deadlock.
- [ ] Burn-in: at least 100 internal sessions, no P0/P1 transcription failures.
- [ ] Download reliability: >=99% success on first or resumed retry path in internal network test matrix.
- [ ] Signed/notarized release pipeline green.

## Platform Decision
- MLX path is Apple Silicon only.
- Intel Macs: explicit unsupported path with clear user-facing message (no silent failure).

## Open Questions
- [ ] Which exact MLX runtime package/API version is selected for production pinning (name + version/commit + license note)?
- [ ] Exact artifact manifest per model for the chosen runtime (required files + checksums + source URLs).
- [ ] Burn-in duration + sampling rate for shadow mode in production builds.
