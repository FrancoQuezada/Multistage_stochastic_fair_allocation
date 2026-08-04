#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

INST_FOLDER="${INST_FOLDER:-inst/inst2020}"
INSTANCE_FROM="${INSTANCE_FROM:-1}"
INSTANCE_TO="${INSTANCE_TO:-10}"
NBSTAGE="${NBSTAGE:-8}"
CHILDS="${CHILDS:-2}"
PERIODS="${PERIODS:-3}"
J_SET="${J_SET:-5,10}"
THETA_SET="${THETA_SET:-0.2,0.6}"
AVG_D_SET="${AVG_D_SET:-100.0}"
DEV_D_SET="${DEV_D_SET:-10.0,20.0}"
OUT_CSV="${OUT_CSV:-vss_none_S8_C2_P3.csv}"

export INST_FOLDER INSTANCE_FROM INSTANCE_TO NBSTAGE CHILDS PERIODS
export J_SET THETA_SET AVG_D_SET DEV_D_SET OUT_CSV

exec julia --quiet run_vss_none_experiments.jl
