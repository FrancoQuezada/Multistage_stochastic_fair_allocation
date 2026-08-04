#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"
cd "$CODES_DIR"

TREE_SET="${TREE_SET:-2:2:12;6:4:4}"
INST_FOLDER="${INST_FOLDER:-$DEFAULT_INST_FOLDER}"
INSTANCES_PER_TREE="${INSTANCES_PER_TREE:-5}"
INSTANCE_SAMPLE_SEED="${INSTANCE_SAMPLE_SEED:-20260804}"
CONDITIONAL_STAGE_SET="${CONDITIONAL_STAGE_SET:-2,3,4,5,6}"
J_SET="${J_SET:-5}"
THETA_SET="${THETA_SET:-0.2}"
AVG_D_SET="${AVG_D_SET:-100.0}"
DEV_D_SET="${DEV_D_SET:-10.0}"
DEMAND_PROFILE_SET="${DEMAND_PROFILE_SET:-mixed}"
BATTERY_SCALE_SET="${BATTERY_SCALE_SET:-1.0}"
PV_SCALE_SET="${PV_SCALE_SET:-1.0}"
FAIRNESS_MMR="${FAIRNESS_MMR:-1.2}"
LEX_EPS_ABS="${LEX_EPS_ABS:-1.0}"
MAX_PARALLEL_POLICIES="${MAX_PARALLEL_POLICIES:-15}"
CPLEX_THREADS="${CPLEX_THREADS:-1}"
REBUILD_MANIFEST="${REBUILD_MANIFEST:-false}"
RUN_VALIDATION_AFTER_MERGE="${RUN_VALIDATION_AFTER_MERGE:-true}"
VALIDATION_MODE="${VALIDATION_MODE:-main}"
VALIDATE_STAGE1_EQUIVALENCE="${VALIDATE_STAGE1_EQUIVALENCE:-true}"
FAIRNESS_COMPARISON_DIR="${FAIRNESS_COMPARISON_DIR:-$RESULTS_MODELS_DIR/fairness_comparison}"
MANIFEST_PATH="${MANIFEST_PATH:-$FAIRNESS_COMPARISON_DIR/config_manifest.csv}"
REFERENCE_HASHES_PATH="${REFERENCE_HASHES_PATH:-$RESULTS_MODELS_DIR/fairness_comparison/source_hashes_before.txt}"

(( MAX_PARALLEL_POLICIES >= 1 && MAX_PARALLEL_POLICIES <= 15 )) || {
  echo "ERROR: MAX_PARALLEL_POLICIES debe estar entre 1 y 15." >&2
  exit 2
}
(( CPLEX_THREADS >= 1 )) || {
  echo "ERROR: CPLEX_THREADS debe ser positivo." >&2
  exit 2
}

mkdir -p "$FAIRNESS_COMPARISON_DIR/baseline" "$FAIRNESS_COMPARISON_DIR/by_policy" "$FAIRNESS_COMPARISON_DIR/consolidated"

export TREE_SET INSTANCES_PER_TREE INSTANCE_SAMPLE_SEED CONDITIONAL_STAGE_SET
export J_SET THETA_SET AVG_D_SET DEV_D_SET DEMAND_PROFILE_SET BATTERY_SCALE_SET PV_SCALE_SET
export FAIRNESS_MMR LEX_EPS_ABS MAX_PARALLEL_POLICIES CPLEX_THREADS REBUILD_MANIFEST
export FAIRNESS_COMPARISON_DIR MANIFEST_PATH VALIDATION_MODE VALIDATE_STAGE1_EQUIVALENCE
export REFERENCE_HASHES_PATH INST_FOLDER

julia --quiet --startup-file=no --history-file=no build_fairness_comparison_manifest.jl

CPLEX_PARAMETER_FILE="$FAIRNESS_COMPARISON_DIR/cplex_threads_${CPLEX_THREADS}.prm"
export CPLEX_PARAMETER_FILE
julia --quiet --startup-file=no --history-file=no -e '
include("fairness_comparison_metrics.jl")
write_cplex_thread_parameter_file(ENV["CPLEX_PARAMETER_FILE"], parse(Int, ENV["CPLEX_THREADS"]))
'
export ILOG_CPLEX_PARAMETER_FILE="$CPLEX_PARAMETER_FILE"
export OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1

