# MLX Runtime API Contract (Production)

Last updated: 2026-02-24
Owner: carla-core

## Runtime Pin (production)

- Runtime package: `mlx-whisper`
- Pin: `==0.4.3`
- Distribution artifact: `mlx_whisper-0.4.3-py3-none-any.whl`
- Artifact SHA-256: `6b82b6597a994643a3e5496c7bc229a672e5ca308458455bfe276e76ae024489`
- Source channel: PyPI (`https://pypi.org/project/mlx-whisper/0.4.3/`)

## Why this runtime

- Matches current production adapter (`import mlx_whisper`) used by `MLXPythonWhisperRuntime`
- Stable API for both file transcription and language hinting
- Apple Silicon optimized path aligned with Carla platform policy

## API Contract (v1)

This is the required contract for any runtime implementation behind `MLXWhisperBindingImpl`.

### Request shape

`MLXRuntimeTranscriptionRequest`

- `audioFileURL: URL` (required)
  - Must reference an existing decodable audio file
  - PCM streaming chunks are materialized to temporary mono WAV before request dispatch
- `modelID: String` (required)
  - Canonical MLX Hugging Face repo ID (for example `mlx-community/whisper-medium`)
- `languageCode: String?` (optional)
  - Canonical BCP-47 style hint (`ll` or `ll-RR`)
  - `nil` means auto-detect

### Success response shape

`MLXRuntimeTranscription`

- `detectedLanguageCode: String?`
- `segments: [MLXRuntimeSegment]` (can be empty only for truly silent input)

`MLXRuntimeSegment`

- `startSeconds: Double` (>= 0)
- `endSeconds: Double` (>= `startSeconds`)
- `text: String` (may be empty per segment, but non-empty output expected for known-good fixtures)
- `confidence: Float?` (0...1 when present)

### Error surface contract

Runtime implementations may fail with process/runtime/library errors, but must preserve deterministic mapping in `MLXWhisperBindingImpl`:

- unsupported language -> `MLXWhisperLibraryError.unsupportedLanguage`
- missing/unavailable model -> `MLXWhisperLibraryError.modelNotLoaded` or `modelNotFound`
- audio decode/corrupt/missing file -> `MLXWhisperLibraryError.decodeFailure`
- runtime startup/package unavailable -> `MLXWhisperLibraryError.runtimeFailure`
- unknown library failure -> `MLXWhisperLibraryError.libraryFailure`

## Operational constraints

- Apple Silicon only (Intel explicitly unsupported)
- Python runtime must provide `mlx_whisper` importability
- Model must pass `MLXModelManager.validateModelID` before runtime invocation

## Compatibility policy

- Contract is backward-compatible within v1: additive fields only, no removals/renames
- Any breaking change requires a new contract version (`v2`) and companion binding migration
