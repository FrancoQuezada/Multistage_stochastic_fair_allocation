#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

DEFAULT_INST_FOLDER="inst/inst2020"
if [[ ! -d "$DEFAULT_INST_FOLDER" && -d "../inst/inst2020" ]]; then
  DEFAULT_INST_FOLDER="../inst/inst2020"
fi

INST_FOLDER="${INST_FOLDER:-$DEFAULT_INST_FOLDER}"
INSTANCE_FROM="${INSTANCE_FROM:-1}"
INSTANCE_TO="${INSTANCE_TO:-10}"
HEURISTIC_SET="${HEURISTIC_SET:-SA}"
TREE_SET="${TREE_SET:-6:4:4}"
J_SET="${J_SET:-5,10}"
THETA_SET="${THETA_SET:-0.2,0.6}"
AVG_D_SET="${AVG_D_SET:-100.0}"
DEV_D_SET="${DEV_D_SET:-10.0,20.0}"
DEMAND_PROFILE_SET="${DEMAND_PROFILE_SET:-mixed}"
BATTERY_SCALE_SET="${BATTERY_SCALE_SET:-1.0}"
PV_SCALE_SET="${PV_SCALE_SET:-1.0}"
ETA_SET="${ETA_SET:-1.0}"
OUT_CSV="${OUT_CSV:-constructive_heuristics_SA_S6_C4_P4.csv}"
OUT_CSV_HOUSE="${OUT_CSV_HOUSE:-constructive_heuristics_SA_S6_C4_P4_by_house.csv}"
OUT_CSV_DIAG="${OUT_CSV_DIAG:-constructive_heuristics_SA_S6_C4_P4_diagnostics.csv}"
OUT_CSV_DIAG_HOUSE="${OUT_CSV_DIAG_HOUSE:-constructive_heuristics_SA_S6_C4_P4_diagnostics_by_house.csv}"

export INST_FOLDER INSTANCE_FROM INSTANCE_TO HEURISTIC_SET TREE_SET
export J_SET THETA_SET AVG_D_SET DEV_D_SET DEMAND_PROFILE_SET
export BATTERY_SCALE_SET PV_SCALE_SET ETA_SET OUT_CSV OUT_CSV_HOUSE
export OUT_CSV_DIAG OUT_CSV_DIAG_HOUSE

julia --quiet --startup-file=no --history-file=no run_constructive_heuristics.jl
