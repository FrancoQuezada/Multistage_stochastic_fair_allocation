# =====================================================================================
# Controller API.
#
# `solve_current_action` is the only way a controller produces a decision. The three
# controllers differ exclusively in the look-ahead information structure they were handed;
# the physical model, the shared-battery mode convention and the fairness rules are shared.
#
# Every future decision returned by the optimization model is discarded after the current
# action has been extracted.
# =====================================================================================

"""
Solve one remaining-horizon problem and extract the current-period action.

The returned `PeriodAction` contains exactly one scalar shared-battery operating mode plus the
household-indexed physical flows. In `TWO_STAGE_RH` that action is the first-stage decision,
common to every future scenario; in `MULTISTAGE_RH` it belongs to the root information state;
in `DETERMINISTIC_RH` it is the current-period decision of the single forecast path.
"""
function solve_current_action(
    source::OOSPricedSource,
    simulation_state::SimulationState,
    current_observation::PeriodObservation,
    lookahead_tree::LookaheadTree,
    controller_kind::ControllerKind,
    fairness_policy::FairnessPolicy,
    experiment_config::OOSExperimentConfig;
    mip_start::Union{Nothing,ModeStart}=nothing,
    static_shares::Union{Nothing,Matrix{Float64},OOSStaticShareTable}=nothing,
    implementation_block::AbstractUnitRange{Int}=simulation_state.period:simulation_state.period,
)
    instance_template = priced_template(source)
    _assert_lookahead_consistency(
        instance_template, simulation_state, current_observation, lookahead_tree,
        controller_kind, experiment_config; implementation_block=implementation_block,
    )

    expected_modes = expected_mode_binary_count(lookahead_tree)
    expected_binaries = expected_binary_count(
        lookahead_tree, instance_template.J, experiment_config.grid_direction_exclusivity,
        experiment_config.battery_direction_exclusivity,
    )
    t_build = time()
    refs = try
        build_remaining_horizon_model(
            source, simulation_state, lookahead_tree, experiment_config,
        )
    catch exception
        return _failed_controller_result(
            controller_kind, fairness_policy, simulation_state, expected_modes,
            "Fallo al construir el modelo: $(sprint(showerror, exception))",
            time() - t_build,
        )
    end

    past = fairness_past_state(simulation_state)
    context = try
        add_fairness_constraints!(
            refs, fairness_policy, past, experiment_config; static_shares=static_shares,
        )
    catch exception
        return _failed_controller_result(
            controller_kind, fairness_policy, simulation_state, expected_modes,
            "Fallo al imponer la regla $(fairness_policy): $(sprint(showerror, exception))",
            refs.build_time_sec,
        )
    end
    build_time = time() - t_build

    if mip_start !== nothing
        try
            apply_mode_start!(refs, mip_start)
        catch exception
            return _failed_controller_result(
                controller_kind, fairness_policy, simulation_state, expected_modes,
                "Arranque MIP rechazado: $(sprint(showerror, exception))", build_time,
            )
        end
    end

    # The mode-node count of the generated model must match the centralized expectation before
    # any value is read back.
    generated_before_solve = generated_binary_count(refs.model)
    if generated_before_solve != expected_binaries
        return _failed_controller_result(
            controller_kind, fairness_policy, simulation_state, expected_modes,
            "El modelo generó $generated_before_solve binarios y la convención centralizada " *
            "espera $expected_binaries ($expected_modes de modo compartido más " *
            "$(expected_binaries - expected_modes) de dirección de red).",
            build_time,
        )
    end

    lex_result = nothing
    t_solve = time()
    if is_lexicographic_policy(fairness_policy)
        lex_result = solve_lexicographic!(
            refs, fairness_policy, past, context.aggregates, experiment_config,
        )
    else
        optimize!(refs.model)
    end
    solve_wall = time() - t_solve
    solver_time = is_lexicographic_policy(fairness_policy) ?
        lex_result.solver_time_sec : _safe_solve_time(refs.model)

    statistics = collect_model_statistics(refs, lookahead_tree)
    phases = lex_result === nothing ?
        [_phase_record(refs.model, 0, "single_solve", solve_wall, solver_time)] :
        lex_result.phase_records
    strict_outcome = classify_solve_outcome(refs.model)
    # Stage 8: SA joined PEA in needing an endogenous minimum band, so the recovery workflow —
    # and the record that reports it — now covers both. The record type is unchanged.
    recoverable =
        fairness_policy === PEA ? experiment_config.pea_tolerance_mode === :adaptive_minimum :
        fairness_policy === SA ? experiment_config.sa_tolerance_mode === :adaptive_minimum : false
    pea_record = fairness_policy in (PEA, SA) ?
        pea_strict_success(string(strict_outcome)) : pea_not_applicable()
    solve_failed = !has_values(refs.model) || (lex_result !== nothing && !lex_result.solved)

    # --- strict-first / adaptive-minimum PEA recovery -----------------------------------
    if solve_failed && recoverable
        recovery = attempt_adaptive_pea_recovery(
            source, simulation_state, lookahead_tree, experiment_config, past,
            string(strict_outcome), strict_outcome; policy=fairness_policy,
        )
        append!(phases, recovery.phases)
        pea_record = recovery.pea
        if recovery.solved
            # From here on the Phase-II model is the model of record; the strict model and the
            # diagnostic model are discarded and neither supplies an implemented action.
            refs = recovery.refs
            context = recovery.context
            statistics = collect_model_statistics(refs, lookahead_tree)
            solve_wall += recovery.wall_time_sec
            solver_time += recovery.solver_time_sec
            solve_failed = false
        else
            solve_wall += recovery.wall_time_sec
            solver_time += recovery.solver_time_sec
        end
    elseif solve_failed && fairness_policy in (PEA, SA)
        # `failure_source`, never `source`: the latter is this function's priced data source.
        failure_source, detail, diagnostic = attribute_failure_source(
            source, simulation_state, lookahead_tree, experiment_config; phase=1,
        )
        diagnostic === nothing || push!(phases, diagnostic)
        pea_record = PEARecoveryRecord(
            true, false, false, 0.0, string(strict_outcome), "not_run", "not_run",
            "recovery_disabled", string(failure_source),
        )
    end

    termination = string(termination_status(refs.model))
    primal = string(primal_status(refs.model))

    if solve_failed
        message = lex_result !== nothing && !lex_result.solved ?
            lex_result.failure_message :
            "El modelo no produjo valores (terminación $termination, primal $primal)."
        if fairness_policy in (PEA, SA)
            message *= " PEA_RECOVERY=$(pea_record.recovery_status) " *
                       "FAILURE_SOURCE=$(pea_record.failure_source)"
        else
            failure_source, detail, diagnostic = attribute_failure_source(
                source, simulation_state, lookahead_tree, experiment_config; phase=1,
            )
            diagnostic === nothing || push!(phases, diagnostic)
            message *= " FAILURE_SOURCE=$(failure_source) ($detail)"
        end
        return ControllerResult(
            controller_kind, fairness_policy, simulation_state.period,
            termination, primal, false, nothing,
            NaN, NaN,
            lex_result === nothing ? Float64[] : lex_result.phase_objectives,
            build_time, solve_wall, solver_time,
            statistics, zero_residuals(), simulation_state.soc_before, message, nothing,
            phases, pea_record, PeriodAction[],
        )
    end

    block_actions, extraction_message =
        extract_block_actions(refs, experiment_config, implementation_block)
    action = block_actions === nothing ? nothing : first(block_actions)
    if action === nothing
        return ControllerResult(
            controller_kind, fairness_policy, simulation_state.period,
            termination, primal, false, nothing,
            objective_value(refs.model), _safe_objective_bound(refs.model),
            lex_result === nothing ? Float64[] : lex_result.phase_objectives,
            build_time, solve_wall, solver_time,
            statistics, zero_residuals(), simulation_state.soc_before, extraction_message,
            nothing, phases, pea_record, PeriodAction[],
        )
    end

    lex_levels = lex_result === nothing ? nothing : lex_result.phase_levels
    fairness_gap = try
        fairness_residual(
            refs, fairness_policy, past, context; lexicographic_levels=lex_levels,
        )
    catch
        NaN
    end

    residuals = model_side_residuals(refs, simulation_state, experiment_config, fairness_gap)
    # Aggregate flows of the provisional plan, retained only to seed the next period's MIP start.
    plan_flows = experiment_config.use_warm_starts ? aggregate_flows_from_solution(refs) : nothing
    phase_objectives = lex_result === nothing ?
        [objective_value(refs.model)] : lex_result.phase_objectives

    return ControllerResult(
        controller_kind, fairness_policy, simulation_state.period,
        termination, primal, true, action,
        objective_value(refs.model), _safe_objective_bound(refs.model),
        phase_objectives,
        build_time, solve_wall, solver_time,
        statistics, residuals, simulation_state.soc_before, "", plan_flows, phases, pea_record,
        block_actions,
    )
