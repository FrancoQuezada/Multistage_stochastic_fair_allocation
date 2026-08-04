#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"
cd "$CODES_DIR"

BASELINE_PATH="${BASELINE_PATH:-$RESULTS_MODELS_DIR/conditional_fairness_validation/baseline_before.bin}"
VALIDATION_LOG="${VALIDATION_LOG:-$RESULTS_MODELS_DIR/conditional_fairness_validation/validation.log}"
mkdir -p "$(dirname "$VALIDATION_LOG")"
export BASELINE_PATH

julia --quiet --startup-file=no --history-file=no validate_conditional_fairness.jl 2>&1 | tee "$VALIDATION_LOG"
