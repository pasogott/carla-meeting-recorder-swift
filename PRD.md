# PRD — Carla: Privacy-First Meeting Recorder for macOS

## 1. Vision

Carla is a macOS menu bar app that automatically records, transcribes, and summarizes all meetings — regardless of platform (Zoom, Google Meet, MS Teams, FaceTime, or any other audio source). Everything runs locally. No cloud. No bots joining calls. No subscriptions.

**One-liner:** _"Your invisible meeting assistant that never leaves your Mac."_

## 2. Target Users

| Persona | Need |
|---|---|
| **Freelancers / Consultants** | Record client calls for reference without awkward bot notifications |
| **Sales Teams** | Capture deal discussions, extract action items, no data leaks |
| **Managers** | Review meeting notes, track decisions across 10+ meetings/week |
| **Legal / Compliance** | Local-only storage, GDPR/DSGVO compliant by design |
| **Developers** | Record standups, planning sessions, search past discussions |

## 3. Core Principles

1. **Privacy by default** — Audio never leaves the device
2. **Invisible** — No bot joins, no "recording" banner in calls
3. **Universal** — Works with any app that uses audio
4. **Zero friction** — Click record or auto-start, that's it
5. **Offline-first** — Full functionality without internet

---

## 4. Feature Breakdown

### Phase 1: MVP — Record & Transcribe (v0.1)

#### P1.1 Menu Bar App Shell
- [x] macOS menu bar app (MenuBarExtra)
- [x] Persistent icon in menu bar (mic icon, red when recording)
- [x] Dropdown: Start/Stop recording, Open transcript viewer, Settings, Quit
- [x] Launch at login option
- [ ] Minimal resource footprint when idle

#### P1.2 Audio Capture
- [x] Capture microphone input (AVAudioEngine)
- [x] Capture system audio output (ScreenCaptureKit) → **ADR-01**
- [x] Record as separate mono tracks (mic + system) + combined stereo mix → **ADR-02**
- [ ] Record in WAV, compress to M4A after transcription → **ADR-08**
- [x] Detect Bluetooth HFP switch, suggest built-in mic for recording → **ADR-03**
- [x] Handle audio device changes mid-recording (e.g., switch from speakers to headphones)
- [ ] Audio level meters in menu bar dropdown
- [ ] Permission handling: Microphone + Screen Recording (for system audio)

#### P1.3 Local Transcription
- [x] Integrate MLX Whisper runtime via Swift/Python bridge → **ADR-05**
- [ ] Bundle "base" model (~150MB) for real-time streaming transcription
- [ ] Bundle "small" model (~500MB) for post-recording polish pass
- [ ] Option to download "medium" or "large" model for even better quality
- [x] Real-time transcription during recording ("base", streaming, chunked) → **ADR-04**
- [x] Post-recording batch transcription ("small", higher accuracy) → **ADR-04**
- [x] User-set primary language + auto-detection fallback → **ADR-06**
- [x] Speaker diarization (basic: mic vs. system audio = you vs. others)

#### P1.4 Storage & Retrieval
- [x] GRDB (SQLite + FTS5) for meeting metadata + transcripts → **ADR-07**
- [x] Audio files stored in `~/Library/Application Support/Carla/`
- [x] Meeting list view (date, duration, title, platform detected)
- [x] Full-text search across all transcripts
- [x] Export: Markdown, TXT, SRT (subtitles), JSON
- [x] Delete meeting + audio with confirmation

#### P1.5 Basic UI
- [x] Transcript viewer window (open from menu bar)
- [x] Timeline view: scrollable transcript with timestamps
- [x] Click timestamp → jump to audio position
- [x] Copy transcript or selection
- [x] Manual meeting title editing
- [x] Settings window: audio device selection, model selection, storage path, launch at login

---

### Phase 2: Smart Features (v0.2)