end

# -------------------------------------------------------------------------------------
# Current-action extraction
# -------------------------------------------------------------------------------------

"""
Extract the ordered actions of one committed block from the deterministic prefix chain.

Stage 6: the block `t : t+h-1` lives on the known prefix, which is branch-free by construction,
so exactly one node carries each committed period and the extraction is unambiguous rather than a
choice among scenarios. A prefix that is not a chain is a contract violation and is reported as
one; nothing is averaged, selected or repaired.

Returns `(actions, message)`; `actions === nothing` on any failure, with `message` naming it.
"""
function extract_block_actions(
    refs::PhysicalModelRefs,
    config::OOSExperimentConfig,
    block::AbstractUnitRange{Int},
)
    tree = refs.tree
    first(block) == tree.calendar_period[tree.root] || return (
        nothing,
        "El bloque $block no empieza en la raíz del look-ahead " *
        "($(tree.calendar_period[tree.root])).",
    )
    last(block) <= tree.last_period || return (
        nothing,
        "El bloque $block excede la ventana del look-ahead " *
        "($(tree.first_period):$(tree.last_period)).",
    )

    node = tree.root
    actions = PeriodAction[]
    for period in block
        tree.calendar_period[node] == period || return (
            nothing,
            "El nodo $node del prefijo está en el período $(tree.calendar_period[node]) y el " *
            "bloque espera $period.",
        )
        action, message = extract_action_at(refs, config, node)
        action === nothing && return (nothing, "Período $period: $message")
        push!(actions, action)
        period == last(block) && break
        children = [n for n in tree.nodes if tree.parent[n] == node]
        length(children) == 1 || return (
            nothing,
            "El prefijo conocido debe ser una cadena determinista: el nodo $node del período " *
            "$period tiene $(length(children)) hijos, así que el período $(period + 1) no " *
            "tiene una acción comprometida única.",
        )
        node = only(children)
    end
    return (actions, "")
