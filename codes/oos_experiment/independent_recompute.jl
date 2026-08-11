# =====================================================================================
# Independent downstream recomputation (OOS redesign stage 11).
#
# Every summary the campaign reports is recomputed here FROM THE PERIOD-LEVEL CSVs, by a code
# path that shares nothing with the one that produced them. If the two disagree, either the
# summary is wrong or the rows are — and both are results the campaign must not ship.
#
# The point is independence, so this file reuses NO accumulator, metric struct or deviation
# helper from the metrics layer. It reads CSV columns and does arithmetic, and nothing else.
# Sharing the implementation would make the check vacuous — a test that a function agrees with
# itself. A source gate in `IV1` enforces that literally, which is why the names of the functions
# being avoided are deliberately not spelled anywhere in this file.
# =====================================================================================

"""One recomputed quantity compared against what the campaign reported."""
struct RecomputedQuantity
    key::String
    reported::Float64
    recomputed::Float64
    absolute_difference::Float64
    within_tolerance::Bool
end

"""Outcome of recomputing a whole result directory from its period rows."""
struct RecomputationReport
    directory::String
    passed::Bool
    tolerance::Float64
    configurations::Int
    quantities::Vector{RecomputedQuantity}
    mismatches::Vector{RecomputedQuantity}
end

recomputation_summary(report::RecomputationReport) =
    "$(length(report.quantities) - length(report.mismatches))/$(length(report.quantities)) " *
    "cantidades reproducidas"

