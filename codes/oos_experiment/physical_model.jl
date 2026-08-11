# =====================================================================================
# The single verified physical model builder of the out-of-sample experiment.
#
# Every controller and every allocation/fairness rule calls this one function, so the
# shared-battery physics cannot diverge between compared configurations. The shared-battery
# operating mode is created exclusively by the repository's verified
# `add_shared_battery_mode_constraints!`, which produces one node-level binary
# `battery_mode[n]` and the two aggregate rate rows
#
#     sum_j y[j,n] <= F_d (1 - v_n),      sum_j z[j,n] <= F_c v_n.
#
# There is no household-indexed BATTERY mode variable: the shared-battery correction does not
# imply one, and none exists anywhere in this module.
#
# There IS, since stage 8, a household-indexed GRID-DIRECTION binary. It is a different family
# with a different justification: a household has one grid connection point, so it cannot import
# and export at the same information state. The stage-8 Phase-A audit found that the unrestricted
# formulation admitted such overlap in practice — up to 318 kWh in one period under `SA`, where
# inflating a household's cost is a way to reach a savings-equality target by burning energy. The
# two families are counted separately everywhere so the shared-battery model-size claim stays
# exactly as measurable as before.
# =====================================================================================

"""
Explicit references into one generated remaining-horizon model.

`v` is the node-level shared-battery operating mode; it is never a household-indexed
container. `aggregate_charge[n]` and `aggregate_discharge[n]` are the aggregate flows `Z_n`
and `Y_n`.
"""
struct PhysicalModelRefs
    model::JuMP.Model

    s::Any
    I::Any
    G::Any
    z::Any
    y::Any
    p::Any
    lambda::Any
    v::Any

    aggregate_charge::Any
    aggregate_discharge::Any

    mode_nodes::Vector{Int}

    # --- context needed by the fairness layers and the audit ----------------------------
    node_cost::Any
    future_cost::Any
    expected_future_cost::Any
    tree::LookaheadTree

    """
    The priced source this model was built from: an `OOSRollingContext` on the campaign path,
    a bare `OOSInstanceTemplate` on the retained pre-stage-4 path. The fairness layers read
    their prices through it, so a look-ahead reaching past T0 is priced from the extended
    support rather than from `template.nu`.
    """
    source::OOSPricedSource

    """
    Readability alias of `priced_template(source)`; the two are equal by construction. Physical
    parameters are read far more often than prices, so they keep their short spelling.
    """
    template::OOSInstanceTemplate

    formulation_variant::Symbol

    """Whether this model carries the stage-8 grid-direction binaries."""
    grid_direction_exclusivity::Bool

    build_time_sec::Float64
end

"""
Primal feasibility tolerance pinned into CPLEX for every out-of-sample model.

This is the solver's *guarantee*: a returned solution may violate any single row by up to this
much. Every action-validation tolerance is calibrated above it — a validator cannot be stricter
than the solver it validates.
"""
const OOS_SOLVER_FEASIBILITY_TOL = 1e-6

"""Configure the solver identically for every compared configuration."""
function configure_oos_solver!(model::JuMP.Model, config::OOSExperimentConfig)
    set_attribute(model, "CPXPARAM_TimeLimit", config.solver_time_limit_sec)
    set_attribute(model, "CPXPARAM_Simplex_Tolerances_Feasibility", OOS_SOLVER_FEASIBILITY_TOL)
    # Declared, never inherited: see `solver_mip_gap`. Left at the solver's own default, a
    # tolerance of 1e-4 would be of the same order as the effects this study estimates.
    set_attribute(model, "CPXPARAM_MIP_Tolerances_MIPGap", config.solver_mip_gap)
    if config.solver_threads > 0
        set_attribute(model, "CPXPARAM_Threads", config.solver_threads)
    end
    set_silent(model)
    return model
end