declare -A WORKER_STATUS
BASELINE_LOG="$FAIRNESS_COMPARISON_DIR/baseline/execution.log"
if julia --quiet --startup-file=no --history-file=no run_none_baseline_worker.jl >"$BASELINE_LOG" 2>&1; then
  WORKER_STATUS[NONE]=0
else
  WORKER_STATUS[NONE]=$?
  echo "ERROR: el worker NONE falló; consulta $BASELINE_LOG" >&2
fi

STATUS_PATH="$FAIRNESS_COMPARISON_DIR/worker_exit_status.csv"
write_status_file() {
  local temporary="${STATUS_PATH}.tmp.$$"
  printf 'Worker,ExitCode,LogFile\n' >"$temporary"
  printf 'NONE,%s,%s\n' "${WORKER_STATUS[NONE]}" "$BASELINE_LOG" >>"$temporary"
  for policy in "${POLICIES[@]}"; do
    if [[ -n "${WORKER_STATUS[$policy]+x}" ]]; then
      printf '%s,%s,%s\n' "$policy" "${WORKER_STATUS[$policy]}" "$FAIRNESS_COMPARISON_DIR/by_policy/$policy/execution.log" >>"$temporary"
    fi
  done
  mv -f "$temporary" "$STATUS_PATH"
}

if [[ "${WORKER_STATUS[NONE]}" -ne 0 ]]; then
  POLICIES=()
  write_status_file
  exit "${WORKER_STATUS[NONE]}"
fi

POLICIES=(
  PEA SA LEXMMFPEA LEXMMFSA
  ERDINC_PSR ERDINC_ESR ERDINC_PESR ERDINC_PC ERDINC_EC ERDINC_PEC
  STATIC_DEMAND_SHARE CPEA CSA CLEXMMFPEA CLEXMMFSA
)

wait_batch() {
  local -n batch_pids_ref=$1
  local -n batch_names_ref=$2
  local idx policy pid
  for idx in "${!batch_pids_ref[@]}"; do
    pid="${batch_pids_ref[$idx]}"
    policy="${batch_names_ref[$idx]}"
    if wait "$pid"; then
      WORKER_STATUS[$policy]=0
    else
      WORKER_STATUS[$policy]=$?
      echo "ERROR: worker $policy falló; consulta $FAIRNESS_COMPARISON_DIR/by_policy/$policy/execution.log" >&2
    fi
  done
  batch_pids_ref=()
  batch_names_ref=()
}

batch_pids=()
batch_names=()
for policy in "${POLICIES[@]}"; do
  policy_dir="$FAIRNESS_COMPARISON_DIR/by_policy/$policy"
  mkdir -p "$policy_dir"
  POLICY="$policy" julia --quiet --startup-file=no --history-file=no \
    run_fairness_policy_worker.jl >"$policy_dir/execution.log" 2>&1 &
  batch_pids+=("$!")
  batch_names+=("$policy")
  if (( ${#batch_pids[@]} >= MAX_PARALLEL_POLICIES )); then
    wait_batch batch_pids batch_names
  fi
done
if (( ${#batch_pids[@]} > 0 )); then
  wait_batch batch_pids batch_names
fi

write_status_file
failed_workers=()
for policy in NONE "${POLICIES[@]}"; do
  if [[ "${WORKER_STATUS[$policy]}" -ne 0 ]]; then
    failed_workers+=("$policy")
  fi
done

if (( ${#failed_workers[@]} > 0 )); then
  failed_path="$FAIRNESS_COMPARISON_DIR/failed_runs.csv"
  temporary="${failed_path}.tmp.$$"
  printf 'ConfigID,Fairness,ConditionalStage,FailureReason,WorkerExitCode\n' >"$temporary"
  for policy in "${failed_workers[@]}"; do
    printf ',%s,,worker_exit_code,%s\n' "$policy" "${WORKER_STATUS[$policy]}" >>"$temporary"
  done
  mv -f "$temporary" "$failed_path"
  echo "Workers fallidos: ${failed_workers[*]}" >&2
  echo "No se ejecuta la consolidación porque hubo fallos." >&2
  exit 1
fi

julia --quiet --startup-file=no --history-file=no merge_fairness_comparison.jl

if [[ "${RUN_VALIDATION_AFTER_MERGE,,}" == "true" ]]; then
  julia --quiet --startup-file=no --history-file=no validate_fairness_comparison.jl \
    2>&1 | tee "$FAIRNESS_COMPARISON_DIR/validation.log"
fi

echo "Experimento comparativo completado en: $FAIRNESS_COMPARISON_DIR"