end

"""
Extract the current-period action from the root information state.

Retained shape: it is `extract_action_at` at the root, i.e. the single-period case of
`extract_block_actions`.
"""
extract_current_action(refs::PhysicalModelRefs, config::OOSExperimentConfig) =
    extract_action_at(refs, config, refs.tree.root)

"""
Extract the action committed at one information state.

Every future decision of the solved model other than this node's is discarded here. The shared
mode is a scalar and is required to exist at the node.
"""
function extract_action_at(refs::PhysicalModelRefs, config::OOSExperimentConfig, root::Int)
    tree = refs.tree
    J = refs.template.J

    root in refs.mode_nodes || return (
        nothing,
        "El nodo $root no declara un modo compartido de batería; la acción sería incompleta.",
    )

    mode_value = value(refs.v[root])
    local mode::Float64
    if refs.battery_direction_exclusivity
        integrality = min(abs(mode_value), abs(1 - mode_value))
        if integrality > config.integrality_tol
            return (
                nothing,
                "El modo compartido de la raíz no es binario: v=$mode_value " *
                "(residuo $integrality > $(config.integrality_tol)).",
            )
        end
        mode = Float64(round(mode_value))
    else
        # LP relaxation: the solved value may be legitimately fractional in [0,1] and is kept
        # unrounded, so it stays consistent with the physical link constraints it satisfied.
        mode = mode_value
    end

    p = [value(refs.p[j, root]) for j in 1:J]
    z = [value(refs.z[j, root]) for j in 1:J]
    y = [value(refs.y[j, root]) for j in 1:J]
    I = [value(refs.I[j, root]) for j in 1:J]
    G = [value(refs.G[j, root]) for j in 1:J]
    lambda = [value(refs.lambda[j, root]) for j in 1:J]

    charge = sum(z)
    discharge = sum(y)
    model_charge = value(refs.aggregate_charge[root])
    model_discharge = value(refs.aggregate_discharge[root])
    if abs(charge - model_charge) > config.feasibility_tol ||
       abs(discharge - model_discharge) > config.feasibility_tol
        return (
            nothing,
            "Los agregados almacenados no coinciden con la suma de los flujos por hogar " *
            "(carga $charge vs $model_charge, descarga $discharge vs $model_discharge).",
        )
    end

    action = PeriodAction(
        tree.calendar_period[root], mode, p, z, y, I, G, lambda,
        charge, discharge, value(refs.s[root]),
    )
    return (action, "")
