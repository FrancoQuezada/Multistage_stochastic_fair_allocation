#!/usr/bin/env bash
# Export and inspect one representative model per major builder path.
#
# Covers the three controllers crossed with NONE, STATIC_DEMAND_SHARE, PEA, SA and the
# lexicographic PV and savings phase models. Files land in results_oos/model_audit/ and are
# never mixed with normal run outputs. Both the structural inspection (JuMP metadata and
# constraint coefficients) and the file inspection (name patterns) must pass.
#
# Usage:
#   FORMULATION_ID='shared_battery_mode_node_level_v1' \
#   bash scripts/oos/export_representative_models.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_oos.sh"

FORMULATION_ID="${FORMULATION_ID:-shared_battery_mode_node_level_v1}"
export FORMULATION_ID
export FORMULATION_VARIANT="${FORMULATION_VARIANT:-aggregate_only}"
export EXPERIMENT_SEED="${EXPERIMENT_SEED:-12345}"
export TREE_SET="${TREE_SET:-3:2:8}"
export J_SET="${J_SET:-5}"
export INST_FOLDER="${INST_FOLDER:-$DEFAULT_INST_FOLDER}"
export INSTANCE_FROM="${INSTANCE_FROM:-1}"
export TWO_STAGE_SCENARIOS="${TWO_STAGE_SCENARIOS:-5}"
export MULTISTAGE_BRANCHING="${MULTISTAGE_BRANCHING:-2,2}"
export OOS_OUTPUT_DIR="${OOS_OUTPUT_DIR:-$RESULTS_OOS_DIR}"
# The gate must exercise the SAME PEA policy the campaign runs: never validate one policy
# and run another.
export PEA_TOLERANCE_MODE="${PEA_TOLERANCE_MODE:-adaptive_minimum}"
# Absolute numerical allowance in kWh; same unit as epsilon_pea, not dimensionless.
export PEA_TOLERANCE_NUMERIC_EPS="${PEA_TOLERANCE_NUMERIC_EPS:-1e-6}"
export FAIRNESS_ABS_TOL="${FAIRNESS_ABS_TOL:-0.0}"
# Abstract temporal contract, in model periods. Forwarded only when set explicitly: the defaults
# are the Julia constants in codes/oos_experiment/types.jl, so the shell cannot drift from them.
[[ -n "${EVALUATION_HORIZON:-}" ]] && export EVALUATION_HORIZON
[[ -n "${LOOKAHEAD_HORIZON:-}" ]] && export LOOKAHEAD_HORIZON
[[ -n "${IMPLEMENTATION_STEP:-}" ]] && export IMPLEMENTATION_STEP

oos_resolve_julia

echo "=== Exportación e inspección de modelos representativos ($FORMULATION_ID) ==="
echo "destino: $OOS_OUTPUT_DIR/model_audit"
cd "$CODES_DIR"
"${JULIA_ARGV[@]}" -e '
include("oos_experiment/oos_experiment.jl")
using CSV, DataFrames

config = OOSExperimentConfig(
    experiment_seed=parse(Int, ENV["EXPERIMENT_SEED"]),
    oos_replications=1,
    # Abstract temporal contract; the defaults are the module constants, never re-declared here.
    evaluation_horizon=_env_int("EVALUATION_HORIZON", OOS_DEFAULT_EVALUATION_HORIZON),
    lookahead_horizon=_env_int("LOOKAHEAD_HORIZON", OOS_DEFAULT_LOOKAHEAD_HORIZON),
    implementation_step=_env_int("IMPLEMENTATION_STEP", OOS_DEFAULT_IMPLEMENTATION_STEP),
    controller_set=collect(instances(ControllerKind)),
    fairness_set=collect(instances(FairnessPolicy)),
    two_stage_scenarios=parse(Int, ENV["TWO_STAGE_SCENARIOS"]),
    multistage_branching=[parse(Int, strip(x)) for x in split(ENV["MULTISTAGE_BRANCHING"], ",") if !isempty(strip(x))],
    fairness_abs_tol=parse(Float64, get(ENV, "FAIRNESS_ABS_TOL", "0.0")),
    pea_tolerance_mode=Symbol(get(ENV, "PEA_TOLERANCE_MODE", "adaptive_minimum")),
    pea_tolerance_numeric_eps=parse(Float64, get(ENV, "PEA_TOLERANCE_NUMERIC_EPS", "1e-6")),
    formulation_id=ENV["FORMULATION_ID"],
    formulation_variant=Symbol(ENV["FORMULATION_VARIANT"]),
    output_directory=ENV["OOS_OUTPUT_DIR"],
    instance_file=joinpath(ENV["INST_FOLDER"], sort(readdir(ENV["INST_FOLDER"]))[parse(Int, ENV["INSTANCE_FROM"])]),
    households=first([parse(Int, strip(x)) for x in split(ENV["J_SET"], ",")]),
    in_sample_stages=parse(Int, split(ENV["TREE_SET"], ":")[1]),
    in_sample_children=parse(Int, split(ENV["TREE_SET"], ":")[2]),
    in_sample_periods_per_stage=parse(Int, split(ENV["TREE_SET"], ":")[3]),
    export_representative_models=true,
    require_shared_battery_validation=true,
)

common = build_common_objects(config; verbose=true)
audits = export_representative_models(config, common; verbose=true)
enforce_audit!(audits)

ensure_output_directory(config)
path = output_path(config, :model_audit)
CSV.write(path, model_audit_frame(config, audits))
println("Resumen de auditoría escrito en: ", path)
println("Efecto de tamaño: |V_mode| frente a |H||V_mode|")
for audit in audits
    println("  ", audit.label,
            " : binarios=", audit.generated_mode_binaries,
            ", |V_mode|=", audit.expected_mode_nodes,
            ", únicos nonanticipativos=", audit.unique_policy_modes,
            ", |H||V_mode| legacy=", audit.legacy_household_mode_binaries)
end
'
