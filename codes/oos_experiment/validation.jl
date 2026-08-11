# =====================================================================================
# Implemented-action validation and the shared-battery compatibility gate.
#
# The simulator recomputes every physical identity from the implemented action itself, never
# trusting the optimization model's reported values. No solution is ever silently clipped:
# a violated tolerance invalidates the solve and stops that configuration.
# =====================================================================================

"""Outcome of validating one implemented current-period action."""
struct ActionValidation
    valid::Bool
    residuals::ActionResiduals
    soc_after::Float64
    violations::Vector{String}
end

"""
Validate the implemented current-period action against the corrected physical model.

Checks, with the configured tolerances and never with exact comparisons against zero:

  * PV allocation      `|sum_j p_j - C_t| <= eps_feas`
  * household balance  `|D_{j,t} - (p+y+I-z-G)| <= eps_feas`
  * battery transition `|s_after - (s_before + delta e_c Z - delta Y / e_d)| <= eps_feas`
  * shared mode        no simultaneous aggregate flows, both rate links, binary mode
  * bounds             state-of-charge window, rate limits, nonnegativity, terminal residual

`lookahead_end` is the last abstract period of the window this action was optimized over. The
terminal state-of-charge target binds only there, so the realized action is held to it only when
the implemented period *is* that endpoint. Under the stage-4 default (`h = 1 < L = 24`) it never
is: the target is a model-side boundary condition on the moving window, not a promise about the
realized trajectory. Passing `nothing` disables the check entirely; the retained pre-stage-4
default is `template.T`, which reproduces the old behaviour exactly.
"""
function validate_period_action(
    source::OOSPricedSource,
    state::SimulationState,
    action::PeriodAction,
    config::OOSExperimentConfig;
    lookahead_end::Union{Nothing,Int}=priced_template(source).T,
)
    template = priced_template(source)
    violations = String[]
    J = template.J
    t = action.period
    demand = @view state.realized_demand_history[:, t]
    pv = state.realized_pv_history[t]

    # 14.1 PV allocation. The identity sums the J household rows `p[j] = lambda[j] C` plus the
    # share row `sum_j lambda[j] = 1`, so the accumulated round-off can reach (J+1) times the
    # solver's per-row feasibility guarantee. The floor keeps the check meaningful as J grows.
    pv_tolerance = max(config.feasibility_tol, (J + 1) * OOS_SOLVER_FEASIBILITY_TOL)
    pv_residual = abs(sum(action.p) - pv)
    pv_residual <= pv_tolerance ||
        push!(violations, "Asignación de PV: residuo $pv_residual > $pv_tolerance.")

    # 14.2 Household energy balances.
    balance_residual = 0.0
    for j in 1:J
        residual = abs(demand[j] - (action.p[j] + action.y[j] + action.I[j] - action.z[j] - action.G[j]))
        balance_residual = max(balance_residual, residual)
    end
    balance_residual <= config.feasibility_tol ||
        push!(violations, "Balance por hogar: residuo $balance_residual > $(config.feasibility_tol).")

    # Stored aggregates must equal the sums of the household flows.
    charge = sum(action.z)
    discharge = sum(action.y)
    aggregate_residual = max(
        abs(charge - action.aggregate_charge), abs(discharge - action.aggregate_discharge),
    )
    aggregate_residual <= config.feasibility_tol ||
        push!(violations, "Agregados almacenados: residuo $aggregate_residual.")

    # 14.3 Battery transition, recomputed by the simulator.
    soc_after = induced_soc(template, state.soc_before, charge, discharge)
    transition_residual = abs(action.soc_after_model - soc_after)
    transition_residual <= config.feasibility_tol || push!(
        violations,
        "Transición de la batería: el modelo reporta $(action.soc_after_model) y el simulador " *
        "$soc_after (residuo $transition_residual).",
    )

    # 14.4 Shared-mode feasibility. Both checks below only apply to the binary formulation:
    # under the `[0,1]` LP relaxation (`battery_direction_exclusivity=false`) a fractional
    # mode legitimately allows simultaneous nonzero aggregate charge and discharge, bounded
    # by their own share of the big-M -- that is expected, not a violation.
    mode = Float64(action.shared_battery_mode)
    integrality = min(abs(mode), abs(1 - mode))
    if config.battery_direction_exclusivity
        integrality <= config.integrality_tol ||
            push!(violations, "El modo compartido no es binario: $mode.")
    end
    simultaneous = min(max(charge, 0.0), max(discharge, 0.0))
    if config.battery_direction_exclusivity && charge > config.flow_tol && discharge > config.flow_tol
        push!(violations, "Carga ($charge) y descarga ($discharge) agregadas simultáneas.")
    end
    charge_link = max(charge - template.f_under * mode, 0.0)
    discharge_link = max(discharge - template.f_bar * (1 - mode), 0.0)
    charge_link <= config.feasibility_tol ||
        push!(violations, "Vínculo de carga: residuo $charge_link.")
    discharge_link <= config.feasibility_tol ||
        push!(violations, "Vínculo de descarga: residuo $discharge_link.")

    # 14.5 Bounds.
    soc_bound_residual = max(soc_after - template.s_max, template.s_min - soc_after, 0.0)
    soc_bound_residual <= config.feasibility_tol ||
        push!(violations, "Estado de carga fuera de rango: $soc_after (residuo $soc_bound_residual).")
    negativity = 0.0
    for vector in (action.p, action.z, action.y, action.I, action.G, action.lambda)
        negativity = max(negativity, maximum(max.(-vector, 0.0); init=0.0))
    end
    negativity <= config.feasibility_tol ||
        push!(violations, "Flujo negativo implementado: $negativity.")
    lambda_residual = abs(sum(action.lambda) - 1.0)
    lambda_residual <= config.feasibility_tol ||
        push!(violations, "Los coeficientes de asignación suman $(sum(action.lambda)).")

    terminal_residual = lookahead_end !== nothing && t == lookahead_end ?
        abs(soc_after - template.s_I) : 0.0
    terminal_residual <= config.feasibility_tol ||
        push!(violations, "Residuo terminal de la batería: $terminal_residual.")

    residuals = ActionResiduals(
        pv_residual, balance_residual, transition_residual,
        charge_link, discharge_link, simultaneous <= config.flow_tol ? 0.0 : simultaneous,
        integrality, soc_bound_residual, terminal_residual, 0.0,
    )
    return ActionValidation(isempty(violations), residuals, soc_after, violations)