"""
Build the look-ahead physical model for one information structure.

`state.soc_before` is the state of charge entering the root period, so the root transition is
`s_root = s_before + delta e_c Z_root - (delta / e_d) Y_root` and every non-root node uses its
parent's state of charge.

Stage 4 changed two things here. The window is no longer the shrinking interval `t:T0`: when the
source is an `OOSRollingContext` the tree must span exactly `lookahead_horizon` abstract periods
from its own root. And the terminal battery target is imposed at **the end of that window**,
`tree.last_period`, instead of permanently at `template.T`. For a legacy tree that still ends at
`template.T` the two coincide, so the retained pre-stage-4 path is unchanged.

Prices come from `priced_matrix(source)`, so a window reaching past the repository horizon uses
the extended support built in stage 3.
"""
function build_remaining_horizon_model(
    source::OOSPricedSource,
    state::SimulationState,
    tree::LookaheadTree,
    config::OOSExperimentConfig,
)
    t_build = time()
    assert_mode_node_consistency(tree)
    template = priced_template(source)
    prices = priced_matrix(source)
    J = template.J
    N = lookahead_node_count(tree)
    size(tree.demand, 1) == J || error("El look-ahead debe declarar la demanda de los $J hogares.")
    tree.calendar_period[tree.root] == state.period || error(
        "La raíz del look-ahead está en el período $(tree.calendar_period[tree.root]) " *
        "pero el estado está en $(state.period)."
    )
    assert_priced_period(source, tree.last_period)
    if source isa OOSRollingContext
        # The stage-4 moving-window contract. It is enforced only on the campaign path: the
        # retained bare-template method keeps accepting the pre-stage-4 shrinking horizon.
        _assert_matching_temporal_contract(source.config, config)
        span = tree.last_period - tree.first_period + 1
        span == config.lookahead_horizon || error(
            "El look-ahead cubre $span períodos abstractos " *
            "($(tree.first_period):$(tree.last_period)) y el contrato temporal exige " *
            "lookahead_horizon=$(config.lookahead_horizon)."
        )
    end

    model = Model(CPLEX.Optimizer)
    configure_oos_solver!(model, config)
    tau = tree.calendar_period
    prob = tree.probability

    @variable(model, s[1:N] >= 0)
    @variable(model, I[1:J, 1:N] >= 0)
    @variable(model, G[1:J, 1:N] >= 0)
    @variable(model, z[1:J, 1:N] >= 0)
    @variable(model, y[1:J, 1:N] >= 0)
    @variable(model, p[1:J, 1:N] >= 0)
    @variable(model, lambda[1:J, 1:N] >= 0)

    # One shared-battery operating mode per relevant information state, from the verified
    # repository builder. `mode_nodes` comes from the centralized convention only.
    v = add_shared_battery_mode_constraints!(
        model, y, z, 1:J, tree.mode_nodes;
        discharge_limit=template.f_bar,
        charge_limit=template.f_under,
    )

    @expression(model, aggregate_charge[n in 1:N], sum(z[j, n] for j in 1:J))
    @expression(model, aggregate_discharge[n in 1:N], sum(y[j, n] for j in 1:J))

    # Allocation and community energy balance.
    @constraint(model, pv_allocation[j in 1:J, n in 1:N], p[j, n] == lambda[j, n] * tree.pv[n])
    @constraint(model, allocation_shares[n in 1:N], sum(lambda[j, n] for j in 1:J) == 1)

    # Battery state of charge.
    @constraint(model, soc_upper[n in 1:N], s[n] <= template.s_max)
    @constraint(model, soc_lower[n in 1:N], s[n] >= template.s_min)
    @constraint(model, soc_root,
        s[tree.root] == state.soc_before +
                        template.delta * template.e_c * aggregate_charge[tree.root] -
                        template.delta * aggregate_discharge[tree.root] / template.e_d)
    @constraint(model, soc_transition[n in 1:N; n != tree.root],
        s[n] == s[tree.parent[n]] +
                template.delta * template.e_c * aggregate_charge[n] -
                template.delta * aggregate_discharge[n] / template.e_d)

    # Household energy balance.
    @constraint(model, household_balance[j in 1:J, n in 1:N],
        tree.demand[j, n] == p[j, n] + y[j, n] + I[j, n] - z[j, n] - G[j, n])

    # Terminal battery target at the end of the moving look-ahead window. Every controller of a
    # given rolling start shares that endpoint, so the requirement stays identical across the
    # compared methods; it is no longer pinned to the repository horizon.
    @constraint(model, terminal_soc[n in 1:N; tau[n] == tree.last_period], s[n] == template.s_I)

    # Grid-direction exclusivity (stage 8, Phase B). A household has ONE grid connection point,
    # so importing and exporting at the same information state is not physically admissible.
    # Without this rule the pair `(I, G)` has a free common offset — the balance pins only their
    # difference — and although the offset costs `(nu - beta)` per unit and is therefore removed
    # by cost minimization, a savings-equality rule can REWARD it: inflating a household's
    # operating cost drives its realized savings down onto the fairness target. The stage-8
    # Phase-A audit observed exactly that, up to 318 kWh in one period under `SA`.
    #
    # The big-Ms are read off the look-ahead data rather than picked as a constant. When
    # `w = 1` export is off, so the balance gives `I = D + z - p - y <= D + F_c`; when `w = 0`
    # import is off, so `G = p + y - z - D <= C + F_d`. Both bounds are valid on the side the
    # binary enables, which is all a big-M needs.
    if config.grid_direction_exclusivity
        @variable(model, grid_import_direction[1:J, 1:N], Bin)
        @constraint(model, grid_import_cap[j in 1:J, n in 1:N],
            I[j, n] <= (tree.demand[j, n] + template.f_under) * grid_import_direction[j, n])
        @constraint(model, grid_export_cap[j in 1:J, n in 1:N],
            G[j, n] <= (tree.pv[n] + template.f_bar) * (1 - grid_import_direction[j, n]))
    end

    # Named redundant household linking rows, only for the explicitly requested variant.
    if config.formulation_variant === :aggregate_plus_redundant_links
        @constraint(model, redundant_charge_link[j in 1:J, n in tree.mode_nodes],
            z[j, n] <= template.f_under * v[n])
        @constraint(model, redundant_discharge_link[j in 1:J, n in tree.mode_nodes],
            y[j, n] <= template.f_bar * (1 - v[n]))
    end

    @expression(model, node_cost[j in 1:J, n in 1:N],
        template.delta * (
            template.mu * y[j, n] +
            prices[j, tau[n]] * I[j, n] -
            template.beta * G[j, n]
        ))
    @expression(model, future_cost[j in 1:J], sum(prob[n] * node_cost[j, n] for n in 1:N))
    @expression(model, expected_future_cost, sum(future_cost[j] for j in 1:J))

    # Expected remaining operating cost. Past realized costs are constants and are excluded.
    @objective(model, Min, expected_future_cost)

    return PhysicalModelRefs(
        model, s, I, G, z, y, p, lambda, v,
        aggregate_charge, aggregate_discharge, copy(tree.mode_nodes),
        node_cost, future_cost, expected_future_cost,
        tree, source, template, config.formulation_variant,
        config.grid_direction_exclusivity, time() - t_build,
    )
