#!/usr/bin/env bash
# Deterministic merge of a campaign's shards into one analyzable dataset.
#
# Refuses to produce anything while the shard set is incomplete, duplicated or in conflict, and
# fuses in canonical manifest order rather than completion order, so the merged bytes do not
# depend on how the campaign was scheduled. The campaign aggregates are recomputed here from the
# merged replication-level rows — they cannot be concatenated out of the shards.
#
# Usage:
#   STRUCTURAL_MANIFEST_PATH=results_oos/campaign/structural_manifest.json \
#   OOS_SHARD_ROOT=results_oos/campaign/shards \
#   OOS_MERGED_DIR=results_oos/campaign/merged \
#   FORMULATION_ID='shared_battery_mode_node_level_v1' \
#   bash scripts/oos/merge_oos_shards.sh
#
# Exits non-zero when the merge is refused or when the merged dataset fails schema validation or
# the independent recomputation from the raw period rows.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_oos.sh"

oos_require_preconditions
oos_resolve_julia

if [[ -z "${STRUCTURAL_MANIFEST_PATH:-}" ]]; then
  echo "ERROR: STRUCTURAL_MANIFEST_PATH es obligatorio; debe ser el mismo manifiesto con el que se corrieron los shards." >&2
  exit 1
fi
if [[ ! -f "$STRUCTURAL_MANIFEST_PATH" ]]; then
  echo "ERROR: no existe el manifiesto: $STRUCTURAL_MANIFEST_PATH" >&2
  exit 1
fi

export STRUCTURAL_MANIFEST_PATH
export OOS_SHARD_ROOT="${OOS_SHARD_ROOT:-$RESULTS_OOS_DIR/campaign/shards}"
export OOS_MERGED_DIR="${OOS_MERGED_DIR:-$RESULTS_OOS_DIR/campaign/merged}"

if [[ ! -d "$OOS_SHARD_ROOT" ]]; then
  echo "ERROR: no existe la raíz de shards: $OOS_SHARD_ROOT" >&2
  exit 1
fi

export JULIA_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1

[[ -n "${OOS_REPLICATIONS:-}" ]] && export OOS_REPLICATIONS

echo "=== Merge de shards de campaña OOS ==="
echo "julia      : ${JULIA_ARGV[*]}"
echo "manifiesto : $STRUCTURAL_MANIFEST_PATH"
echo "shard root : $OOS_SHARD_ROOT"
echo "destino    : $OOS_MERGED_DIR"
echo

"${JULIA_ARGV[@]}" "$CODES_DIR/oos_experiment/merge_oos_shards.jl"

echo
echo "Dataset fusionado en: $OOS_MERGED_DIR"