end

# =====================================================================================
# State recoverability across rolling solves (OOS redesign stage 9)
#
# Stage 6 made one solve commit `h` periods. The state handed to the NEXT solve is therefore the
# product of `h` sequential physical transitions, and the next look-ahead is built as if that
# state were exactly reachable. If it is not — if the state drifted, left its admissible window,
# or disagrees with the trajectory that produced it — the next solve is answering a different
# question than the one the experiment believes it asked.
#
# These checks are diagnostic and BLOCKING: an unrecoverable state stops the configuration. They
# never repair anything. There is no clipping, no rounding onto a bound, no substitution of
# another controller's state and no fallback: that prohibition is the whole point of the stage.
# =====================================================================================

"""Outcome of checking that a state may legitimately be carried into the next rolling solve."""
struct StateRecoverability
    recoverable::Bool
    period::Int
    soc::Float64
    soc_bound_residual::Float64
    replay_residual::Float64
    violations::Vector{String}
end

"""
Check that the state entering the next rolling solve is exactly the one the block produced.

Three independent conditions, none of which the simulator's per-action validation already covers:

  1. **Continuity.** The state's period is the one after the block that was just implemented, and
     its revealed history covers exactly that block. A gap or an overlap means a period was
     skipped or implemented twice.
  2. **Admissibility.** The carried state of charge lies inside `[s_min, s_max]`. The per-action
     check verifies the transition; this verifies the value that survives it, which is what the
     next model will use as `state.soc_before`.
  3. **Replay.** Re-applying the block's implemented aggregate flows to the state of charge that
     entered the block must reproduce the carried value. This catches an accumulated drift that
     no single-period residual is large enough to reveal.

`entry_soc` is the state of charge before the first action of the block.
"""
function check_state_recoverability(
    source::OOSPricedSource,
    state::SimulationState,
    block::AbstractUnitRange{Int},
    entry_soc::Float64,
    actions::AbstractVector{PeriodAction},
    config::OOSExperimentConfig,
)
    template = priced_template(source)
    violations = String[]

    length(actions) == length(block) || push!(violations,
        "El bloque $block comprometió $(length(actions)) acciones.")
    state.period == last(block) + 1 || push!(violations,
        "Tras implementar $block el estado quedó en el período $(state.period) y debía quedar " *
        "en $(last(block) + 1).")
    state.revealed_periods >= last(block) || push!(violations,
        "La historia revelada llega a $(state.revealed_periods) y el bloque $block ya fue " *
        "implementado.")

    soc = state.soc_before
    soc_bound_residual = max(soc - template.s_max, template.s_min - soc, 0.0)
    soc_bound_residual <= config.feasibility_tol || push!(violations,
        "El estado de carga transportado $soc está fuera de [$(template.s_min), " *
        "$(template.s_max)] por $soc_bound_residual.")

    replayed = entry_soc
    for action in actions
        replayed = induced_soc(template, replayed, action.aggregate_charge,
                               action.aggregate_discharge)
    end
    replay_residual = abs(replayed - soc)
    # Scaled by the block length: `h` sequential transitions can accumulate `h` times the
    # per-transition round-off, and holding a ten-period block to a one-period tolerance would
    # reject arithmetic rather than error.
    replay_tolerance = max(1, length(block)) * config.feasibility_tol
    replay_residual <= replay_tolerance || push!(violations,
        "Reaplicar los flujos del bloque $block da $replayed y el estado transporta $soc " *
        "(residuo $replay_residual > $replay_tolerance).")

    return StateRecoverability(
        isempty(violations), state.period, soc, soc_bound_residual, replay_residual, violations,
    )
