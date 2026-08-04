#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

FAIRNESS_SET="SA"
TREE_SET="6:2:4"
INSTANCE_FROM="${INSTANCE_FROM:-1}"
INSTANCE_TO="${INSTANCE_TO:-10}"
J_SET="${J_SET:-5,10}"
THETA_SET="${THETA_SET:-0.2,0.6}"
AVG_D_SET="${AVG_D_SET:-100.0}"
DEV_D_SET="${DEV_D_SET:-10.0,20.0}"
OUT_CSV="${OUT_CSV:-fairness_SA_report_test.csv}"
OUT_CSV_HOUSE="${OUT_CSV_HOUSE:-fairness_SA_report_by_house_test.csv}"

SCRIPT_NAME="script_SA_S6_C2_P4.sh"
export SCRIPT_NAME FAIRNESS_SET TREE_SET INSTANCE_FROM INSTANCE_TO
export J_SET THETA_SET AVG_D_SET DEV_D_SET OUT_CSV OUT_CSV_HOUSE

exec "$SCRIPT_DIR/script.sh" "$@"
