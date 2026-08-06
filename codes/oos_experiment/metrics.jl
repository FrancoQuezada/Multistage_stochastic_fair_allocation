# =====================================================================================
# Realized metrics, fairness diagnostics and paired statistical comparison.
#
# Every diagnostic is recomputed from the *implemented* trajectory under the corrected
# physical feasible region. The formulas are unchanged; only the outcomes they are evaluated
# on are new.
#
# Reported quantities are deliberately node/period-level or household-level. There is no
# "percentage of households in a battery mode": the operating mode is shared.
# =====================================================================================

"""Small floor protecting relative-deviation denominators."""
const OOS_RELATIVE_FLOOR = 1e-9

"""Household-level realized outcome of one completed configuration."""
struct HouseholdMetrics
    household::Int
    demand::Float64
    pv_allocation::Float64
    demand_normalized_pv::Float64
    charge_contribution::Float64
    discharge_allocation::Float64
    grid_import::Float64
    grid_export::Float64
    operating_cost::Float64
    all_grid_cost::Float64
    savings::Float64
    savings_ratio::Float64
    pv_order_statistic::Int
    savings_order_statistic::Int
end

"""Replication-level realized outcome, including the fairness diagnostics."""
struct ReplicationMetrics
    replication_id::Int
    controller::ControllerKind
    fairness::FairnessPolicy
    completed::Bool
    periods_completed::Int

    total_operating_cost::Float64
    total_all_grid_cost::Float64
    total_savings::Float64

    terminal_soc::Float64
    terminal_residual::Float64

    total_pv::Float64
    total_grid_import::Float64
    total_grid_export::Float64
    total_battery_charge::Float64
    total_battery_discharge::Float64

    charging_periods::Int
    discharging_periods::Int
    idle_periods::Int

    realized_alpha::Float64
    max_pv_relative_deviation::Float64
    mean_pv_relative_deviation::Float64
    realized_gamma::Float64
    max_savings_relative_deviation::Float64
    mean_savings_relative_deviation::Float64

    min_household_pv::Float64
    min_household_savings::Float64
    sorted_household_pv::Vector{Float64}
    sorted_household_savings::Vector{Float64}

    max_fairness_residual::Float64
    max_physical_residual::Float64
    max_simultaneous_flow::Float64
    max_mode_link_residual::Float64
    max_integrality_residual::Float64

    optimization_failures::Int
    physical_violations::Int
    total_build_time_sec::Float64
    total_solve_time_sec::Float64
    failure_message::String

    # --- resource metadata and horizon coverage ----------------------------------------
    resource::String
    horizon_covered::Float64

    # --- strict-first / adaptive-minimum PEA statistics (kWh) --------------------------
    pea_tolerance_activations::Int
    pea_tolerance_activation_rate::Float64
    pea_tolerance_mean_active::Float64
    pea_tolerance_mean_all_periods::Float64
    pea_tolerance_max::Float64
    pea_strict_feasible_periods::Int
    pea_tolerances::Vector{Float64}

    households::Vector{HouseholdMetrics}
end

# -------------------------------------------------------------------------------------
# Fairness diagnostics
# -------------------------------------------------------------------------------------

"""
Realized proportional PV deviation.

    alpha_real = sum_t C_t / sum_{j,t} D_{j,t}
    dev_j      = |P_j_real - alpha_real * D_j_real| / max(alpha_real * D_j_real, eps)
"""
function realized_pv_deviation(pv_allocation::Vector{Float64}, demand::Vector{Float64}, total_pv::Float64)
    total_demand = sum(demand)
    alpha = total_demand > OOS_RELATIVE_FLOOR ? total_pv / total_demand : 0.0
    deviations = [
        abs(pv_allocation[j] - alpha * demand[j]) / max(alpha * demand[j], OOS_RELATIVE_FLOOR)
        for j in eachindex(demand)
    ]
    return (alpha=alpha, deviations=deviations)
end

"""
Realized proportional savings deviation.

    S_j_real   = B_j_real - K_j_real
    gamma_real = sum_j S_j_real / sum_j B_j_real
    dev_j      = |S_j_real - gamma_real B_j_real| / max(|gamma_real B_j_real|, eps)
"""
function realized_savings_deviation(benchmark::Vector{Float64}, cost::Vector{Float64})
    savings = benchmark .- cost
    total_benchmark = sum(benchmark)
    gamma = abs(total_benchmark) > OOS_RELATIVE_FLOOR ? sum(savings) / total_benchmark : 0.0
    deviations = [
        abs(savings[j] - gamma * benchmark[j]) / max(abs(gamma * benchmark[j]), OOS_RELATIVE_FLOOR)
        for j in eachindex(benchmark)
    ]
    return (gamma=gamma, savings=savings, deviations=deviations)
