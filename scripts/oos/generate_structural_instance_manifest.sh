#!/usr/bin/env bash
# Generate the canonical structural-instance manifest (redesign stage 3, schema v2).
#
# Builds the B x 2 x 2 x 2 x K factorial catalog of structural instances, materializes each one
# through the repository's verified instance pipeline, validates every internal invariant and
# writes the manifest atomically. It runs NO out-of-sample campaign and generates no scenario
# support.
#
# The four numeric factor levels and K are REQUIRED and have no defaults on purpose: stage 12
# calibrates them, so a default here would read as a calibrated recommendation.
#
# Usage:
#   INSTANCE_DRAWS_PER_CELL=2 \
#   LOW_BATTERY_SCALE=0.5 HIGH_BATTERY_SCALE=2.0 \
#   LOW_UNCERTAINTY_THETA=0.1 HIGH_UNCERTAINTY_THETA=0.4 \
#   STRUCTURAL_MANIFEST_PATH=results_oos_structural/structural_instance_manifest.json \
#   bash scripts/oos/generate_structural_instance_manifest.sh
#
# The values above are illustrative fixtures, NOT campaign levels.
#
# Optional: STRUCTURAL_BASE_INSTANCES (comma-separated) or INST_FOLDER/INSTANCE_FROM/INSTANCE_TO;
# EXPERIMENT_SEED, J_SET, AVG_D_SET, DEV_D_SET, PV_SCALE_SET, TREE_SET, OOS_REPLICATIONS,
# EVALUATION_HORIZON, LOOKAHEAD_HORIZON, IMPLEMENTATION_STEP, REPOSITORY_DEMAND_PROFILE,
# STRUCTURAL_MANIFEST_OVERWRITE, STRUCTURAL_MANIFEST_COMPANIONS.
#
# An existing manifest with identical content is an idempotent no-op. Conflicting content fails
# unless STRUCTURAL_MANIFEST_OVERWRITE=1, so a different manifest is never silently replaced.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_oos.sh"

oos_resolve_julia

for required in INSTANCE_DRAWS_PER_CELL LOW_BATTERY_SCALE HIGH_BATTERY_SCALE \
                LOW_UNCERTAINTY_THETA HIGH_UNCERTAINTY_THETA STRUCTURAL_MANIFEST_PATH; do
  if [[ -z "${!required:-}" ]]; then
    echo "ERROR: $required es obligatorio." >&2
    echo "       El catálogo estructural no tiene valores por defecto para los niveles" >&2
    echo "       numéricos de los factores ni para K: la etapa 12 los calibra." >&2
    exit 1
  fi
  export "$required"
done

# The manifest is a standalone artefact. Refuse to drop it inside a pre-existing results
# directory that belongs to another workflow.
MANIFEST_DIR="$(dirname "$STRUCTURAL_MANIFEST_PATH")"
mkdir -p "$MANIFEST_DIR"
MANIFEST_DIR_RESOLVED="$(cd "$MANIFEST_DIR" && pwd)"
for protected in "${OOS_PROTECTED_DIRS[@]}"; do
  [[ -d "$protected" ]] || continue
  if [[ "$MANIFEST_DIR_RESOLVED" == "$(cd "$protected" && pwd)" ]]; then
    echo "ERROR: STRUCTURAL_MANIFEST_PATH apunta a '$protected', que pertenece a un flujo existente." >&2
    exit 1
  fi
done

# Forwarded only when explicitly set, so the shell never re-declares a Julia-side default.
[[ -n "${STRUCTURAL_BASE_INSTANCES:-}" ]] && export STRUCTURAL_BASE_INSTANCES
[[ -n "${INST_FOLDER:-}" ]] && export INST_FOLDER
[[ -n "${INSTANCE_FROM:-}" ]] && export INSTANCE_FROM
[[ -n "${INSTANCE_TO:-}" ]] && export INSTANCE_TO
[[ -n "${EXPERIMENT_SEED:-}" ]] && export EXPERIMENT_SEED
[[ -n "${J_SET:-}" ]] && export J_SET
[[ -n "${AVG_D_SET:-}" ]] && export AVG_D_SET
[[ -n "${DEV_D_SET:-}" ]] && export DEV_D_SET
[[ -n "${PV_SCALE_SET:-}" ]] && export PV_SCALE_SET
[[ -n "${TREE_SET:-}" ]] && export TREE_SET
[[ -n "${OOS_REPLICATIONS:-}" ]] && export OOS_REPLICATIONS
[[ -n "${EVALUATION_HORIZON:-}" ]] && export EVALUATION_HORIZON
[[ -n "${LOOKAHEAD_HORIZON:-}" ]] && export LOOKAHEAD_HORIZON
[[ -n "${IMPLEMENTATION_STEP:-}" ]] && export IMPLEMENTATION_STEP
[[ -n "${REPOSITORY_DEMAND_PROFILE:-}" ]] && export REPOSITORY_DEMAND_PROFILE
[[ -n "${STRUCTURAL_MANIFEST_OVERWRITE:-}" ]] && export STRUCTURAL_MANIFEST_OVERWRITE
[[ -n "${STRUCTURAL_MANIFEST_COMPANIONS:-}" ]] && export STRUCTURAL_MANIFEST_COMPANIONS
[[ -n "${FORMULATION_ID:-}" ]] && export FORMULATION_ID

echo "=== Manifiesto de instancias estructurales ==="
echo "julia    : ${JULIA_ARGV[*]}"
echo "destino  : $STRUCTURAL_MANIFEST_PATH"
echo "niveles  : batería LOW=$LOW_BATTERY_SCALE HIGH=$HIGH_BATTERY_SCALE"
echo "           theta   LOW=$LOW_UNCERTAINTY_THETA HIGH=$HIGH_UNCERTAINTY_THETA"
echo "           K=$INSTANCE_DRAWS_PER_CELL   [PROVISIONAL, sin calibrar: etapa 12]"

"${JULIA_ARGV[@]}" "$CODES_DIR/oos_experiment/generate_structural_instance_manifest.jl"

echo
echo "El manifiesto estructural quedó escrito y validado."
echo "Es el contrato de catálogo, datos y semillas de la campaña: scripts/oos/run_oos_task.sh"
echo "enumera sus tareas desde aquí y se niega a correr si el catálogo regenerado no coincide."