"""
Recompute the reported summaries from `period_actions.csv` and compare.

Checks, per `(replication, controller, fairness)` configuration:

  * total operating cost, against `replication_summary.csv`;
  * the all-grid benchmark and total savings;
  * each household's PV allocation, demand, cost and savings, against `household_summary.csv`;
  * each household's realized proportional PV and savings targets and deviations, against
    `fairness_diagnostics.csv`.

Only COMPLETED configurations are compared. An aborted one has a partial trajectory by design,
and its horizon-total diagnostics are deliberately `NaN`, so comparing them would test the
abort convention rather than the arithmetic.

`tolerance` is absolute and generous relative to the quantities involved: the two paths
accumulate the same additions in different orders, so they agree to floating-point associativity
rather than bit for bit.
"""
function recompute_from_period_rows(directory::AbstractString; tolerance::Float64=1e-6)
    isdir(directory) || error("No existe el directorio de resultados: $directory")
    periods = CSV.read(joinpath(directory, "period_actions.csv"), DataFrame)
    replications = CSV.read(joinpath(directory, "replication_summary.csv"), DataFrame)
    households = CSV.read(joinpath(directory, "household_summary.csv"), DataFrame)
    diagnostics_path = joinpath(directory, "fairness_diagnostics.csv")
    diagnostics = isfile(diagnostics_path) ? CSV.read(diagnostics_path, DataFrame) : nothing

    quantities = RecomputedQuantity[]
    compare(key, reported, recomputed) = push!(quantities, RecomputedQuantity(
        key, Float64(reported), Float64(recomputed),
        abs(Float64(reported) - Float64(recomputed)),
        abs(Float64(reported) - Float64(recomputed)) <= tolerance,
    ))

    # A replication number identifies a trajectory only WITHIN one structural instance, so a
    # merged campaign has one row per instance for the same (replication, controller, policy).
    # Every filter below therefore carries the instance; without it the rows of unrelated
    # instances would be summed together.
    configurations = 0
    for summary in eachrow(replications)
        summary.CompletionStatus == "completed" || continue
        configurations += 1
        instance = _row_instance(summary)
        replication = summary.Replication
        controller = String(summary.Controller)
        fairness = String(summary.Fairness)
        label = "$(instance)|r$(replication)|$(controller)|$(fairness)"

        rows = filter(
            r -> _row_instance(r) == instance && r.Replication == replication &&
                 String(r.Controller) == controller && String(r.Fairness) == fairness,
            periods,
        )
        nrow(rows) > 0 || continue
        last_period = maximum(rows.Period)

        # --- configuration totals, summed from the raw household-period rows ----------------
        compare("$label|TotalOperatingCost", summary.TotalOperatingCost, sum(rows.HouseholdCost))

        # The benchmark and the savings are only carried cumulatively, so they are read at the
        # final period rather than summed — summing a cumulative column would double count.
        final_rows = filter(r -> r.Period == last_period, rows)
        compare("$label|AllGridBenchmark", summary.AllGridBenchmark,
                sum(final_rows.CumulativeAllGridCost))
        compare("$label|TotalSavings", summary.TotalSavings, sum(final_rows.CumulativeSavings))
        compare("$label|TotalPV", summary.TotalPV, sum(rows.ImplementedP))
        compare("$label|TotalGridImport", summary.TotalGridImport, sum(rows.ImplementedI))
        compare("$label|TotalGridExport", summary.TotalGridExport, sum(rows.ImplementedG))
        compare("$label|AggregateBatteryCharge", summary.AggregateBatteryCharge,
                sum(rows.ImplementedZ))
        compare("$label|AggregateBatteryDischarge", summary.AggregateBatteryDischarge,
                sum(rows.ImplementedY))

        # --- per household ------------------------------------------------------------------
        house_ids = sort(unique(rows.House))
        pv_by_house = Dict{Int,Float64}()
        demand_by_house = Dict{Int,Float64}()
        cost_by_house = Dict{Int,Float64}()
        benchmark_by_house = Dict{Int,Float64}()
        for house in house_ids
            house_rows = filter(r -> r.House == house, rows)
            pv_by_house[house] = sum(house_rows.ImplementedP)
            demand_by_house[house] = sum(house_rows.RealizedDemand)
            cost_by_house[house] = sum(house_rows.HouseholdCost)
            benchmark_by_house[house] =
                only(filter(r -> r.Period == last_period, house_rows).CumulativeAllGridCost)
        end

        for house in house_ids
            reported = filter(
                r -> _row_instance(r) == instance && r.Replication == replication &&
                     String(r.Controller) == controller &&
                     String(r.Fairness) == fairness && r.House == house,
                households,
            )
            nrow(reported) == 1 || continue
            entry = only(eachrow(reported))
            compare("$label|h$house|PVAllocation", entry.PVAllocation, pv_by_house[house])
            compare("$label|h$house|Demand", entry.Demand, demand_by_house[house])
            compare("$label|h$house|OperatingCost", entry.OperatingCost, cost_by_house[house])
            compare("$label|h$house|Savings", entry.Savings,
                    benchmark_by_house[house] - cost_by_house[house])
        end

        # --- policy-aligned diagnostics, recomputed from their definitions -------------------
        diagnostics === nothing && continue
        total_pv = sum(values(pv_by_house))
        total_demand = sum(values(demand_by_house))
        total_benchmark = sum(values(benchmark_by_house))
        savings_by_house = Dict(
            house => benchmark_by_house[house] - cost_by_house[house] for house in house_ids
        )
        total_savings = sum(values(savings_by_house))
        # alpha = total PV / total demand;  gamma = total savings / total benchmark.
        alpha = total_demand > OOS_RELATIVE_FLOOR ? total_pv / total_demand : 0.0
        gamma = abs(total_benchmark) > OOS_RELATIVE_FLOOR ? total_savings / total_benchmark : 0.0

        for house in house_ids
            reported = filter(
                r -> _row_instance(r) == instance && r.Replication == replication &&
                     String(r.Controller) == controller &&
                     String(r.Fairness) == fairness && r.House == house,
                diagnostics,
            )
            nrow(reported) == 1 || continue
            entry = only(eachrow(reported))
            compare("$label|h$house|PVProportionalTarget", entry.PVProportionalTarget,
                    alpha * demand_by_house[house])
            compare("$label|h$house|PVDeviation", entry.PVDeviation,
                    pv_by_house[house] - alpha * demand_by_house[house])
            compare("$label|h$house|SavingsProportionalTarget", entry.SavingsProportionalTarget,
                    gamma * benchmark_by_house[house])
            compare("$label|h$house|SavingsDeviation", entry.SavingsDeviation,
                    savings_by_house[house] - gamma * benchmark_by_house[house])
            if total_pv > OOS_RELATIVE_FLOOR
                compare("$label|h$house|PVRate", entry.PVRate, pv_by_house[house] / total_pv)
            end
        end
    end

    mismatches = [q for q in quantities if !q.within_tolerance]
    return RecomputationReport(
        String(directory), isempty(mismatches), tolerance, configurations,
        quantities, mismatches,
    )
end