end

"""Convenience form: a context already carries the configuration the model must honour."""
build_remaining_horizon_model(
    context::OOSRollingContext,
    state::SimulationState,
    tree::LookaheadTree,
) = build_remaining_horizon_model(context, state, tree, context.config)

"""
Reject a configuration whose temporal contract disagrees with the context's.

The context materialized its data support from one `(H, L, h)` triple. Building a model against
a different triple would silently price or terminate the window on the wrong endpoint, so the
mismatch is named instead of tolerated. Non-temporal fields (tolerances, solver settings,
formulation variant) may legitimately differ and are not compared.
"""
function _assert_matching_temporal_contract(
    context_config::OOSExperimentConfig,
    config::OOSExperimentConfig,
)
    (context_config.evaluation_horizon == config.evaluation_horizon &&
     context_config.lookahead_horizon == config.lookahead_horizon &&
     context_config.implementation_step == config.implementation_step) || error(
        "El contexto se construyó con (H=$(context_config.evaluation_horizon), " *
        "L=$(context_config.lookahead_horizon), h=$(context_config.implementation_step)) y se " *
        "solicitó el modelo con (H=$(config.evaluation_horizon), " *
        "L=$(config.lookahead_horizon), h=$(config.implementation_step))."
    )
    return nothing
end

