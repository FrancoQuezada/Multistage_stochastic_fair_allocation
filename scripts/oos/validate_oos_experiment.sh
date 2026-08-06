#!/usr/bin/env bash
# Required validation suite of the out-of-sample experiment.
#
# Runs tests/oos/runtests.jl, which covers specification sections 22.1 to 22.14 and the
# representative-model audit of section 23. The last test set re-runs the repository's own
# regression suite in a subprocess, so an additive change that destabilizes an existing
# workflow fails here.
#
# Usage:
#   bash scripts/oos/validate_oos_experiment.sh
#   OOS_SKIP_REPO_REGRESSION=1 bash scripts/oos/validate_oos_experiment.sh   # faster inner loop

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_oos.sh"

oos_resolve_julia

export OOS_SKIP_REPO_REGRESSION="${OOS_SKIP_REPO_REGRESSION:-0}"

echo "=== Suite de validación del experimento fuera de muestra ==="
echo "julia : ${JULIA_ARGV[*]}"
echo "suite : $TESTS_OOS_DIR/runtests.jl"

"${JULIA_ARGV[@]}" "$TESTS_OOS_DIR/runtests.jl"

echo
echo "La suite de validación pasó. La campaña queda desbloqueada para este formulation_id."
