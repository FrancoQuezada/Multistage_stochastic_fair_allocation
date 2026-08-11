#!/usr/bin/env bash
# Validate a saved structural-instance manifest (redesign stage 3, schema v2).
#
# Reads the manifest from disk as a downstream consumer would and verifies its cardinality,
# identifiers, digest, seed contracts, period-data support, battery pairings, household assignments
# and resolved physical parameters. With rematerialization enabled it re-invokes the repository
# instance pipeline and compares the stored deterministic-data digests and physical parameters.
#
# Runs NO out-of-sample campaign.
#
# Usage:
#   STRUCTURAL_MANIFEST_PATH=results_oos_structural/structural_instance_manifest.json \
#   bash scripts/oos/validate_structural_instance_manifest.sh
#
#   # or positionally
#   bash scripts/oos/validate_structural_instance_manifest.sh path/to/manifest.json
#
# Optional:
#   STRUCTURAL_MANIFEST_REMATERIALIZE=0        skip the physical re-check (default 1)
#   STRUCTURAL_MANIFEST_REMATERIALIZE_LIMIT=N  bound the rematerialized rows (default 0 = all)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_oos.sh"

oos_resolve_julia

MANIFEST="${1:-${STRUCTURAL_MANIFEST_PATH:-}}"
if [[ -z "$MANIFEST" ]]; then
  echo "ERROR: indica el manifiesto como argumento o vía STRUCTURAL_MANIFEST_PATH." >&2
  exit 1
fi
if [[ ! -f "$MANIFEST" ]]; then
  echo "ERROR: no existe el manifiesto: $MANIFEST" >&2
  exit 1
fi

[[ -n "${STRUCTURAL_MANIFEST_REMATERIALIZE:-}" ]] && export STRUCTURAL_MANIFEST_REMATERIALIZE
[[ -n "${STRUCTURAL_MANIFEST_REMATERIALIZE_LIMIT:-}" ]] && export STRUCTURAL_MANIFEST_REMATERIALIZE_LIMIT

echo "=== Validación del manifiesto estructural ==="
echo "julia      : ${JULIA_ARGV[*]}"
echo "manifiesto : $MANIFEST"

"${JULIA_ARGV[@]}" "$CODES_DIR/oos_experiment/validate_structural_instance_manifest.jl" "$MANIFEST"

echo
echo "El manifiesto estructural pasó la validación independiente."