end

# =====================================================================================
# Shared-battery compatibility gate (Phase 0)
# =====================================================================================

"""One check of the shared-battery micro-instance gate."""
struct GateCheck
    name::String
    passed::Bool
    detail::String
end

"""Result of the whole shared-battery compatibility gate."""
struct GateReport
    passed::Bool
    checks::Vector{GateCheck}
    formulation_id::String
end

gate_summary(report::GateReport) =
    "$(count(c -> c.passed, report.checks))/$(length(report.checks)) verificaciones aprobadas"

function _micro_mode_model(; households::Int=2, nodes::Int=1, charge_limit=3.0, discharge_limit=4.0)
    model = Model(CPLEX.Optimizer)
    set_silent(model)
    @variable(model, y[1:households, 1:nodes] >= 0)
    @variable(model, z[1:households, 1:nodes] >= 0)
    v = add_shared_battery_mode_constraints!(
        model, y, z, 1:households, 1:nodes;
        discharge_limit=discharge_limit, charge_limit=charge_limit,
    )
    @objective(model, Min, 0)
    return (model=model, y=y, z=z, v=v)
end

function _micro_feasible(y_values, z_values; mode=nothing, charge_limit=3.0, discharge_limit=4.0)
    refs = _micro_mode_model(
        households=size(y_values, 1), nodes=size(y_values, 2),
        charge_limit=charge_limit, discharge_limit=discharge_limit,
    )
    fix.(refs.y, y_values; force=true)
    fix.(refs.z, z_values; force=true)
    mode === nothing || fix.(refs.v, mode; force=true)
    optimize!(refs.model)
    return is_solved_and_feasible(refs.model; allow_local=false, dual=false)
