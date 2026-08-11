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
the simulated realizations. Repository horizon, required support endpoint and materialized data
endpoint are separate fields; none is silently reused as another.
"""
struct RepositoryUncertaintyProvider <: AbstractConditionalUncertaintyProvider
    J::Int
    # Compatibility alias retained for existing single-instance callers. It is always exactly
    # `repository_instance_horizon`; extended interfaces validate against the separate required
    # support endpoint below.
    T::Int
    repository_instance_horizon::Int
    required_period_support_end::Int
    materialized_data_end::Int
    period_mapping_version::String
    pv_det::Vector{Float64}
    theta::Float64
    demand_models::Vector{OOSHouseholdDemandModel}
    ar::Float64
    ma::Float64
    repair_pea::Bool
end

function _validate_template_support_match(
    template::OOSInstanceTemplate,
    support::OOSPeriodDataSupport,
)
    validate_period_data_support(support)
    support.repository_instance_horizon == template.T || error(
        "El soporte declara T0=$(support.repository_instance_horizon), pero la plantilla " *
        "declara T=$(template.T)."
    )
    support.households == template.J || error(
        "El soporte declara $(support.households) hogares, pero la plantilla declara $(template.J)."
    )
    support.nu[:, 1:template.T] == template.nu || error(
        "Los precios base del soporte no coinciden exactamente con la plantilla."
    )
    support.pv_det[1:template.T] == template.pv_det || error(
        "El PV determinista base del soporte no coincide exactamente con la plantilla."
    )

    template_models = Dict(model.household => model for model in template.demand_models)
    length(template_models) == template.J || error(
        "La plantilla no contiene exactamente un modelo de demanda por hogar."
    )
    for extended in support.demand_models
        haskey(template_models, extended.household) || error(
            "El soporte contiene un hogar no declarado por la plantilla: $(extended.household)."
        )
        base = template_models[extended.household]
        base.profile == extended.profile || error(
            "El soporte cambió el perfil resuelto del hogar $(extended.household)."
        )
        base.avg == extended.avg && base.dev == extended.dev || error(
            "El soporte cambió los parámetros de demanda del hogar $(extended.household)."
        )
        [period for period in extended.active_periods if period <= template.T] ==
            base.active_periods || error(
            "El soporte cambió la actividad base del hogar $(extended.household)."
        )
    end
    return nothing
end

"""
Compatibility constructor for the pre-Stage-3 positional provider shape.

It keeps `T` as both the repository horizon and support endpoint, exactly as before. New callers
should prefer the template/support constructors so the three endpoints remain explicit.
"""
function RepositoryUncertaintyProvider(
    J::Int,
    T::Int,
    pv_det::AbstractVector{<:Real},
    theta::Real,
    demand_models::AbstractVector{OOSHouseholdDemandModel},
    ar::Real,
    ma::Real,
    repair_pea::Bool,
)
    J >= 1 || error("Se requiere al menos un hogar.")
    T >= 1 || error("El horizonte del proveedor debe ser >= 1.")
    length(pv_det) == T || error("El PV del proveedor debe tener exactamente T entradas.")
    all(isfinite, pv_det) || error("El PV del proveedor contiene valores no finitos.")
    theta_value = Float64(theta)
    isfinite(theta_value) && theta_value >= 0 || error("theta debe ser finito y >= 0.")
    ar_value = Float64(ar)
    ma_value = Float64(ma)
    isfinite(ar_value) || error("El coeficiente AR de PV debe ser finito.")
    isfinite(ma_value) || error("El coeficiente MA de PV debe ser finito.")
    _validate_resolved_demand_models(demand_models, J, T)
    return RepositoryUncertaintyProvider(
        J,
        T,
        T,
        T,
        T,
        OOS_PERIOD_MAPPING_VERSION,
        Float64.(collect(pv_det)),
        theta_value,
        [_copy_oos_demand_model(model) for model in demand_models],
        ar_value,
        ma_value,
        repair_pea,
    )
end

function RepositoryUncertaintyProvider(
    support::OOSPeriodDataSupport,
    theta::Real;
    ar::Float64=OOS_PV_AR_COEFFICIENT,
    ma::Float64=OOS_PV_MA_COEFFICIENT,
    repair_pea::Bool=true,
)
    validate_period_data_support(support)
    theta_value = Float64(theta)
    isfinite(theta_value) && theta_value >= 0 || error(
        "theta debe ser finito y >= 0; se recibió $theta."
    )
    isfinite(ar) || error("El coeficiente AR de PV debe ser finito.")
    isfinite(ma) || error("El coeficiente MA de PV debe ser finito.")
    return RepositoryUncertaintyProvider(
        support.households,
        support.repository_instance_horizon,
        support.repository_instance_horizon,
        support.required_period_support_end,
        support.materialized_data_end,
        String(support.period_mapping_version),
        copy(support.pv_det),
        theta_value,
        [_copy_oos_demand_model(model) for model in support.demand_models],
        ar,
        ma,
        repair_pea,
    )
end

function RepositoryUncertaintyProvider(
    template::OOSInstanceTemplate;
    data_support::Union{Nothing,OOSPeriodDataSupport}=nothing,
    ar::Float64=OOS_PV_AR_COEFFICIENT,
    ma::Float64=OOS_PV_MA_COEFFICIENT,
    repair_pea::Bool=true,
)
    # Legacy constructor: absent support materializes exactly T0 and therefore retains the active
    # simulator's pre-stage-3 horizon and generated values.
    support = data_support === nothing ?
        build_period_data_support(template, template.T) : data_support
    _validate_template_support_match(template, support)
    return RepositoryUncertaintyProvider(
        support,
        template.theta;
        ar=ar,
        ma=ma,
        repair_pea=repair_pea,
    )
end

"""Additive positional constructor for an explicitly extended support object."""
RepositoryUncertaintyProvider(
    template::OOSInstanceTemplate,
    support::OOSPeriodDataSupport;
    kwargs...,
) = RepositoryUncertaintyProvider(template; data_support=support, kwargs...)

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

# RETIRED IN STAGE 5: `lookahead_rng`, whose key was
# `(experiment_seed, replication, period, controller)`. Keying the look-ahead by the controller
# gave the three methods unrelated Monte Carlo samples, so any measured difference between them
# mixed the information structure with the sampling. Its replacement is
# `lookahead_support_rng` in `common_support.jl`, keyed by `(experiment_seed, replication,
# rolling start)` and by nothing else; the three methods are views of the one object it seeds.

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
`alea` = every period. Longer legacy horizons repeat that repository pattern through the same
centralized `base_period_index` used by every Stage-3 extension; there is no local modular
arithmetic here.
"""
function demand_active_periods(profile::AbstractString, T::Int)
    T >= 1 || error("El horizonte de actividad de demanda debe ser >= 1; se recibió $T.")
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
    return [t for t in 1:T if base_period_index(t, 24) in window]
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