end

# -------------------------------------------------------------------------------------
# Replication metrics
# -------------------------------------------------------------------------------------

"""
Summarize a per-period PEA band sequence, in kWh.

Conventions, applied identically at replication and configuration level:

  * an *activation* is a period whose band exceeds `OOS_PEA_ACTIVATION_THRESHOLD`, so solver
    noise cannot inflate the count;
  * `mean_active` averages over activated periods only. With no activation it is `0.0`, not
    `NaN`, so the column stays numeric and sums correctly;
  * `mean_all_periods` averages over every solved period, including the zeros.
"""
function summarize_pea_tolerances(tolerances::AbstractVector{<:Real})
    periods = length(tolerances)
    active = [Float64(x) for x in tolerances if x > OOS_PEA_ACTIVATION_THRESHOLD]
    activations = length(active)
    return (
        activations=activations,
        activation_rate=periods == 0 ? 0.0 : activations / periods,
        mean_active=activations == 0 ? 0.0 : sum(active) / activations,
        mean_all_periods=periods == 0 ? 0.0 : sum(Float64, tolerances) / periods,
        maximum=periods == 0 ? 0.0 : maximum(Float64, tolerances),
        periods=periods,
        total=sum(Float64, tolerances; init=0.0),
    )
end

"""Aggregate one configuration's implemented trajectory into its realized metrics."""
function compute_replication_metrics(
    template::OOSInstanceTemplate,
    run::ReplicationRun,
    config::OOSExperimentConfig,
)
    J = template.J
    state = run.final_state
    demand = copy(state.cumulative_demand)
    pv_allocation = copy(state.cumulative_pv)
    cost = copy(state.cumulative_operating_cost)
    benchmark = copy(state.cumulative_all_grid_cost)

    charge = zeros(J)
    discharge = zeros(J)
    import_grid = zeros(J)
    export_grid = zeros(J)
    charging_periods = 0
    discharging_periods = 0
    idle_periods = 0
    max_fairness = 0.0
    max_physical = 0.0
    max_simultaneous = 0.0
    max_link = 0.0
    max_integrality = 0.0

    for record in run.records
        action = record.action
        for j in 1:J
            charge[j] += action.z[j]
            discharge[j] += action.y[j]
            import_grid[j] += action.I[j]
            export_grid[j] += action.G[j]
        end
        charging = action.aggregate_charge > config.flow_tol
        discharging = action.aggregate_discharge > config.flow_tol
        if charging && !discharging
            charging_periods += 1
        elseif discharging && !charging
            discharging_periods += 1
        elseif !charging && !discharging
            idle_periods += 1
        end
        residuals = record.validation.residuals
        max_physical = max(max_physical, max_residual(residuals))
        max_simultaneous = max(max_simultaneous, residuals.simultaneous_flow)
        max_link = max(max_link, residuals.charge_link, residuals.discharge_link)
        max_integrality = max(max_integrality, residuals.integrality)
        model_fairness = record.result.residuals.fairness
        isnan(model_fairness) || (max_fairness = max(max_fairness, model_fairness))
    end

    total_pv = sum(pv_allocation)
    pv_diagnostics = realized_pv_deviation(pv_allocation, demand, total_pv)
    savings_diagnostics = realized_savings_deviation(benchmark, cost)
    savings = savings_diagnostics.savings

    terminal_soc = isempty(run.records) ? template.s_I : run.records[end].soc_after
    terminal_residual = run.periods_completed == template.T ?
        abs(terminal_soc - template.s_I) : NaN

    # Horizon-total diagnostics are only meaningful over a complete horizon. On an aborted
    # run they are set to NaN so a truncated trajectory can never be compared against a
    # complete one; the raw accumulations are kept and labelled by HorizonCovered.
    complete = run.completed && run.periods_completed == template.T
    partial(value) = complete ? value : NaN
    tolerance_stats = summarize_pea_tolerances(run.pea_tolerances)

    pv_order = _order_statistics(pv_allocation)
    savings_order = _order_statistics(savings)

    households = [
        HouseholdMetrics(
            j, demand[j], pv_allocation[j],
            demand[j] > OOS_RELATIVE_FLOOR ? pv_allocation[j] / demand[j] : NaN,
            charge[j], discharge[j], import_grid[j], export_grid[j],
            cost[j], benchmark[j], savings[j],
            abs(benchmark[j]) > OOS_RELATIVE_FLOOR ? savings[j] / benchmark[j] : NaN,
            pv_order[j], savings_order[j],
        )
        for j in 1:J
    ]

    return ReplicationMetrics(
        run.replication_id, run.controller, run.fairness, run.completed, run.periods_completed,
        sum(cost), sum(benchmark), sum(savings),
        terminal_soc, terminal_residual,
        total_pv, sum(import_grid), sum(export_grid), sum(charge), sum(discharge),
        charging_periods, discharging_periods, idle_periods,
        partial(pv_diagnostics.alpha),
        partial(isempty(pv_diagnostics.deviations) ? NaN : maximum(pv_diagnostics.deviations)),
        partial(isempty(pv_diagnostics.deviations) ? NaN : sum(pv_diagnostics.deviations) / J),
        partial(savings_diagnostics.gamma),
        partial(isempty(savings_diagnostics.deviations) ? NaN : maximum(savings_diagnostics.deviations)),
        partial(isempty(savings_diagnostics.deviations) ? NaN : sum(savings_diagnostics.deviations) / J),
        partial(isempty(pv_allocation) ? NaN : minimum(pv_allocation)),
        partial(isempty(savings) ? NaN : minimum(savings)),
        sort(pv_allocation), sort(savings),
        max_fairness, max_physical, max_simultaneous, max_link, max_integrality,
        run.optimization_failures, run.physical_violations,
        run.total_build_time_sec, run.total_solve_time_sec, run.failure_message,
        policy_resource(run.fairness),
        template.T == 0 ? 0.0 : run.periods_completed / template.T,
        tolerance_stats.activations, tolerance_stats.activation_rate,
        tolerance_stats.mean_active, tolerance_stats.mean_all_periods,
        tolerance_stats.maximum, run.pea_strict_feasible_periods,
        copy(run.pea_tolerances),
        households,
    )
