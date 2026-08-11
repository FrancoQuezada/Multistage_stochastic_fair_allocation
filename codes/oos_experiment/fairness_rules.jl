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

"""Identifier prefix of a resolved static demand-share table."""
const OOS_SHARE_TABLE_ID_PREFIX = "ST"

"""Length of the digest inside a `ShareTableID`."""
const OOS_SHARE_TABLE_DIGEST_LENGTH = 12

"""Algorithm tag of the resolved share table, versioned with its contract."""
const OOS_SHARE_TABLE_ALGORITHM = "static_demand_share_table_v1"

"""
Largest admissible departure from `sum_j lambda[j, tau] = 1` in a resolved share table.

The repository's `static_demand_shares` normalizes per period, so the residual is pure
floating-point round-off. The bound is deliberately far below any economically meaningful
allocation and far above the round-off of a `J`-term division.
"""
const OOS_SHARE_TABLE_SUM_TOL = 1e-9

"""
One resolved `STATIC_DEMAND_SHARE` table: the benchmark's coefficients plus their identity.

Immutable and task-local. Resolved once per structural instance from the common ex-ante
in-sample expected demand, then repeated through `base_period_index`. It is a function of the
instance and the temporal contract alone: not of the OOS replication, not of the controller, not
of the fairness policy being solved, and never of a realized future.

`base_shares` is the `J x T0` table the repository's verified `static_demand_shares` produced;
`shares` is its repetition over `1:period_end`. Keeping both is what lets an audit separate "the
benchmark changed" from "the window got longer".
"""
struct OOSStaticShareTable
    share_table_id::String
    algorithm::String
    households::Int
    base_horizon::Int
    period_end::Int
    base_shares::Matrix{Float64}
    shares::Matrix{Float64}

    function OOSStaticShareTable(
        households::Int,
        base_horizon::Int,
        period_end::Int,
        base_shares::AbstractMatrix{Float64},
        shares::AbstractMatrix{Float64},
    )
        households >= 1 || error("Se requiere al menos un hogar.")
        base_horizon >= 1 || error("El horizonte base debe ser >= 1.")
        period_end >= base_horizon || error(
            "El extremo de la tabla ($period_end) no puede ser menor que el horizonte base " *
            "($base_horizon)."
        )
        size(base_shares) == (households, base_horizon) || error(
            "La tabla base tiene dimensión $(size(base_shares)); se esperaba " *
            "($households, $base_horizon)."
        )
        size(shares) == (households, period_end) || error(
            "La tabla extendida tiene dimensión $(size(shares)); se esperaba " *
            "($households, $period_end)."
        )
        all(isfinite, shares) || error("La tabla de cuotas contiene valores no finitos.")
        all(>=(-OOS_SHARE_TABLE_SUM_TOL), shares) || error(
            "La tabla de cuotas contiene un coeficiente negativo."
        )
        shares[:, 1:base_horizon] == base_shares || error(
            "La tabla extendida altera la tabla base dentro de 1:$base_horizon."
        )
        for period in 1:period_end
            total = sum(@view shares[:, period])
            abs(total - 1.0) <= OOS_SHARE_TABLE_SUM_TOL || error(
                "Los coeficientes del período $period suman $total en lugar de 1."
            )
            base = base_period_index(period, base_horizon)
            shares[:, period] == shares[:, base] || error(
                "El período $period no repite exactamente el período base $base."
            )
        end
        identifier = share_table_id(
            households, base_horizon, period_end, base_shares,
        )
        return new(
            identifier, OOS_SHARE_TABLE_ALGORITHM, households, base_horizon, period_end,
            Matrix{Float64}(base_shares), Matrix{Float64}(shares),
        )
    end
end

"""
Deterministic identifier of a resolved share table.

Digested from the BASE coefficients and the mapping contract through the canonical JSON writer
and the repository's persisted digest. Two contracts that differ only in window length therefore
share an identifier prefix component but not the identifier, because `period_end` is part of the
payload — a reader can tell "same benchmark, longer window" from "different benchmark".
"""
function share_table_id(
    households::Int,
    base_horizon::Int,
    period_end::Int,
    base_shares::AbstractMatrix{Float64},
)
    payload = Dict{String,Any}(
        "algorithm" => OOS_SHARE_TABLE_ALGORITHM,
        "households" => households,
        "base_horizon" => base_horizon,
        "period_end" => period_end,
        "period_mapping_name" => OOS_PERIOD_MAPPING_NAME,
        "period_mapping_version" => OOS_PERIOD_MAPPING_VERSION,
        "base_shares" => [
            [Float64(base_shares[j, t]) for t in 1:base_horizon] for j in 1:households
        ],
    )
    digest = oos_stable_digest(canonical_json(payload))
    return string(
        OOS_SHARE_TABLE_ID_PREFIX, "-",
        digest[1:min(OOS_SHARE_TABLE_DIGEST_LENGTH, length(digest))],
    )
