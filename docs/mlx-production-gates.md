# MLX Production Gate Report

Status: **FAIL**

## Gate summary

| Gate | Metric | Threshold | Result |
|---|---:|---:|---|
| en_median_wer | null | 0.1200 | FAIL (samples=0) |
| de_median_wer | null | 0.1500 | FAIL (samples=0) |
| realtime_partial_p95_ms | null | 2500.0000 | FAIL (samples=0) |
| stop_to_final_p95_ms | null | 8000.0000 | FAIL (samples=0) |
| queue_growth_bounded | 0 | 50 | PASS (events=0) |
| drop_rate_vs_baseline | 0.0000 | 0.0500 | PASS (dropped=0, queued=0) |
| soak_duration_minutes | null | [60.0, 120.0] | FAIL (source=/Users/pascal/projects/carla/dist/asr-soak-report.json) |
| soak_no_crash_oom_deadlock | {"crashes": 0, "deadlocks": 0, "oom": 0} | {"crashes": 0, "deadlocks": 0, "oom": 0} | PASS (source=/Users/pascal/projects/carla/dist/asr-soak-report.json) |
| burnin_sessions | 0 | 100 | FAIL (source=/Users/pascal/projects/carla/dist/asr-burnin-report.json) |
| burnin_p0_p1_failures | {"p0": 0, "p1": 0} | {"p0": 0, "p1": 0} | PASS (source=/Users/pascal/projects/carla/dist/asr-burnin-report.json) |
| download_reliability | null | 0.9900 | FAIL (successes=0, attempts=0; source=/Users/pascal/projects/carla/dist/asr-download-report.json) |

## Input schemas

- `asr-wer-eval.json`: `{ "samples": [{ "language": "en|de", "reference": "...", "hypothesis": "..." }] }`
- `asr-soak-report.json`: `{ "duration_minutes": 90, "crash_count": 0, "oom_count": 0, "deadlock_count": 0 }`
- `asr-download-report.json`: `{ "attempts": 100, "successes": 99 }`
- `asr-burnin-report.json`: `{ "sessions": 100, "p0_failures": 0, "p1_failures": 0 }`

## Inputs

- `shadow_artifacts_dir`: `/Users/pascal/projects/carla/dist/asr-shadow`
- `wer_eval_path`: `/Users/pascal/projects/carla/dist/asr-wer-eval.json`
- `soak_report_path`: `/Users/pascal/projects/carla/dist/asr-soak-report.json`
- `download_report_path`: `/Users/pascal/projects/carla/dist/asr-download-report.json`
- `burnin_report_path`: `/Users/pascal/projects/carla/dist/asr-burnin-report.json`