end

"""Rank of each household in ascending order of its outcome (1 = smallest)."""
function _order_statistics(values::Vector{Float64})
    order = sortperm(values)
    ranks = zeros(Int, length(values))
    for (rank, index) in enumerate(order)
        ranks[index] = rank
    end
    return ranks
end

# -------------------------------------------------------------------------------------
# Configuration-level aggregation
# -------------------------------------------------------------------------------------

"""Pooled PEA statistics for one (controller, allocation/fairness rule) configuration."""
struct ConfigurationPEASummary
    controller::ControllerKind
    fairness::FairnessPolicy
    resource::String
    replications::Int
    completed_replications::Int
    periods_solved::Int
    activations::Int
    activation_rate::Float64
    mean_active::Float64
    mean_all_periods::Float64
    maximum_tolerance::Float64
    strict_feasible_periods::Int
end

"""
Aggregate PEA tolerance statistics across replications, **pooled over periods**.

`mean_active` divides the sum of all positive bands across replications by the total number of
active periods across replications. It is deliberately *not* an unweighted mean of replication
means, which would over-weight replications that activated only once.
"""
function configuration_pea_summaries(metrics::Vector{ReplicationMetrics})
    grouped = Dict{Tuple{ControllerKind,FairnessPolicy},Vector{ReplicationMetrics}}()
    for entry in metrics
        push!(get!(grouped, (entry.controller, entry.fairness), ReplicationMetrics[]), entry)
    end
    summaries = ConfigurationPEASummary[]
    for key in sort(collect(keys(grouped)); by=k -> (Int(k[1]), Int(k[2])))
        entries = grouped[key]
        pooled = reduce(vcat, [entry.pea_tolerances for entry in entries]; init=Float64[])
        stats = summarize_pea_tolerances(pooled)
        push!(summaries, ConfigurationPEASummary(
            key[1], key[2], policy_resource(key[2]),
            length(entries), count(e -> e.completed, entries),
            stats.periods, stats.activations, stats.activation_rate,
            stats.mean_active, stats.mean_all_periods, stats.maximum,
            sum(e.pea_strict_feasible_periods for e in entries),
        ))
    end
    return summaries
end

# -------------------------------------------------------------------------------------
# Paired statistical comparison
# -------------------------------------------------------------------------------------

"""Summary of one paired sample of out-of-sample observations."""
struct PairedSummary
    label::String
    baseline::String
    comparison::String
    observations::Int
    mean::Float64
    standard_deviation::Float64
    standard_error::Float64
    confidence_low::Float64
    confidence_high::Float64
