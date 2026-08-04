#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"
LOG_DIR="${LOG_DIR:-$RESULTS_SENSITIVITY_DIR/logs_sensitivity_battery_parallel}"
mkdir -p "$LOG_DIR"
scripts=(
  script_SENSITIVITY_BATTERY_NONE_S6_C4_P4.sh
  script_SENSITIVITY_BATTERY_PEA_S6_C4_P4.sh
  script_SENSITIVITY_BATTERY_SA_S6_C4_P4.sh
  script_SENSITIVITY_BATTERY_LEXMMFPEA_S6_C4_P4.sh
  script_SENSITIVITY_BATTERY_LEXMMFSA_S6_C4_P4.sh
)
pids=()
for s in "${scripts[@]}"; do bash "$SCRIPT_DIR/$s" >"$LOG_DIR/${s%.sh}.log" 2>&1 & pids+=("$!"); done
status=0
for pid in "${pids[@]}"; do wait "$pid" || status=1; done
[[ $status -eq 0 ]] || exit $status
bash "$SCRIPT_DIR/merge_sensitivity_battery_reports.sh"
