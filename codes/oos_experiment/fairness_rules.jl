# =====================================================================================
# Allocation / fairness rules on the remaining-horizon model.
#
# All six rules are imposed on the *same* corrected shared-battery physical model. The
# shared-mode correction changes the feasible region; it does not redefine any fairness rule.
#
# Fixed realized past quantities enter each expression exactly once, through
# `FairnessPastState`. Nothing here reads or writes a battery mode.
# =====================================================================================

"""Floor of the all-grid benchmark denominator, mirroring the repository's `TOL` safeguard."""
const OOS_SA_DENOMINATOR_FLOOR = 1.0

"""Smallest admissible community demand denominator of the PEA rule."""
const OOS_PEA_DENOMINATOR_FLOOR = 1e-9

"""
Fixed realized past entering the fairness expressions.

Built once per solve from the simulation state, so no fairness rule can double-count or
omit the realized past.
"""
struct FairnessPastState
    pv::Vector{Float64}          # P_j^past : realized PV allocated to household j
    demand::Vector{Float64}      # D_j^past : realized demand of household j
    cost::Vector{Float64}        # K_j^past : realized operating cost of household j
    benchmark::Vector{Float64}   # B_j^past : realized all-grid benchmark of household j
    total_pv::Float64            # C^past   : realized community PV
    periods::Int
end

function fairness_past_state(state::SimulationState)
    return FairnessPastState(
        copy(state.cumulative_pv),
        copy(state.cumulative_demand),
        copy(state.cumulative_operating_cost),
        copy(state.cumulative_all_grid_cost),
        realized_total_pv(state),
        state.period - 1,
    )
end

"""Realized past savings, derived rather than stored."""
past_savings(past::FairnessPastState) = past.benchmark .- past.cost

"""
Constant scenario aggregates of the look-ahead's exogenous data.

`pv_total[s]`, `demand[j,s]` and `benchmark[j,s]` accumulate over the nodes of scenario `s`,
i.e. over the remaining horizon only.
"""
function scenario_aggregates(template::OOSInstanceTemplate, tree::LookaheadTree)
    S = lookahead_scenario_count(tree)
    J = template.J
    pv_total = zeros(S)
    demand = zeros(J, S)
    benchmark = zeros(J, S)
    for (s, path) in enumerate(tree.scenarios)
        for n in path
            pv_total[s] += tree.pv[n]
            for j in 1:J
                demand[j, s] += tree.demand[j, n]
                benchmark[j, s] += template.delta * template.nu[j, tree.calendar_period[n]] *
                                   tree.demand[j, n]
            end
        end
    end
    return (pv_total=pv_total, demand=demand, benchmark=benchmark,
            probability=scenario_probabilities(tree))
end

# -------------------------------------------------------------------------------------
# Rule-specific expressions
# -------------------------------------------------------------------------------------

"""
Expected total PV allocation per household, `P_j^past + E_t[sum_tau p_{j,tau}]`.

This is the PEA and lexicographic-PV outcome measure.
"""
function expected_pv_allocation_expressions(refs::PhysicalModelRefs, past::FairnessPastState)
    tree = refs.tree
    J = refs.template.J
    return [
        past.pv[j] + sum(tree.probability[n] * refs.p[j, n] for n in tree.nodes)
        for j in 1:J
    ]
end

"""
Expected total savings per household, `S_j^past + E_t[S_{j,t}]`.

`S_j^omega = B_j^omega - K_j^omega` with the realized past included in both terms, so the
expectation is taken over the remaining horizon only.
"""
function expected_savings_expressions(
    refs::PhysicalModelRefs,
    past::FairnessPastState,
    aggregates,
)
    tree = refs.tree
    J = refs.template.J
    saving_past = past_savings(past)
    return [
        saving_past[j] + sum(
            aggregates.probability[s] * (
                aggregates.benchmark[j, s] -
                sum(refs.node_cost[j, n] for n in tree.scenarios[s])
            )
            for s in eachindex(tree.scenarios)
        )
        for j in 1:J
    ]
end