"""Restore the expected-future-cost objective after a lexicographic phase."""
function set_expected_cost_objective!(refs::PhysicalModelRefs)
    @objective(refs.model, Min, refs.expected_future_cost)
    return refs
end

# -------------------------------------------------------------------------------------
# Model statistics measured on the generated model
# -------------------------------------------------------------------------------------

"""Number of binary variables actually generated by the solver interface."""
generated_binary_count(model::JuMP.Model) =
    num_constraints(model, VariableRef, JuMP.MOI.ZeroOne)

"""Nonzero coefficient count of the generated linear constraint matrix."""
function model_nonzero_count(model::JuMP.Model)
    total = 0
    for (F, S) in list_of_constraint_types(model)
        F === VariableRef && continue
        for reference in all_constraints(model, F, S)
            object = constraint_object(reference)
            function_value = object.func
            if function_value isa JuMP.AffExpr
                total += length(function_value.terms)
            elseif function_value isa Vector{JuMP.AffExpr}
                total += sum(length(term.terms) for term in function_value; init=0)
            end
        end
    end
    return total
end

"""Total number of constraints, including variable bounds registered as constraints."""
function model_constraint_count(model::JuMP.Model)
    total = 0
    for (F, S) in list_of_constraint_types(model)
        total += num_constraints(model, F, S)
    end
    return total
end

"""Best-effort solver statistic; returns `fallback` when CPLEX does not expose it."""
function safe_solver_attribute(model::JuMP.Model, getter, fallback)
    try
        value = MOI.get(model, getter)
        return value === nothing ? fallback : value
    catch
        return fallback
    end
end

"""
Collect dimensions and solver statistics of one solve.

Every dimension is measured on the generated model. The expected mode-node count comes from
the centralized convention, so a mismatch is detected instead of assumed away.
"""
function collect_model_statistics(refs::PhysicalModelRefs, tree::LookaheadTree)
    model = refs.model
    binaries = generated_binary_count(model)
    variables = num_variables(model)
    # `GeneratedModeBinaries` must remain the SHARED-BATTERY count, not the total: the
    # model-size-effect report compares it against `|H||V_mode|`, and folding the grid-direction
    # family into it would silently corrupt that comparison. The direction binaries are the
    # difference between this and `binaries`.
    direction_binaries = expected_grid_direction_binary_count(
        tree, refs.template.J, refs.grid_direction_exclusivity,
    )
    return ModelStatistics(
        variables,
        binaries,
        variables - binaries,
        model_constraint_count(model),
        model_nonzero_count(model),
        expected_mode_binary_count(tree),
        binaries - direction_binaries,
        unique_policy_mode_count(tree),
        0,
        0,
        Float64(safe_solver_attribute(model, MOI.ObjectiveBound(), NaN)),
        Int(safe_solver_attribute(model, MOI.NodeCount(), 0)),
        Float64(safe_solver_attribute(model, MOI.RelativeGap(), NaN)),
        # Peak resident set size of THIS worker process, in MiB. `Sys.maxrss` is monotone, so the
        # value read after a solve is the high-water mark reached up to that point — which is the
        # quantity that decides how many workers fit on a machine, and the one plan section 7
        # (Stage 14) asks the pilot to review. It is machine-dependent by nature, which is why it
        # is emitted only in `solve_provenance.csv` and never enters the scientific digest.
        Sys.maxrss() / 1024^2,
    )
end

empty_model_statistics(expected_modes::Int=0) =
    ModelStatistics(0, 0, 0, 0, 0, expected_modes, 0, 0, 0, 0, NaN, 0, NaN, NaN)
