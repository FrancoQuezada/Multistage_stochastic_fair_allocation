# =====================================================================================
# Common conditional uncertainty provider.
#
# One calibrated stochastic process serves both the out-of-sample world and every
# controller's look-ahead representation:
#
#   PV        e_tau = a * e_{tau-1} + b * eps_{tau-1} + eps_tau,  eps ~ N(0, theta)
#             C_tau = max(0, pv_det[tau] * (1 + e_tau))
#   demand    D_{j,tau} ~ N(avg, dev) inside the household's active window, 0 outside
#
# The recursion, the coefficients (a, b) = (0.8, 0.2), the active windows and the per-node
# PEA feasibility repair are the repository's own conventions (`arma`, `pv_ms`,
# `demandProfile`, `repairDemandsForPEA!` in `codes/parametersMS.jl`).
#
# Two documented deviations make the process and its filter mutually consistent:
#   1. the pre-sample latent state is initialized at its unconditional mean (e_0 = eps_0 = 0)
#      instead of the repository's `randn()` draw, so a controller's filter is exactly the
#      conditional law of the generated process;
#   2. the first period receives a PV value (the repository's `pv_ms` leaves node 1 unset).
#
# Prices are deterministic in this first implementation (see the experiment specification:
# no stochastic prices). The provider never generates battery-mode decisions or any
# household-indexed mode data.
# =====================================================================================

const OOS_PV_AR_COEFFICIENT = 0.8
const OOS_PV_MA_COEFFICIENT = 0.2
const OOS_PV_IDENTIFIABILITY_TOL = 1e-9
const OOS_PEA_REPAIR_TOL = 1e-8

abstract type AbstractConditionalUncertaintyProvider end

"""
Repository-calibrated conditional uncertainty provider.

`demand_models` fixes each household's active window once, ex ante, and is recorded in
`experiment_config.json`. It is shared by the in-sample look-ahead world and the
out-of-sample world, which is what makes the static demand-share coefficients coherent with
the simulated realizations.
"""
struct RepositoryUncertaintyProvider <: AbstractConditionalUncertaintyProvider
    J::Int
    T::Int
    pv_det::Vector{Float64}
    theta::Float64
    demand_models::Vector{OOSHouseholdDemandModel}
    ar::Float64
    ma::Float64
    repair_pea::Bool
end

function RepositoryUncertaintyProvider(
    template::OOSInstanceTemplate;
    ar::Float64=OOS_PV_AR_COEFFICIENT,
    ma::Float64=OOS_PV_MA_COEFFICIENT,
    repair_pea::Bool=true,
)
    length(template.pv_det) >= template.T || error(
        "El perfil determinista de PV tiene $(length(template.pv_det)) períodos y se requieren $(template.T)."
    )
    length(template.demand_models) == template.J || error(
        "Se requiere un modelo de demanda por hogar."
    )
    return RepositoryUncertaintyProvider(
        template.J, template.T, collect(template.pv_det[1:template.T]), template.theta,
        template.demand_models, ar, ma, repair_pea,
    )
end

# -------------------------------------------------------------------------------------
# Deterministic stream separation
# -------------------------------------------------------------------------------------

"""
Deterministic 64-bit FNV-1a seed, mirroring `deterministic_seed` in `codes/parametersMS.jl`.

`stream` separates the out-of-sample stream from the in-sample look-ahead streams, so no
in-sample draw can ever consume an out-of-sample random number.
"""
function oos_stream_seed(experiment_seed::Int, stream::AbstractString, parts...)
    key = string(experiment_seed, "|", stream, "|", join(parts, "|"))
    acc = UInt(1469598103934665603)
    for b in codeunits(key)
        acc = (acc ⊻ UInt(b)) * UInt(1099511628211)
    end
    return Int(mod(acc, UInt(2^31 - 1))) + 1
end

"""RNG for the out-of-sample trajectory of one replication."""
oos_path_rng(config::OOSExperimentConfig, replication_id::Int) =
    MersenneTwister(oos_stream_seed(config.experiment_seed, "oos_path", replication_id))

"""
RNG for one controller's look-ahead at one `(replication, period)` pair.

The fairness policy is deliberately absent from the key: every allocation/fairness rule
under the same controller receives exactly the same forecast, scenario set or tree.
"""
lookahead_rng(config::OOSExperimentConfig, replication_id::Int, period::Int, controller::ControllerKind) =
    MersenneTwister(oos_stream_seed(
        config.experiment_seed, "lookahead", replication_id, period, string(controller),
    ))