"""
PEA target: `E_t[alpha^omega D_j^omega]` with `alpha^omega = C^omega / D^omega`.

All three totals include the realized past exactly once. Community demand strictly dominates
community PV per period thanks to the provider's PEA repair, so the denominator is positive.
"""
function pea_targets(template::OOSInstanceTemplate, past::FairnessPastState, aggregates)
    J = template.J
    S = length(aggregates.pv_total)
    targets = zeros(J)
    for s in 1:S
        community_pv = past.total_pv + aggregates.pv_total[s]
        household_demand = [past.demand[j] + aggregates.demand[j, s] for j in 1:J]
        community_demand = sum(household_demand)
        community_demand > OOS_PEA_DENOMINATOR_FLOOR || error(
            "La demanda comunitaria total del escenario $s no es positiva ($community_demand); " *
            "la regla PEA no está definida."
        )
        alpha = community_pv / community_demand
        for j in 1:J
            targets[j] += aggregates.probability[s] * alpha * household_demand[j]
        end
    end
    return targets
end

"""
SA target coefficients.

Returns `(benchmark_total, share)` where `share[j,s] = B_j^omega / max(floor, B^omega)`, so
the SA right-hand side is the linear expression `sum_s prob_s * share[j,s] * S^omega_s`.
"""
function sa_target_coefficients(template::OOSInstanceTemplate, past::FairnessPastState, aggregates)
    J = template.J
    S = length(aggregates.pv_total)
    benchmark = zeros(J, S)
    total = zeros(S)
    share = zeros(J, S)
    for s in 1:S
        for j in 1:J
            benchmark[j, s] = past.benchmark[j] + aggregates.benchmark[j, s]
        end
        total[s] = max(OOS_SA_DENOMINATOR_FLOOR, sum(benchmark[:, s]))
        for j in 1:J
            share[j, s] = benchmark[j, s] / total[s]
        end
    end
    return (benchmark=benchmark, benchmark_total=total, share=share)
end

"""
Per-scenario community savings expression `S^omega = sum_k S_k^omega`, including the past.
"""
function scenario_community_savings_expressions(
    refs::PhysicalModelRefs,
    past::FairnessPastState,
    aggregates,
)
    tree = refs.tree
    J = refs.template.J
    saving_past = sum(past_savings(past))
    return [
        saving_past +
        sum(aggregates.benchmark[j, s] for j in 1:J) -
        sum(refs.node_cost[j, n] for j in 1:J, n in tree.scenarios[s])
        for s in eachindex(tree.scenarios)
    ]
end

# -------------------------------------------------------------------------------------
# PEA constraint builders
#
# All three share the same physical model, look-ahead tree, realized history, battery state,
# proportional target and node probabilities. The only difference is equality versus band.
# Every variant is root-level and horizon-total: one family indexed by household only, each
# row spanning the whole remaining horizon with node probabilities as coefficients.
# -------------------------------------------------------------------------------------

"""
Strict ex-ante PEA, one equality per household:

    P_past[j] + sum_n rho_n p[j,n]  ==  Q[j]

The realized past enters as a fixed constant; JuMP normalizes it onto the right-hand side.
"""
function build_strict_pea_constraints!(
    refs::PhysicalModelRefs,
    past::FairnessPastState,
    aggregates,
)
    J = refs.template.J
    targets = pea_targets(refs.template, past, aggregates)
    allocation = expected_pv_allocation_expressions(refs, past)
    @constraint(refs.model, pea_balance[j in 1:J], allocation[j] == targets[j])
    return (targets=targets, epsilon=nothing, mode=:strict)
end

"""
Adaptive PEA with an endogenous common band, one nonnegative scalar for the whole solve:

    -epsilon_pea <= P_past[j] + sum_n rho_n p[j,n] - Q[j] <= epsilon_pea,   epsilon_pea >= 0

`epsilon_pea` is the maximum absolute household-level deviation admitted at this
rolling-horizon step, in kWh. It is a decision variable, not a parameter: its value is
*minimized* in Phase I rather than chosen from a grid.
"""
function build_adaptive_pea_constraints!(
    refs::PhysicalModelRefs,
    past::FairnessPastState,
    aggregates,
)
    J = refs.template.J
    targets = pea_targets(refs.template, past, aggregates)
    allocation = expected_pv_allocation_expressions(refs, past)
    model = refs.model
    @variable(model, epsilon_pea >= 0)
    @constraint(model, pea_band_upper[j in 1:J], allocation[j] - targets[j] <= epsilon_pea)
    @constraint(model, pea_band_lower[j in 1:J], targets[j] - allocation[j] <= epsilon_pea)
    return (targets=targets, epsilon=epsilon_pea, mode=:adaptive)
end

