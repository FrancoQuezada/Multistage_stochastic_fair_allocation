#!/usr/bin/env bash
# Pre-flight readiness check for the full out-of-sample campaign.
#
# Runs every blocking gate WITHOUT launching the expensive campaign: environment, both test
# suites, both validation gates, the default policy matrix, a small fresh 18-configuration
# smoke campaign, and the downstream schema reader against that smoke output.
#
# Exits 0 only when every blocking check passes. Otherwise it exits nonzero and names the
# failed check, both human-readably and as PREFLIGHT_CHECK_NN=... lines for machine parsing.
#
# Usage:
#   bash scripts/oos/preflight_oos_campaign.sh
#   PREFLIGHT_KEEP_SMOKE=1 bash scripts/oos/preflight_oos_campaign.sh   # keep smoke outputs
#
# Deliberately NOT `set -e`: every check must run so the report is complete, and the exit code
# is computed from the recorded results at the end.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_oos.sh"

FORMULATION_ID="${FORMULATION_ID:-shared_battery_mode_node_level_v1}"
export FORMULATION_ID

# Small but genuinely 18-configuration smoke campaign. Deterministic seed.
SMOKE_REPLICATIONS="${PREFLIGHT_SMOKE_REPLICATIONS:-2}"
SMOKE_TREE_SET="${PREFLIGHT_SMOKE_TREE_SET:-3:2:8}"
SMOKE_HOUSEHOLDS="${PREFLIGHT_SMOKE_J:-4}"
SMOKE_TWO_STAGE="${PREFLIGHT_SMOKE_TWO_STAGE_SCENARIOS:-3}"
SMOKE_BRANCHING="${PREFLIGHT_SMOKE_MULTISTAGE_BRANCHING:-2,2}"
SMOKE_SEED="${PREFLIGHT_SMOKE_SEED:-12345}"

SMOKE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/oos_preflight_smoke.XXXXXX")"
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/oos_preflight_logs.XXXXXX")"
cleanup() {
  if [[ "${PREFLIGHT_KEEP_SMOKE:-0}" == "1" ]]; then
    echo "Salidas del smoke conservadas en: $SMOKE_DIR"
    echo "Registros conservados en:         $LOG_DIR"
  else
    rm -rf "$SMOKE_DIR"
  fi
}
trap cleanup EXIT

declare -a CHECK_IDS=() CHECK_NAMES=() CHECK_STATUS=() CHECK_DETAIL=()
FAILED=0

record() {                       # record <id> <name> <status> <detail>
  CHECK_IDS+=("$1"); CHECK_NAMES+=("$2"); CHECK_STATUS+=("$3"); CHECK_DETAIL+=("${4:-}")
  if [[ "$3" == "FAIL" ]]; then FAILED=$((FAILED + 1)); fi
  printf '  [%s] %-2s %-46s %s\n' "$3" "$1" "$2" "${4:-}"
}

run_check() {                    # run_check <id> <name> <logfile> <command...>
  local id="$1" name="$2" log="$3"; shift 3
  if "$@" >"$log" 2>&1; then
    record "$id" "$name" "PASS" ""
  else
    record "$id" "$name" "FAIL" "ver $log"
  fi
}

echo "======================================================================"
echo " PRE-FLIGHT — campaña fuera de muestra"
echo " formulation_id : $FORMULATION_ID"
echo " repo           : $ROOT_DIR"
echo " smoke dir      : $SMOKE_DIR"
echo "======================================================================"

# ---- 01 Julia channel resolved from Manifest.toml -----------------------------------
oos_resolve_julia
MANIFEST_JULIA="$(sed -n 's/^julia_version *= *"\(.*\)"/\1/p' "$ROOT_DIR/Manifest.toml" | head -1)"
if [[ "${JULIA_ARGV[*]}" == *"+$MANIFEST_JULIA"* ]]; then
  record 01 "Canal Julia resuelto desde Manifest" "PASS" "julia $MANIFEST_JULIA"
else
  record 01 "Canal Julia resuelto desde Manifest" "FAIL" \
    "Manifest pide $MANIFEST_JULIA; resuelto '${JULIA_ARGV[*]}'"
fi

