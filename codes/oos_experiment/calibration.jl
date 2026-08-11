# =====================================================================================
# Factor-level calibration (OOS redesign stage 12).
#
# The structural design has three factors whose LEVELS were placeholders until now: battery size,
# uncertainty and demand regime. This module turns each level into a quantity with a stated
# meaning, derives the configuration that realizes it, and MEASURES what was actually achieved.
#
# The two approved definitions (plan section 11, decision log 2026-08-08):
#
#   * a battery level is a fraction of the community's DAILY ENERGY DEMAND — 25 % and 75 % — so
#     the levels mean the same thing on every instance;
#   * an uncertainty level is a REALIZED relative PV forecast error — about 10 % and 30 % — not a
#     raw `theta`, which has no interpretation on its own.
#
# Nothing here fixes a branching structure, a replication count or a structural-draw count: those
# stay parameterized by decision. The support probe below REPORTS stability against whatever
# structure it is given; it does not choose one.
#
# Every routine is a measurement. None of them writes into the campaign's output tree, and none
# is consulted by the simulator.
# =====================================================================================

"""Approved battery levels, as a fraction of daily energy demand."""
const OOS_BATTERY_CAPACITY_FRACTIONS = (low=0.25, high=0.75)

"""Approved uncertainty levels, as a realized mean relative PV error."""
const OOS_TARGET_PV_RELATIVE_ERROR = (low=0.10, high=0.30)

"""
Expected community energy demand over one base profile length `T0`.

Summed from the RESOLVED demand models — each household's mean demand over the periods its
profile is active — so it reflects the instance actually built, including its household
composition. It is an expectation, not a realization: the battery level must be a property of the
instance, not of one out-of-sample draw.
"""
function daily_energy_demand(template::OOSInstanceTemplate)
    total = 0.0
    for model in template.demand_models
        active = count(period -> period <= template.T, model.active_periods)
        total += model.avg * active
    end
    return total
end

"""
One battery level, fully resolved.

Named `CalibratedBatteryLevel` and not `BatteryLevel`: the latter is the stage-2 structural FACTOR
enum (`LOW_BATTERY` / `HIGH_BATTERY`). This is the resolved physical vector that a factor level
maps to, which is a different object with a different lifetime.
"""
struct CalibratedBatteryLevel
    label::String
    target_fraction::Float64
    battery_scale::Float64
    daily_demand::Float64
    s_min::Float64
    s_max::Float64
    s_I::Float64
    f_under::Float64
    f_bar::Float64
    usable_capacity::Float64
    achieved_fraction::Float64
    c_rate::Float64
end

"""
The `battery_scale` whose resolved instance has usable capacity `fraction * daily demand`.

`scaleInstance!` multiplies `s_max` by the scale and leaves `s_min` untouched, so usable capacity
is `scale * base_s_max - s_min` and the inverse is exact:

    scale = (fraction * daily_demand + s_min) / base_s_max

`base_s_max` and `s_min` are read from an UNSCALED instance, because the scaling is not
idempotent and re-reading a scaled template would compound it.
"""
function battery_scale_for_capacity_fraction(
    base_template::OOSInstanceTemplate,
    fraction::Real,
)
    fraction > 0 || error("La fracción de capacidad debe ser positiva; se recibió $fraction.")
    demand = daily_energy_demand(base_template)
    demand > 0 || error("La demanda diaria esperada de la instancia base es cero.")
    base_template.s_max > 0 || error("La instancia base declara s_max = 0.")
    return (Float64(fraction) * demand + base_template.s_min) / base_template.s_max
end

