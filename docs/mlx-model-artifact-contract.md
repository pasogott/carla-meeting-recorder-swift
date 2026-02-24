# MLX Model Artifact Contract (EN/DE)

Last updated: 2026-02-24  
Source of truth: `Carla/Sources/Transcription/MLXModelArtifactManifest.json`

## Purpose

Defines the exact artifact set Carla treats as a valid MLX Whisper model install. This contract is consumed by model download, readiness, and validation flows.

## Policy

- Target languages: **English (`en`)** and **German (`de`)**
- Default runtime model: **`mlx-community/whisper-medium`**
- Optional high-quality model: **`mlx-community/whisper-large-v3`**
- Pressure fallback model: **`mlx-community/whisper-small`**
- Legacy compatibility model retained in catalog: **`mlx-community/whisper-base`**

Policy tier values:

- `required_default`
- `optional_quality`
- `pressure_fallback`
- `legacy_compatibility`

## Required artifact layout per model

For each model ID `<repo>`, required files are under `<models-root>/<repo>/` and sourced from:

`https://huggingface.co/<repo>/resolve/main/<file>`

Required files:

1. `config.json`
2. `generation_config.json`
3. `preprocessor_config.json`
4. `tokenizer.json`
5. `tokenizer_config.json`
6. `vocab.json`
7. `merges.txt`
8. `model.bin`

## Machine-readable manifest

Manifest file: `Carla/Sources/Transcription/MLXModelArtifactManifest.json`

Contains for each model:

- profile
- model_id
- display_name
- policy_tier
- cache_file_name (legacy/current single-file cache identifier)
- primary_download_url
- expected_size_bytes range
- required_artifacts[] with `relative_path`, `source_url`, `sha256`

## Integrity notes

- `sha256` is currently `null` placeholders in manifest and will be populated/enforced by checksum-validation tasks.
- Current runtime still uses `expected_size_bytes` as compatibility guard until checksum enforcement is landed.
