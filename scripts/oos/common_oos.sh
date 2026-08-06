#!/usr/bin/env bash
# Shared setup for the out-of-sample receding-horizon experiment scripts.
#
# Additive: it sources the repository's existing scripts/common.sh without modifying it and
# adds only the results_oos/ location. Nothing here writes to the existing model-result
# directories.

OOS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$OOS_SCRIPT_DIR/../common.sh"

RESULTS_OOS_DIR="$ROOT_DIR/results_oos"
# Exported so Julia snippets can locate the module without depending on the working directory.
export OOS_CODES_DIR="$CODES_DIR"
TESTS_OOS_DIR="$ROOT_DIR/tests/oos"
mkdir -p "$RESULTS_OOS_DIR" "$RESULTS_OOS_DIR/model_audit"

# Directories that belong to the pre-existing workflows and must never be written to here.
OOS_PROTECTED_DIRS=(
  "$RESULTS_MODELS_DIR"
  "$RESULTS_HEURISTICS_DIR"
  "$RESULTS_SENSITIVITY_DIR"
  "$RESULTS_DECOMPOSICION_DIR"
)

# The Manifest is resolved for one Julia version; use it so CPLEX loads reproducibly.
oos_resolve_julia() {
  local manifest="$ROOT_DIR/Manifest.toml"
  local manifest_version=""
  if [[ -f "$manifest" ]]; then
    manifest_version="$(sed -n 's/^julia_version *= *"\(.*\)"/\1/p' "$manifest" | head -1)"
  fi
  JULIA_BIN="${JULIA_BIN:-julia}"
  JULIA_CHANNEL="${JULIA_CHANNEL:-$manifest_version}"

  JULIA_ARGV=("$JULIA_BIN")
  if [[ -n "$JULIA_CHANNEL" ]]; then
    if "$JULIA_BIN" "+$JULIA_CHANNEL" --version >/dev/null 2>&1; then
      JULIA_ARGV=("$JULIA_BIN" "+$JULIA_CHANNEL")
    else
      echo "AVISO: el canal Julia '$JULIA_CHANNEL' del Manifest no está disponible; se usa '$JULIA_BIN'." >&2
    fi
  fi
  JULIA_ARGV+=("--project=$ROOT_DIR" "--startup-file=no" "--history-file=no")
}

# Refuse to start unless the campaign is identified and isolated from existing outputs.
oos_require_preconditions() {
  if [[ -z "${FORMULATION_ID:-}" ]]; then
    echo "ERROR: FORMULATION_ID es obligatorio. El experimento se niega a arrancar sin identificador de formulación." >&2
    echo "       Ejemplo: FORMULATION_ID='shared_battery_mode_node_level_v1'" >&2
    return 1
  fi

  local output_dir
  output_dir="${OOS_OUTPUT_DIR:-$RESULTS_OOS_DIR}"
  mkdir -p "$output_dir"
  local resolved
  resolved="$(cd "$output_dir" && pwd)"
  local protected
  for protected in "${OOS_PROTECTED_DIRS[@]}"; do
    [[ -d "$protected" ]] || continue
    if [[ "$resolved" == "$(cd "$protected" && pwd)" ]]; then
      echo "ERROR: OOS_OUTPUT_DIR apunta a '$protected', que pertenece a un flujo existente." >&2
      echo "       Usa results_oos/ o un directorio nuevo." >&2
      return 1
    fi
  done

  if [[ "${REQUIRE_SHARED_BATTERY_VALIDATION:-1}" != "1" ]]; then
    if [[ "${OOS_ACKNOWLEDGE_UNVALIDATED:-0}" != "1" ]]; then
      echo "ERROR: REQUIRE_SHARED_BATTERY_VALIDATION=0 desactiva la compuerta de batería compartida." >&2
      echo "       La campaña permanece bloqueada hasta que la validación se complete." >&2
      echo "       Para una corrida exploratoria explícita, define OOS_ACKNOWLEDGE_UNVALIDATED=1." >&2
      return 1
    fi
    echo "AVISO: corrida exploratoria sin compuerta de validación; los resultados no son publicables." >&2
  fi
  return 0
}
