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

"""
Floor below which a paired relative comparison is refused rather than reported.

Plan section 4.8 requires a stated rule for a zero or near-zero denominator. This is it: a
percentage whose baseline is smaller than the floor is written as `NaN` and counted in
`ZeroDenominatorObservations`, never as a large or infinite number.
"""
const OOS_RELATIVE_COMPARATOR_FLOOR = 1e-6

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

# -------------------------------------------------------------------------------------
# Policy-aligned fairness diagnostics (OOS redesign stage 10)
#
# Plan section 4.8: a fairness statistic must match the mathematical definition of the policy it
# is reported against. A proportional-rate dispersion does not validate a max-min rule, and a
# max-min shortfall does not validate a proportional one. Every diagnostic family below is
# computed for every run — they are cheap and comparable — but `applicable_diagnostic` names the
# ONE family that validates this policy, so a reader cannot present an incompatible statistic as
# validation.
# -------------------------------------------------------------------------------------

"""Which diagnostic family validates a policy, and which are merely descriptive."""
function applicable_fairness_diagnostic(policy::FairnessPolicy)
    policy === PEA && return "proportional_pv"
    policy === SA && return "proportional_savings"
    policy === LEXMMFPEA && return "lexicographic_pv"
    policy === LEXMMFSA && return "lexicographic_savings"
    policy === STATIC_DEMAND_SHARE && return "static_share_residual"
    policy === NONE && return "descriptive_only"
    error("Familia de diagnóstico no definida para la regla $policy.")
end

"""
Realized fairness diagnostics of one configuration, by family.

`NONE` receives `descriptive_only`. That is not a formality: with no distributive rule the
household split of the community PV is a DEGENERATE optimum — total cost depends on the
aggregates alone, so any split with the same community total is equally optimal, and stage 9
observed cold and warm runs landing on different vertices of that face. `NONE` household
allocations are therefore outcomes of an arbitrary optimum and must never be read as a
distributive result or as a violation of a rule that does not exist.
"""
struct PolicyFairnessDiagnostics
    policy::FairnessPolicy
    resource::String
    applicable_diagnostic::String

    # proportional PV: target `alpha_real * D_j` with `alpha_real = sum_t C_t / sum_j D_j`
    pv_rate::Vector{Float64}
    pv_proportional_target::Vector{Float64}
    pv_deviation::Vector{Float64}

    # proportional savings: target `gamma_real * B_j` with `gamma_real = sum_j S_j / sum_j B_j`
    savings_rate::Vector{Float64}
    savings_proportional_target::Vector{Float64}
    savings_deviation::Vector{Float64}

    # static shares: what the ex-ante table would have allocated from the REALIZED PV
    static_share_target::Vector{Float64}
    static_share_deviation::Vector{Float64}
    max_static_share_deviation::Float64

    # lexicographic: the ordered outcome vector, its cumulative sums, and the worst-off gap
    sorted_pv::Vector{Float64}
    sorted_savings::Vector{Float64}
    cumulative_pv_order::Vector{Float64}
    cumulative_savings_order::Vector{Float64}
    min_pv::Float64
    min_savings::Float64
    lexicographic_pv_shortfall::Float64
    lexicographic_savings_shortfall::Float64
end

"""
Absolute gap of the worst-off household from the mean outcome.

`max(0, mean - min)`. This is the realized max-min diagnostic: a perfectly equal allocation gives
zero, and the value is the amount by which the least-served household falls below the average.
It is reported in the resource's own unit, never as a dispersion ratio, because a max-min rule is
not a statement about dispersion.
"""
lexicographic_shortfall(values::AbstractVector{Float64}) =
    isempty(values) ? NaN : max(0.0, sum(values) / length(values) - minimum(values))

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

    """Policy-aligned fairness diagnostics (stage 10); `applicable_diagnostic` names the one
    family that validates this run's policy."""
    fairness_diagnostics::PolicyFairnessDiagnostics
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