end

# -------------------------------------------------------------------------------------
# Model-side residuals at the root
# -------------------------------------------------------------------------------------

"""
Residuals of the solved model at the root information state.

These check the *model*; the implemented action is checked independently by the simulator in
`validation.jl`, so an inconsistency between model and simulator cannot hide.
"""
function model_side_residuals(
    refs::PhysicalModelRefs,
    state::SimulationState,
    config::OOSExperimentConfig,
    fairness_gap::Float64,
)
    tree = refs.tree
    template = refs.template
    root = tree.root
    J = template.J

    p = [value(refs.p[j, root]) for j in 1:J]
    z = [value(refs.z[j, root]) for j in 1:J]
    y = [value(refs.y[j, root]) for j in 1:J]
    I = [value(refs.I[j, root]) for j in 1:J]
    G = [value(refs.G[j, root]) for j in 1:J]
    charge = sum(z)
    discharge = sum(y)
    mode = value(refs.v[root])
    soc_after = value(refs.s[root])

    pv_residual = abs(sum(p) - tree.pv[root])
    balance_residual = maximum(
        abs(tree.demand[j, root] - (p[j] + y[j] + I[j] - z[j] - G[j])) for j in 1:J
    )
    transition_residual = abs(soc_after - induced_soc(template, state.soc_before, charge, discharge))
    charge_link = max(charge - template.f_under * mode, 0.0)
    discharge_link = max(discharge - template.f_bar * (1 - mode), 0.0)
    simultaneous = min(max(charge, 0.0), max(discharge, 0.0))
    integrality = min(abs(mode), abs(1 - mode))
    soc_bounds = max(soc_after - template.s_max, template.s_min - soc_after, 0.0)
    # The terminal target binds at the end of this look-ahead window, so the ROOT carries a
    # terminal residual only in the degenerate case where the window is a single period.
    terminal = tree.calendar_period[root] == tree.last_period ?
        abs(soc_after - template.s_I) : 0.0

    return ActionResiduals(
        pv_residual, balance_residual, transition_residual,
        charge_link, discharge_link, simultaneous <= config.flow_tol ? 0.0 : simultaneous,
        integrality, soc_bounds, terminal, fairness_gap,
    )
end

# -------------------------------------------------------------------------------------
# Solver-status classification
# -------------------------------------------------------------------------------------