#### P2.1 AI Summarization (Local Default + Optional Cloud) → **ADR-14**
- [ ] Integrate local LLM via llama.cpp (Phi-3 Mini 3.8B as default)
- [ ] One-click meeting summary generation
- [ ] Structured output: Summary, Key Decisions, Action Items, Follow-ups
- [ ] Custom prompt templates for different meeting types
- [ ] Optional: OpenAI API key for cloud-based summarization (user's own key)

#### P2.2 Calendar Integration
- [ ] Read calendar via EventKit (requires permission)
- [ ] Auto-detect meeting start → prompt to record
- [ ] Auto-title recordings from calendar event name
- [ ] Show upcoming meetings in menu bar dropdown
- [ ] Associate transcripts with calendar events

#### P2.3 Auto-Recording
- [ ] Detect meeting app launch (Zoom, Teams, Meet in browser)
- [ ] Auto-start recording when meeting detected
- [ ] Auto-stop when meeting ends (audio silence detection)
- [ ] Configurable: always auto-record, ask first, or manual only

#### P2.4 Speaker Identification
- [ ] Basic: "You" (mic) vs. "Others" (system audio)
- [ ] Advanced: Speaker embedding/clustering for multi-participant calls
- [ ] Assign names to speakers manually, remember for future calls
- [ ] Per-speaker transcript filtering

---

### Phase 3: Power Features (v0.3)

#### P3.1 Chat with Meetings
- [ ] Natural language search: "What did Sarah say about the budget?"
- [ ] RAG over transcript database (local embeddings + vector search)
- [ ] Cross-meeting queries: "Summarize all pricing discussions this month"
- [ ] Chat UI in transcript viewer

#### P3.2 Smart Follow-ups
- [ ] Extract action items with assignees and deadlines
- [ ] Generate follow-up email drafts
- [ ] Export action items to task managers (Todoist, Things, Reminders)
- [ ] Weekly digest of all meetings and open action items

#### P3.3 Team Sharing (Optional, Local Network)
- [ ] Share transcripts via local network (Bonjour)
- [ ] Export meeting packs (audio + transcript + summary)
- [ ] No cloud required

#### P3.4 Advanced Audio
- [ ] Noise cancellation / enhancement before transcription
- [ ] Echo cancellation for speaker audio
- [ ] Audio bookmarks (press hotkey to mark important moment)
- [ ] Playback speed control (0.5x – 3x)

---

## 5. Technical Architecture

### Audio Pipeline

```
┌─────────────────────────────────────────────────────┐
│                    macOS Audio System                 │
├──────────────────┬──────────────────────────────────┤
│                  │                                    │
│   Microphone     │    System Audio                   │
│   (AVAudioEngine)│    (ScreenCaptureKit)             │
│                  │                                    │
└────────┬─────────┴─────────────┬────────────────────┘
         │                       │
         ▼                       ▼
┌─────────────────────────────────────────────────────┐
│              Audio Mixer / Recorder                   │
│  ┌──────────┐  ┌──────────┐  ┌───────────────────┐  │
│  │ Ring      │  │ File     │  │ Streaming chunks  │  │
│  │ Buffer    │  │ Writer   │  │ → MLX Whisper     │  │
│  └──────────┘  └──────────┘  └───────────────────┘  │
└─────────────────────────────────────────────────────┘
         │                              │
         ▼                              ▼
┌──────────────┐              ┌──────────────────┐
│  Audio File  │              │  Live Transcript  │
│  (M4A/WAV)   │              │  (updating UI)    │
└──────────────┘              └──────────────────┘
```

### Data Model

```
Meeting
├── id: UUID
├── title: String
├── startedAt: Date
├── endedAt: Date?
├── duration: TimeInterval
├── audioFilePath: String
├── platform: Platform? (zoom/meet/teams/unknown)
├── calendarEventID: String?
├── segments: [TranscriptSegment]
├── summary: MeetingSummary?
└── tags: [String]

TranscriptSegment
├── id: UUID
├── meetingID: UUID
├── startTime: TimeInterval
├── endTime: TimeInterval
├── text: String
├── speaker: Speaker
├── confidence: Float
└── language: String

Speaker
├── id: UUID
├── label: String ("You", "Speaker 1", or assigned name)
├── isLocal: Bool (mic = true, system = false)
└── embedding: Data? (for future speaker recognition)

MeetingSummary
├── summary: String
├── keyDecisions: [String]
├── actionItems: [ActionItem]
├── followUps: [String]
└── generatedAt: Date

ActionItem
├── description: String
├── assignee: String?
├── deadline: Date?
└── completed: Bool
```

### macOS Permissions Required

| Permission | Reason | When |
|---|---|---|
| Microphone | Capture user's voice | First recording |
| Screen Recording | System audio via ScreenCaptureKit | First recording |
| Calendar (read) | Auto-detect meetings, auto-title | Phase 2, optional |
| Accessibility | Detect active meeting apps | Phase 2, optional |
| Notifications | Recording status, meeting reminders | Phase 2, optional |

---

## 6. UX Flow

### First Launch
1. App installs, appears in menu bar
2. Click icon → Welcome popover explains what Carla does
3. Recording consent disclaimer — user confirms responsibility for their jurisdiction → **ADR-11**
4. "Grant Permissions" button → guides through Mic + Screen Recording
5. Set primary language for transcription → **ADR-06**
6. Download MLX Whisper models: "base" + "small" (background, progress shown) → **ADR-05**
7. Ready state: icon turns white/idle

### Recording a Meeting
1. User joins Zoom/Meet/Teams call
2. Click Carla icon → "Start Recording" (or auto-start if enabled)
3. Icon turns red, subtle pulse animation
4. Live transcript appears in dropdown (compact) or floating panel
5. Meeting ends → user clicks "Stop" (or auto-stop)
6. Transcript finalizes, summary generates in background
7. Notification: "Meeting transcribed. Click to view."

### Reviewing a Meeting
1. Click Carla icon → "View Meetings"
2. Meeting list opens (SwiftUI window)
3. Select meeting → transcript with timestamps
4. Click timestamp → audio jumps to that point
5. "Summarize" button → AI generates summary
6. Export / share / delete

---

## 7. Non-Functional Requirements

| Requirement | Target |
|---|---|
| CPU usage (idle) | < 1% |
| CPU usage (recording) | < 15% |
| CPU usage (transcribing) | < 50% (background thread) |
| Memory (idle) | < 50MB |
| Memory (recording + transcribing) | < 500MB |
| App size (without models) | < 20MB |
| Whisper base model | ~150MB |
| Audio file size | ~1MB/min (M4A) |
| Transcription speed | ≥ 1x realtime on M1+ |
| Startup time | < 2s |
| Recording latency | < 100ms |

---

## 8. Competitive Landscape

| Feature | Carla | meetergo Log | meetjamie | Otter.ai | Fireflies |
|---|---|---|---|---|---|
| 100% Local | ✅ | ✅ | ❌ | ❌ | ❌ |
| No bot joins | ✅ | ✅ | ✅ | ❌ | ❌ |
| One-time purchase | ✅ | ✅ | ❌ | Freemium | Freemium |
| Offline | ✅ | ✅ | ❌ | ❌ | ❌ |
| AI Summary (local) | ✅ | ❌ | ❌ | ❌ | ❌ |
| Chat with meetings | ✅ (planned) | ❌ | ✅ | ✅ | ✅ |
| Calendar integration | ✅ (planned) | ❌ | ✅ | ✅ | ✅ |
| Open Source | ✅ | ❌ | ❌ | ❌ | ❌ |
| macOS native | ✅ | ✅ | ❌ (Electron) | Web | Web |

---

## 9. Milestones & Issues Roadmap

### Milestone 1: MVP Foundation (v0.1)

| # | Issue | Label | Priority |
|---|---|---|---|
| 1 | Set up Xcode project with MenuBarExtra shell | `infra` | P0 |
| 2 | Implement microphone audio capture | `audio` | P0 |
| 3 | Implement system audio capture via ScreenCaptureKit | `audio` | P0 |
| 4 | Audio mixer: combine mic + system into recording | `audio` | P0 |
| 5 | Integrate MLX Whisper for local transcription | `transcription` | P0 |
| 6 | Real-time streaming transcription during recording | `transcription` | P0 |
| 7 | SQLite storage for meetings + transcripts | `infra` | P0 |
| 8 | Meeting list view (SwiftUI window) | `ui` | P1 |
| 9 | Transcript viewer with timestamps + audio playback | `ui` | P1 |
| 10 | Full-text search across transcripts | `feature` | P1 |
| 11 | Export transcripts (Markdown, TXT, SRT) | `feature` | P1 |
| 12 | Settings window (audio device, model, storage) | `ui` | P1 |
| 13 | Permission handling + onboarding flow | `ui` | P1 |
| 14 | Launch at login | `feature` | P2 |

### Milestone 2: Smart Features (v0.2)

| # | Issue | Label | Priority |
|---|---|---|---|
| 15 | Local LLM integration for meeting summaries | `ai` | P0 |
| 16 | Calendar integration via EventKit | `feature` | P1 |
| 17 | Auto-detect meeting start + auto-record | `feature` | P1 |
| 18 | Speaker identification (you vs. others) | `transcription` | P1 |
| 19 | Auto-stop on meeting end (silence detection) | `audio` | P2 |
| 20 | Audio bookmarks via global hotkey | `feature` | P2 |

### Milestone 3: Power Features (v0.3)

| # | Issue | Label | Priority |
|---|---|---|---|
| 21 | RAG: Chat with your meetings (local embeddings) | `ai` | P0 |
| 22 | Action item extraction + follow-up drafts | `ai` | P1 |
| 23 | Advanced speaker diarization | `transcription` | P1 |
| 24 | Noise cancellation preprocessing | `audio` | P2 |
| 25 | Playback speed control | `ui` | P2 |

---

## 10. Architecture Decisions (Resolved)

See `DECISIONS.md` for full ADR documentation. Summary:

| # | Decision | Choice |
|---|---|---|
| ADR-01 | Audio Capture | ScreenCaptureKit (no virtual audio device) |
| ADR-02 | Audio Tracks | Separate tracks (mic + system) + stereo mix for playback |
| ADR-03 | Bluetooth | Smart routing suggestion (use built-in mic, BT for playback) |
| ADR-04 | Transcription | Real-time ("base") + post-recording polish ("small") |
| ADR-05 | Whisper Models | "base" ~150MB for live, "small" ~500MB for polish |
| ADR-06 | Languages | User-set primary language + auto-detection fallback |
| ADR-07 | Database | GRDB (SQLite + FTS5) |
| ADR-08 | Audio Format | Record WAV → compress to M4A after transcription |
| ADR-09 | App Architecture | MenuBarExtra + separate window |
| ADR-10 | Distribution | Direct download + Sparkle (no App Store) |
| ADR-11 | Legal/Consent | One-time onboarding disclaimer |
| ADR-12 | Open Source | No license keys or payment gating in-app |
| ADR-13 | MVP Scope | Full v0.1 per PRD (5–6 weeks) |
| ADR-14 | LLM Summarization | Local (llama.cpp) default + optional OpenAI API key |