"""
Resolve one battery level and report what it actually achieved.

`achieved_fraction` is recomputed from the resolved vector rather than assumed, so a level that
missed its target is visible instead of implied.

**The `scaleInstance!` discontinuity is deliberately not hidden.** At `battery_scale == 1.0` the
repository takes a no-op branch and the rates keep their base values; at any other scale the
rates are multiplied by `4 * scale`. The consequence, which the calibration report must state, is
that the C-rate is CONSTANT across every calibrated level — the rate and the capacity both carry
the same `scale` factor — but it is four times the base instance's C-rate. A calibrated level is
therefore never comparable to a `battery_scale = 1.0` run, and none of the campaign levels may be
allowed to land on exactly 1.0.
"""
function resolve_battery_level(
    config::OOSExperimentConfig,
    base_template::OOSInstanceTemplate,
    label::AbstractString,
    fraction::Real,
)
    scale = battery_scale_for_capacity_fraction(base_template, fraction)
    isapprox(scale, 1.0; atol=1e-9) && error(
        "El nivel '$label' resuelve a battery_scale = 1.0 exactamente, que es la rama no-op de " *
        "scaleInstance! y deja las tasas sin escalar. Ese nivel no es comparable con los demás; " *
        "elige otra fracción objetivo."
    )
    scaled = build_instance_template(
        OOSExperimentConfig(; _calibration_keywords(config)..., battery_scale=scale),
    ).template
    demand = daily_energy_demand(scaled)
    usable = scaled.s_max - scaled.s_min
    return CalibratedBatteryLevel(
        String(label), Float64(fraction), scale, demand,
        scaled.s_min, scaled.s_max, scaled.s_I, scaled.f_under, scaled.f_bar,
        usable, usable / demand, scaled.f_bar / usable,
    )
end

"""Configuration keywords, so a calibration variant can be built without restating every field."""
_calibration_keywords(config::OOSExperimentConfig) = (
    experiment_seed=config.experiment_seed, households=config.households,
    instance_file=config.instance_file, theta=config.theta,
    avg_demand=config.avg_demand, dev_demand=config.dev_demand,
    demand_profile=config.demand_profile, pv_scale=config.pv_scale,
    in_sample_stages=config.in_sample_stages, in_sample_children=config.in_sample_children,
    in_sample_periods_per_stage=config.in_sample_periods_per_stage,
    evaluation_horizon=config.evaluation_horizon,
    lookahead_horizon=config.lookahead_horizon,
    implementation_step=config.implementation_step,
    export_representative_models=false, require_shared_battery_validation=false,
)

"""Resolve both approved battery levels of one base instance."""
function resolve_battery_levels(
    config::OOSExperimentConfig;
    fractions=OOS_BATTERY_CAPACITY_FRACTIONS,
)
    base = build_instance_template(
        OOSExperimentConfig(; _calibration_keywords(config)..., battery_scale=1.0),
    ).template
    return [
        resolve_battery_level(config, base, String(label), fraction)
        for (label, fraction) in pairs(fractions)
    ]
end

# -------------------------------------------------------------------------------------
# Uncertainty: realized relative PV error
# -------------------------------------------------------------------------------------

"""Measured PV error statistics of one `theta`."""
struct PVErrorMeasurement
    theta::Float64
    paths::Int
    periods::Int
    mean_relative_error::Float64
    median_relative_error::Float64
    truncation_rate::Float64
end

"""
Measure the realized relative PV forecast error of one `theta`, by simulation.

The process realizes `PV_t = max(0, pv_det[t] * (1 + e_t))`, so on periods with positive
deterministic PV the relative deviation from the reference IS the latent error:

    relative_error_t = |PV_t - pv_det[t]| / pv_det[t]

The reported figure is the mean of that over every such period of every sampled path. It is
measured rather than derived, which is the point: `theta` is a process parameter with no
standalone interpretation, and the design speaks in terms of forecast error.

`truncation_rate` is the fraction of those periods where `1 + e_t < 0` and the `max(0, .)` bound
bit. It is the degeneracy guard: once truncation is common the process stops behaving like a
multiplicative error and `theta` no longer means what the level claims.
"""
function measure_pv_relative_error(
    config::OOSExperimentConfig,
    theta::Real;
    paths::Int=64,
    seed_offset::Int=0,
)
    variant = OOSExperimentConfig(; _calibration_keywords(config)..., theta=theta)
    template = build_instance_template(variant).template
    support = build_period_data_support(template, required_period_support_end(variant))
    provider = RepositoryUncertaintyProvider(template; data_support=support)
    horizon = realized_period_end(variant)

    errors = Float64[]
    truncated = 0
    considered = 0
    for index in 1:paths
        path = sample_oos_path(
            provider, horizon, MersenneTwister(
                oos_stream_seed(variant.experiment_seed, "calibration_pv", seed_offset, index));
            replication_id=index,
        )
        for period in 1:horizon
            reference = support.pv_det[period]
            reference > OOS_RELATIVE_FLOOR || continue
            considered += 1
            push!(errors, abs(path.pv[period] - reference) / reference)
            # The truncation bound bit exactly when the realization is zero while the reference
            # is not: `max(0, .)` is the only way that can happen.
            path.pv[period] <= 0.0 && (truncated += 1)
        end
    end
    considered > 0 || error("Ningún período tiene PV determinista positivo; no hay error que medir.")
    return PVErrorMeasurement(
        Float64(theta), paths, considered,
        sum(errors) / length(errors), _calibration_median(errors),
        truncated / considered,
    )