end

"""
Run the shared-battery micro-instance gate.

Covers the specification's required cases on at least two households and one or more
battery-decision nodes: cross-household charge/discharge at the same node is infeasible,
same-household simultaneous flow is infeasible, several households may share one aggregate
direction within its rate, idle is feasible under either binary value, and the mode-binary
count equals `|V_mode|`.

Every case here proves an EXCLUSIVITY property that only holds when the shared-battery mode
is binary. Under `config.battery_direction_exclusivity=false` (the `[0,1]` LP relaxation)
none of these infeasibility claims are expected to hold -- a fractional mode legitimately
permits combinations this gate is designed to reject -- so the gate is skipped rather than
restated for a domain it was never written to describe.
"""
function run_shared_battery_micro_gate(config::OOSExperimentConfig)
    if !config.battery_direction_exclusivity
        return GateReport(
            true,
            [GateCheck(
                "shared_battery_micro_gate_not_applicable",
                true,
                "Compuerta omitida: la campaña usa la relajación continua [0,1] del modo " *
                "compartido (battery_direction_exclusivity=false), y esta compuerta prueba " *
                "propiedades de exclusividad que solo aplican a la formulación binaria.",
            )],
            config.formulation_id,
        )
    end

    checks = GateCheck[]

    push!(checks, GateCheck(
        "cross_household_charge_and_discharge_infeasible",
        !_micro_feasible([0.0; 1.0;;], [1.0; 0.0;;]),
        "Un hogar cargando mientras otro recibe descarga en el mismo nodo debe ser infactible.",
    ))
    push!(checks, GateCheck(
        "same_household_simultaneous_flow_infeasible",
        !_micro_feasible([1.0; 0.0;;], [1.0; 0.0;;]),
        "El mismo hogar no puede cargar y descargar simultáneamente.",
    ))
    push!(checks, GateCheck(
        "multiple_households_charge_within_rate",
        _micro_feasible([0.0; 0.0;;], [1.0; 2.0;;]),
        "Varios hogares pueden aportar carga simultánea dentro de F_c.",
    ))
    push!(checks, GateCheck(
        "multiple_households_discharge_within_rate",
        _micro_feasible([1.5; 2.5;;], [0.0; 0.0;;]),
        "Varios hogares pueden recibir descarga simultánea dentro de F_d.",
    ))
    push!(checks, GateCheck(
        "aggregate_charge_rate_enforced",
        !_micro_feasible([0.0; 0.0;;], [1.5; 2.0;;]),
        "La suma de cargas no puede exceder F_c.",
    ))
    push!(checks, GateCheck(
        "aggregate_discharge_rate_enforced",
        !_micro_feasible([2.0; 2.1;;], [0.0; 0.0;;]),
        "La suma de descargas no puede exceder F_d.",
    ))
    push!(checks, GateCheck(
        "idle_feasible_in_both_modes",
        _micro_feasible(zeros(2, 1), zeros(2, 1); mode=[0.0]) &&
        _micro_feasible(zeros(2, 1), zeros(2, 1); mode=[1.0]),
        "La operación en reposo es factible con cualquiera de los dos valores binarios.",
    ))

    multi_node = _micro_mode_model(households=3, nodes=4)
    generated = generated_binary_count(multi_node.model)
    push!(checks, GateCheck(
        "mode_binary_count_equals_mode_nodes",
        generated == 4,
        "Con 3 hogares y 4 nodos se generaron $generated binarios; se esperan 4 (|V_mode|), " *
        "no 12 (|H||V_mode|).",
    ))
    push!(checks, GateCheck(
        "mode_variable_is_not_household_indexed",
        all(!occursin(',', name(variable)) for variable in multi_node.v) &&
        all(startswith(name(variable), "battery_mode[") for variable in multi_node.v),
        "El modo compartido debe llamarse battery_mode[n] y no llevar índice de hogar.",
    ))

    passed = all(check -> check.passed, checks)
    return GateReport(passed, checks, config.formulation_id)
