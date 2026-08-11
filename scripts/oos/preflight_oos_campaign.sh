#!/usr/bin/env bash
# Pre-flight readiness check for the full out-of-sample campaign.
#
# Runs every blocking gate WITHOUT launching the expensive campaign: environment, both test
# suites, both validation gates, the default policy matrix, a small fresh 18-configuration
# smoke campaign, the downstream schema reader against that smoke output, the abstract temporal
# contract (H / L / h in model periods), and the Stage-3 structural manifest with extended
# period-data support and deterministic-base isolation (generation, rematerialized validation and
# byte reproducibility).
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
# TREE_SET (S:C:P) sizes the BASE INSTANCE's own in-sample tree. It is unrelated to L/H/h and to
# MULTISTAGE_BRANCHING below: legacy demandProfile() in parametersMS.jl always writes into
# demand_det[17:24], a fixed 24-slot range, regardless of the configured geometry. S*P < 24
# throws a BoundsError inside instance generation (check 11), not a validation error, so this
# floor is not caught by config validation. Keep S*P >= 24 here no matter what L/H/h or
# MULTISTAGE_BRANCHING are set to.
SMOKE_TREE_SET="${PREFLIGHT_SMOKE_TREE_SET:-6:4:4}"
SMOKE_HOUSEHOLDS="${PREFLIGHT_SMOKE_J:-4}"
SMOKE_TWO_STAGE="${PREFLIGHT_SMOKE_TWO_STAGE_SCENARIOS:-256}"
# MULTISTAGE_BRANCHING sizes the OOS multistage LOOK-AHEAD tree instead (unrelated to TREE_SET
# above): its S*P should sum to SMOKE_LOOKAHEAD below, or the layout truncates/reconciles it.
# Optional, blank by default so an unset knob falls through to the Julia-side default exactly
# like the equivalent variables in run_oos_experiment.sh. MULTISTAGE_BRANCHING now also accepts
# the compact stages:children:periods_per_stage form (e.g. "4:4:6"), which sets
# periods_per_stage BY ITSELF. Do NOT also set PREFLIGHT_SMOKE_MULTISTAGE_PERIODS_PER_STAGE when
# PREFLIGHT_SMOKE_MULTISTAGE_BRANCHING is in this compact form — the config resolution errors on
# that combination on purpose (see parse_multistage_tree_spec in types.jl). Only set the periods
# knob below if you switch PREFLIGHT_SMOKE_MULTISTAGE_BRANCHING to the plain list form (e.g. "4,4").
SMOKE_BRANCHING="${PREFLIGHT_SMOKE_MULTISTAGE_BRANCHING:-5:4:4}"
SMOKE_PERIODS_PER_STAGE="${PREFLIGHT_SMOKE_MULTISTAGE_PERIODS_PER_STAGE:-}"
SMOKE_EVALUATION_HORIZON="${PREFLIGHT_SMOKE_EVALUATION_HORIZON:-20}" 
SMOKE_IMPLEMENTATION_STEP="${PREFLIGHT_SMOKE_IMPLEMENTATION_STEP:-4}"  #Ventana RH
SMOKE_SEED="${PREFLIGHT_SMOKE_SEED:-12345}"
# Short moving window, since redesign stage 4. The smoke exists so the downstream reader (check
# 09) can audit BOTH branches of the PEA solve-sequence schema: strict-feasible periods with one
# solve, and recovered periods with four. Under the stage-4 fixed window a full 24-period
# look-ahead keeps the strict equality reachable throughout, so no period would ever be recovered
# and the four-solve branch would go unaudited. A short window produces genuine fairness
# infeasibility the way the campaign will. This is a PRE-FLIGHT FIXTURE, exactly like the other
# PREFLIGHT_SMOKE_* values; check 07 separately verifies the DEFAULT configuration matrix.
SMOKE_LOOKAHEAD="${PREFLIGHT_SMOKE_LOOKAHEAD_HORIZON:-20}"

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
      MULTISTAGE_PERIODS_PER_STAGE="$SMOKE_PERIODS_PER_STAGE" \
      EXPERIMENT_SEED="$SMOKE_SEED" SOLVER_TIME_LIMIT_SEC=120.0 SOLVER_THREADS=1 \
      EVALUATION_HORIZON="$SMOKE_EVALUATION_HORIZON" \
      LOOKAHEAD_HORIZON="$SMOKE_LOOKAHEAD" \
      IMPLEMENTATION_STEP="$SMOKE_IMPLEMENTATION_STEP" \
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