"""
DEPRECATED fixed economic band, honoured only under `pea_tolerance_mode === :fixed_band`.

A fixed band changes the economic meaning of PEA and is never used by the default campaign.
It is retained solely so historical configurations remain reproducible.
"""
function build_fixed_band_pea_constraints!(
    refs::PhysicalModelRefs,
    past::FairnessPastState,
    config::OOSExperimentConfig,
    aggregates,
)
    J = refs.template.J
    targets = pea_targets(refs.template, past, aggregates)
    allocation = expected_pv_allocation_expressions(refs, past)
    model = refs.model
    @constraint(model, pea_upper[j in 1:J],
        allocation[j] - targets[j] <= config.fairness_abs_tol)
    @constraint(model, pea_lower[j in 1:J],
        targets[j] - allocation[j] <= config.fairness_abs_tol)
    return (targets=targets, epsilon=nothing, mode=:fixed_band)
end

# -------------------------------------------------------------------------------------
# Constraint installation
# -------------------------------------------------------------------------------------

"""
Impose the allocation/fairness rule on an already built physical model.

Returns a handle bundle used later to evaluate the realized fairness residual. Lexicographic
rules install no constraint here: they are driven by `lexicographic.jl`, which reuses this
same physical model for every phase.
"""
function add_fairness_constraints!(
    refs::PhysicalModelRefs,
    policy::FairnessPolicy,
    past::FairnessPastState,
    config::OOSExperimentConfig;
    static_shares::Union{Nothing,Matrix{Float64}}=nothing,
)
    tree = refs.tree
    template = refs.template
    J = template.J
    aggregates = scenario_aggregates(template, tree)

    if policy === NONE
        return (policy=policy, aggregates=aggregates, handles=nothing)

    elseif policy === STATIC_DEMAND_SHARE
        static_shares === nothing && error(
            "STATIC_DEMAND_SHARE requiere los coeficientes estáticos calculados ex ante."
        )
        size(static_shares) == (J, template.T) || error(
            "Los coeficientes estáticos deben tener dimensión ($J, $(template.T))."
        )
        model = refs.model
        @constraint(model, static_share_fix[j in 1:J, n in tree.nodes],
            refs.lambda[j, n] == static_shares[j, tree.calendar_period[n]])
        return (policy=policy, aggregates=aggregates, handles=(shares=static_shares,))

    elseif policy === PEA
        handles = if config.pea_tolerance_mode === :fixed_band
            build_fixed_band_pea_constraints!(refs, past, config, aggregates)
        else
            # Both :strict and :adaptive_minimum start from the strict equality. The adaptive
            # band is only ever built afterwards, on a fresh model, and only after a proven
            # fairness infeasibility.
            build_strict_pea_constraints!(refs, past, aggregates)
        end
        return (policy=policy, aggregates=aggregates, handles=handles)

    elseif policy === SA
        coefficients = sa_target_coefficients(template, past, aggregates)
        savings = expected_savings_expressions(refs, past, aggregates)
        community = scenario_community_savings_expressions(refs, past, aggregates)
        model = refs.model
        target = [
            sum(aggregates.probability[s] * coefficients.share[j, s] * community[s]
                for s in eachindex(tree.scenarios))
            for j in 1:J
        ]
        if config.sa_fairness_abs_tol > 0
            @constraint(model, sa_upper[j in 1:J],
                savings[j] - target[j] <= config.sa_fairness_abs_tol)
            @constraint(model, sa_lower[j in 1:J],
                target[j] - savings[j] <= config.sa_fairness_abs_tol)
        else
            @constraint(model, sa_balance[j in 1:J], savings[j] == target[j])
        end
        return (policy=policy, aggregates=aggregates, handles=(coefficients=coefficients,))

    elseif is_lexicographic_policy(policy)
        # Installed phase by phase in `lexicographic.jl`, on this same physical model.
        return (policy=policy, aggregates=aggregates, handles=nothing)
    end

    error("Regla de asignación/equidad no soportada: $policy.")
end

# -------------------------------------------------------------------------------------
# Realized fairness residuals
# -------------------------------------------------------------------------------------

