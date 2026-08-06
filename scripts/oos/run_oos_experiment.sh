#!/usr/bin/env bash
# Full out-of-sample receding-horizon campaign.
#
# Usage:
#   FORMULATION_ID='shared_battery_mode_node_level_v1' \
#   OOS_REPLICATIONS=1000 \
#   CONTROLLER_SET='DETERMINISTIC_RH,TWO_STAGE_RH,MULTISTAGE_RH' \
#   FAIRNESS_SET='NONE,STATIC_DEMAND_SHARE,PEA,SA,LEXMMFPEA,LEXMMFSA' \
#   TWO_STAGE_SCENARIOS=100 \
#   MULTISTAGE_BRANCHING='4,4' \
#   EXPERIMENT_SEED=12345 \
#   PEA_TOLERANCE_MODE=adaptive_minimum \
#   REQUIRE_SHARED_BATTERY_VALIDATION=1 \
#   EXPORT_REPRESENTATIVE_MODELS=1 \
#   bash scripts/oos/run_oos_experiment.sh
#
# Refuses to start when the formulation ID is missing, when the validation gate is disabled
# without an explicit acknowledgement, or when the output directory belongs to an existing
# workflow. Representative-model inspection failures and inconsistent battery physics abort
# inside Julia, before any configuration runs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_oos.sh"

oos_require_preconditions
oos_resolve_julia

export INST_FOLDER="${INST_FOLDER:-$DEFAULT_INST_FOLDER}"
export INSTANCE_FROM="${INSTANCE_FROM:-1}"
export INSTANCE_TO="${INSTANCE_TO:-$INSTANCE_FROM}"
export TREE_SET="${TREE_SET:-3:2:8}"
export J_SET="${J_SET:-5}"
export THETA_SET="${THETA_SET:-0.2}"
export AVG_D_SET="${AVG_D_SET:-100.0}"
export DEV_D_SET="${DEV_D_SET:-10.0}"
export DEMAND_PROFILE_SET="${DEMAND_PROFILE_SET:-mixed}"
export BATTERY_SCALE_SET="${BATTERY_SCALE_SET:-1.0}"
export PV_SCALE_SET="${PV_SCALE_SET:-1.0}"

export FORMULATION_ID
export FORMULATION_VARIANT="${FORMULATION_VARIANT:-aggregate_only}"
export EXPERIMENT_ID="${EXPERIMENT_ID:-oos_experiment}"
export EXPERIMENT_SEED="${EXPERIMENT_SEED:-12345}"
export OOS_REPLICATIONS="${OOS_REPLICATIONS:-20}"
export CONTROLLER_SET="${CONTROLLER_SET:-DETERMINISTIC_RH,TWO_STAGE_RH,MULTISTAGE_RH}"
export FAIRNESS_SET="${FAIRNESS_SET:-NONE,STATIC_DEMAND_SHARE,PEA,SA,LEXMMFPEA,LEXMMFSA}"
export TWO_STAGE_SCENARIOS="${TWO_STAGE_SCENARIOS:-20}"
export MULTISTAGE_BRANCHING="${MULTISTAGE_BRANCHING:-2,2}"
export MULTISTAGE_PERIODS_PER_STAGE="${MULTISTAGE_PERIODS_PER_STAGE:-}"
# PEA policy: strict equality first, endogenous minimum band only after a PROVEN fairness
# infeasibility. FAIRNESS_ABS_TOL is deprecated as a fixed economic band and must stay 0.0
# unless PEA_TOLERANCE_MODE=fixed_band is selected explicitly.
export PEA_TOLERANCE_MODE="${PEA_TOLERANCE_MODE:-adaptive_minimum}"
# Absolute numerical allowance in kWh (same unit as epsilon_pea), used only in the Phase-II
# cap  epsilon_pea <= epsilon_pea_star + eps.  It is not dimensionless and not an economic band.
export PEA_TOLERANCE_NUMERIC_EPS="${PEA_TOLERANCE_NUMERIC_EPS:-1e-6}"
export FAIRNESS_ABS_TOL="${FAIRNESS_ABS_TOL:-0.0}"
export SA_FAIRNESS_ABS_TOL="${SA_FAIRNESS_ABS_TOL:-1.0}"
export LEX_EPS_ABS="${LEX_EPS_ABS:-1.0}"
# Tolerance defaults live in codes/oos_experiment/types.jl (OOS_DEFAULT_*). They are forwarded
# only when the caller sets them explicitly, so the shell cannot drift from the Julia default.
[[ -n "${FLOW_TOL:-}" ]] && export FLOW_TOL
[[ -n "${FEASIBILITY_TOL:-}" ]] && export FEASIBILITY_TOL
[[ -n "${INTEGRALITY_TOL:-}" ]] && export INTEGRALITY_TOL
export SOLVER_TIME_LIMIT_SEC="${SOLVER_TIME_LIMIT_SEC:-600.0}"
export SOLVER_THREADS="${SOLVER_THREADS:-0}"
export USE_WARM_STARTS="${USE_WARM_STARTS:-0}"
export ALLOW_LEGACY_CONVERSION="${ALLOW_LEGACY_CONVERSION:-0}"
export EXPORT_REPRESENTATIVE_MODELS="${EXPORT_REPRESENTATIVE_MODELS:-1}"
export REQUIRE_SHARED_BATTERY_VALIDATION="${REQUIRE_SHARED_BATTERY_VALIDATION:-1}"
export OOS_OUTPUT_DIR="${OOS_OUTPUT_DIR:-$RESULTS_OOS_DIR}"
export PROMPT_VERSION="${PROMPT_VERSION:-oos_receding_horizon_prompt_v1}"

echo "=== Campaña fuera de muestra ==="
echo "formulation_id      : $FORMULATION_ID"
echo "formulation_variant : $FORMULATION_VARIANT"
echo "controladores       : $CONTROLLER_SET"
echo "reglas de equidad   : $FAIRNESS_SET"
echo "política PEA        : $PEA_TOLERANCE_MODE (eps numérico $PEA_TOLERANCE_NUMERIC_EPS kWh)"
echo "réplicas OOS        : $OOS_REPLICATIONS"
echo "salida              : $OOS_OUTPUT_DIR"
echo "julia               : ${JULIA_ARGV[*]}"

cd "$CODES_DIR"
"${JULIA_ARGV[@]}" -e '
include("oos_experiment/oos_experiment.jl")
config = oos_config_from_environment()
run_oos_experiment(config; verbose=true)
'
