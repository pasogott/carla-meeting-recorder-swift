# AGENTS.md — Carla

## Project Overview

**Carla** is a macOS menu bar application that records all meetings — Zoom, Google Meet, Microsoft Teams — locally and privately. It intercepts system audio (microphone + speaker) to capture both sides of a conversation in high quality. Transcription and AI features run on-device. No cloud, no bots, no subscriptions. See `PRD.md` for product vision, competitive analysis, and feature roadmap.

## Tech Stack

- **Language:** Swift
- **UI:** SwiftUI (menu bar app via `MenuBarExtra`)
- **Audio Capture:** Core Audio / AVFoundation (virtual audio device for system audio tap)
- **Transcription:** Whisper.cpp (local, on-device)
- **AI Summarization:** llama.cpp (local LLM inference, cross-platform: macOS + iOS)
- **Storage:** SQLite (via GRDB or SwiftData) + local audio files
- **Build:** Xcode, Swift Package Manager
- **Min Target:** macOS 14 (Sonoma)

## Repository Structure

```
carla/
├── AGENTS.md
├── PRD.md
├── Carla/                 # Xcode project
│   ├── Carla.xcodeproj
│   ├── Sources/
│   │   ├── App/           # SwiftUI App entry, MenuBarExtra
│   │   ├── Audio/         # Audio capture, virtual device, tap
│   │   ├── Transcription/ # Whisper.cpp integration
│   │   ├── AI/            # Summarization, action items, LLM
│   │   ├── Models/        # Data models (Meeting, Transcript, etc.)
│   │   ├── Storage/       # SQLite / SwiftData persistence
│   │   ├── Calendar/      # Calendar integration (EventKit)
│   │   ├── Views/         # SwiftUI views (settings, transcript viewer)
│   │   └── Utils/         # Helpers, extensions
│   ├── Resources/         # Assets, Whisper model files
│   └── Tests/
└── docs/                  # Additional documentation
```

## Git Workflow

### Branch Strategy

- `main` — stable releases only, protected
- `development` — integration branch, all PRs target here
- Feature branches: `feature/<issue-number>-<short-description>`
- Bugfix branches: `fix/<issue-number>-<short-description>`

### Workflow: Issue → Branch → PR

Every change follows this strict flow:

#### 1. Create Issue

```bash
gh issue create --title "feat: <description>" --body "<details>" --label "<label>"
```

Labels: `feature`, `bug`, `enhancement`, `audio`, `transcription`, `ai`, `ui`, `infra`

#### 2. Create Branch from Issue

```bash
git checkout development
git pull origin development
git checkout -b feature/<issue-number>-<short-description>
```

#### 3. Develop & Commit

```bash
# Atomic commits, conventional commit messages
git commit -m "feat(audio): add system audio tap via ScreenCaptureKit"
git commit -m "fix(transcription): handle empty audio buffer"
```

**Commit conventions:**
- `feat(scope):` — new feature
- `fix(scope):` — bug fix
- `refactor(scope):` — code restructure
- `docs:` — documentation only
- `test:` — tests only
- `chore:` — build, deps, config

**No AI attribution in commits.**

#### 4. Push & Create PR

```bash
git push -u origin feature/<issue-number>-<short-description>

gh pr create \
  --base development \
  --title "feat: <description>" \
  --body "Closes #<issue-number>

## Changes
- ...

## Testing
- ..." \
  --label "<label>"
```

#### 5. Review & Merge

- PRs require passing builds
- Squash merge into `development`
- Delete branch after merge

### Release Flow

```bash
git checkout main
git merge development
git tag v<version>
git push origin main --tags
```

## Coding Standards

- Pure Swift, no external deps where possible
- SwiftUI for all UI
- `async/await` for concurrency
- All public functions need documentation comments
- Tests for all non-UI logic
- No force unwraps (`!`) except in tests
- Use `Result` or throwing functions for error handling

## Audio Architecture

Carla sits between the microphone and the meeting app:

```
┌──────────┐     ┌───────────┐     ┌──────────────┐
│ Hardware  │────▶│  Carla    │────▶│ Meeting App  │
│   Mic     │     │ (capture) │     │ (Zoom/Meet/  │
└──────────┘     └───────────┘     │  Teams)      │
                       │            └──────────────┘
                       ▼                    │
                 ┌───────────┐              │
                 │ Local     │◀─────────────┘
                 │ Recording │  (system audio tap)
                 └───────────┘
```

- **Mic capture:** AVAudioEngine input tap
- **System audio:** ScreenCaptureKit audio stream (macOS 13+) or virtual audio device
- **Output:** Combined stereo file (mic L, speaker R) or separate tracks

## Key Dependencies

| Dependency | Purpose | Integration |
|---|---|---|
| whisper.cpp | Local transcription | SPM / embedded binary |
| ScreenCaptureKit | System audio capture | Native framework |
| EventKit | Calendar integration | Native framework |
| SwiftData/GRDB | Local persistence | SPM |
| llama.cpp | Local AI summarization | SPM / embedded |