end

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
i.e. over the look-ahead window only.

Prices come from the context's extended support, so a window that reaches past the repository
horizon T0 prices its benchmark with the repeated base entries rather than running off the end
of `template.nu`.
"""
function scenario_aggregates(source::OOSPricedSource, tree::LookaheadTree)
    template = priced_template(source)
    prices = priced_matrix(source)
    assert_priced_period(source, tree.last_period)
    S = lookahead_scenario_count(tree)
    J = template.J
    pv_total = zeros(S)
    demand = zeros(J, S)
    benchmark = zeros(J, S)
    for (s, path) in enumerate(tree.scenarios)
        for n in path
            pv_total[s] += tree.pv[n]
            tau = tree.calendar_period[n]
            for j in 1:J
                demand[j, s] += tree.demand[j, n]
                benchmark[j, s] += template.delta * prices[j, tau] * tree.demand[j, n]
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
Adaptive SA with an endogenous common band, one nonnegative scalar for the whole solve:

    -epsilon_sa <= S_j - Target_j <= epsilon_sa,   epsilon_sa >= 0

`epsilon_sa` is the maximum absolute household-level savings deviation admitted at this
rolling-horizon step, in the same monetary unit as the operating cost. Exactly like
`epsilon_pea`, it is a DECISION VARIABLE minimized in Phase I, never a value picked from a grid.

STAGE 8 introduced this. Before grid-direction exclusivity, the strict savings equality was
reachable because a household could burn energy through the grid — importing and exporting at the
same node — to inflate its own operating cost down onto the target. Closing that channel made the
equality structurally unreachable on a rolling window with a fixed realized past, exactly as it
already was for `PEA`. Widening the hand-picked `sa_fairness_abs_tol` is the wrong lever: a
bounded probe found that even `1e5` did not restore feasibility, because the shortfall is
structural rather than marginal. The endogenous minimum is the same remedy the project already
approved for `PEA`, applied to the policy that turned out to need it too.
"""
function build_adaptive_sa_constraints!(
    refs::PhysicalModelRefs,
    past::FairnessPastState,
    aggregates,
)
    J = refs.template.J
    tree = refs.tree
    coefficients = sa_target_coefficients(refs.template, past, aggregates)
    savings = expected_savings_expressions(refs, past, aggregates)
    community = scenario_community_savings_expressions(refs, past, aggregates)
    targets = [
        sum(aggregates.probability[s] * coefficients.share[j, s] * community[s]
            for s in eachindex(tree.scenarios))
        for j in 1:J
    ]
    model = refs.model
    @variable(model, epsilon_sa >= 0)
    @constraint(model, sa_band_upper[j in 1:J], savings[j] - targets[j] <= epsilon_sa)
    @constraint(model, sa_band_lower[j in 1:J], targets[j] - savings[j] <= epsilon_sa)
    return (coefficients=coefficients, targets=targets, epsilon=epsilon_sa, mode=:adaptive)
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
    static_shares::Union{Nothing,Matrix{Float64},OOSStaticShareTable}=nothing,
)
    # Stage 7: a resolved table may be passed directly. Its coefficients are the same matrix, so
    # everything downstream is unchanged; what the object adds is the identity and the contract.
    static_shares = static_shares isa OOSStaticShareTable ? static_shares.shares : static_shares
    tree = refs.tree
    template = refs.template
    J = template.J
    aggregates = scenario_aggregates(refs.source, tree)

    if policy === NONE
        return (policy=policy, aggregates=aggregates, handles=nothing)

    elseif policy === STATIC_DEMAND_SHARE
        static_shares === nothing && error(
            "STATIC_DEMAND_SHARE requiere los coeficientes estáticos calculados ex ante."
        )
        # With a moving look-ahead a window can reach past T0, so the requirement is that the
        # share table COVER every abstract period of this window — not that its width equal
        # `template.T`. A campaign table spans the whole materialized support and therefore
        # covers every window; a narrower table is rejected by naming the period it lacks.
        size(static_shares, 1) == J || error(
            "Los coeficientes estáticos declaran $(size(static_shares, 1)) hogares y el modelo " *
            "declara $J."
        )
        size(static_shares, 2) >= tree.last_period || error(
            "Los coeficientes estáticos cubren $(size(static_shares, 2)) períodos y el " *
            "look-ahead llega al período $(tree.last_period)."
        )
        assert_priced_period(refs.source, tree.last_period)
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
        # Mirrors PEA. `:adaptive_minimum` and `:strict` both start from the exact equality; the
        # endogenous band is only ever built afterwards, on a fresh model, and only after a proven
        # fairness infeasibility. `:fixed_band` honours the deprecated hand-picked constant.
        if config.sa_tolerance_mode === :fixed_band && config.sa_fairness_abs_tol > 0
            @constraint(model, sa_upper[j in 1:J],
                savings[j] - target[j] <= config.sa_fairness_abs_tol)
            @constraint(model, sa_lower[j in 1:J],
                target[j] - savings[j] <= config.sa_fairness_abs_tol)
        else
            @constraint(model, sa_balance[j in 1:J], savings[j] == target[j])
        end
        return (
            policy=policy, aggregates=aggregates,
            handles=(coefficients=coefficients, targets=target, epsilon=nothing, mode=:strict),
        )

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