"""
Classify one solve.

A primal solution is decisive: if the solver produced values the model is feasible, whatever
the termination status says (a time limit with an incumbent still proves feasibility). Only
`SOLVE_PROVEN_INFEASIBLE` and `SOLVE_PRESUMED_INFEASIBLE` may lead to PEA recovery, and the
presumed case additionally requires the physical diagnostic to come back feasible. Time
limits, numerical errors and unrecognized statuses are never read as fairness infeasibility.
"""
function classify_solve_outcome(model::JuMP.Model)
    has_values(model) && return SOLVE_OK
    status = termination_status(model)
    status == MOI.INFEASIBLE && return SOLVE_PROVEN_INFEASIBLE
    status == MOI.INFEASIBLE_OR_UNBOUNDED && return SOLVE_PRESUMED_INFEASIBLE
    status == MOI.TIME_LIMIT && return SOLVE_TIME_LIMIT
    status in (MOI.NUMERICAL_ERROR, MOI.SLOW_PROGRESS, MOI.INVALID_MODEL) &&
        return SOLVE_NUMERICAL_ERROR
    return SOLVE_UNKNOWN
end

"""`true` only for outcomes that constitute an infeasibility finding."""
is_infeasibility_finding(outcome::SolveOutcome) =
    outcome in (SOLVE_PROVEN_INFEASIBLE, SOLVE_PRESUMED_INFEASIBLE)

# -------------------------------------------------------------------------------------
# Failure attribution
# -------------------------------------------------------------------------------------

"""
Attribute a failed solve to the allocation/fairness rule or to the physical model.

Strictly diagnostic. A fresh physical model is built *without* any fairness rule, on the same
current state, look-ahead tree and information, and solved only to label the failure. Its
solution is never extracted, never implemented and never copied into any action.

Returns `(source, detail, record)`. `FAILURE_UNDETERMINED` is returned whenever the diagnostic
itself hits a time limit, a numerical error or an unrecognized status, so an inconclusive probe
can never be mistaken for a fairness finding.

`record` is the `SolvePhaseRecord` of the diagnostic solve. It exists so the solve log counts
this solve honestly — a recovered period runs **four** solves (strict, diagnostic, Phase I,
Phase II), not three. The record is bookkeeping only: its objective value is diagnostic and its
solution is never extracted or implemented.
"""
function attribute_failure_source(
    source::OOSPricedSource,
    state::SimulationState,
    tree::LookaheadTree,
    config::OOSExperimentConfig;
    phase::Int=1,
)
    t_probe = time()
    try
        probe = build_remaining_horizon_model(source, state, tree, config)
        optimize!(probe.model)
        wall = time() - t_probe
        record = _phase_record(
            probe.model, phase, "pea_diagnostic_physical", wall, _safe_solve_time(probe.model),
        )
        outcome = classify_solve_outcome(probe.model)
        if outcome === SOLVE_OK
            return (FAILURE_FAIRNESS_RULE,
                    "el modelo físico sin regla distributiva es factible en este período, " *
                    "así que la regla es inalcanzable dado el pasado realizado fijo", record)
        elseif is_infeasibility_finding(outcome)
            return (FAILURE_PHYSICAL_MODEL,
                    "el modelo físico sin regla distributiva también es infactible ($outcome)",
                    record)
        end
        return (FAILURE_UNDETERMINED,
                "el diagnóstico físico terminó en $outcome sin prueba de (in)factibilidad",
                record)
    catch exception
        return (FAILURE_UNDETERMINED, sprint(showerror, exception), nothing)
    end
end

# -------------------------------------------------------------------------------------
# Adaptive-minimum PEA recovery (Phase I and Phase II)
# -------------------------------------------------------------------------------------

"""
Phase I: minimize the common absolute PEA band.

    min epsilon_pea
    s.t. the complete current physical model,
         -epsilon_pea <= P_past[j] + E_t[P_future[j]] - Q[j] <= epsilon_pea   for all j,
         epsilon_pea >= 0

`epsilon_pea_star` is the smallest household-level deviation, in kWh, that makes the
rolling-horizon problem feasible given the realized past.
"""
function solve_minimum_pea_tolerance!(
    refs::PhysicalModelRefs,
    past::FairnessPastState,
    aggregates,
    config::OOSExperimentConfig,
)
    handles = build_adaptive_pea_constraints!(refs, past, aggregates)
    @objective(refs.model, Min, handles.epsilon)
    t_phase = time()
    optimize!(refs.model)
    wall = time() - t_phase
    solver = _safe_solve_time(refs.model)
    outcome = classify_solve_outcome(refs.model)
    return (
        handles=handles,
        outcome=outcome,
        epsilon_star=outcome === SOLVE_OK ? value(handles.epsilon) : NaN,
        wall_time_sec=wall,
        solver_time_sec=solver,
        record=_phase_record(refs.model, 2, "pea_phase1_min_tolerance", wall, solver),
    )
