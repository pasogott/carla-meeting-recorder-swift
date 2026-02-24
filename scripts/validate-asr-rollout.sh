#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ARTIFACTS_DIR="${ASR_SHADOW_ARTIFACTS_DIR:-$ROOT/dist/asr-shadow}"
REPORT_PATH="${ASR_VALIDATION_REPORT_PATH:-$ROOT/dist/asr-validation-report.json}"

python3 - <<'PY'
import json
import math
import os
from pathlib import Path

artifacts_dir = Path(os.environ.get("ASR_SHADOW_ARTIFACTS_DIR", ""))
if not artifacts_dir:
    artifacts_dir = Path("dist/asr-shadow")
report_path = Path(os.environ.get("ASR_VALIDATION_REPORT_PATH", "dist/asr-validation-report.json"))

latencies = []
dropped = 0
queued = 0
errors = 0
count = 0

if artifacts_dir.exists():
    for events_file in artifacts_dir.rglob("events.jsonl"):
        for line in events_file.read_text().splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            count += 1
            latency = event.get("endToEndLatencyMs")
            if isinstance(latency, (int, float)):
                latencies.append(float(latency))
            dropped += int(event.get("droppedItems") or 0)
            queued += int(event.get("queueDepth") or 0)
            if event.get("primaryErrorTaxonomy"):
                errors += 1

latencies.sort()

def percentile(values, q):
    if not values:
        return None
    idx = min(len(values) - 1, max(0, math.ceil(q * len(values)) - 1))
    return values[idx]

drop_rate = 0.0
if queued + dropped > 0:
    drop_rate = dropped / (queued + dropped)

report = {
    "sample_count": count,
    "latency_ms": {
        "p50": percentile(latencies, 0.50),
        "p95": percentile(latencies, 0.95),
        "p99": percentile(latencies, 0.99),
    },
    "drop_rate": drop_rate,
    "error_rate": (errors / count) if count else 0.0,
    "gates": {
        "min_samples": int(os.environ.get("ASR_GATE_MIN_SAMPLES", "0")),
        "max_drop_rate": float(os.environ.get("ASR_GATE_MAX_DROP_RATE", "0.05")),
        "max_p95_latency_ms": float(os.environ.get("ASR_GATE_MAX_P95_LATENCY_MS", "2500")),
    },
}

min_samples = report["gates"]["min_samples"]
max_drop_rate = report["gates"]["max_drop_rate"]
max_p95_latency = report["gates"]["max_p95_latency_ms"]

p95 = report["latency_ms"]["p95"]
failures = []
if count < min_samples:
    failures.append(f"insufficient_samples:{count}<{min_samples}")
if report["drop_rate"] > max_drop_rate:
    failures.append(f"drop_rate:{report['drop_rate']:.6f}>{max_drop_rate}")
if p95 is not None and p95 > max_p95_latency:
    failures.append(f"p95_latency:{p95:.2f}>{max_p95_latency}")

report["status"] = "pass" if not failures else "fail"
report["failures"] = failures

report_path.parent.mkdir(parents=True, exist_ok=True)
report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
print(f"Wrote ASR validation report: {report_path}")
if failures:
    raise SystemExit(1)
PY