end

"""Mean, standard deviation, standard error and a normal-approximation interval."""
function summarize_sample(values::Vector{Float64}, label::String, baseline::String, comparison::String;
    confidence_z::Float64=1.96)
    n = length(values)
    if n == 0
        return PairedSummary(label, baseline, comparison, 0, NaN, NaN, NaN, NaN, NaN)
    end
    average = sum(values) / n
    deviation = n > 1 ? sqrt(sum((v - average)^2 for v in values) / (n - 1)) : 0.0
    error_of_mean = n > 1 ? deviation / sqrt(n) : 0.0
    return PairedSummary(
        label, baseline, comparison, n, average, deviation, error_of_mean,
        average - confidence_z * error_of_mean, average + confidence_z * error_of_mean,
    )
end

"""
Paired differences of one metric across controllers and across allocation/fairness rules.

Only replications completed by *both* members of a pair contribute, so every difference is a
genuine paired observation on the same out-of-sample trajectory.
"""
function paired_comparisons(
    metrics::Vector{ReplicationMetrics},
    metric_name::String,
    extractor,
)
    indexed = Dict{Tuple{Int,ControllerKind,FairnessPolicy},ReplicationMetrics}()
    for entry in metrics
        indexed[(entry.replication_id, entry.controller, entry.fairness)] = entry
    end
    replications = sort(unique(entry.replication_id for entry in metrics))
    controllers = sort(unique(entry.controller for entry in metrics); by=Int)
    policies = sort(unique(entry.fairness for entry in metrics); by=Int)

    summaries = PairedSummary[]

    # Levels: one summary per configuration.
    for controller in controllers, policy in policies
        values = Float64[]
        for r in replications
            entry = get(indexed, (r, controller, policy), nothing)
            entry === nothing && continue
            entry.completed || continue
            push!(values, Float64(extractor(entry)))
        end
        push!(summaries, summarize_sample(
            values, "$(metric_name)__level", "$(controller)|$(policy)", "-",
        ))
    end

    # Paired controller differences, holding the allocation/fairness rule fixed.
    for policy in policies, a in eachindex(controllers), b in eachindex(controllers)
        a < b || continue
        values = Float64[]
        for r in replications
            first_entry = get(indexed, (r, controllers[a], policy), nothing)
            second_entry = get(indexed, (r, controllers[b], policy), nothing)
            (first_entry === nothing || second_entry === nothing) && continue
            (first_entry.completed && second_entry.completed) || continue
            push!(values, Float64(extractor(second_entry)) - Float64(extractor(first_entry)))
        end
        push!(summaries, summarize_sample(
            values, "$(metric_name)__controller_difference",
            "$(controllers[a])|$(policy)", "$(controllers[b])|$(policy)",
        ))
    end

    # Paired allocation/fairness-rule differences, holding the controller fixed.
    for controller in controllers, a in eachindex(policies), b in eachindex(policies)
        a < b || continue
        values = Float64[]
        for r in replications
            first_entry = get(indexed, (r, controller, policies[a]), nothing)
            second_entry = get(indexed, (r, controller, policies[b]), nothing)
            (first_entry === nothing || second_entry === nothing) && continue
            (first_entry.completed && second_entry.completed) || continue
            push!(values, Float64(extractor(second_entry)) - Float64(extractor(first_entry)))
        end
        push!(summaries, summarize_sample(
            values, "$(metric_name)__fairness_difference",
            "$(controller)|$(policies[a])", "$(controller)|$(policies[b])",
        ))
    end

    return summaries
end

"""Standard bundle of paired statistics over the campaign's primary metrics."""
function campaign_statistics(metrics::Vector{ReplicationMetrics})
    summaries = PairedSummary[]
    append!(summaries, paired_comparisons(metrics, "total_operating_cost", m -> m.total_operating_cost))
    append!(summaries, paired_comparisons(metrics, "total_savings", m -> m.total_savings))
    append!(summaries, paired_comparisons(metrics, "max_pv_relative_deviation", m -> m.max_pv_relative_deviation))
    append!(summaries, paired_comparisons(metrics, "max_savings_relative_deviation", m -> m.max_savings_relative_deviation))
    append!(summaries, paired_comparisons(metrics, "min_household_pv", m -> m.min_household_pv))
    append!(summaries, paired_comparisons(metrics, "min_household_savings", m -> m.min_household_savings))
    append!(summaries, paired_comparisons(metrics, "total_solve_time_sec", m -> m.total_solve_time_sec))
    return summaries
end