end

"""
Phase II: restore the operational objective at the minimum band.

Adds `epsilon_pea <= epsilon_pea_star + pea_tolerance_numeric_eps` and re-optimizes the
expected remaining operating cost. The Phase-I optimum remains feasible for this problem, so
Phase II cannot be made infeasible by the cap itself.

`pea_tolerance_numeric_eps` is added to `epsilon_pea_star`, so it is measured in the **same
unit, kWh** — it is not dimensionless. It is a small absolute numerical allowance (default
`1e-6` kWh), orders of magnitude below any observed band, and never an economic relaxation.
"""
function solve_pea_operational_phase!(
    refs::PhysicalModelRefs,
    handles,
    epsilon_star::Float64,
    config::OOSExperimentConfig,
)
    @constraint(refs.model, pea_tolerance_cap,
        handles.epsilon <= epsilon_star + config.pea_tolerance_numeric_eps)
    set_expected_cost_objective!(refs)
    t_phase = time()
    optimize!(refs.model)
    wall = time() - t_phase
    solver = _safe_solve_time(refs.model)
    outcome = classify_solve_outcome(refs.model)
    return (
        outcome=outcome,
        epsilon=outcome === SOLVE_OK ? value(handles.epsilon) : NaN,
        wall_time_sec=wall,
        solver_time_sec=solver,
        record=_phase_record(refs.model, 3, "pea_phase2_operational", wall, solver),
    )
end

"""
Phase I for SA: minimize the common absolute savings band.

Structurally identical to `solve_minimum_pea_tolerance!`, on the SA outcome measure. `epsilon_sa`
is the smallest household-level savings deviation that makes the rolling-horizon problem feasible
given the realized past.
"""
function solve_minimum_sa_tolerance!(
    refs::PhysicalModelRefs,
    past::FairnessPastState,
    aggregates,
    config::OOSExperimentConfig,
)
    handles = build_adaptive_sa_constraints!(refs, past, aggregates)
    @objective(refs.model, Min, handles.epsilon)
    t_phase = time()
    optimize!(refs.model)
    wall = time() - t_phase
    solver = _safe_solve_time(refs.model)
    outcome = classify_solve_outcome(refs.model)
    return (
        handles=handles,
        outcome=outcome,
        epsilon_star=outcome === SOLVE_OK ? value(handles.epsilon) : NaN,
        wall_time_sec=wall,
        solver_time_sec=solver,
        record=_phase_record(refs.model, 2, "pea_phase1_min_tolerance", wall, solver),
    )
end

"""
Phase II for SA: restore the operational objective at the minimum band.

Adds `epsilon_sa <= epsilon_sa_star + pea_tolerance_numeric_eps` and re-optimizes the expected
remaining operating cost. The Phase-I optimum stays feasible, so the cap cannot make Phase II
infeasible by itself. The numerical allowance is shared with PEA deliberately: it is a round-off
guard, not a policy parameter.
"""
function solve_sa_operational_phase!(
    refs::PhysicalModelRefs,
    handles,
    epsilon_star::Float64,
    config::OOSExperimentConfig,
)
    @constraint(refs.model, sa_tolerance_cap,
        handles.epsilon <= epsilon_star + config.pea_tolerance_numeric_eps)
    set_expected_cost_objective!(refs)
    t_phase = time()
    optimize!(refs.model)
    wall = time() - t_phase
    solver = _safe_solve_time(refs.model)
    outcome = classify_solve_outcome(refs.model)
    return (
        outcome=outcome,
        epsilon=outcome === SOLVE_OK ? value(handles.epsilon) : NaN,
        wall_time_sec=wall,
        solver_time_sec=solver,
        record=_phase_record(refs.model, 3, "pea_phase2_operational", wall, solver),
    )