end

_calibration_median(values::Vector{Float64}) =
    isempty(values) ? NaN : sort(values)[cld(length(values), 2)]

"""
Find the `theta` whose realized relative PV error matches a target, by bisection.

The error is monotone increasing in `theta` — a larger noise scale cannot reduce the dispersion —
so bisection is the right inversion and needs no derivative. The bracket is widened first, and a
target the process cannot reach is reported as such rather than silently returning the endpoint.
"""
function calibrate_theta_for_relative_error(
    config::OOSExperimentConfig,
    target::Real;
    paths::Int=64,
    tolerance::Float64=0.005,
    max_iterations::Int=25,
    lower::Float64=0.0,
    upper::Float64=2.0,
)
    target > 0 || error("El error relativo objetivo debe ser positivo.")
    low, high = lower, upper
    high_measurement = measure_pv_relative_error(config, high; paths=paths)
    high_measurement.mean_relative_error >= target || error(
        "El error relativo máximo alcanzable con theta = $high es " *
        "$(high_measurement.mean_relative_error), por debajo del objetivo $target."
    )

    measurement = high_measurement
    for _ in 1:max_iterations
        middle = (low + high) / 2
        measurement = measure_pv_relative_error(config, middle; paths=paths)
        abs(measurement.mean_relative_error - target) <= tolerance && return measurement
        if measurement.mean_relative_error < target
            low = middle
        else
            high = middle
        end
    end
    return measurement
end

"""Calibrate both approved uncertainty levels."""
calibrate_uncertainty_levels(config::OOSExperimentConfig; paths::Int=64, kwargs...) = [
    (label=String(label),
     target=Float64(target),
     measurement=calibrate_theta_for_relative_error(config, target; paths=paths, kwargs...))
    for (label, target) in pairs(OOS_TARGET_PV_RELATIVE_ERROR)
]

# -------------------------------------------------------------------------------------
# Common-support stability
# -------------------------------------------------------------------------------------

"""Stability of the decision under independent redraws of one branching structure."""
struct SupportStability
    branching::Vector{Int}
    leaves::Int
    multistage_nodes::Int
    two_stage_nodes::Int
    seeds::Int
    rolling_start::Int
    reference_pv::Float64
    first_branch_period::Int
    mean_first_action_spread::Float64
    max_first_action_spread::Float64
    prebranch_forecast_spread::Float64
    postbranch_forecast_spread::Float64
end

"""
Rolling start whose deterministic PV reference is largest.

The stability probe measures how much the committed DECISION moves between support redraws, and
that question is vacuous at a period with no sun: the PV allocation is then identically zero for
every household under every structure, and a spread of zero would report perfect stability while
measuring nothing. Anchoring the probe at the period with the most PV puts it where the decision
actually has room to move.
"""
function most_illuminated_rolling_start(config::OOSExperimentConfig, support::OOSPeriodDataSupport)
    starts = rolling_iteration_starts(config)
    best = first(starts)
    for start in starts
        support.pv_det[start] > support.pv_det[best] && (best = start)
    end
    return best
end

