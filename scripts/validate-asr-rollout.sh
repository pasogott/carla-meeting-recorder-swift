#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

export ASR_SHADOW_ARTIFACTS_DIR="${ASR_SHADOW_ARTIFACTS_DIR:-$ROOT/dist/asr-shadow}"
export ASR_VALIDATION_REPORT_PATH="${ASR_VALIDATION_REPORT_PATH:-$ROOT/dist/asr-validation-report.json}"
export ASR_VALIDATION_MARKDOWN_PATH="${ASR_VALIDATION_MARKDOWN_PATH:-$ROOT/docs/mlx-production-gates.md}"
export ASR_WER_EVAL_PATH="${ASR_WER_EVAL_PATH:-$ROOT/dist/asr-wer-eval.json}"
export ASR_SOAK_REPORT_PATH="${ASR_SOAK_REPORT_PATH:-$ROOT/dist/asr-soak-report.json}"
export ASR_DOWNLOAD_REPORT_PATH="${ASR_DOWNLOAD_REPORT_PATH:-$ROOT/dist/asr-download-report.json}"
export ASR_BURNIN_REPORT_PATH="${ASR_BURNIN_REPORT_PATH:-$ROOT/dist/asr-burnin-report.json}"

python3 - <<'PY'
import json
import math
import os
import re
from collections import defaultdict
from pathlib import Path
from statistics import median


def percentile(values, q):
    if not values:
        return None
    values = sorted(values)
    idx = min(len(values) - 1, max(0, math.ceil(q * len(values)) - 1))
    return values[idx]


def tokenize(text: str):
    return re.findall(r"[\w']+", text.lower())


def levenshtein_distance(left, right):
    if not left:
        return len(right)
    if not right:
        return len(left)

    prev = list(range(len(right) + 1))
    for i, ltok in enumerate(left, start=1):
        cur = [i]
        for j, rtok in enumerate(right, start=1):
            if ltok == rtok:
                cur.append(prev[j - 1])
            else:
                cur.append(min(prev[j - 1], prev[j], cur[-1]) + 1)
        prev = cur
    return prev[-1]


def word_error_rate(reference: str, hypothesis: str):
    ref_tokens = tokenize(reference)
    hyp_tokens = tokenize(hypothesis)
    if not ref_tokens:
        return 0.0 if not hyp_tokens else 1.0
    return levenshtein_distance(ref_tokens, hyp_tokens) / len(ref_tokens)


def load_json(path: Path):
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError:
        return None


shadow_dir = Path(os.environ["ASR_SHADOW_ARTIFACTS_DIR"])
report_path = Path(os.environ["ASR_VALIDATION_REPORT_PATH"])
markdown_path = Path(os.environ["ASR_VALIDATION_MARKDOWN_PATH"])
wer_path = Path(os.environ["ASR_WER_EVAL_PATH"])
soak_path = Path(os.environ["ASR_SOAK_REPORT_PATH"])
download_path = Path(os.environ["ASR_DOWNLOAD_REPORT_PATH"])
burnin_path = Path(os.environ["ASR_BURNIN_REPORT_PATH"])

latency_stream = []
latency_finalize = []
queue_depths = []
dropped = 0
queued = 0
events_count = 0
max_increasing_streak = 0