"""Required abstract-period endpoint exposed by a provider."""
required_period_support_end(provider::RepositoryUncertaintyProvider) =
    provider.required_period_support_end

# Descriptive compatibility alias for callers introduced during the Stage-3 transition.
provider_period_support_end(provider::RepositoryUncertaintyProvider) =
    required_period_support_end(provider)

"""
Reject a period the provider has no materialized data for.

The bound is `materialized_data_end`, i.e. what actually exists, not
`required_period_support_end`, i.e. the minimum the rolling contract demands. The two differ
exactly when the contract is shorter than the repository horizon (`max(T0, required) == T0`),
and in that case the base profile is still fully materialized and still legitimately servable —
the legacy in-sample calibration tree over `1:T0` depends on it. Since
`materialized_data_end >= required_period_support_end` always holds, nothing the rolling contract
needs is ever rejected here; the window itself is validated separately, against the
configuration, by the rolling context.
"""
function _assert_provider_period(provider::RepositoryUncertaintyProvider, period::Int)
    1 <= period <= provider.materialized_data_end || error(
        "El período $period no fue materializado; el extremo de datos es " *
        "$(provider.materialized_data_end) (el contrato rodante requiere hasta " *
        "$(required_period_support_end(provider)))."
    )
    return period
end

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
    length(pv_history) <= required_period_support_end(provider) || error(
        "La historia de PV cubre $(length(pv_history)) períodos, pero el soporte termina en " *
        "$(required_period_support_end(provider))."
    )
    all(isfinite, pv_history) || error("La historia observada de PV contiene valores no finitos.")
    e = 0.0
    eps = 0.0
    for (tau, observed) in enumerate(pv_history)
        _assert_provider_period(provider, tau)
        prediction = provider.ar * e + provider.ma * eps
        reference = provider.pv_det[tau]
        if reference > OOS_PV_IDENTIFIABILITY_TOL
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

"""PV realization implied by a latent error at an abstract period."""
function pv_from_state(
    provider::RepositoryUncertaintyProvider,
    state::PVFilterState,
    period::Int,
)
    _assert_provider_period(provider, period)
    isfinite(state.e) || error("El estado latente de PV no es finito.")
    return max(0.0, provider.pv_det[period] * (1.0 + state.e))
end

pv_noise(provider::RepositoryUncertaintyProvider, rng::AbstractRNG) =
    provider.theta <= 0 ? 0.0 : rand(rng, Normal(0.0, provider.theta))

# -------------------------------------------------------------------------------------
# Demand realizations
# -------------------------------------------------------------------------------------

