#!/usr/bin/env bash
# One shard of the out-of-sample campaign, run serially from the structural manifest.
#
# Concurrency is external: launch this once per shard index, in separate processes, against the
# same shard root. There is no coordinator and no shared cursor — the stride partition is a pure
# function of (index, shards), so no two processes can pick the same task.
#
# Usage:
#   STRUCTURAL_MANIFEST_PATH=results_oos/campaign/structural_manifest.json \
#   OOS_SHARD_ROOT=results_oos/campaign/shards \
#   FORMULATION_ID='shared_battery_mode_node_level_v1' \
#   OOS_SHARD_INDEX=1 OOS_SHARDS=8 \
#   bash scripts/oos/run_oos_task.sh
#
#   # the whole fan-out, eight processes:
#   for i in $(seq 1 8); do OOS_SHARD_INDEX=$i OOS_SHARDS=8 \
#     bash scripts/oos/run_oos_task.sh > shard-$i.log 2>&1 & done; wait
#
# Solver, Julia and BLAS threading are pinned to one so that N processes are N units of work and
# a shard's result cannot depend on how many of them happen to be running. The CPLEX pin travels
# as OOS_SOLVER_THREADS and is applied as a solver ATTRIBUTE inside Julia: CPLEX does not read
# CPXPARAM_Threads from the environment, so exporting it alone leaves every shard using the
# whole machine.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_oos.sh"

oos_require_preconditions
oos_resolve_julia

if [[ -z "${STRUCTURAL_MANIFEST_PATH:-}" ]]; then
  echo "ERROR: STRUCTURAL_MANIFEST_PATH es obligatorio." >&2
  echo "       Genérelo con scripts/oos/generate_structural_instance_manifest.sh" >&2
  exit 1
fi
if [[ ! -f "$STRUCTURAL_MANIFEST_PATH" ]]; then
  echo "ERROR: no existe el manifiesto: $STRUCTURAL_MANIFEST_PATH" >&2
  exit 1
fi

export STRUCTURAL_MANIFEST_PATH
export OOS_SHARD_ROOT="${OOS_SHARD_ROOT:-$RESULTS_OOS_DIR/campaign/shards}"
export OOS_SHARD_INDEX="${OOS_SHARD_INDEX:-1}"
export OOS_SHARDS="${OOS_SHARDS:-1}"
mkdir -p "$OOS_SHARD_ROOT"

# One thread everywhere. A shard is a scientific unit; its content must not vary with the
# machine's parallelism.
export OOS_SOLVER_THREADS="${OOS_SOLVER_THREADS:-1}"
export JULIA_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export OMP_NUM_THREADS=1

[[ -n "${OOS_REPLICATIONS:-}" ]] && export OOS_REPLICATIONS
[[ -n "${CONTROLLER_SET:-}" ]] && export CONTROLLER_SET
[[ -n "${FAIRNESS_SET:-}" ]] && export FAIRNESS_SET
[[ -n "${MULTISTAGE_BRANCHING:-}" ]] && export MULTISTAGE_BRANCHING
[[ -n "${TWO_STAGE_SCENARIOS:-}" ]] && export TWO_STAGE_SCENARIOS
[[ -n "${SOLVER_TIME_LIMIT_SEC:-}" ]] && export SOLVER_TIME_LIMIT_SEC
[[ -n "${SOLVER_MIP_GAP:-}" ]] && export SOLVER_MIP_GAP
[[ -n "${PEA_TOLERANCE_MODE:-}" ]] && export PEA_TOLERANCE_MODE
[[ -n "${OOS_WORKER:-}" ]] && export OOS_WORKER

echo "=== Shard de campaña OOS ==="
echo "julia      : ${JULIA_ARGV[*]}"
echo "manifiesto : $STRUCTURAL_MANIFEST_PATH"
echo "shard      : $OOS_SHARD_INDEX de $OOS_SHARDS"
echo "shard root : $OOS_SHARD_ROOT"
echo "hilos      : CPLEX=$OOS_SOLVER_THREADS (atributo) Julia=1 BLAS=1"
echo

"${JULIA_ARGV[@]}" "$CODES_DIR/oos_experiment/run_oos_task.jl"

echo
echo "Shard terminado. Fusione con scripts/oos/merge_oos_shards.sh cuando estén todos."