"""RNG for the common in-sample objects (static demand shares, calibration diagnostics)."""
in_sample_rng(config::OOSExperimentConfig) =
    MersenneTwister(oos_stream_seed(config.experiment_seed, "in_sample"))

"""RNG for the ex-ante assignment of household demand profiles."""
demand_profile_rng(config::OOSExperimentConfig) =
    MersenneTwister(oos_stream_seed(config.experiment_seed, "demand_profiles"))

# -------------------------------------------------------------------------------------
# Household demand models
# -------------------------------------------------------------------------------------

"""
Active window of one repository demand profile.

The windows replicate `demandProfile`: morning = 1:8, midday = 9:16, night = 17:24 and
`alea` = every period. Longer horizons repeat the 24-period pattern.
"""
function demand_active_periods(profile::AbstractString, T::Int)
    profile == "alea" && return collect(1:T)
    window = if profile == "morning"
        1:8
    elseif profile == "midday"
        9:16
    elseif profile == "night"
        17:24
    else
        error("Perfil de demanda por hogar no soportado: $profile.")
    end
    return [t for t in 1:T if mod1(t, 24) in window]
end

"""
Ex-ante assignment of household demand profiles, using the repository's `pick_type` weights.

Drawn once from a dedicated stream and identical across replications, controllers and
allocation/fairness rules.
"""
function assign_demand_models(
    J::Int,
    T::Int,
    avg::Float64,
    dev::Float64,
    demand_profile::AbstractString,
    rng::AbstractRNG,
)
    types = ["morning", "midday", "night"]
    pick = function ()
        if demand_profile == "mixed" || demand_profile == "align_medium"
            return rand(rng, types)
        elseif demand_profile == "mixed2"
            return rand(rng, ["morning", "night"])
        elseif demand_profile == "align_high"
            u = rand(rng)
            return u < 0.15 ? "morning" : (u < 0.85 ? "midday" : "night")
        elseif demand_profile == "align_low"
            u = rand(rng)
            return u < 0.15 ? "morning" : (u < 0.30 ? "midday" : "night")
        elseif demand_profile in types || demand_profile == "alea"
            return String(demand_profile)
        end
        error("Perfil de demanda no soportado: $demand_profile.")
    end
    return [
        begin
            profile = pick()
            OOSHouseholdDemandModel(j, profile, demand_active_periods(profile, T), avg, dev)
        end
        for j in 1:J
    ]
end

# -------------------------------------------------------------------------------------
# PV latent state
# -------------------------------------------------------------------------------------

"""Filtered latent PV state `(e, eps)` after the observed history."""
struct PVFilterState
    e::Float64
    eps::Float64
    periods::Int
end

"""
Filter the latent PV error from the observed PV history only.

`e_tau` is identified whenever `pv_det[tau] > 0` because `C_tau = pv_det[tau] (1 + e_tau)`
above the truncation. Two documented cases are not identified and fall back to the
conditional mean of the latent state:

  * `pv_det[tau] == 0` (no production is possible, so the realization carries no signal);
  * `C_tau == 0` while `pv_det[tau] > 0`, i.e. the truncation is active; the latent error is
    then pinned to the truncation boundary `e_tau = -1`.
"""
function filter_pv_state(provider::RepositoryUncertaintyProvider, pv_history::AbstractVector{<:Real})
    e = 0.0
    eps = 0.0
    for tau in eachindex(pv_history)
        prediction = provider.ar * e + provider.ma * eps
        reference = provider.pv_det[tau]
        if reference > OOS_PV_IDENTIFIABILITY_TOL
            observed = pv_history[tau]
            e_observed = observed <= 0.0 ? -1.0 : observed / reference - 1.0
            eps = e_observed - prediction
            e = e_observed
        else
            e = prediction
            eps = 0.0
        end
    end
    return PVFilterState(e, eps, length(pv_history))
end

"""One step of the latent recursion; `noise == 0` yields the conditional mean."""
advance_pv_state(provider::RepositoryUncertaintyProvider, state::PVFilterState, noise::Float64) =
    PVFilterState(
        provider.ar * state.e + provider.ma * state.eps + noise,
        noise,
        state.periods + 1,
    )

"""PV realization implied by a latent error at a calendar period."""
pv_from_state(provider::RepositoryUncertaintyProvider, state::PVFilterState, period::Int) =
    max(0.0, provider.pv_det[period] * (1.0 + state.e))