"""Independent demand draw for one abstract period."""
function sample_demand_column(provider::RepositoryUncertaintyProvider, period::Int, rng::AbstractRNG)
    _assert_provider_period(provider, period)
    column = zeros(provider.J)
    for model in provider.demand_models
        if period in model.active_periods
            column[model.household] = model.dev <= 0 ?
                model.avg : rand(rng, Normal(model.avg, model.dev))
        end
    end
    return column
end

"""Conditional mean demand for one abstract period."""
function mean_demand_column(provider::RepositoryUncertaintyProvider, period::Int)
    _assert_provider_period(provider, period)
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
    _check_history(history, current_period, horizon_end, provider)
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
    _check_history(history, current_period, horizon_end, provider)
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
    rng::AbstractRNG;
    known_prefix::Int=1,
)
    _check_history(history, current_period, horizon_end, provider; known_prefix=known_prefix)
    prefix_end = current_period + known_prefix - 1
    root_pv = history.pv[current_period]
    root_demand = collect(history.demand[:, current_period])
    # Filtered over the WHOLE observed history, which under stage 6 runs through the end of the
    # known prefix. The branching therefore starts from a latent state conditioned on everything
    # every controller was told, not only on the rolling start.
    prefix_end_state = filter_pv_state(provider, history.pv)

    known_values = known_prefix == 1 ? nothing : (
        collect(history.pv[current_period:prefix_end]),
        Matrix{Float64}(history.demand[:, current_period:prefix_end]),
    )

    # Latent state per generated node, indexed by node id; node 1 is the observed root.
    states = Dict{Int,PVFilterState}(1 => prefix_end_state)

    sampler = function (period::Int, node_history::Vector{Int}, node_index::Int)
        parent = node_history[end]
        # A node whose parent lies inside the deterministic prefix has no recorded parent state:
        # it continues from the prefix-end filtered state, which is the correct conditioning.
        parent_state = get(states, parent, prefix_end_state)
        state = advance_pv_state(provider, parent_state, pv_noise(provider, rng))
        states[node_index] = state
        pv = pv_from_state(provider, state, period)
        column = sample_demand_column(provider, period, rng)
        maybe_repair!(provider, column, pv)
        return (pv, column)
    end

    tree = multistage_lookahead_tree(
        provider.J, current_period, horizon_end, root_pv, root_demand,
        branching_spec.branching, branching_spec.periods_per_stage, sampler;
        known_prefix=known_prefix, known_values=known_values,
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
    support_end = required_period_support_end(provider)
    1 <= horizon <= support_end || error(
        "El horizonte OOS debe estar en 1:$support_end; se recibió $horizon."
    )
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

function _check_history(
    history::ObservedHistory,
    current_period::Int,
    horizon_end::Int,
    provider::RepositoryUncertaintyProvider;
    known_prefix::Int=1,
)
    known_prefix >= 1 || error("El prefijo conocido debe ser >= 1; se recibió $known_prefix.")
    # Stage 6: the observed history runs through the END of the known prefix, `t + h - 1`, and is
    # the same for every controller. With `h = 1` this is the pre-stage-6 condition unchanged.
    history.periods == current_period + known_prefix - 1 || error(
        "La historia observada cubre $(history.periods) períodos y el prefijo conocido " *
        "$current_period:$(current_period + known_prefix - 1) requiere " *
        "$(current_period + known_prefix - 1)."
    )
    support_end = required_period_support_end(provider)
    1 <= current_period <= horizon_end <= support_end || error(
        "Ventana de horizonte inválida: [$current_period, $horizon_end] con extremo de " *
        "soporte=$support_end."
    )
    length(history.pv) == history.periods || error("Historia de PV inconsistente.")
    size(history.demand, 1) == provider.J || error(
        "La historia de demanda debe declarar $(provider.J) hogares."
    )
    size(history.demand, 2) == history.periods || error("Historia de demanda inconsistente.")
    all(isfinite, history.pv) || error("La historia de PV contiene valores no finitos.")
    all(isfinite, history.demand) || error("La historia de demanda contiene valores no finitos.")
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
    # Bounded by the MATERIALIZED endpoint, not by the rolling contract's required endpoint. The
    # in-sample tree is the repository's legacy calibration object over `1:T0`; it exists
    # independently of the moving window, so a short contract (say H=12, L=8, giving a required
    # endpoint of 19 on a T0=24 instance) must not make it unservable. `materialized_data_end` is
    # `max(T0, required)`, so it always covers the base horizon.
    maximum(time_periods) <= provider.materialized_data_end || error(
        "El árbol in-sample cubre $(maximum(time_periods)) períodos y los datos materializados " *
        "del proceso terminan en $(provider.materialized_data_end)."
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
