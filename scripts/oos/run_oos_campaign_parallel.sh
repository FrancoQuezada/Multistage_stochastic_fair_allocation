#!/usr/bin/env bash
# Full out-of-sample campaign, parallel: one call instead of three.
#
# Wraps, in order: generate_structural_instance_manifest.sh -> N x run_oos_task.sh (background,
# one process per shard) -> merge_oos_shards.sh. Each of the three is already idempotent on its
# own; this script adds nothing but the sequencing, the fan-out and a fail-fast check that no
# shard process died before merging.
#
# Usage:
#   FORMULATION_ID='shared_battery_mode_node_level_v1' \
#   INSTANCE_DRAWS_PER_CELL=2 LOW_BATTERY_SCALE=0.5 HIGH_BATTERY_SCALE=2.0 \
#   LOW_UNCERTAINTY_THETA=0.1 HIGH_UNCERTAINTY_THETA=0.4 \
#   OOS_REPLICATIONS=10 EVALUATION_HORIZON=24 LOOKAHEAD_HORIZON=24 IMPLEMENTATION_STEP=4 \
#   MULTISTAGE_BRANCHING='5:4:4' \
#   OOS_SHARDS=8 \
#   bash scripts/oos/run_oos_campaign_parallel.sh
# 
# OOS_SHARDS defaults to `nproc` (this machine's core count) if unset — override it to leave
# headroom or to match a smaller allocation. STRUCTURAL_MANIFEST_PATH, OOS_SHARD_ROOT and
# OOS_MERGED_DIR default under results_oos/campaign/ and are shared automatically across the
# three steps; override any of them to point at a fresh campaign directory.
#
# INSTANCE_DRAWS_PER_CELL, LOW/HIGH_BATTERY_SCALE and LOW/HIGH_UNCERTAINTY_THETA have
# deliberately NO default here, for the same reason generate_structural_instance_manifest.sh
# refuses one: a default would read as a calibrated recommendation, which only Stage 12 can give.
#
# CONTROLLER_SET, FAIRNESS_SET, TWO_STAGE_SCENARIOS and every other run_oos_task.sh option are
# simply inherited from this process's environment by each shard, exactly as if you had exported
# them before calling run_oos_task.sh yourself.
#
# Re-running after a partial failure is safe: completed shards are idempotent and skip re-work,
# so only the shards that did not finish actually redo anything.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_oos.sh"

oos_require_preconditions

export STRUCTURAL_MANIFEST_PATH="${STRUCTURAL_MANIFEST_PATH:-$RESULTS_OOS_DIR/campaign/structural_manifest.json}"
export OOS_SHARD_ROOT="${OOS_SHARD_ROOT:-$RESULTS_OOS_DIR/campaign/shards}"
export OOS_MERGED_DIR="${OOS_MERGED_DIR:-$RESULTS_OOS_DIR/campaign/merged}"
OOS_SHARDS="${OOS_SHARDS:-$(nproc)}"

echo "======================================================================"
echo " Campaña OOS en paralelo"
echo " formulation_id    : $FORMULATION_ID"
echo " manifiesto        : $STRUCTURAL_MANIFEST_PATH"
echo " shard root        : $OOS_SHARD_ROOT"
echo " salida fusionada  : $OOS_MERGED_DIR"
echo " procesos (shards) : $OOS_SHARDS"
echo "======================================================================"

echo
echo "--- 1/3: manifiesto de instancias estructurales ---"
bash "$SCRIPT_DIR/generate_structural_instance_manifest.sh"

echo
echo "--- 2/3: $OOS_SHARDS procesos en paralelo ---"
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/oos_campaign_shard_logs.XXXXXX")"
echo "logs de shard en: $LOG_DIR"
declare -a PIDS=()
for i in $(seq 1 "$OOS_SHARDS"); do
  OOS_SHARD_INDEX="$i" OOS_SHARDS="$OOS_SHARDS" \
    bash "$SCRIPT_DIR/run_oos_task.sh" > "$LOG_DIR/shard-$i.log" 2>&1 &
  PIDS+=("$!")
done

FAILED_SHARDS=0
for index in "${!PIDS[@]}"; do
  shard=$((index + 1))
  if ! wait "${PIDS[$index]}"; then
    echo "  [FALLA] shard $shard: ver $LOG_DIR/shard-$shard.log" >&2
    FAILED_SHARDS=$((FAILED_SHARDS + 1))
  fi
done

if [[ "$FAILED_SHARDS" -gt 0 ]]; then
  echo "ERROR: $FAILED_SHARDS de $OOS_SHARDS shards fallaron. No se fusiona un conjunto incompleto." >&2
  echo "       Revisá los logs en $LOG_DIR y volvé a correr este script: los shards ya" >&2
  echo "       comprometidos son idempotentes, así que solo se reintentan los que faltan." >&2
  exit 1
fi

echo
echo "--- 3/3: fusión determinista ---"
bash "$SCRIPT_DIR/merge_oos_shards.sh"

echo
echo "Campaña completa. Dataset fusionado en: $OOS_MERGED_DIR"