end

"""
Run the adaptive-minimum PEA recovery after a strict solve failed.

Guarded so the band can only be activated when the strict model is proven infeasible *and*
the same physical model without PEA is feasible. Everything else — time limits, numerical
errors, unknown statuses, physical infeasibility — returns without activating any tolerance.

The recovery rebuilds the model from the identical priced source, state, tree and configuration,
so the strict and adaptive formulations differ only in equality versus optimized band.
"""
function attempt_adaptive_pea_recovery(
    source::OOSPricedSource,
    state::SimulationState,
    tree::LookaheadTree,
    config::OOSExperimentConfig,
    past::FairnessPastState,
    strict_status::String,
    strict_outcome::SolveOutcome;
    policy::FairnessPolicy=PEA,
)
    policy in (PEA, SA) || error(
        "La recuperación de banda mínima solo aplica a PEA y SA; se recibió $policy."
    )
    phase1_solver = policy === PEA ? solve_minimum_pea_tolerance! : solve_minimum_sa_tolerance!
    phase2_solver = policy === PEA ? solve_pea_operational_phase! : solve_sa_operational_phase!
    blocked(recovery_status, failure_source) = (
        solved=false, refs=nothing, context=nothing, phases=SolvePhaseRecord[],
        wall_time_sec=0.0, solver_time_sec=0.0,
        pea=PEARecoveryRecord(true, false, false, 0.0, strict_status, "not_run", "not_run",
                              recovery_status, string(failure_source)),
    )

    # Gate 1: an infeasibility finding is required. No proof, no recovery.
    is_infeasibility_finding(strict_outcome) ||
        return blocked("blocked_no_infeasibility_proof", FAILURE_UNDETERMINED)

    # Gate 2: the failure must be attributable to the fairness rule, not to the physics.
    # This is solve #2 of the recovered period and is logged as such.
    failure_source, detail, diagnostic =
        attribute_failure_source(source, state, tree, config; phase=1)
    diagnostic_phases = diagnostic === nothing ? SolvePhaseRecord[] : [diagnostic]
    if failure_source === FAILURE_PHYSICAL_MODEL
        return (; blocked("blocked_physical_model", failure_source)..., phases=diagnostic_phases)
    elseif failure_source === FAILURE_UNDETERMINED
        return (;
            blocked("blocked_undetermined_source", failure_source)...,
            phases=diagnostic_phases,
        )
    end

    refs = build_remaining_horizon_model(source, state, tree, config)
    aggregates = scenario_aggregates(source, tree)

    phase1 = phase1_solver(refs, past, aggregates, config)
    if phase1.outcome !== SOLVE_OK
        return (solved=false, refs=nothing, context=nothing,
                phases=vcat(diagnostic_phases, [phase1.record]),
                wall_time_sec=phase1.wall_time_sec, solver_time_sec=phase1.solver_time_sec,
                pea=PEARecoveryRecord(true, false, false, 0.0, strict_status,
                                      string(phase1.outcome), "not_run", "phase1_failed",
                                      string(FAILURE_FAIRNESS_RULE)))
    end

    phase2 = phase2_solver(refs, phase1.handles, phase1.epsilon_star, config)
    total_wall = phase1.wall_time_sec + phase2.wall_time_sec
    total_solver = phase1.solver_time_sec + phase2.solver_time_sec
    if phase2.outcome !== SOLVE_OK
        # No silent fallback: the Phase-I solution is never implemented.
        return (solved=false, refs=nothing, context=nothing,
                phases=vcat(diagnostic_phases, [phase1.record, phase2.record]),
                wall_time_sec=total_wall, solver_time_sec=total_solver,
                pea=PEARecoveryRecord(true, false, false, 0.0, strict_status,
                                      string(phase1.outcome), string(phase2.outcome),
                                      "phase2_failed", string(FAILURE_FAIRNESS_RULE)))
    end

    tolerance = phase2.epsilon
    activated = tolerance > OOS_PEA_ACTIVATION_THRESHOLD
    return (
        solved=true, refs=refs,
        context=(policy=policy, aggregates=aggregates, handles=phase1.handles),
        phases=vcat(diagnostic_phases, [phase1.record, phase2.record]),
        wall_time_sec=total_wall, solver_time_sec=total_solver,
        pea=PEARecoveryRecord(true, false, activated, tolerance, strict_status,
                              string(phase1.outcome), string(phase2.outcome),
                              "recovered", string(FAILURE_FAIRNESS_RULE)),
    )
