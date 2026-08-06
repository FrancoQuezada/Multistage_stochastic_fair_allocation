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
# There is no household-indexed mode variable, and no import/export binary: the
# shared-battery correction does not imply a new grid-direction mode.
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
    template::OOSInstanceTemplate
    formulation_variant::Symbol
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
    if config.solver_threads > 0
        set_attribute(model, "CPXPARAM_Threads", config.solver_threads)
    end
    set_silent(model)
    return model
end

"""
Build the remaining-horizon physical model for one look-ahead structure.

`state.soc_before` is the state of charge entering the root period, so the root transition is
`s_root = s_before + delta e_c Z_root - (delta / e_d) Y_root` and every non-root node uses its
parent's state of charge. The terminal battery target is imposed on the same calendar
endpoint `T` for all controllers.
"""
function build_remaining_horizon_model(
    template::OOSInstanceTemplate,
    state::SimulationState,
    tree::LookaheadTree,
    config::OOSExperimentConfig,
)
    t_build = time()
    assert_mode_node_consistency(tree)
    J = template.J
    N = lookahead_node_count(tree)
    size(tree.demand, 1) == J || error("El look-ahead debe declarar la demanda de los $J hogares.")
    tree.calendar_period[tree.root] == state.period || error(
        "La raíz del look-ahead está en el período $(tree.calendar_period[tree.root]) " *
        "pero el estado está en $(state.period)."
    )
    tree.last_period == template.T || error(
        "El look-ahead debe terminar en el período calendario $(template.T), no en $(tree.last_period)."
    )

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

    # Terminal battery target, on the same calendar endpoint for every controller.
    @constraint(model, terminal_soc[n in 1:N; tau[n] == template.T], s[n] == template.s_I)

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
            template.nu[j, tau[n]] * I[j, n] -
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
        tree, template, config.formulation_variant, time() - t_build,
    )
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
    return ModelStatistics(
        variables,
        binaries,
        variables - binaries,
        model_constraint_count(model),
        model_nonzero_count(model),
        expected_mode_binary_count(tree),
        binaries,
        unique_policy_mode_count(tree),
        0,
        0,
        Float64(safe_solver_attribute(model, MOI.ObjectiveBound(), NaN)),
        Int(safe_solver_attribute(model, MOI.NodeCount(), 0)),
        Float64(safe_solver_attribute(model, MOI.RelativeGap(), NaN)),
        NaN,
    )
end

empty_model_statistics(expected_modes::Int=0) =
    ModelStatistics(0, 0, 0, 0, 0, expected_modes, 0, 0, 0, 0, NaN, 0, NaN, NaN)