# ---- 10 abstract temporal contract reaches the Julia configuration ---------------------------
# Stage 1 of the redesign: H, L and h are a validated configuration contract. This check proves
# that the three environment variables reach `OOSExperimentConfig`, that an absent variable falls
# back to the documented Julia default, that a malformed value fails instead of being absorbed
# into a default, and that a non-divisible step is accepted with its final block intact.
run_check 10 "Contrato temporal abstracto (H/L/h) en config" \
  "$LOG_DIR/10_temporal.log" \
  env FORMULATION_ID="$FORMULATION_ID" OOS_OUTPUT_DIR="$SMOKE_DIR/temporal" \
  "${JULIA_ARGV[@]}" -e '
    include(joinpath(ENV["OOS_CODES_DIR"], "oos_experiment", "oos_experiment.jl"))
    for key in ("EVALUATION_HORIZON", "LOOKAHEAD_HORIZON", "IMPLEMENTATION_STEP")
        haskey(ENV, key) && delete!(ENV, key)
    end

    defaults = oos_config_from_environment()
    defaults.evaluation_horizon == OOS_DEFAULT_EVALUATION_HORIZON ||
        error("H por defecto: $(defaults.evaluation_horizon)")
    defaults.lookahead_horizon == OOS_DEFAULT_LOOKAHEAD_HORIZON ||
        error("L por defecto: $(defaults.lookahead_horizon)")
    defaults.implementation_step == OOS_DEFAULT_IMPLEMENTATION_STEP ||
        error("h por defecto: $(defaults.implementation_step)")
    rolling_solve_count(defaults) == defaults.evaluation_horizon ||
        error("conteo de iteraciones con h=1: $(rolling_solve_count(defaults))")

    # A non-divisible step is admissible and its final block is not truncated.
    withenv("EVALUATION_HORIZON" => "24", "LOOKAHEAD_HORIZON" => "24",
            "IMPLEMENTATION_STEP" => "10") do
        config = oos_config_from_environment()
        config.implementation_step == 10 || error("h no llegó: $(config.implementation_step)")
        rolling_iteration_starts(config) == [1, 11, 21] ||
            error("inicios: $(rolling_iteration_starts(config))")
        implementation_block(config, 21) == 21:30 ||
            error("bloque final: $(implementation_block(config, 21))")
        evaluation_block(config, 21) == 21:24 ||
            error("bloque evaluado: $(evaluation_block(config, 21))")
        required_period_support_end(config) == 44 ||
            error("soporte requerido: $(required_period_support_end(config))")
    end

    # A malformed value must fail loudly, never fall back to the default. The outcome is
    # recorded in a flag rather than raised inside the `try`, so the guard cannot swallow its
    # own sentinel error and report a pass.
    malformed_rejected = withenv("IMPLEMENTATION_STEP" => "cuatro") do
        try
            oos_config_from_environment()
            false
        catch exception
            exception isa ErrorException && occursin("IMPLEMENTATION_STEP", exception.msg)
        end
    end
    malformed_rejected || error("IMPLEMENTATION_STEP malformado fue aceptado en silencio")

    # An invalid combination must fail during configuration construction.
    combination_rejected = withenv("EVALUATION_HORIZON" => "24", "LOOKAHEAD_HORIZON" => "4",
                                   "IMPLEMENTATION_STEP" => "6") do
        try
            oos_config_from_environment()
            false
        catch exception
            exception isa ErrorException
        end
    end
    combination_rejected || error("h > L fue aceptado")

    # No clock-time or calendar variable may be introduced by this contract.
    for forbidden in ("PERIOD_DURATION_MINUTES", "PROFILE_CYCLE")
        haskey(ENV, forbidden) && error("variable de reloj/calendario presente: $forbidden")
    end
    println("TEMPORAL OK")'

