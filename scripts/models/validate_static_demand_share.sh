#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"
cd "$CODES_DIR"

BASELINE_PATH="${BASELINE_PATH:-$RESULTS_MODELS_DIR/static_demand_share_validation/existing_policies_before.bin}"
UNRELATED_HASHES_PATH="${UNRELATED_HASHES_PATH:-$RESULTS_MODELS_DIR/static_demand_share_validation/unrelated_hashes_before.txt}"
AFTER_PATH="${AFTER_PATH:-$RESULTS_MODELS_DIR/static_demand_share_validation/existing_policies_after.bin}"
VALIDATION_LOG="${VALIDATION_LOG:-$RESULTS_MODELS_DIR/static_demand_share_validation/validation.log}"
mkdir -p "$(dirname "$VALIDATION_LOG")"

export BASELINE_PATH UNRELATED_HASHES_PATH AFTER_PATH
julia --quiet --startup-file=no --history-file=no validate_static_demand_share.jl 2>&1 | tee "$VALIDATION_LOG"
