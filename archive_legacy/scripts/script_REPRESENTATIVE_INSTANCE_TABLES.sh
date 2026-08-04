#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

INST_FILE="${INST_FILE:-inst/inst2020/Drahi_1.csv}"
NBSTAGE="${NBSTAGE:-6}"
CHILDS="${CHILDS:-4}"
PERIODS="${PERIODS:-4}"
J_SET="${J_SET:-5,10}"
THETA_SET="${THETA_SET:-0.2,0.6}"
AVG_D="${AVG_D:-100.0}"
DEV_D="${DEV_D:-10.0}"
FAIRNESS_SET="${FAIRNESS_SET:-NONE,PEA,SA,LEXMMFPEA,LEXMMFSA}"
BATTERY_SCALE="${BATTERY_SCALE:-1.0}"
PV_SCALE="${PV_SCALE:-1.0}"

OUT_DETAIL_CSV="${OUT_DETAIL_CSV:-representative_instance_house_metrics.csv}"
OUT_AUTONOMY_CSV="${OUT_AUTONOMY_CSV:-representative_instance_pv_autonomy_summary.csv}"
OUT_SAVINGS_CSV="${OUT_SAVINGS_CSV:-representative_instance_savings_summary.csv}"
OUT_TEX="${OUT_TEX:-representative_instance_tables.tex}"

export INST_FILE NBSTAGE CHILDS PERIODS J_SET THETA_SET AVG_D DEV_D FAIRNESS_SET
export BATTERY_SCALE PV_SCALE OUT_DETAIL_CSV OUT_AUTONOMY_CSV OUT_SAVINGS_CSV OUT_TEX

exec julia --quiet --startup-file=no --history-file=no run_representative_instance_tables.jl
