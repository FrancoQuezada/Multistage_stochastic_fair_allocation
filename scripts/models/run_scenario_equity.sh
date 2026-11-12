#!/usr/bin/env bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$TASK_ROOT"
export JULIA_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export OMP_NUM_THREADS=1
TASK_OUTPUT="${SCENARIO_EQUITY_DIR:-$TASK_ROOT/results_models/scenario_equity}"
mkdir -p "$TASK_OUTPUT"
if [[ "${1:-recover}" != "check-inputs" ]]; then
  if [[ "${SCENARIO_EQUITY_COORDINATED_WORKER:-0}" != "1" ]]; then
    exec 8>"$TASK_OUTPUT/campaign.lock"
    flock -n 8 || { echo "A coordinated scenario equity campaign is running." >&2; exit 1; }
  fi
  exec 9>"$TASK_OUTPUT/execution.lock"
  flock -n 9 || { echo "Another scenario equity writer is running." >&2; exit 1; }
fi
# The repository Manifest.toml was resolved with Julia 1.12.6.
exec julia +1.12.6 --project="$TASK_ROOT" --startup-file=no --history-file=no \
  "$TASK_ROOT/codes/run_scenario_equity.jl" "${1:-recover}"