"""Compute every fairness diagnostic family for one completed configuration."""
function policy_fairness_diagnostics(
    run::ReplicationRun,
    pv_allocation::Vector{Float64},
    demand::Vector{Float64},
    benchmark::Vector{Float64},
    cost::Vector{Float64},
    share_table::Union{Nothing,OOSStaticShareTable},
)
    J = length(pv_allocation)
    total_pv = sum(pv_allocation)
    savings = benchmark .- cost
    total_savings = sum(savings)
    total_benchmark = sum(benchmark)

    pv_diagnostics = realized_pv_deviation(pv_allocation, demand, total_pv)
    pv_target = [pv_diagnostics.alpha * demand[j] for j in 1:J]
    pv_rate = [total_pv > OOS_RELATIVE_FLOOR ? pv_allocation[j] / total_pv : NaN for j in 1:J]

    gamma = abs(total_benchmark) > OOS_RELATIVE_FLOOR ? total_savings / total_benchmark : 0.0
    savings_target = [gamma * benchmark[j] for j in 1:J]
    savings_rate = [
        abs(total_savings) > OOS_RELATIVE_FLOOR ? savings[j] / total_savings : NaN for j in 1:J
    ]

    # What the ex-ante static table would have allocated out of the REALIZED community PV. This
    # is the only residual that validates `STATIC_DEMAND_SHARE`, and it is defined even for the
    # policies that do not use the table, where it is descriptive.
    static_target = zeros(J)
    if share_table !== nothing
        for record in run.records, j in 1:J
            static_target[j] += share_table.shares[j, record.period] * record.realized_pv
        end
    else
        fill!(static_target, NaN)
    end
    static_deviation = pv_allocation .- static_target
    max_static = isempty(static_deviation) || any(isnan, static_deviation) ?
        NaN : maximum(abs.(static_deviation))

    sorted_pv = sort(pv_allocation)
    sorted_savings = sort(savings)
    return PolicyFairnessDiagnostics(
        run.fairness, policy_resource(run.fairness),
        applicable_fairness_diagnostic(run.fairness),
        pv_rate, pv_target, pv_allocation .- pv_target,
        savings_rate, savings_target, savings .- savings_target,
        static_target, static_deviation, max_static,
        sorted_pv, sorted_savings, cumsum(sorted_pv), cumsum(sorted_savings),
        isempty(pv_allocation) ? NaN : minimum(pv_allocation),
        isempty(savings) ? NaN : minimum(savings),
        lexicographic_shortfall(pv_allocation), lexicographic_shortfall(savings),
    )
end