if shadow_dir.exists():
    for events_file in shadow_dir.rglob("events.jsonl"):
        prev_depth = None
        increasing_streak = 0
        for raw_line in events_file.read_text().splitlines():
            line = raw_line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue

            if event.get("type") == "quality-governor-transition":
                continue

            events_count += 1
            operation = event.get("operation")
            end_to_end = event.get("endToEndLatencyMs")
            primary = event.get("primaryLatencyMs")
            queue_depth = int(event.get("queueDepth") or 0)
            dropped_items = int(event.get("droppedItems") or 0)

            queue_depths.append(queue_depth)
            dropped += dropped_items
            queued += queue_depth

            if operation == "streamChunk":
                latency = end_to_end if isinstance(end_to_end, (int, float)) else primary
                if isinstance(latency, (int, float)):
                    latency_stream.append(float(latency))
            elif operation == "transcribeFile":
                latency = end_to_end if isinstance(end_to_end, (int, float)) else primary
                if isinstance(latency, (int, float)):
                    latency_finalize.append(float(latency))

            if prev_depth is not None and queue_depth > prev_depth:
                increasing_streak += 1
            else:
                increasing_streak = 0
            max_increasing_streak = max(max_increasing_streak, increasing_streak)
            prev_depth = queue_depth

wer_payload = load_json(wer_path) or {}
wer_samples = wer_payload.get("samples") if isinstance(wer_payload, dict) else None
wer_by_language = defaultdict(list)
if isinstance(wer_samples, list):
    for sample in wer_samples:
        if not isinstance(sample, dict):
            continue
        language = str(sample.get("language", "")).lower().strip()
        reference = sample.get("reference")
        hypothesis = sample.get("hypothesis")
        if not language or not isinstance(reference, str) or not isinstance(hypothesis, str):
            continue
        wer_by_language[language].append(word_error_rate(reference, hypothesis))

soak_payload = load_json(soak_path) or {}
download_payload = load_json(download_path) or {}
burnin_payload = load_json(burnin_path) or {}

# Gates / thresholds
gates = {
    "en_median_wer_max": float(os.environ.get("ASR_GATE_EN_MEDIAN_WER_MAX", "0.12")),
    "de_median_wer_max": float(os.environ.get("ASR_GATE_DE_MEDIAN_WER_MAX", "0.15")),
    "realtime_p95_latency_ms_max": float(os.environ.get("ASR_GATE_REALTIME_P95_MS_MAX", "2500")),
    "stop_to_final_p95_latency_ms_max": float(os.environ.get("ASR_GATE_STOP_TO_FINAL_P95_MS_MAX", "8000")),
    "max_queue_growth_streak": int(os.environ.get("ASR_GATE_MAX_QUEUE_GROWTH_STREAK", "50")),
    "max_drop_rate": float(os.environ.get("ASR_GATE_MAX_DROP_RATE", "0.05")),
    "min_soak_minutes": float(os.environ.get("ASR_GATE_MIN_SOAK_MINUTES", "60")),
    "max_soak_minutes": float(os.environ.get("ASR_GATE_MAX_SOAK_MINUTES", "120")),
    "download_reliability_min": float(os.environ.get("ASR_GATE_DOWNLOAD_RELIABILITY_MIN", "0.99")),
    "burnin_min_sessions": int(os.environ.get("ASR_GATE_BURNIN_MIN_SESSIONS", "100")),
}

stream_p95 = percentile(latency_stream, 0.95)
finalize_p95 = percentile(latency_finalize, 0.95)
drop_rate = (dropped / (queued + dropped)) if (queued + dropped) else 0.0

en_median_wer = median(wer_by_language["en"]) if wer_by_language["en"] else None
de_median_wer = median(wer_by_language["de"]) if wer_by_language["de"] else None

soak_duration = soak_payload.get("duration_minutes") if isinstance(soak_payload, dict) else None
soak_crashes = int(soak_payload.get("crash_count") or 0) if isinstance(soak_payload, dict) else None
soak_oom = int(soak_payload.get("oom_count") or 0) if isinstance(soak_payload, dict) else None
soak_deadlocks = int(soak_payload.get("deadlock_count") or 0) if isinstance(soak_payload, dict) else None

attempts = int(download_payload.get("attempts") or 0) if isinstance(download_payload, dict) else 0
successes = int(download_payload.get("successes") or 0) if isinstance(download_payload, dict) else 0
download_reliability = (successes / attempts) if attempts > 0 else None