"""
Measure how much the decision moves when only the support SEED changes.

For a fixed instance, replication and rolling start, the support is redrawn under several
independent seeds and the resulting first-period decisions are compared. A structure whose
decisions still move materially across redraws is under-sampled: the comparison between methods
would then be reporting Monte Carlo noise that all three share rather than the effect of the
information structure.

`forecast_spread` is the same question asked of the DETERMINISTIC view alone, which is the
sharpest case — its forecast is a probability-weighted mean of the leaves, so too few leaves make
the low-information baseline itself noisy.

This REPORTS stability for whatever structure it is given. It does not choose one: the branching
vector stays a parameter of the simulation by decision.
"""
function probe_support_stability(
    config::OOSExperimentConfig,
    branching::Vector{Int};
    seeds::Int=8,
    rolling_start::Union{Nothing,Int}=nothing,
)
    variant = OOSExperimentConfig(;
        _calibration_keywords(config)..., multistage_branching=branching,
        battery_scale=config.battery_scale,
        controller_set=[DETERMINISTIC_RH, TWO_STAGE_RH, MULTISTAGE_RH],
        fairness_set=[NONE], oos_replications=1,
    )
    common = build_common_objects(variant; verbose=false)
    path = common.oos_paths[1]
    start = rolling_start === nothing ?
        most_illuminated_rolling_start(variant, common.context.support) : rolling_start
    rolling_start = start
    prefix_end = last(implementation_block(variant, rolling_start))
    history = ObservedHistory(
        prefix_end, collect(path.pv[1:prefix_end]), collect(path.demand[:, 1:prefix_end]),
    )
    horizon_end = lookahead_end_period(variant, rolling_start)

    # A FIXED, comparable state at the probed rolling start. It is deliberately not the realized
    # state: reaching that would require solving the preceding blocks, and the solve is the very
    # thing under test. Every redraw is handed this same state, so the only thing varying between
    # them is the support — which is exactly the sensitivity being measured. The history is
    # revealed directly rather than through `reveal_block!`, whose contract is the simulator's
    # period-by-period advance, not a probe's jump.
    state = initial_simulation_state(common.context, path.replication_id)
    for period in 1:prefix_end
        state.realized_pv_history[period] = path.pv[period]
        for household in 1:common.template.J
            state.realized_demand_history[household, period] = path.demand[household, period]
        end
    end
    state.revealed_periods = prefix_end
    state.period = rolling_start
    state.soc_before = common.template.s_I
    observation = PeriodObservation(
        rolling_start, path.pv[rolling_start], collect(path.demand[:, rolling_start]))

    supports = [
        build_common_conditional_support(
            common.provider, variant, history, rolling_start, horizon_end, 1;
            rng=MersenneTwister(oos_stream_seed(
                variant.experiment_seed, "calibration_support", seed)),
        )
        for seed in 1:seeds
    ]
    leaves = support_leaf_count(first(supports))
    multistage_nodes = lookahead_node_count(multistage_support_view(first(supports)))
    two_stage_nodes = lookahead_node_count(two_stage_support_view(first(supports)))

    # How much the deterministic FORECAST moves between redraws — reported SEPARATELY before and
    # after branching begins, because the two are different questions.
    #
    # Inside the first stage there is exactly one node per period, so the "probability-weighted
    # mean" is a single sampled value carrying the full process noise. NO leaf count reduces that:
    # more leaves buy averaging only after the branch. A single figure over the whole window is
    # dominated by the un-averaged prefix and is therefore insensitive to the leaf count, which
    # would make the probe look uninformative when it is the metric that is wrong.
    #
    # The lever for the pre-branch region is a SHORTER FIRST STAGE, not a wider tree.
    reference_support = first(supports)
    first_branch = minimum(
        (reference_support.tree.calendar_period[node]
         for node in eachindex(reference_support.tree.parent)
         if reference_support.tree.probability[node] < 1.0),
        init=reference_support.last_period + 1,
    )
    forecasts = [deterministic_support_view(support).pv for support in supports]
    reference_pv = first(forecasts)
    scale = max(maximum(abs.(reference_pv)), OOS_RELATIVE_FLOOR)
    branch_index = first_branch - rolling_start + 1
    spread_over(range) = isempty(range) ? NaN : maximum(
        maximum(abs.(forecast[range] .- reference_pv[range])) for forecast in forecasts
    ) / scale
    prebranch_spread = spread_over(1:min(branch_index - 1, length(reference_pv)))
    postbranch_spread = spread_over(min(branch_index, length(reference_pv)):length(reference_pv))

    # How much the IMPLEMENTED decision moves, per controller. The decision is the whole
    # committed action — PV allocation, both battery flows and the resulting state of charge —
    # not the PV split alone: under `NONE` that split is a degenerate optimum, so a probe reading
    # only `p` would confuse degeneracy with instability in one direction and, at a dark period,
    # miss real movement in the other.
    spreads = Float64[]
    for controller in variant.controller_set
        decisions = Vector{Float64}[]
        for support in supports
            tree = support_view(support, controller)
            result = solve_current_action(
                common.context, state, observation, tree, controller, NONE, variant;
                static_shares=common.share_table,
                implementation_block=implementation_block(variant, rolling_start),
            )
            result.solved && result.action !== nothing || continue
            action = result.action
            push!(decisions, vcat(
                action.p, action.z, action.y,
                [action.aggregate_charge, action.aggregate_discharge, action.soc_after_model],
            ))
        end
        length(decisions) >= 2 || continue
        reference = first(decisions)
        # Normalized by the magnitude of the decision itself, so the figure is a relative spread
        # and stays comparable across battery levels and instances.
        scale = max(maximum(abs.(reference)), OOS_RELATIVE_FLOOR)
        push!(spreads, maximum(
            maximum(abs.(decision .- reference)) for decision in decisions
        ) / scale)
    end

    return SupportStability(
        copy(branching), leaves, multistage_nodes, two_stage_nodes, seeds,
        rolling_start, common.context.support.pv_det[rolling_start], first_branch,
        isempty(spreads) ? NaN : sum(spreads) / length(spreads),
        isempty(spreads) ? NaN : maximum(spreads),
        prebranch_spread, postbranch_spread,
    )
