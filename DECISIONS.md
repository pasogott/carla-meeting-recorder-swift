# Architecture Decisions — Carla

Documented: 2026-02-12

## ADR-01: Audio Capture — ScreenCaptureKit

**Decision:** Use ScreenCaptureKit (macOS 13+) for system audio capture.

**Rationale:** Pure Swift, no kernel extension, Apple-supported API, zukunftssicher. Requires Screen Recording permission — acceptable trade-off vs. complexity of a virtual audio device.

## ADR-02: Audio Tracks — Separate + Stereo Mix

**Decision:** Record mic and system audio as separate mono tracks. Additionally generate a combined stereo file (mic L, speaker R) for playback/export.

**Rationale:** Separate tracks enable better speaker diarization and per-track processing (e.g., noise reduction). Stereo mix provides convenient single-file playback and export.

## ADR-03: Bluetooth Audio — Smart Routing Suggestion

**Decision:** Detect Bluetooth HFP profile switch and suggest using MacBook mic for recording while keeping Bluetooth for playback.

**Rationale:** AirPods/Bluetooth headphones degrade to 16kHz mono when mic is active. Suggesting the built-in mic preserves recording quality while the user keeps their preferred listening device.

## ADR-04: Transcription — Real-time + Post-Recording Polish

**Decision:** Provide live transcription during recording AND a higher-accuracy post-recording pass.

**Rationale:** Live feedback is valuable during meetings. Post-recording polish corrects errors with full context. More complex but delivers the best user experience.

## ADR-05: MLX Whisper Models — base for realtime, small for polish

**Decision:** Use MLX Whisper `mlx-community/whisper-base` for realtime chunks and `mlx-community/whisper-small` for post-recording polish.

**Rationale:** `base` keeps stop-to-final latency within realtime targets while `small` improves final transcript quality. Model IDs are stored canonically and legacy profile values (`base/small/medium/large`) map deterministically.

## ADR-06: Language — Canonical Primary + Auto-Detection Fallback

**Decision:** User-selected language is canonicalized (`ll` or `ll-RR`) and passed as fixed language hint when valid. On unsupported-language failures, transcription retries with auto-detect.

**Rationale:** Canonical validation prevents malformed hints and keeps fallback behavior deterministic in multilingual meetings.

## ADR-07: Database — GRDB (SQLite + FTS5)

**Decision:** Use GRDB for all persistence (meetings, transcripts, metadata).

**Rationale:** Full SQLite access including FTS5 for full-text search across transcripts — essential for the product. Battle-tested Swift API, migrations, raw SQL when needed. SwiftUI binding built manually via ObservableObject layer.

## ADR-08: Audio Format — WAV → M4A Compression

**Decision:** Record in WAV (uncompressed). After transcription, compress to M4A (AAC) for archival. Delete WAV after successful compression.

**Rationale:** Whisper gets best quality input directly from WAV. M4A archival keeps storage manageable (~1MB/min vs ~10MB/min). Temporary disk spike during recording/transcription is acceptable.

## ADR-09: App Architecture — MenuBarExtra + Separate Window

**Decision:** MenuBarExtra popover for quick actions (start/stop, status, recent meetings). Separate SwiftUI window for meeting list, transcript viewer, search, and settings.

**Rationale:** Industry-standard pattern (iStatMenus, Bartender, Dato). Popover stays lightweight, full window provides space for transcript reading and search.

## ADR-10: Distribution — Direct Download + Sparkle

**Decision:** Distribute outside the Mac App Store via direct download. Use Sparkle framework for automatic updates. Sign with Developer ID.

**Rationale:** App Store sandboxing would severely limit ScreenCaptureKit access. Direct download provides full API freedom. Sparkle is the standard for indie macOS apps.

## ADR-11: Legal/Consent — Onboarding Disclaimer

**Decision:** Show a one-time disclaimer during onboarding: "You are responsible for recording consent in your jurisdiction." User confirms with checkbox.

**Rationale:** Keeps Carla legally protected without adding friction to every recording. Recording consent laws vary by jurisdiction — not Carla's responsibility to enforce.

## ADR-12: Open Source — No In-App License/Payment Gate

**Decision:** Carla runs without any in-app license activation, payment validation, or account requirement.

**Rationale:** Reduces onboarding friction, simplifies architecture, and aligns product behavior with open-source distribution principles.

## ADR-13: MVP Scope — Full v0.1 per PRD (5–6 Weeks)

**Decision:** Implement all 14 issues from the PRD v0.1 milestone, including onboarding, search, export, and audio playback with timestamp navigation.

**Rationale:** Full v0.1 delivers a polished, shippable product rather than a rough prototype. 5–6 week timeline is acceptable.

## ADR-14: ASR Burn-in Validation + Rollback Guard

**Decision:** MLX is primary ASR backend. During burn-in, optional shadow sampling can be enabled with `CARLA_ASR_SHADOW_SAMPLE_RATE` and bounded by `CARLA_ASR_BURN_IN_END`. Emergency rollback flag `CARLA_ASR_ROLLBACK_ENABLE` disables shadow burn-in path.

**Rationale:** Enables evidence-driven rollout with bounded operational risk and explicit shutdown controls.

## ADR-15: LLM Summarization — Local Default + Optional Cloud

**Decision:** Phase 2 ships with local LLM (llama.cpp, Phi-3 Mini or similar) as default. Optional: user can enter their own OpenAI API key for cloud-based summarization.

**Rationale:** Preserves the "100% local" privacy promise while giving power users access to better quality via their own API key. Two code paths but clean abstraction behind a summarization protocol.