burnin_sessions = int(burnin_payload.get("sessions") or 0) if isinstance(burnin_payload, dict) else 0
burnin_p0_failures = int(burnin_payload.get("p0_failures") or 0) if isinstance(burnin_payload, dict) else 0
burnin_p1_failures = int(burnin_payload.get("p1_failures") or 0) if isinstance(burnin_payload, dict) else 0

checks = []

def add_check(name, passed, metric=None, threshold=None, detail=None):
    checks.append({
        "name": name,
        "passed": bool(passed),
        "metric": metric,
        "threshold": threshold,
        "detail": detail,
    })

# Quality gates
add_check(
    "en_median_wer",
    en_median_wer is not None and en_median_wer <= gates["en_median_wer_max"],
    metric=en_median_wer,
    threshold=gates["en_median_wer_max"],
    detail=f"samples={len(wer_by_language['en'])}",
)
add_check(
    "de_median_wer",
    de_median_wer is not None and de_median_wer <= gates["de_median_wer_max"],
    metric=de_median_wer,
    threshold=gates["de_median_wer_max"],
    detail=f"samples={len(wer_by_language['de'])}",
)

# Latency gates
add_check(
    "realtime_partial_p95_ms",
    stream_p95 is not None and stream_p95 <= gates["realtime_p95_latency_ms_max"],
    metric=stream_p95,
    threshold=gates["realtime_p95_latency_ms_max"],
    detail=f"samples={len(latency_stream)}",
)
add_check(
    "stop_to_final_p95_ms",
    finalize_p95 is not None and finalize_p95 <= gates["stop_to_final_p95_latency_ms_max"],
    metric=finalize_p95,
    threshold=gates["stop_to_final_p95_latency_ms_max"],
    detail=f"samples={len(latency_finalize)}",
)

# Reliability gates
add_check(
    "queue_growth_bounded",
    max_increasing_streak <= gates["max_queue_growth_streak"],
    metric=max_increasing_streak,
    threshold=gates["max_queue_growth_streak"],
    detail=f"events={events_count}",
)
add_check(
    "drop_rate_vs_baseline",
    drop_rate <= gates["max_drop_rate"],
    metric=drop_rate,
    threshold=gates["max_drop_rate"],
    detail=f"dropped={dropped}, queued={queued}",
)
add_check(
    "soak_duration_minutes",
    isinstance(soak_duration, (int, float)) and gates["min_soak_minutes"] <= float(soak_duration) <= gates["max_soak_minutes"],
    metric=soak_duration,
    threshold=[gates["min_soak_minutes"], gates["max_soak_minutes"]],
    detail=f"source={soak_path}",
)
add_check(
    "soak_no_crash_oom_deadlock",
    soak_crashes == 0 and soak_oom == 0 and soak_deadlocks == 0,
    metric={"crashes": soak_crashes, "oom": soak_oom, "deadlocks": soak_deadlocks},
    threshold={"crashes": 0, "oom": 0, "deadlocks": 0},
    detail=f"source={soak_path}",
)
add_check(
    "burnin_sessions",
    burnin_sessions >= gates["burnin_min_sessions"],
    metric=burnin_sessions,
    threshold=gates["burnin_min_sessions"],
    detail=f"source={burnin_path}",
)
add_check(
    "burnin_p0_p1_failures",
    burnin_p0_failures == 0 and burnin_p1_failures == 0,
    metric={"p0": burnin_p0_failures, "p1": burnin_p1_failures},
    threshold={"p0": 0, "p1": 0},
    detail=f"source={burnin_path}",
)
add_check(
    "download_reliability",
    download_reliability is not None and download_reliability >= gates["download_reliability_min"],
    metric=download_reliability,
    threshold=gates["download_reliability_min"],
    detail=f"successes={successes}, attempts={attempts}; source={download_path}",
)

failures = [check for check in checks if not check["passed"]]