# ---- 02 project environment and CPLEX --------------------------------------------------
run_check 02 "Entorno del proyecto y carga de CPLEX" "$LOG_DIR/02_cplex.log" \
  "${JULIA_ARGV[@]}" -e '
    using CPLEX, JuMP
    model = Model(CPLEX.Optimizer); set_silent(model)
    @variable(model, x >= 0); @objective(model, Min, x); optimize!(model)
    termination_status(model) == MOI.OPTIMAL || error("CPLEX no resolvió el modelo trivial.")
    println("CPLEX OK, Julia ", VERSION)'

# ---- 03 repository regression suite ------------------------------------------------------
run_check 03 "Suite de regresión del repositorio" "$LOG_DIR/03_repo_tests.log" \
  "${JULIA_ARGV[@]}" "$ROOT_DIR/test/runtests.jl"

# ---- 04 + 05 OOS test suite / validation gate --------------------------------------------
# validate_oos_experiment.sh IS the OOS validation gate; the repository suite is skipped here
# because check 03 already ran it explicitly, so it executes exactly once per pre-flight.
run_check 04 "Suite OOS + compuerta de validación OOS" "$LOG_DIR/04_oos_tests.log" \
  env OOS_SKIP_REPO_REGRESSION=1 bash "$SCRIPT_DIR/validate_oos_experiment.sh"

# ---- 06 shared-battery validation gate ----------------------------------------------------
run_check 06 "Compuerta de batería compartida" "$LOG_DIR/06_battery_gate.log" \
  env OOS_OUTPUT_DIR="$SMOKE_DIR/gate" FORMULATION_ID="$FORMULATION_ID" \
  bash "$SCRIPT_DIR/validate_shared_battery_formulation.sh"

# ---- 07 default campaign matrix ------------------------------------------------------------
run_check 07 "Matriz por defecto: 18 = 6 reglas x 3 controladores" "$LOG_DIR/07_matrix.log" \
  env FORMULATION_ID="$FORMULATION_ID" OOS_OUTPUT_DIR="$SMOKE_DIR/matrix" \
  "${JULIA_ARGV[@]}" -e '
    include(joinpath(ENV["OOS_CODES_DIR"], "oos_experiment", "oos_experiment.jl"))
    for key in ("CONTROLLER_SET", "FAIRNESS_SET", "PEA_TOLERANCE_MODE", "FAIRNESS_ABS_TOL")
        haskey(ENV, key) && delete!(ENV, key)
    end
    config = oos_config_from_environment()
    length(config.controller_set) == 3 || error("controladores: $(config.controller_set)")
    length(config.fairness_set) == 6 || error("reglas: $(config.fairness_set)")
    configuration_count(config) == 18 || error("configuraciones: $(configuration_count(config))")
    config.pea_tolerance_mode === :adaptive_minimum ||
        error("modo PEA por defecto: $(config.pea_tolerance_mode)")
    config.fairness_abs_tol == 0.0 || error("banda fija por defecto: $(config.fairness_abs_tol)")
    for label in ("CPEA", "CSA", "CLEXMMFPEA", "CLEXMMFSA", "ERDINC_PSR", "MMFPEA")
        try
            parse_fairness_policy(label)
            error("etiqueta condicional/legada aceptada: $label")
        catch exception
            exception isa ErrorException && occursin("no soportada", exception.msg) && continue
            rethrow()
        end
    end
    for controller in config.controller_set, policy in config.fairness_set
        println("CONFIG ", controller, " | ", policy, " | ", policy_resource(policy))
    end
    println("MATRIX OK")'

# ---- 08 fresh 18-configuration smoke campaign ------------------------------------------------
run_check 08 "Campaña smoke de 18 configuraciones (directorio nuevo)" "$LOG_DIR/08_smoke.log" \
  env FORMULATION_ID="$FORMULATION_ID" EXPERIMENT_ID="oos_preflight_smoke" \
      OOS_OUTPUT_DIR="$SMOKE_DIR/campaign" OOS_REPLICATIONS="$SMOKE_REPLICATIONS" \
      TREE_SET="$SMOKE_TREE_SET" J_SET="$SMOKE_HOUSEHOLDS" \
      TWO_STAGE_SCENARIOS="$SMOKE_TWO_STAGE" MULTISTAGE_BRANCHING="$SMOKE_BRANCHING" \
      EXPERIMENT_SEED="$SMOKE_SEED" SOLVER_TIME_LIMIT_SEC=120.0 \
      EXPORT_REPRESENTATIVE_MODELS=0 \
  bash "$SCRIPT_DIR/run_oos_experiment.sh"

