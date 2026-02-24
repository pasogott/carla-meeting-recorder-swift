#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

echo "Running MLX production gate validation..."

if ./scripts/validate-asr-rollout.sh; then
  echo "✅ MLX production gates passed"
else
  echo "❌ MLX production gates failed (see dist/asr-validation-report.json and docs/mlx-production-gates.md)"
  exit 1
fi