end

# -------------------------------------------------------------------------------------
# Internal helpers
# -------------------------------------------------------------------------------------

function _assert_lookahead_consistency(
    template::OOSInstanceTemplate,
    state::SimulationState,
    observation::PeriodObservation,
    tree::LookaheadTree,
    controller::ControllerKind,
    config::OOSExperimentConfig;
    implementation_block::AbstractUnitRange{Int}=state.period:state.period,
)
    tree.controller === controller || error(
        "El look-ahead fue construido para $(tree.controller) y se solicitó $controller."
    )
    observation.period == state.period || error(
        "La observación corresponde al período $(observation.period) y el estado al $(state.period)."
    )
    tree.calendar_period[tree.root] == observation.period || error(
        "La raíz del look-ahead no coincide con el período observado."
    )
    abs(tree.pv[tree.root] - observation.pv) <= config.feasibility_tol || error(
        "La raíz del look-ahead usa PV $(tree.pv[tree.root]) y la realización observada es $(observation.pv)."
    )
    for j in 1:template.J
        abs(tree.demand[j, tree.root] - observation.demand[j]) <= config.feasibility_tol || error(
            "La raíz del look-ahead no reproduce la demanda observada del hogar $j."
        )
    end

    # STAGE 6. Every period of the known prefix — not only the root — must be deterministic and
    # must reproduce the realization the simulator revealed. Checking the whole prefix is what
    # rules out a controller silently being handed sampled values where another was handed
    # realized ones.
    state.revealed_periods >= last(implementation_block) || error(
        "El bloque $implementation_block excede la historia revelada " *
        "($(state.revealed_periods) períodos)."
    )
    node = tree.root
    for period in implementation_block
        tree.calendar_period[node] == period || error(
            "El nodo $node del prefijo está en el período $(tree.calendar_period[node]) y el " *
            "bloque comprometido espera $period."
        )
        abs(tree.pv[node] - state.realized_pv_history[period]) <= config.feasibility_tol || error(
            "El período $period del prefijo usa PV $(tree.pv[node]) y la realización revelada " *
            "es $(state.realized_pv_history[period])."
        )
        for j in 1:template.J
            abs(tree.demand[j, node] - state.realized_demand_history[j, period]) <=
                config.feasibility_tol || error(
                "El período $period del prefijo no reproduce la demanda realizada del hogar $j."
            )
        end
        period == last(implementation_block) && break
        children = [n for n in tree.nodes if tree.parent[n] == node]
        length(children) == 1 || error(
            "El prefijo conocido debe ser determinista y común: el nodo $node del período " *
            "$period se ramifica en $(length(children)) hijos antes del fin del bloque " *
            "$implementation_block."
        )
        node = only(children)
    end
    return nothing
end

function _failed_controller_result(
    controller::ControllerKind,
    policy::FairnessPolicy,
    state::SimulationState,
    expected_modes::Int,
    message::String,
    build_time::Float64,
)
    return ControllerResult(
        controller, policy, state.period,
        "BUILD_OR_START_FAILURE", "NO_SOLUTION", false, nothing,
        NaN, NaN, Float64[],
        build_time, 0.0, 0.0,
        empty_model_statistics(expected_modes), zero_residuals(),
        state.soc_before, message, nothing, SolvePhaseRecord[],
        PEARecoveryRecord(policy === PEA, false, false, 0.0, "build_failure", "not_run",
                          "not_run", "build_failure", string(FAILURE_UNDETERMINED)),
        PeriodAction[],
    )
end

_safe_objective_bound(model::JuMP.Model) = try
    objective_bound(model)
catch
    NaN
end