# ---- 09..16 downstream reader against the smoke outputs -----------------------------------
# One Julia session performs the schema validation, the independent PEA recomputation, the
# solve-sequence audit and the policy/resource checks, because they all read the same files.
if [[ -d "$SMOKE_DIR/campaign" ]]; then
  run_check 09 "Lector downstream: esquema, PEA, secuencias, políticas" \
    "$LOG_DIR/09_downstream.log" \
    env OOS_SMOKE_DIR="$SMOKE_DIR/campaign" \
        OOS_EXPECTED_REPLICATIONS="$SMOKE_REPLICATIONS" \
    "${JULIA_ARGV[@]}" "$CODES_DIR/oos_experiment/run_downstream_checks.jl"
else
  record 09 "Lector downstream: esquema, PEA, secuencias, políticas" "FAIL" \
    "la campaña smoke no produjo un directorio de salida"
fi

# ---- 17 no tracked script depends on an obsolete schema name ---------------------------------
OBSOLETE_HITS="$(
  grep -rIn --exclude-dir=.git --exclude-dir=results_oos \
       --exclude-dir=results_models --exclude-dir=results_sensitivity \
       --exclude-dir=results_sensitivity_old --exclude-dir=results_heuristics \
       --exclude-dir=results_decomposicion \
       -e 'PEA_Tolerance_Numeric_Eps[^_]' -e 'PEA_Tolerance_Numeric_Eps$' \
       "$ROOT_DIR" 2>/dev/null \
    | grep -v 'output_schema.jl' \
    | grep -v 'tests/oos/runtests.jl' \
    | grep -v 'preflight_oos_campaign.sh' \
    | grep -v 'docs/oos_experiment.md' || true
)"
if [[ -z "$OBSOLETE_HITS" ]]; then
  record 17 "Ningún script usa nombres de esquema obsoletos" "PASS" ""
else
  record 17 "Ningún script usa nombres de esquema obsoletos" "FAIL" \
    "$(echo "$OBSOLETE_HITS" | head -3 | tr '\n' ';')"
fi

# ---- stale historical result directories (advisory, never blocking) ---------------------------
if [[ -f "$RESULTS_OOS_DIR/experiment_config.json" ]]; then
  if grep -q '"output_schema_version"' "$RESULTS_OOS_DIR/experiment_config.json"; then
    record 7a "results_oos/ existente usa el esquema actual" "PASS" ""
  else
    record 7a "results_oos/ existente es de un esquema anterior" "WARN" \
      "usa un directorio nuevo para la campaña completa; no se modifica nada"
  fi
fi

if [[ -n "$(cd "$ROOT_DIR" && git status --porcelain 2>/dev/null)" ]]; then
  record 7b "Árbol de trabajo limpio" "WARN" \
    "hay cambios sin confirmar; el commit registrado no reproduce exactamente los resultados"
fi

# ---- 18 readiness result -----------------------------------------------------------------------
echo
echo "======================================================================"
echo "RESULTADO DE PRE-FLIGHT"
echo "======================================================================"
for index in "${!CHECK_IDS[@]}"; do
  printf 'PREFLIGHT_CHECK_%s=%s\n' "${CHECK_IDS[$index]}" "${CHECK_STATUS[$index]}"
done
printf 'PREFLIGHT_FAILED_CHECKS=%d\n' "$FAILED"
printf 'PREFLIGHT_SMOKE_REPLICATIONS=%s\n' "$SMOKE_REPLICATIONS"
printf 'PREFLIGHT_FORMULATION_ID=%s\n' "$FORMULATION_ID"

if [[ "$FAILED" -eq 0 ]]; then
  printf 'PREFLIGHT_RESULT=READY\n'
  echo
  echo "Todas las verificaciones bloqueantes pasaron. La campaña completa puede lanzarse."
  exit 0
fi

printf 'PREFLIGHT_RESULT=NOT_READY\n'
echo
echo "Verificaciones fallidas:"
for index in "${!CHECK_IDS[@]}"; do
  [[ "${CHECK_STATUS[$index]}" == "FAIL" ]] &&
    echo "  - ${CHECK_IDS[$index]} ${CHECK_NAMES[$index]}: ${CHECK_DETAIL[$index]}"
done
echo "Registros en: $LOG_DIR"
exit 1