"""Aggregate one configuration's implemented trajectory into its realized metrics."""
function compute_replication_metrics(
    template::OOSInstanceTemplate,
    run::ReplicationRun,
    config::OOSExperimentConfig;
    share_table::Union{Nothing,OOSStaticShareTable}=nothing,
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

    # Completeness is measured against the EVALUATION HORIZON, not against the repository
    # horizon and not against the number of solves. With `h = 1` there is one solve per evaluated
    # period and the two coincide; with `h > 1` one solve commits `h` periods, of which only the
    # ones inside `1:H` are recorded. `template.T` is the base profile length and says nothing
    # about either.
    expected_records = config.evaluation_horizon

    terminal_soc = isempty(run.records) ? template.s_I : run.records[end].soc_after
    # Reported as a DIAGNOSTIC, not as a constraint residual. Stage 4 moved the terminal target
    # to the end of each look-ahead window, so the state of charge reached at the end of the
    # evaluation horizon is an outcome of the rolling policy rather than something the model
    # promised. It is still recorded so the drift is visible.
    terminal_residual = run.periods_completed == expected_records ?
        abs(terminal_soc - template.s_I) : NaN

    # Horizon-total diagnostics are only meaningful over a complete horizon. On an aborted
    # run they are set to NaN so a truncated trajectory can never be compared against a
    # complete one; the raw accumulations are kept and labelled by HorizonCovered.
    complete = run.completed && run.periods_completed == expected_records
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
        expected_records == 0 ? 0.0 : run.periods_completed / expected_records,
        tolerance_stats.activations, tolerance_stats.activation_rate,
        tolerance_stats.mean_active, tolerance_stats.mean_all_periods,
        tolerance_stats.maximum, run.pea_strict_feasible_periods,
        copy(run.pea_tolerances),
        households,
        policy_fairness_diagnostics(run, pv_allocation, demand, benchmark, cost, share_table),
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

# =====================================================================================
# Grid-direction audit (OOS redesign stage 8, Phase A)
#
# The approved formulation has NO grid-direction binary: `I[j,n]` and `G[j,n]` are independent
# nonnegative variables, so a household importing and exporting in the same information state is
# not structurally excluded. Whether it ever HAPPENS is an empirical question, and stage 8 answers
# it before deciding whether to pay for a binary.
#
# The economics say it should not: a household's node cost is
# `delta * (mu*y + nu*I - beta*G)`, so simultaneous import and export costs `nu - beta` per unit
# of the overlap while changing nothing physical. Whenever `beta <= nu` the overlap is weakly
# dominated and cost minimization removes it. The audit measures that instead of asserting it.
#
# Phase A is diagnostic only. It adds no variable, no constraint and no binary. Phase B — an
# explicit exclusivity formulation — is authorized only if this audit finds overlap.
# =====================================================================================

"""
Simultaneous grid import and export measured on one implemented action.

`household_overlap` is `max_j min(I_j, G_j)` and `aggregate_overlap` is
`min(sum_j I_j, sum_j G_j)`. Both are in kWh and both are zero for an action that trades in one
direction only. The aggregate figure is reported separately because a community can legitimately
have one household importing while another exports; only the HOUSEHOLD figure is evidence that
the missing exclusivity rule bites.
"""
function grid_direction_overlap(action::PeriodAction)
    household = 0.0
    for j in eachindex(action.I)
        household = max(household, min(action.I[j], action.G[j]))
    end
    return (
        household_overlap=household,
        aggregate_overlap=min(sum(action.I), sum(action.G)),
    )
end

"""One configuration's grid-direction audit, pooled over its implemented periods."""
struct GridDirectionAudit
    controller::ControllerKind
    fairness::FairnessPolicy
    periods::Int
    household_violations::Int
    aggregate_overlaps::Int
    max_household_overlap::Float64
    max_aggregate_overlap::Float64
    tolerance::Float64
end

"""
Audit one completed configuration for simultaneous household import and export.

A *violation* is a period in which some household's `min(I_j, G_j)` exceeds `flow_tol`. Counting
against the flow tolerance rather than against zero keeps solver round-off out of the statistic,
exactly as the shared-mode simultaneity check does.
"""
function audit_grid_direction(run::ReplicationRun, config::OOSExperimentConfig)
    household_violations = 0
    aggregate_overlaps = 0
    max_household = 0.0
    max_aggregate = 0.0
    for record in run.records
        overlap = grid_direction_overlap(record.action)
        max_household = max(max_household, overlap.household_overlap)
        max_aggregate = max(max_aggregate, overlap.aggregate_overlap)
        overlap.household_overlap > config.flow_tol && (household_violations += 1)
        overlap.aggregate_overlap > config.flow_tol && (aggregate_overlaps += 1)
    end
    return GridDirectionAudit(
        run.controller, run.fairness, length(run.records),
        household_violations, aggregate_overlaps,
        max_household, max_aggregate, config.flow_tol,
    )
end

"""`true` when no household imported and exported simultaneously beyond the flow tolerance."""
grid_direction_clean(audit::GridDirectionAudit) = audit.household_violations == 0

"""
Turn a set of configuration audits into a gate report.

The check PASSES when no household overlap was observed, which is the evidence that the approved
formulation needs no direction binary. It FAILS — and therefore authorizes the stage-8 Phase-B
decision — the moment one is observed, naming the configuration and the magnitude.
"""
function grid_direction_gate(audits::Vector{GridDirectionAudit}, formulation_id::String)
    checks = GateCheck[]
    for audit in audits
        push!(checks, GateCheck(
            "grid_direction_$(audit.controller)_$(audit.fairness)",
            grid_direction_clean(audit),
            grid_direction_clean(audit) ?
            "Sin importación y exportación simultáneas por hogar en $(audit.periods) período(s); " *
            "solape máximo por hogar $(audit.max_household_overlap) <= $(audit.tolerance) kWh." :
            "$(audit.household_violations)/$(audit.periods) período(s) con un hogar importando y " *
            "exportando a la vez; solape máximo $(audit.max_household_overlap) kWh. Esto habilita " *
            "la decisión de la Fase B de la etapa 8 (exclusividad explícita de dirección de red).",
        ))
    end
    return GateReport(all(check -> check.passed, checks), checks, formulation_id)
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

    """
    `level` or `difference` (stage 10).

    A `level` row reports one configuration's own metric and has no comparator, so its relative
    fields are `NaN` by construction. A `difference` row always names both sides in `baseline`
    and `comparison`, which is what makes `mean_relative_percent` readable — plan section 4.8
    forbids an unlabelled percentage.
    """
    comparison_kind::String

    """`100 * mean((C - B) / |B|)` over the paired observations whose baseline clears the
    floor. `NaN` for a level row or when no observation clears it."""
    mean_relative_percent::Float64

    """Paired observations whose baseline was too small to divide by, excluded from the
    percentage above rather than producing a large or infinite value."""
    zero_denominator_observations::Int
end

"""Mean, standard deviation, standard error and a normal-approximation interval."""
function summarize_sample(values::Vector{Float64}, label::String, baseline::String, comparison::String;
    confidence_z::Float64=1.96,
    comparison_kind::String="level",
    relative_values::Vector{Float64}=Float64[],
    zero_denominator_observations::Int=0,
)
    relative = isempty(relative_values) ? NaN :
        sum(relative_values) / length(relative_values)
    n = length(values)
    if n == 0
        return PairedSummary(label, baseline, comparison, 0, NaN, NaN, NaN, NaN, NaN,
                             comparison_kind, relative, zero_denominator_observations)
    end
    average = sum(values) / n
    deviation = n > 1 ? sqrt(sum((v - average)^2 for v in values) / (n - 1)) : 0.0
    error_of_mean = n > 1 ? deviation / sqrt(n) : 0.0
    return PairedSummary(
        label, baseline, comparison, n, average, deviation, error_of_mean,
        average - confidence_z * error_of_mean, average + confidence_z * error_of_mean,
        comparison_kind, relative, zero_denominator_observations,
    )
end

"""
Paired relative difference `100 * (comparison - baseline) / |baseline|`, with the floor rule.

Returns `(relative_values, zero_denominator_observations)`. An observation whose baseline is
below `OOS_RELATIVE_COMPARATOR_FLOOR` is EXCLUDED and counted, never reported as a large or
infinite percentage.
"""
function paired_relative_differences(
    baseline_values::Vector{Float64},
    comparison_values::Vector{Float64},
)
    relative = Float64[]
    excluded = 0
    for (b, c) in zip(baseline_values, comparison_values)
        if abs(b) < OOS_RELATIVE_COMPARATOR_FLOOR
            excluded += 1
        else
            push!(relative, 100.0 * (c - b) / abs(b))
        end
    end
    return (relative, excluded)
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
        baselines = Float64[]
        comparisons = Float64[]
        for r in replications
            first_entry = get(indexed, (r, controllers[a], policy), nothing)
            second_entry = get(indexed, (r, controllers[b], policy), nothing)
            (first_entry === nothing || second_entry === nothing) && continue
            (first_entry.completed && second_entry.completed) || continue
            base = Float64(extractor(first_entry))
            comparison = Float64(extractor(second_entry))
            push!(baselines, base)
            push!(comparisons, comparison)
            push!(values, comparison - base)
        end
        relative, excluded = paired_relative_differences(baselines, comparisons)
        push!(summaries, summarize_sample(
            values, "$(metric_name)__controller_difference",
            "$(controllers[a])|$(policy)", "$(controllers[b])|$(policy)";
            comparison_kind="difference", relative_values=relative,
            zero_denominator_observations=excluded,
        ))
    end

    # Paired allocation/fairness-rule differences, holding the controller fixed.
    for controller in controllers, a in eachindex(policies), b in eachindex(policies)
        a < b || continue
        values = Float64[]
        baselines = Float64[]
        comparisons = Float64[]
        for r in replications
            first_entry = get(indexed, (r, controller, policies[a]), nothing)
            second_entry = get(indexed, (r, controller, policies[b]), nothing)
            (first_entry === nothing || second_entry === nothing) && continue
            (first_entry.completed && second_entry.completed) || continue
            base = Float64(extractor(first_entry))
            comparison = Float64(extractor(second_entry))
            push!(baselines, base)
            push!(comparisons, comparison)
            push!(values, comparison - base)
        end
        relative, excluded = paired_relative_differences(baselines, comparisons)
        push!(summaries, summarize_sample(
            values, "$(metric_name)__fairness_difference",
            "$(controller)|$(policies[a])", "$(controller)|$(policies[b])";
            comparison_kind="difference", relative_values=relative,
            zero_denominator_observations=excluded,
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
    # STAGE 11. `total_solve_time_sec` was here and is deliberately gone: solver time is
    # EXECUTION PROVENANCE, not a scientific outcome, and including it made `paired_statistics.csv`
    # differ between two runs that computed exactly the same thing. Runtime is measured from
    # `execution_provenance.csv` and `solve_provenance.csv` instead.
    return summaries
end