The base table is computed on `1:T0` from the in-sample tree, exactly as before, and is then
repeated through the same centralized `base_period_index` the deterministic data uses. The rule
therefore keeps fixing an allocation when a moving look-ahead reaches past the repository
horizon, and it still never reads an out-of-sample realization.
"""
function compute_static_demand_shares(
    template::OOSInstanceTemplate,
    provider::RepositoryUncertaintyProvider,
    tree::Tree,
    rng::AbstractRNG;
    period_end::Int=template.T,
)
    period_end >= template.T || error(
        "El extremo de las cuotas estáticas ($period_end) no puede ser menor que el horizonte " *
        "base T0=$(template.T)."
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
    base_shares = static_demand_shares(instance)
    size(base_shares) == (template.J, template.T) || error(
        "Los coeficientes estáticos tienen dimensión $(size(base_shares)) y se esperaba " *
        "($(template.J), $(template.T))."
    )
    shares = extend_static_demand_shares(base_shares, template.T, period_end)
    return (shares=shares, base_shares=base_shares, in_sample=data)
end

# -------------------------------------------------------------------------------------
# Static share table (OOS redesign stage 7)
#
# Stage 4 made the coefficients repeat past the repository horizon so a moving window could be
# priced at all. Stage 7 turns them into an auditable, immutable object with an identity: the
# table is resolved ONCE per structural instance from the ex-ante in-sample reference, it never
# reads an out-of-sample realization, and every result can name the exact table it used.
# -------------------------------------------------------------------------------------

"""
Resolve the static share table of one structural instance, once.

Delegates to `compute_static_demand_shares`, so the benchmark keeps the repository's published
definition, and then wraps the result in the immutable contract above. The `rng` is the common
ex-ante in-sample stream: the same one for every replication, controller and policy.
"""
function resolve_static_share_table(
    template::OOSInstanceTemplate,
    provider::RepositoryUncertaintyProvider,
    tree::Tree,
    rng::AbstractRNG;
    period_end::Int=template.T,
)
    resolved = compute_static_demand_shares(
        template, provider, tree, rng; period_end=period_end,
    )
    return OOSStaticShareTable(
        template.J, template.T, period_end, resolved.base_shares, resolved.shares,
    )
end

"""Compact manifest-ready description of a resolved share table."""
share_table_summary(table::OOSStaticShareTable) = Dict{String,Any}(
    "share_table_id" => table.share_table_id,
    "algorithm" => table.algorithm,
    "households" => table.households,
    "base_horizon" => table.base_horizon,
    "period_end" => table.period_end,
    "period_mapping_name" => OOS_PERIOD_MAPPING_NAME,
    "period_mapping_version" => OOS_PERIOD_MAPPING_VERSION,
    "depends_on_oos_replication" => false,
    "depends_on_controller" => false,
    "depends_on_fairness_policy" => false,
    "reads_realized_future" => false,
)

"""
Repeat a base `J x T0` share table over `1:period_end`.

Uses `base_period_index`, the one abstract-period mapping of the data layer, so the shares
repeat in lockstep with prices, the deterministic PV reference and household activity. The
first `T0` columns are preserved exactly — with `==`, not a tolerance, because this copies
values rather than recomputing them.
"""
function extend_static_demand_shares(
    base_shares::AbstractMatrix{Float64},
    base_horizon::Int,
    period_end::Int,
)
    J = size(base_shares, 1)
    size(base_shares, 2) == base_horizon || error(
        "La tabla base de cuotas tiene $(size(base_shares, 2)) columnas y el horizonte base " *
        "es $base_horizon."
    )
    period_end >= base_horizon || error(
        "El extremo solicitado ($period_end) es menor que el horizonte base ($base_horizon)."
    )
    extended = Matrix{Float64}(undef, J, period_end)
    for period in 1:period_end
        extended[:, period] .= @view base_shares[:, base_period_index(period, base_horizon)]
    end
    extended[:, 1:base_horizon] == base_shares || error(
        "La extensión alteró la tabla base de cuotas estáticas."
    )
    return extended
end