# ---- 11 Stage-3 structural manifest: generate, validate, reproduce --------------------------
# Exercises schema v2 end to end on a BOUNDED fixture: one base instance, K = 2, h = 12, two OOS
# replications -> 16 structural instances and two deterministic data blocks. The numeric factor
# levels below are PRE-FLIGHT FIXTURES, exactly like PREFLIGHT_SMOKE_*; they are not calibrated
# campaign levels, which Stage 12 selects only after the isolation gate passes.
PREFLIGHT_STRUCTURAL_DIR="$SMOKE_DIR/structural"
PREFLIGHT_STRUCTURAL_MANIFEST="$PREFLIGHT_STRUCTURAL_DIR/structural_instance_manifest.json"
run_check 11 "Manifiesto v2: soporte e aislamiento determinista" \
  "$LOG_DIR/11_structural_manifest.log" \
  env INSTANCE_DRAWS_PER_CELL="${PREFLIGHT_STRUCTURAL_DRAWS:-2}" \
      LOW_BATTERY_SCALE="${PREFLIGHT_LOW_BATTERY_SCALE:-0.5}" \
      HIGH_BATTERY_SCALE="${PREFLIGHT_HIGH_BATTERY_SCALE:-2.0}" \
      LOW_UNCERTAINTY_THETA="${PREFLIGHT_LOW_UNCERTAINTY_THETA:-0.1}" \
      HIGH_UNCERTAINTY_THETA="${PREFLIGHT_HIGH_UNCERTAINTY_THETA:-0.4}" \
      STRUCTURAL_MANIFEST_PATH="$PREFLIGHT_STRUCTURAL_MANIFEST" \
      STRUCTURAL_BASE_INSTANCES="codes/inst/inst2020/Drahi_1.csv" \
      J_SET="${PREFLIGHT_SMOKE_J:-4}" OOS_REPLICATIONS=2 \
      TREE_SET="$SMOKE_TREE_SET" EXPERIMENT_SEED="$SMOKE_SEED" \
      EVALUATION_HORIZON=24 LOOKAHEAD_HORIZON=24 IMPLEMENTATION_STEP=12 \
  bash "$SCRIPT_DIR/generate_structural_instance_manifest.sh"

if [[ -f "$PREFLIGHT_STRUCTURAL_MANIFEST" ]]; then
  # The saved manifest must validate standalone, including rematerializing every instance and
  # comparing deterministic-data digests and resolved physical parameters against the pipeline.
  run_check 12 "Manifiesto v2: rematerialización independiente" \
    "$LOG_DIR/12_structural_validation.log" \
    env STRUCTURAL_MANIFEST_REMATERIALIZE=1 \
    bash "$SCRIPT_DIR/validate_structural_instance_manifest.sh" "$PREFLIGHT_STRUCTURAL_MANIFEST"

  # Regenerating into a fresh directory must reproduce the bytes exactly, and reversing the
  # controller and fairness order, changing the solver threads and changing a simulated worker
  PREFLIGHT_STRUCTURAL_REPEAT="$SMOKE_DIR/structural_repeat"
  if env INSTANCE_DRAWS_PER_CELL="${PREFLIGHT_STRUCTURAL_DRAWS:-2}" \
         LOW_BATTERY_SCALE="${PREFLIGHT_LOW_BATTERY_SCALE:-0.5}" \
         HIGH_BATTERY_SCALE="${PREFLIGHT_HIGH_BATTERY_SCALE:-2.0}" \
         LOW_UNCERTAINTY_THETA="${PREFLIGHT_LOW_UNCERTAINTY_THETA:-0.1}" \
         HIGH_UNCERTAINTY_THETA="${PREFLIGHT_HIGH_UNCERTAINTY_THETA:-0.4}" \
         STRUCTURAL_MANIFEST_PATH="$PREFLIGHT_STRUCTURAL_REPEAT/structural_instance_manifest.json" \
         STRUCTURAL_BASE_INSTANCES="codes/inst/inst2020/Drahi_1.csv" \
         J_SET="${PREFLIGHT_SMOKE_J:-4}" OOS_REPLICATIONS=2 \
         TREE_SET="$SMOKE_TREE_SET" EXPERIMENT_SEED="$SMOKE_SEED" \
         EVALUATION_HORIZON=24 LOOKAHEAD_HORIZON=24 IMPLEMENTATION_STEP=12 \
         CONTROLLER_SET='MULTISTAGE_RH,TWO_STAGE_RH,DETERMINISTIC_RH' \
         FAIRNESS_SET='LEXMMFSA,LEXMMFPEA,SA,PEA,STATIC_DEMAND_SHARE,NONE' \
         SOLVER_THREADS=4 OOS_WORKER_ID=7 \
         bash "$SCRIPT_DIR/generate_structural_instance_manifest.sh" \
         >"$LOG_DIR/13_structural_repeat.log" 2>&1 &&
     cmp -s "$PREFLIGHT_STRUCTURAL_MANIFEST" \
            "$PREFLIGHT_STRUCTURAL_REPEAT/structural_instance_manifest.json"; then
    record 13 "Manifiesto estructural: bytes idénticos entre procesos" "PASS" ""
  else
    record 13 "Manifiesto estructural: bytes idénticos entre procesos" "FAIL" \
      "ver $LOG_DIR/13_structural_repeat.log"
  fi