pv_noise(provider::RepositoryUncertaintyProvider, rng::AbstractRNG) =
    provider.theta <= 0 ? 0.0 : rand(rng, Normal(0.0, provider.theta))

# -------------------------------------------------------------------------------------
# Demand realizations
# -------------------------------------------------------------------------------------

"""Independent demand draw for one calendar period."""
function sample_demand_column(provider::RepositoryUncertaintyProvider, period::Int, rng::AbstractRNG)
    column = zeros(provider.J)
    for model in provider.demand_models
        if period in model.active_periods
            column[model.household] = model.dev <= 0 ?
                model.avg : rand(rng, Normal(model.avg, model.dev))
        end
    end
    return column
end

"""Conditional mean demand for one calendar period."""
function mean_demand_column(provider::RepositoryUncertaintyProvider, period::Int)
    column = zeros(provider.J)
    for model in provider.demand_models
        if period in model.active_periods
            column[model.household] = model.avg
        end
    end
    return column
end

"""
Per-period PEA feasibility repair, replicating `repairDemandsForPEA!` node by node.

Guarantees `sum_j D_{j,tau} >= C_tau`, hence per-scenario PEA feasibility, in the
out-of-sample world and in every look-ahead representation alike.
"""
function repair_period_demand!(demand::AbstractVector{<:Real}, pv::Real, J::Int)
    total = sum(demand)
    deficit = pv - total
    if deficit > OOS_PEA_REPAIR_TOL
        weights = total > 0 ? demand ./ total : fill(1.0 / J, J)
        for j in 1:J
            demand[j] += deficit * weights[j]
        end
    end
    return demand
end

function maybe_repair!(provider::RepositoryUncertaintyProvider, demand::AbstractVector{<:Real}, pv::Real)
    provider.repair_pea && repair_period_demand!(demand, pv, provider.J)
    return demand
end

# -------------------------------------------------------------------------------------
# Provider interface
# -------------------------------------------------------------------------------------

"""
Conditional point-forecast path over `current_period:horizon_end`.

Entry 1 is the *observed* current period, taken verbatim from the history. Later entries use
the conditional mean of the latent PV state and the conditional mean demand.
"""
function conditional_mean_path(
    provider::RepositoryUncertaintyProvider,
    history::ObservedHistory,
    current_period::Int,
    horizon_end::Int,
)
    _check_history(history, current_period, horizon_end, provider.T)
    n = horizon_end - current_period + 1
    pv = zeros(n)
    demand = zeros(provider.J, n)

    pv[1] = history.pv[current_period]
    demand[:, 1] .= @view history.demand[:, current_period]

    state = filter_pv_state(provider, history.pv)
    for k in 2:n
        period = current_period + k - 1
        state = advance_pv_state(provider, state, 0.0)
        pv[k] = pv_from_state(provider, state, period)
        column = mean_demand_column(provider, period)
        maybe_repair!(provider, column, pv[k])
        demand[:, k] .= column
    end
    return ForecastPath(current_period, horizon_end, pv, demand)
end

"""
`number_of_scenarios` conditional complete future scenarios sharing the observed root.

Each scenario carries probability `1/number_of_scenarios`; there is no nonanticipativity
after the root, which is exactly the two-stage information structure.
"""
function conditional_scenario_paths(
    provider::RepositoryUncertaintyProvider,
    history::ObservedHistory,
    current_period::Int,
    horizon_end::Int,
    number_of_scenarios::Int,
    rng::AbstractRNG,
)
    _check_history(history, current_period, horizon_end, provider.T)
    number_of_scenarios >= 1 || error("Se requiere al menos un escenario.")
    n = horizon_end - current_period + 1
    root_state = filter_pv_state(provider, history.pv)
    root_pv = history.pv[current_period]
    root_demand = collect(history.demand[:, current_period])
    probability = 1.0 / number_of_scenarios

    paths = Vector{ScenarioPath}()
    for _ in 1:number_of_scenarios
        pv = zeros(n)
        demand = zeros(provider.J, n)
        pv[1] = root_pv
        demand[:, 1] .= root_demand
        state = root_state
        for k in 2:n
            period = current_period + k - 1
            state = advance_pv_state(provider, state, pv_noise(provider, rng))
            pv[k] = pv_from_state(provider, state, period)
            column = sample_demand_column(provider, period, rng)
            maybe_repair!(provider, column, pv[k])
            demand[:, k] .= column
        end
        push!(paths, ScenarioPath(current_period, horizon_end, probability, pv, demand))
    end
    return paths