"""
Maximum absolute fairness residual of a solved model.

For lexicographic rules the residual is the largest shortfall of the achieved outcome with
respect to the computed lexicographic level, which must stay inside `lex_eps_abs`.
"""
function fairness_residual(
    refs::PhysicalModelRefs,
    policy::FairnessPolicy,
    past::FairnessPastState,
    context;
    lexicographic_levels::Union{Nothing,Vector{Float64}}=nothing,
)
    policy === NONE && return 0.0
    tree = refs.tree
    template = refs.template
    J = template.J
    aggregates = context.aggregates

    if policy === STATIC_DEMAND_SHARE
        shares = context.handles.shares
        residual = 0.0
        for j in 1:J, n in tree.nodes
            residual = max(residual, abs(value(refs.lambda[j, n]) - shares[j, tree.calendar_period[n]]))
        end
        return residual

    elseif policy === PEA
        targets = context.handles.targets
        allocation = [
            past.pv[j] + sum(tree.probability[n] * value(refs.p[j, n]) for n in tree.nodes)
            for j in 1:J
        ]
        return maximum(abs.(allocation .- targets))

    elseif policy === SA
        coefficients = context.handles.coefficients
        node_cost = [value(refs.node_cost[j, n]) for j in 1:J, n in tree.nodes]
        saving_past = past_savings(past)
        savings = zeros(J)
        community = zeros(length(tree.scenarios))
        for (s, path) in enumerate(tree.scenarios)
            community[s] = sum(saving_past) +
                           sum(aggregates.benchmark[j, s] for j in 1:J) -
                           sum(node_cost[j, n] for j in 1:J, n in path)
        end
        for j in 1:J
            savings[j] = saving_past[j] + sum(
                aggregates.probability[s] * (
                    aggregates.benchmark[j, s] - sum(node_cost[j, n] for n in tree.scenarios[s])
                )
                for s in eachindex(tree.scenarios)
            )
        end
        target = [
            sum(aggregates.probability[s] * coefficients.share[j, s] * community[s]
                for s in eachindex(tree.scenarios))
            for j in 1:J
        ]
        return maximum(abs.(savings .- target))

    elseif is_lexicographic_policy(policy)
        lexicographic_levels === nothing && return NaN
        achieved = lexicographic_achieved_outcomes(refs, policy, past, aggregates)
        return lexicographic_level_residual(lexicographic_levels, achieved)
    end

    error("Regla de asignación/equidad no soportada: $policy.")
end

"""Achieved per-household lexicographic outcome values of a solved model."""
function lexicographic_achieved_outcomes(
    refs::PhysicalModelRefs,
    policy::FairnessPolicy,
    past::FairnessPastState,
    aggregates,
)
    tree = refs.tree
    J = refs.template.J
    if policy === LEXMMFPEA
        return [
            past.pv[j] + sum(tree.probability[n] * value(refs.p[j, n]) for n in tree.nodes)
            for j in 1:J
        ]
    elseif policy === LEXMMFSA
        node_cost = [value(refs.node_cost[j, n]) for j in 1:J, n in tree.nodes]
        saving_past = past_savings(past)
        return [
            saving_past[j] + sum(
                aggregates.probability[s] * (
                    aggregates.benchmark[j, s] - sum(node_cost[j, n] for n in tree.scenarios[s])
                )
                for s in eachindex(tree.scenarios)
            )
            for j in 1:J
        ]
    end
    error("La política $policy no es lexicográfica.")
end

# -------------------------------------------------------------------------------------
# Static demand-share coefficients
# -------------------------------------------------------------------------------------

"""
Static demand-share coefficients, computed once from the common in-sample expected demand.

    Dbar[j,t] = sum_{n : tau(n)=t} rho_n D[j,n] / sum_{n : tau(n)=t} rho_n
    lambda_static[j,t] = Dbar[j,t] / sum_k Dbar[k,t],  or 1/J when the total is zero.

The computation delegates to the repository's verified `static_demand_shares`, so the
benchmark keeps its published definition. The coefficients are a static rule inspired by
ex-ante energy-sharing coefficients; they are identical across replications and controllers,
are never updated from realized information, and do not determine the battery mode.
"""
function compute_static_demand_shares(
    template::OOSInstanceTemplate,
    provider::RepositoryUncertaintyProvider,
    tree::Tree,
    rng::AbstractRNG,
)
    data = in_sample_tree_data(provider, tree, rng)
    instance = InstanceM()
    instance.id = template.id
    instance.J = template.J
    instance.T = template.T
    instance.tree = tree
    instance.c_pv = data.pv
    instance.d = data.demand
    instance.delta = template.delta
    instance.nu = template.nu
    shares = static_demand_shares(instance)
    size(shares) == (template.J, template.T) || error(
        "Los coeficientes estáticos tienen dimensión $(size(shares)) y se esperaba " *
        "($(template.J), $(template.T))."
    )
    return (shares=shares, in_sample=data)
end