else
  record 12 "Manifiesto estructural: validación independiente" "FAIL" \
    "la generación no produjo un manifiesto"
  record 13 "Manifiesto estructural: bytes idénticos entre procesos" "FAIL" \
    "la generación no produjo un manifiesto"
fi

# ---- 14 Stage-4 fixed moving look-ahead is wired into the simulator ---------------------------
# Stage 1 proved H/L/h reach the configuration; this proves they reach the SIMULATION. On a
# bounded single-controller configuration it checks that every solve spans exactly L abstract
# periods, that the last evaluated period still gets a full window reaching past the repository
# horizon, that the realized trajectory covers exactly the final implementation block, that no
# implemented action carries a terminal state-of-charge requirement, and that an implementation
# step above one commits and validates its whole block while evaluating only 1:H.
run_check 14 "Ventana móvil fija (L) y bloques de implementación (h)" \
  "$LOG_DIR/14_moving_lookahead.log" \
  env FORMULATION_ID="$FORMULATION_ID" OOS_OUTPUT_DIR="$SMOKE_DIR/moving" \
  "${JULIA_ARGV[@]}" -e '
    include(joinpath(ENV["OOS_CODES_DIR"], "oos_experiment", "oos_experiment.jl"))
    config = OOSExperimentConfig(
        experiment_seed=4242, oos_replications=1, households=3,
        controller_set=[DETERMINISTIC_RH], fairness_set=[NONE],
        instance_file=joinpath(ENV["OOS_CODES_DIR"], "inst", "inst2020", "Drahi_1.csv"),
        export_representative_models=false, require_shared_battery_validation=false,
        solver_time_limit_sec=120.0,
    )
    common = build_common_objects(config; verbose=false)
    ctx = common.context
    T0 = common.template.T

    rolling_support_end(ctx) == required_period_support_end(config) ||
        error("soporte del contexto: $(rolling_support_end(ctx))")
    rolling_realized_end(ctx) == realized_period_end(config) ||
        error("realizado del contexto: $(rolling_realized_end(ctx))")
    common.oos_paths[1].horizon == realized_period_end(config) ||
        error("horizonte OOS: $(common.oos_paths[1].horizon)")
    size(common.static_shares, 2) == rolling_data_end(ctx) ||
        error("ancho de cuotas estáticas: $(size(common.static_shares, 2))")

    cache = cache_lookahead_trees(common.provider, ctx, common.oos_paths[1])
    for t in rolling_iteration_starts(config)
        tree = cache[(t, DETERMINISTIC_RH)]
        tree.first_period == t || error("raíz de la ventana en $t: $(tree.first_period)")
        span = tree.last_period - tree.first_period + 1
        span == config.lookahead_horizon ||
            error("la ventana en $t cubre $span períodos y L=$(config.lookahead_horizon)")
    end
    final = cache[(final_rolling_iteration_start(config), DETERMINISTIC_RH)]
    final.last_period > T0 ||
        error("la ventana final no supera T0=$T0: $(final.last_period)")

    run = simulate_configuration(ctx, common.oos_paths[1], cache, DETERMINISTIC_RH, NONE,
                                 common.static_shares)
    run.completed || error("la simulación acotada no completó: $(run.failure_message)")
    run.periods_completed == rolling_solve_count(config) ||
        error("períodos completados: $(run.periods_completed)")
    all(r.validation.valid for r in run.records) ||
        error("una acción implementada fue inválida")
    all(r.validation.residuals.terminal == 0.0 for r in run.records) ||
        error("una acción implementada cargó un residuo terminal con h < L")

    # Stage 6: a NON-DIVISIBLE implementation step. H = 24, h = 10 gives starts [1, 11, 21] and
    # a final block 21:30 that runs past the evaluation horizon. It must be committed and
    # validated in full while only 21:24 is evaluated.
    stepped = OOSExperimentConfig(; evaluation_horizon=24, lookahead_horizon=24,
        implementation_step=10,
        experiment_seed=4242, oos_replications=1, households=3,
        controller_set=[DETERMINISTIC_RH], fairness_set=[NONE],
        instance_file=joinpath(ENV["OOS_CODES_DIR"], "inst", "inst2020", "Drahi_1.csv"),
        export_representative_models=false, require_shared_battery_validation=false,
        solver_time_limit_sec=120.0)
    rolling_iteration_starts(stepped) == [1, 11, 21] ||
        error("inicios con h=10: $(rolling_iteration_starts(stepped))")
    implementation_block(stepped, 21) == 21:30 || error("bloque final mal formado")
    evaluation_block(stepped, 21) == 21:24 || error("bloque evaluado mal formado")

    stepped_common = build_common_objects(stepped; verbose=false)
    stepped_common.oos_paths[1].horizon == realized_period_end(stepped) == 30 ||
        error("la trayectoria realizada no cubre el bloque final")
    stepped_cache = cache_lookahead_trees(
        stepped_common.provider, stepped_common.context, stepped_common.oos_paths[1])
    for t in rolling_iteration_starts(stepped)
        support = cached_support(stepped_cache, t)
        support.known_prefix == 10 || error("prefijo conocido en $t: $(support.known_prefix)")
        length(support_prefix_nodes(support)) == 10 ||
            error("el prefijo conocido en $t no es una cadena de 10 nodos")
    end
    stepped_run = simulate_configuration(
        stepped_common.context, stepped_common.oos_paths[1], stepped_cache,
        DETERMINISTIC_RH, NONE, stepped_common.static_shares)
    stepped_run.completed ||
        error("la corrida con h=10 no completó: $(stepped_run.failure_message)")
    stepped_run.periods_completed == 24 ||
        error("períodos evaluados con h=10: $(stepped_run.periods_completed)")
    [r.period for r in stepped_run.records] == collect(1:24) ||
        error("los períodos registrados con h=10 no son 1:24")
    # pea_tolerances is period-counted (it feeds configuration_summary.csv PeriodsSolved and the
    # downstream independent per-period recomputation), not solve-counted: one entry per
    # EVALUATED period, so one block tolerance decision repeats across the periods it covers.
    # With h=10 that totals 24, same as periods_completed, not 3 solves.
    length(stepped_run.pea_tolerances) == 24 ||
        error("periodos con tolerancia PEA registrada con h=10: $(length(stepped_run.pea_tolerances))")
    length(last(stepped_run.records).result.block_actions) == 10 ||
        error("el bloque final no comprometió 10 acciones")
    stepped_run.final_state.period == 31 ||
        error("el estado final quedó en $(stepped_run.final_state.period) y se esperaba 31")

    println("MOVING LOOKAHEAD OK: L=", config.lookahead_horizon,
            " inicios=", rolling_solve_count(config),
            " ventana final=", final.first_period, ":", final.last_period,
            " T0=", T0)
    println("ROLLING BLOCKS OK: h=10 inicios=", rolling_iteration_starts(stepped),
            " bloque final=", implementation_block(stepped, 21),
            " evaluado=", evaluation_block(stepped, 21),
            " registros=", stepped_run.periods_completed)'

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