end

"""
Conditional scenario tree with progressive information revelation.

The latent PV state is carried along each tree path, so two nodes sharing a history share the
same conditional distribution — the tree is a genuine filtration, not a bundle of independent
paths.
"""
function conditional_scenario_tree(
    provider::RepositoryUncertaintyProvider,
    history::ObservedHistory,
    current_period::Int,
    horizon_end::Int,
    branching_spec::BranchingSpec,
    rng::AbstractRNG,
)
    _check_history(history, current_period, horizon_end, provider.T)
    root_pv = history.pv[current_period]
    root_demand = collect(history.demand[:, current_period])
    root_state = filter_pv_state(provider, history.pv)

    # Latent state per generated node, indexed by node id; node 1 is the observed root.
    states = Dict{Int,PVFilterState}(1 => root_state)

    sampler = function (period::Int, node_history::Vector{Int}, node_index::Int)
        parent = node_history[end]
        parent_state = states[parent]
        state = advance_pv_state(provider, parent_state, pv_noise(provider, rng))
        states[node_index] = state
        pv = pv_from_state(provider, state, period)
        column = sample_demand_column(provider, period, rng)
        maybe_repair!(provider, column, pv)
        return (pv, column)
    end

    tree = multistage_lookahead_tree(
        provider.J, current_period, horizon_end, root_pv, root_demand,
        branching_spec.branching, branching_spec.periods_per_stage, sampler,
    )
    return conditional_tree_from_lookahead(tree)
end

"""
One independent out-of-sample trajectory: the simulated real world.

Contains no battery-mode data; the operating mode is an endogenous decision.
"""
function sample_oos_path(
    provider::RepositoryUncertaintyProvider,
    horizon::Int,
    rng::AbstractRNG;
    replication_id::Int=0,
)
    1 <= horizon <= provider.T || error("El horizonte OOS debe estar en 1:$(provider.T).")
    pv = zeros(horizon)
    demand = zeros(provider.J, horizon)
    state = PVFilterState(0.0, 0.0, 0)
    for tau in 1:horizon
        state = advance_pv_state(provider, state, pv_noise(provider, rng))
        pv[tau] = pv_from_state(provider, state, tau)
        column = sample_demand_column(provider, tau, rng)
        maybe_repair!(provider, column, pv[tau])
        demand[:, tau] .= column
    end
    return OOSPath(replication_id, horizon, pv, demand)
end

function _check_history(history::ObservedHistory, current_period::Int, horizon_end::Int, T::Int)
    history.periods == current_period || error(
        "La historia observada cubre $(history.periods) períodos pero el período actual es $current_period."
    )
    1 <= current_period <= horizon_end <= T || error(
        "Ventana de horizonte inválida: [$current_period, $horizon_end] con T=$T."
    )
    length(history.pv) == history.periods || error("Historia de PV inconsistente.")
    size(history.demand, 2) == history.periods || error("Historia de demanda inconsistente.")
    return nothing
end

# -------------------------------------------------------------------------------------
# Common in-sample objects
# -------------------------------------------------------------------------------------

"""
Populate a repository scenario `Tree` with in-sample PV and demand from the same process.

Used to compute the static demand-share coefficients once, ex ante, from the common
in-sample expected demand. The PV recursion follows the tree's parent relation exactly as
`pv_ms` does.
"""
function in_sample_tree_data(
    provider::RepositoryUncertaintyProvider,
    tree::Tree,
    rng::AbstractRNG,
)
    time_periods = createTime(tree)
    maximum(time_periods) <= provider.T || error(
        "El árbol in-sample cubre $(maximum(time_periods)) períodos y el proceso calibrado $(provider.T)."
    )
    states = Vector{PVFilterState}(undef, tree.V)
    pv = zeros(tree.V)
    demand = zeros(provider.J, tree.V)
    for n in 1:tree.V
        parent = tree.parents[n]
        parent_state = parent == 0 ? PVFilterState(0.0, 0.0, 0) : states[parent]
        states[n] = advance_pv_state(provider, parent_state, pv_noise(provider, rng))
        pv[n] = pv_from_state(provider, states[n], time_periods[n])
        column = sample_demand_column(provider, time_periods[n], rng)
        maybe_repair!(provider, column, pv[n])
        demand[:, n] .= column
    end
    return (pv=pv, demand=demand, time_periods=time_periods)
end