report = {
    "status": "pass" if not failures else "fail",
    "gates": gates,
    "inputs": {
        "shadow_artifacts_dir": str(shadow_dir),
        "wer_eval_path": str(wer_path),
        "soak_report_path": str(soak_path),
        "download_report_path": str(download_path),
        "burnin_report_path": str(burnin_path),
    },
    "metrics": {
        "shadow_events": events_count,
        "realtime_latency_ms": {
            "samples": len(latency_stream),
            "p50": percentile(latency_stream, 0.50),
            "p95": stream_p95,
            "p99": percentile(latency_stream, 0.99),
        },
        "stop_to_final_latency_ms": {
            "samples": len(latency_finalize),
            "p50": percentile(latency_finalize, 0.50),
            "p95": finalize_p95,
            "p99": percentile(latency_finalize, 0.99),
        },
        "wer": {
            "en": {"samples": len(wer_by_language["en"]), "median": en_median_wer},
            "de": {"samples": len(wer_by_language["de"]), "median": de_median_wer},
        },
        "queue": {
            "max_depth": max(queue_depths) if queue_depths else 0,
            "max_increasing_streak": max_increasing_streak,
            "drop_rate": drop_rate,
            "dropped_items": dropped,
            "queued_items": queued,
        },
        "soak": {
            "duration_minutes": soak_duration,
            "crash_count": soak_crashes,
            "oom_count": soak_oom,
            "deadlock_count": soak_deadlocks,
        },
        "burnin": {
            "sessions": burnin_sessions,
            "p0_failures": burnin_p0_failures,
            "p1_failures": burnin_p1_failures,
        },
        "download": {
            "attempts": attempts,
            "successes": successes,
            "reliability": download_reliability,
        },
    },
    "checks": checks,
    "failures": failures,
}

report_path.parent.mkdir(parents=True, exist_ok=True)
report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")

# Markdown summary
lines = []
lines.append("# MLX Production Gate Report")
lines.append("")
lines.append(f"Status: **{report['status'].upper()}**")
lines.append("")
lines.append("## Gate summary")
lines.append("")
lines.append("| Gate | Metric | Threshold | Result |")
lines.append("|---|---:|---:|---|")

for check in checks:
    metric = check["metric"]
    threshold = check["threshold"]
    if isinstance(metric, float):
        metric_s = f"{metric:.4f}"
    else:
        metric_s = json.dumps(metric, sort_keys=True)
    if isinstance(threshold, float):
        threshold_s = f"{threshold:.4f}"
    else:
        threshold_s = json.dumps(threshold, sort_keys=True)
    result = "PASS" if check["passed"] else "FAIL"
    if check.get("detail"):
        result = f"{result} ({check['detail']})"
    lines.append(f"| {check['name']} | {metric_s} | {threshold_s} | {result} |")

lines.append("")
lines.append("## Input schemas")
lines.append("")
lines.append("- `asr-wer-eval.json`: `{ \"samples\": [{ \"language\": \"en|de\", \"reference\": \"...\", \"hypothesis\": \"...\" }] }`")
lines.append("- `asr-soak-report.json`: `{ \"duration_minutes\": 90, \"crash_count\": 0, \"oom_count\": 0, \"deadlock_count\": 0 }`")
lines.append("- `asr-download-report.json`: `{ \"attempts\": 100, \"successes\": 99 }`")
lines.append("- `asr-burnin-report.json`: `{ \"sessions\": 100, \"p0_failures\": 0, \"p1_failures\": 0 }`")
lines.append("")
lines.append("## Inputs")
lines.append("")
for key, value in report["inputs"].items():
    lines.append(f"- `{key}`: `{value}`")

markdown_path.parent.mkdir(parents=True, exist_ok=True)
markdown_path.write_text("\n".join(lines) + "\n")

print(f"Wrote ASR validation report: {report_path}")
print(f"Wrote gate markdown report: {markdown_path}")

if failures:
    raise SystemExit(1)
PY