end

"""
Run the compatibility gate on the full experiment stack: one gate solve per controller and
per allocation/fairness rule, verifying the mode condition end to end.
"""
function run_controller_fairness_gate(
    context::OOSRollingContext,
    provider::RepositoryUncertaintyProvider,
    static_shares::Union{Matrix{Float64},OOSStaticShareTable};
    period::Int=1,
)
    config = context.config
    checks = GateCheck[]
    path = sample_oos_path(
        provider, rolling_realized_end(context), oos_path_rng(config, 0); replication_id=0,
    )
    # The gate must solve the model the campaign solves, so it uses the same fixed moving window
    # and reveals the same complete known prefix block `reveal_block!` does in the real
    # simulation loop — not just one period, which is wrong as soon as h = implementation_step
    # exceeds 1 (the observed history must cover the whole block, not just `period`).
    horizon_end = lookahead_end_period(config, period)
    block = implementation_block(config, period)

    for controller in config.controller_set, policy in config.fairness_set
        state = initial_simulation_state(context, 0)
        reveal_block!(state, path, block)
        observation = PeriodObservation(period, path.pv[period], collect(path.demand[:, period]))
        tree = build_lookahead_tree(
            provider, config, controller, observed_history(state), period, horizon_end, 0,
        )
        result = solve_current_action(
            context, state, observation, tree, controller, policy, config;
            static_shares=static_shares, implementation_block=block,
        )
        name = "gate_$(controller)_$(policy)"
        if !result.solved
            push!(checks, GateCheck(name, false, "No se obtuvo acción: $(result.failure_message)"))
            continue
        end
        action = result.action
        # The mode/count/simultaneity properties below only characterize the binary
        # formulation; under the `[0,1]` LP relaxation a fractional mode and simultaneous
        # nonzero aggregate charge/discharge are both expected, not violations.
        if config.battery_direction_exclusivity
            mode_ok = action.shared_battery_mode in (0, 1)
            counts_ok = result.statistics.generated_mode_binaries == result.statistics.expected_mode_nodes
            simultaneous_ok = !(action.aggregate_charge > config.flow_tol &&
                                action.aggregate_discharge > config.flow_tol)
        else
            mode_ok = 0.0 <= action.shared_battery_mode <= 1.0
            counts_ok = result.statistics.generated_mode_binaries == 0
            simultaneous_ok = true
        end
        links_ok = max(result.residuals.charge_link, result.residuals.discharge_link) <=
                   config.feasibility_tol
        push!(checks, GateCheck(
            name,
            mode_ok && counts_ok && simultaneous_ok && links_ok,
            "modo=$(action.shared_battery_mode), binarios=$(result.statistics.generated_mode_binaries)/" *
            "$(result.statistics.expected_mode_nodes), Z=$(action.aggregate_charge), " *
            "Y=$(action.aggregate_discharge), residuo de vínculo=" *
            "$(max(result.residuals.charge_link, result.residuals.discharge_link))",
        ))
    end

    passed = all(check -> check.passed, checks)
    return GateReport(passed, checks, config.formulation_id)
end

"""Merge several gate reports into one."""
function merge_gate_reports(reports::GateReport...)
    checks = GateCheck[]
    for report in reports
        append!(checks, report.checks)
    end
    return GateReport(all(check -> check.passed, checks), checks, first(reports).formulation_id)
end

"""Print a gate report and raise when it did not pass."""
function enforce_gate!(report::GateReport; label::String="compuerta de batería compartida")
    println("### $label ($(gate_summary(report)))")
    for check in report.checks
        println("  ", check.passed ? "[OK]  " : "[FALLA] ", check.name, " :: ", check.detail)
    end
    report.passed || error(
        "La $label no pasó; la campaña permanece bloqueada. Revisa las verificaciones marcadas [FALLA]."
    )
    return report
end
