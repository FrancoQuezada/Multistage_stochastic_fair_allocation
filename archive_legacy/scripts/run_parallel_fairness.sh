#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# -----------------------
# Config comun (se hereda a todos los scripts por par fairness/arbol)
# Puedes sobreescribir por ENV al ejecutar.
# -----------------------
INST_FOLDER="${INST_FOLDER:-inst/inst2020}"
INSTANCE_FROM="${INSTANCE_FROM:-1}"
INSTANCE_TO="${INSTANCE_TO:-10}"
TREE_LIST="${TREE_LIST:-6:2:4,6:4:4,8:2:3}"
FAIRNESS_LIST="${FAIRNESS_LIST:-NONE,PEA,SA,LEXMMFPEA,LEXMMFSA}"
J_SET="${J_SET:-5,10}"
THETA_SET="${THETA_SET:-0.2,0.6}"
AVG_D_SET="${AVG_D_SET:-100.0}"
DEV_D_SET="${DEV_D_SET:-10.0,20.0}"
BATTERY_SCALE_SET="${BATTERY_SCALE_SET:-1.0}"
PV_SCALE_SET="${PV_SCALE_SET:-1.0}"

export INST_FOLDER INSTANCE_FROM INSTANCE_TO
export J_SET THETA_SET AVG_D_SET DEV_D_SET BATTERY_SCALE_SET PV_SCALE_SET

# Directorio de logs
LOG_DIR="${LOG_DIR:-logs_parallel}"
mkdir -p "$LOG_DIR"
DRY_RUN="${DRY_RUN:-0}"

split_csv_nonempty() {
  local input="$1"
  local -n out_ref="$2"
  local item
  IFS=',' read -r -a out_ref <<<"$input"
  local cleaned=()
  for item in "${out_ref[@]}"; do
    item="$(echo "$item" | xargs)"
    [[ -n "$item" ]] && cleaned+=("$item")
  done
  out_ref=("${cleaned[@]}")
}

split_csv_nonempty "$FAIRNESS_LIST" fairness_list
split_csv_nonempty "$TREE_LIST" tree_list

if [[ "${#fairness_list[@]}" -eq 0 ]]; then
  echo "ERROR: FAIRNESS_LIST vacia." >&2
  exit 1
fi
if [[ "${#tree_list[@]}" -eq 0 ]]; then
  echo "ERROR: TREE_LIST vacia." >&2
  exit 1
fi

declare -A pids
declare -A run_keys
cmd_count=0
if [[ "$DRY_RUN" == "1" ]]; then
  echo "Dry-run mode: printing commands without execution."
else
  echo "Launching fairness/tree scripts in parallel..."
fi

for fairness in "${fairness_list[@]}"; do
  for tree in "${tree_list[@]}"; do
    if [[ "$tree" != *:*:* ]]; then
      echo "ERROR: TREE_LIST invalida en '$tree'. Usa formato S:C:P." >&2
      exit 1
    fi
    IFS=':' read -r s c p <<<"$tree"
    script="script_${fairness}_S${s}_C${c}_P${p}.sh"
    log_file="$LOG_DIR/${fairness}_S${s}_C${c}_P${p}.log"
    run_key="${fairness}|${tree}"

    if [[ ! -x "$SCRIPT_DIR/$script" ]]; then
      echo "ERROR: missing executable $script" >&2
      exit 1
    fi

    echo "  - $fairness / $tree -> $script (log: $log_file)"
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "CMD: $SCRIPT_DIR/$script > $log_file 2>&1 &"
      cmd_count=$((cmd_count + 1))
    else
      "$SCRIPT_DIR/$script" >"$log_file" 2>&1 &
      pids["$run_key"]=$!
      run_keys["$run_key"]="$log_file"
    fi
  done
done

if [[ "$DRY_RUN" == "1" ]]; then
  echo "Dry-run completed. Commands printed: $cmd_count"
  exit 0
fi

echo "Waiting for all scripts..."
failed=0
for run_key in "${!pids[@]}"; do
  pid="${pids[$run_key]}"
  log_file="${run_keys[$run_key]}"
  if wait "$pid"; then
    echo "[OK] $run_key finished"
  else
    echo "[FAIL] $run_key failed (see $log_file)" >&2
    failed=1
  fi
done

if [[ "$failed" -ne 0 ]]; then
  echo "At least one fairness run failed." >&2
  exit 1
fi

echo "All fairness runs completed successfully."