end

# -------------------------------------------------------------------------------------
# Demand regime
# -------------------------------------------------------------------------------------

"""
Check that the two demand regimes produce materially different household compositions.

The regimes are a STRUCTURAL factor, so they are realized by the stage-2 catalog's
`structural_demand_assignment` — not by the repository's `demand_profile` argument, which is a
different mechanism with different labels and is what the single-instance path uses. Calibrating
the regime through the wrong mechanism would measure something the campaign never runs.

`HOMOGENEOUS` gives every household one drawn profile; `HETEROGENEOUS` spreads the profiles as
evenly as the household count allows. The check confirms that shows up in the composition, over
several structural draws, rather than only in the label.
"""
function compare_demand_regimes(
    households::Int,
    assignment_seeds::AbstractVector{Int},
)
    households >= 1 || error("Se requiere al menos un hogar.")
    homogeneous = [
        structural_demand_assignment(households, HOMOGENEOUS, seed) for seed in assignment_seeds
    ]
    heterogeneous = [
        structural_demand_assignment(households, HETEROGENEOUS, seed) for seed in assignment_seeds
    ]
    homogeneous_distinct = [length(unique(a)) for a in homogeneous]
    heterogeneous_distinct = [length(unique(a)) for a in heterogeneous]
    return (
        draws=length(assignment_seeds),
        homogeneous=homogeneous,
        heterogeneous=heterogeneous,
        homogeneous_distinct_profiles=homogeneous_distinct,
        heterogeneous_distinct_profiles=heterogeneous_distinct,
        # The defining contrast: one profile against as many as the household count allows.
        homogeneous_always_single=all(==(1), homogeneous_distinct),
        heterogeneous_always_spread=all(
            d -> d == min(households, length(OOS_STRUCTURAL_DEMAND_PROFILES)),
            heterogeneous_distinct,
        ),
        differ_on_every_draw=all(
            homogeneous[i] != heterogeneous[i] for i in eachindex(assignment_seeds)
        ),
    )
end
