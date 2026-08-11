# =====================================================================================
# Tidy outputs.
#
# Six separate artefacts, all carrying the `formulation_id`, so old and corrected results can
# never be merged in an unlabelled table. Nothing is written to the existing model-result
# directories: every path lives under `config.output_directory` (default `results_oos/`).
#
# No output contains a household-level battery-mode field, and no output reports a
# "percentage of households in a battery mode". The canonical mode record is period-level, in
# `battery_operation.csv`.
# =====================================================================================

const OOS_OUTPUT_FILES = (
    replication_summary="replication_summary.csv",
    household_summary="household_summary.csv",
    period_actions="period_actions.csv",
    battery_operation="battery_operation.csv",
    solve_log="solve_log.csv",
    pea_recovery="pea_recovery.csv",
    configuration_summary="configuration_summary.csv",
    run_identity="run_identity.csv",
    fairness_diagnostics="fairness_diagnostics.csv",
    execution_provenance="execution_provenance.csv",
    solve_provenance="solve_provenance.csv",
    paired_statistics="paired_statistics.csv",
    experiment_config="experiment_config.json",
    validation_report="validation_report.txt",
    model_audit="model_audit_summary.csv",
)

output_path(config::OOSExperimentConfig, key::Symbol) =
    joinpath(config.output_directory, getfield(OOS_OUTPUT_FILES, key))

function ensure_output_directory(config::OOSExperimentConfig)
    mkpath(config.output_directory)
    mkpath(joinpath(config.output_directory, "model_audit"))
    return config.output_directory
end

# -------------------------------------------------------------------------------------
# 18.1 replication_summary.csv
# -------------------------------------------------------------------------------------

function replication_summary_frame(
    config::OOSExperimentConfig,
    metrics::Vector{ReplicationMetrics},
    identity::OOSRunIdentity,
)
    frame = DataFrame(
        ExperimentID=String[], StructuralInstanceID=String[], PairedBaseID=String[],
        ParallelTaskID=String[],
        Replication=Int[], Controller=String[], Fairness=String[],
        FormulationID=String[], FormulationVariant=String[], Resource=String[],
        CompletionStatus=String[], PeriodsCompleted=Int[], HorizonCovered=Float64[],
        TotalOperatingCost=Float64[], AllGridBenchmark=Float64[], TotalSavings=Float64[],
        TerminalStateOfCharge=Float64[], TerminalResidual=Float64[],
        TotalPV=Float64[], TotalGridImport=Float64[], TotalGridExport=Float64[],
        AggregateBatteryCharge=Float64[], AggregateBatteryDischarge=Float64[],
        ChargingPeriods=Int[], DischargingPeriods=Int[], IdlePeriods=Int[],
        RealizedAlpha=Float64[], MaxPVRelativeDeviation=Float64[], MeanPVRelativeDeviation=Float64[],
        RealizedGamma=Float64[], MaxSavingsRelativeDeviation=Float64[],
        MeanSavingsRelativeDeviation=Float64[],
        MinHouseholdPV=Float64[], MinHouseholdSavings=Float64[],
        MaxFairnessResidual=Float64[], MaxPhysicalResidual=Float64[],
        MaxSimultaneousFlow=Float64[], MaxModeLinkResidual=Float64[],
        MaxIntegralityResidual=Float64[],
        PEAToleranceActivations=Int[], PEAToleranceActivationRate=Float64[],
        PEAToleranceMeanActive=Float64[], PEAToleranceMeanAllPeriods=Float64[],
        PEAToleranceMax=Float64[], PEAStrictFeasiblePeriods=Int[],
        OptimizationFailures=Int[], PhysicalViolations=Int[],
        FailureMessage=String[],
    )
    for entry in metrics
        push!(frame, (
            config.experiment_id, identity.structural_instance_id, identity.paired_base_id,
            identity.parallel_task_id,
            entry.replication_id, string(entry.controller),
            string(entry.fairness), config.formulation_id, string(config.formulation_variant),
            entry.resource,
            entry.completed ? "completed" : "aborted", entry.periods_completed,
            entry.horizon_covered,
            entry.total_operating_cost, entry.total_all_grid_cost, entry.total_savings,
            entry.terminal_soc, entry.terminal_residual,
            entry.total_pv, entry.total_grid_import, entry.total_grid_export,
            entry.total_battery_charge, entry.total_battery_discharge,
            entry.charging_periods, entry.discharging_periods, entry.idle_periods,
            entry.realized_alpha, entry.max_pv_relative_deviation, entry.mean_pv_relative_deviation,
            entry.realized_gamma, entry.max_savings_relative_deviation,
            entry.mean_savings_relative_deviation,
            entry.min_household_pv, entry.min_household_savings,
            entry.max_fairness_residual, entry.max_physical_residual,
            entry.max_simultaneous_flow, entry.max_mode_link_residual,
            entry.max_integrality_residual,
            entry.pea_tolerance_activations, entry.pea_tolerance_activation_rate,
            entry.pea_tolerance_mean_active, entry.pea_tolerance_mean_all_periods,
            entry.pea_tolerance_max, entry.pea_strict_feasible_periods,
            entry.optimization_failures, entry.physical_violations,
            entry.failure_message,
        ))
    end
    return frame
end

# -------------------------------------------------------------------------------------
# 18.2 household_summary.csv
# -------------------------------------------------------------------------------------

function household_summary_frame(
    config::OOSExperimentConfig,
    metrics::Vector{ReplicationMetrics},
    identity::OOSRunIdentity,
)
    frame = DataFrame(
        ExperimentID=String[], StructuralInstanceID=String[], ParallelTaskID=String[],
        Replication=Int[], Controller=String[], Fairness=String[],
        FormulationID=String[], Resource=String[], House=Int[],
        Demand=Float64[], PVAllocation=Float64[], DemandNormalizedPV=Float64[],
        ChargeContribution=Float64[], DischargeAllocation=Float64[],
        GridImport=Float64[], GridExport=Float64[],
        OperatingCost=Float64[], AllGridBenchmark=Float64[],
        Savings=Float64[], SavingsRatio=Float64[],
        PVOrderStatistic=Int[], SavingsOrderStatistic=Int[],
    )
    for entry in metrics, household in entry.households
        push!(frame, (
            config.experiment_id, identity.structural_instance_id, identity.parallel_task_id,
            entry.replication_id, string(entry.controller),
            string(entry.fairness), config.formulation_id, entry.resource, household.household,
            household.demand, household.pv_allocation, household.demand_normalized_pv,
            household.charge_contribution, household.discharge_allocation,
            household.grid_import, household.grid_export,
            household.operating_cost, household.all_grid_cost,
            household.savings, household.savings_ratio,
            household.pv_order_statistic, household.savings_order_statistic,
        ))
    end
    return frame
end

# -------------------------------------------------------------------------------------
# 18.3 period_actions.csv
# -------------------------------------------------------------------------------------

function period_actions_frame(
    config::OOSExperimentConfig,
    runs::Vector{ReplicationRun},
    identity::OOSRunIdentity,
)
    frame = DataFrame(
        FormulationID=String[], StructuralInstanceID=String[], ParallelTaskID=String[],
        ScenarioSupportID=String[], ObjectiveCriterion=String[],
        Replication=Int[], Controller=String[], Fairness=String[], Resource=String[],
        RollingStart=Int[], BlockFirstPeriod=Int[], BlockLastPeriod=Int[],
        EvaluatedFirstPeriod=Int[], EvaluatedLastPeriod=Int[],
        Period=Int[], House=Int[],
        RealizedPV=Float64[], RealizedDemand=Float64[],
        ImplementedP=Float64[], ImplementedZ=Float64[], ImplementedY=Float64[],
        ImplementedI=Float64[], ImplementedG=Float64[], ImplementedLambda=Float64[],
        HouseholdCost=Float64[],
        CumulativePV=Float64[], CumulativeDemand=Float64[],
        CumulativeCost=Float64[], CumulativeAllGridCost=Float64[], CumulativeSavings=Float64[],
        SharedBatteryMode=Float64[],
    )
    for run in runs, record in run.records
        for j in eachindex(record.action.p)
            block = implementation_block(config, record.rolling_start)
            evaluated = evaluation_block(config, record.rolling_start)
            push!(frame, (
                config.formulation_id, identity.structural_instance_id,
                identity.parallel_task_id, record.scenario_support_id,
                identity.objective_criterion,
                record.replication_id, string(record.controller),
                string(record.fairness), policy_resource(record.fairness),
                record.rolling_start, first(block), last(block),
                first(evaluated), last(evaluated),
                record.period, j,
                record.realized_pv, record.realized_demand[j],
                record.action.p[j], record.action.z[j], record.action.y[j],
                record.action.I[j], record.action.G[j], record.action.lambda[j],
                record.household_cost[j],
                record.cumulative_pv[j], record.cumulative_demand[j],
                record.cumulative_cost[j], record.cumulative_benchmark[j],
                record.cumulative_benchmark[j] - record.cumulative_cost[j],
                # Repeated as a foreign-key convenience only; the canonical record is
                # period-level, in battery_operation.csv.
                record.action.shared_battery_mode,
            ))
        end
    end
    return frame
end

# -------------------------------------------------------------------------------------
# 18.4 battery_operation.csv
# -------------------------------------------------------------------------------------

function battery_operation_frame(
    config::OOSExperimentConfig,
    runs::Vector{ReplicationRun},
    identity::OOSRunIdentity,
)
    frame = DataFrame(
        FormulationID=String[], StructuralInstanceID=String[], ParallelTaskID=String[],
        ScenarioSupportID=String[], ObjectiveCriterion=String[],
        Replication=Int[], Controller=String[], Fairness=String[], Resource=String[],
        RollingStart=Int[], Period=Int[], RealizedNode=Int[],
        SharedBatteryMode=Float64[], AggregateCharge=Float64[], AggregateDischarge=Float64[],
        StateOfChargeBefore=Float64[], StateOfChargeAfter=Float64[],
        ChargingLinkResidual=Float64[], DischargingLinkResidual=Float64[],
        SimultaneousFlowFlag=Bool[], SimultaneousFlowResidual=Float64[],
        IntegralityResidual=Float64[], BatteryTransitionResidual=Float64[],
        StateOfChargeBoundResidual=Float64[], TerminalResidual=Float64[],
    )
    for run in runs, record in run.records
        residuals = record.validation.residuals
        push!(frame, (
            config.formulation_id, identity.structural_instance_id, identity.parallel_task_id,
            record.scenario_support_id, identity.objective_criterion,
            record.replication_id, string(record.controller),
            string(record.fairness), policy_resource(record.fairness),
            record.rolling_start, record.period,
            # The realized information state of a receding-horizon simulation is always the
            # root of that period's look-ahead.
            1,
            record.action.shared_battery_mode,
            record.action.aggregate_charge, record.action.aggregate_discharge,
            record.soc_before, record.soc_after,
            residuals.charge_link, residuals.discharge_link,
            residuals.simultaneous_flow > config.flow_tol, residuals.simultaneous_flow,
            residuals.integrality, residuals.battery_transition,
            residuals.soc_bounds, residuals.terminal,
        ))
    end
    return frame
end

# -------------------------------------------------------------------------------------
# 18.5 solve_log.csv
# -------------------------------------------------------------------------------------

function solve_log_frame(
    config::OOSExperimentConfig,
    runs::Vector{ReplicationRun},
    identity::OOSRunIdentity,
)
    frame = DataFrame(
        Replication=Int[], Period=Int[], Controller=String[], Fairness=String[],
        FormulationID=String[], StructuralInstanceID=String[], ParallelTaskID=String[],
        ScenarioSupportID=String[], RollingStart=Int[],
        Phase=Int[], PhaseLabel=String[],
        TerminationStatus=String[], PrimalStatus=String[],
        Objective=Float64[], ObjectiveBound=Float64[],
        BinaryVariables=Int[], ContinuousVariables=Int[], TotalVariables=Int[],
        Constraints=Int[], Nonzeros=Int[],
        ExpectedModeNodes=Int[], GeneratedModeBinaries=Int[], UniquePolicyModes=Int[],
        LegacyHouseholdModeBinaries=Int[],
        LookaheadNodes=Int[], LookaheadScenarios=Int[],
        PresolveReducedVariables=Int[], PresolveReducedConstraints=Int[],
        RootRelaxation=Float64[], BranchAndBoundNodes=Int[], FinalGap=Float64[],
        MaxPhysicalResidual=Float64[], FairnessResidual=Float64[],
        FailureMessage=String[],
    )
    for run in runs, record in run.records
        result = record.result
        statistics = result.statistics
        legacy = record.lookahead_nodes * length(record.action.p)
        for phase in result.phases
            push!(frame, (
                record.replication_id, record.period, string(record.controller),
                string(record.fairness), config.formulation_id,
                identity.structural_instance_id, identity.parallel_task_id,
                record.scenario_support_id, record.rolling_start,
                phase.phase, phase.label,
                phase.termination_status, phase.primal_status,
                phase.objective_value, phase.objective_bound,
                phase.binary_variables, phase.continuous_variables, phase.variables,
                phase.constraints, phase.nonzeros,
                statistics.expected_mode_nodes, statistics.generated_mode_binaries,
                statistics.unique_policy_modes, legacy,
                record.lookahead_nodes, record.lookahead_scenarios,
                statistics.presolve_reduced_variables, statistics.presolve_reduced_constraints,
                phase.root_relaxation, phase.branch_and_bound_nodes, phase.final_gap,
                max_residual(record.validation.residuals), result.residuals.fairness,
                result.failure_message,
            ))
        end
    end
    return frame
end

"""Failed solves that produced no implemented action, kept so partial logs are preserved."""
function failed_solve_log_frame(config::OOSExperimentConfig, runs::Vector{ReplicationRun})
    frame = DataFrame(
        Replication=Int[], Period=Int[], Controller=String[], Fairness=String[],
        FormulationID=String[], FailureMessage=String[],
    )
    for run in runs
        isempty(run.failure_message) && continue
        push!(frame, (
            run.replication_id, run.periods_completed + 1, string(run.controller),
            string(run.fairness), config.formulation_id, run.failure_message,
        ))
    end
    return frame
end

# -------------------------------------------------------------------------------------
# pea_recovery.csv  (one row per solved period, every policy)
# -------------------------------------------------------------------------------------

"""
Per-period record of the strict-first / adaptive-minimum PEA workflow.

The schema is uniform across policies: non-PEA rows carry `PEA_Applicable = false`,
`PEA_Tolerance_Activated = false` and `PEA_Tolerance_Used = 0.0`.

`PEA_Tolerance_Used_kWh` is the common absolute household-level deviation admitted at that
rolling-horizon step, in **kWh** — the unit of the PEA allocation equation. It is an economic
quantity, not a solver feasibility tolerance.

`PEA_Tolerance_Numeric_Eps_kWh` is the Phase-II numerical allowance. It is added to
`epsilon_pea_star` in the cap `epsilon_pea <= epsilon_pea_star + numeric_eps`, so it carries the
**same unit, kWh** — it is not dimensionless. It differs from the band in magnitude and purpose
(default `1e-6` kWh), never in dimension.
"""
function pea_recovery_frame(
    config::OOSExperimentConfig,
    runs::Vector{ReplicationRun},
    identity::OOSRunIdentity,
)
    frame = DataFrame(
        FormulationID=String[], StructuralInstanceID=String[], ParallelTaskID=String[],
        Replication=Int[], Controller=String[], Fairness=String[],
        Resource=String[], RollingStart=Int[], Period=Int[],
        BandPolicy=Bool[], BandToleranceMode=String[],
        PEA_Applicable=Bool[], PEA_Strict_Feasible=Bool[],
        PEA_Tolerance_Activated=Bool[], PEA_Tolerance_Used_kWh=Float64[],
        PEA_Strict_Status=String[], PEA_Phase1_Status=String[], PEA_Phase2_Status=String[],
        PEA_Recovery_Status=String[], Failure_Source=String[],
        PEA_Tolerance_Mode=String[], PEA_Tolerance_Numeric_Eps_kWh=Float64[],
    )
    for run in runs, record in run.records
        pea = record.result.pea
        band_policy = string(record.fairness) in OOS_ADAPTIVE_BAND_POLICIES
        push!(frame, (
            config.formulation_id, identity.structural_instance_id, identity.parallel_task_id,
            record.replication_id, string(record.controller),
            string(record.fairness), policy_resource(record.fairness),
            record.rolling_start, record.period,
            band_policy,
            record.fairness === SA ? string(config.sa_tolerance_mode) :
                record.fairness === PEA ? string(config.pea_tolerance_mode) : "not_applicable",
            pea.applicable, pea.strict_feasible,
            pea.tolerance_activated, pea.tolerance_used,
            pea.strict_status, pea.phase1_status, pea.phase2_status,
            pea.recovery_status, pea.failure_source,
            string(config.pea_tolerance_mode), config.pea_tolerance_numeric_eps,
        ))
    end
    return frame
end


# -------------------------------------------------------------------------------------
# run_identity.csv  (stage 10)
#
# The complete scientific identity of every configuration, once. It keeps the six temporal
# quantities separate — repository horizon, base profile length, evaluation horizon, look-ahead
# horizon, implementation step and required support end — so no reader has to re-derive one from
# another, and it records the seed-key CONTRACT without exposing any mutable execution detail.
# -------------------------------------------------------------------------------------

function run_identity_frame(
    config::OOSExperimentConfig,
    metrics::Vector{ReplicationMetrics},
    identity::OOSRunIdentity,
)
    frame = DataFrame(
        ExperimentID=String[], FormulationID=String[], FormulationVariant=String[],
        StructuralInstanceID=String[], PairedBaseID=String[], DeterministicDataID=String[],
        DemandAssignmentID=String[], ShareTableID=String[], RepositoryInstanceID=String[],
        ParallelTaskID=String[], ShardID=String[],
        Replication=Int[], Controller=String[], Fairness=String[], Resource=String[],
        FairnessFamily=String[], ApplicableDiagnostic=String[],
        ObjectiveCriterion=String[],
        RepositoryHorizon=Int[], BaseProfileLength=Int[], EvaluationHorizon=Int[],
        LookaheadHorizon=Int[], ImplementationStep=Int[],
        RequiredPeriodSupportEnd=Int[], RealizedPeriodEnd=Int[], RollingSolveCount=Int[],
        ConditionalSupportStream=String[], ConditionalSupportSeedKeys=String[],
        ConditionalSupportSeedExclusions=String[],
        GridDirectionExclusivity=Bool[], BatteryDirectionExclusivity=Bool[],
    )
    for entry in metrics
        push!(frame, (
            identity.experiment_id, identity.formulation_id, identity.formulation_variant,
            identity.structural_instance_id, identity.paired_base_id,
            identity.deterministic_data_id, identity.demand_assignment_id,
            identity.share_table_id, identity.repository_instance_id,
            identity.parallel_task_id, identity.shard_id,
            entry.replication_id, string(entry.controller), string(entry.fairness),
            entry.resource,
            entry.fairness_diagnostics.applicable_diagnostic == "descriptive_only" ?
                "none" : entry.resource,
            entry.fairness_diagnostics.applicable_diagnostic,
            identity.objective_criterion,
            identity.repository_instance_horizon, identity.base_profile_length,
            identity.evaluation_horizon, identity.lookahead_horizon,
            identity.implementation_step,
            identity.required_period_support_end, identity.realized_period_end,
            rolling_solve_count(config),
            OOS_LOOKAHEAD_SUPPORT_STREAM,
            join(["experiment_seed", "oos_replication", "rolling_start"], "|"),
            join(["controller", "fairness_policy", "solver_phase", "worker", "retry",
                  "execution_order"], "|"),
            config.grid_direction_exclusivity, config.battery_direction_exclusivity,
        ))
    end
    return frame
end

# -------------------------------------------------------------------------------------
# fairness_diagnostics.csv  (stage 10)
#
# One row per household per configuration, carrying EVERY diagnostic family together with the
# name of the one that validates this policy. Plan section 4.8: a proportional-rate dispersion
# does not validate a max-min rule, so `ApplicableDiagnostic` exists to stop a reader presenting
# an incompatible statistic as validation.
# -------------------------------------------------------------------------------------

function fairness_diagnostics_frame(
    config::OOSExperimentConfig,
    metrics::Vector{ReplicationMetrics},
    identity::OOSRunIdentity,
)
    frame = DataFrame(
        ExperimentID=String[], FormulationID=String[], StructuralInstanceID=String[],
        ParallelTaskID=String[], Replication=Int[], Controller=String[], Fairness=String[],
        Resource=String[], ApplicableDiagnostic=String[], House=Int[],
        PVAllocation=Float64[], PVRate=Float64[], PVProportionalTarget=Float64[],
        PVDeviation=Float64[],
        Savings=Float64[], SavingsRate=Float64[], SavingsProportionalTarget=Float64[],
        SavingsDeviation=Float64[],
        StaticShareTarget=Float64[], StaticShareDeviation=Float64[],
        PVOrderStatistic=Int[], SavingsOrderStatistic=Int[],
        SortedPV=Float64[], SortedSavings=Float64[],
        CumulativePVOrder=Float64[], CumulativeSavingsOrder=Float64[],
        MinHouseholdPV=Float64[], MinHouseholdSavings=Float64[],
        LexicographicPVShortfall=Float64[], LexicographicSavingsShortfall=Float64[],
    )
    for entry in metrics
        diagnostics = entry.fairness_diagnostics
        for household in entry.households
            j = household.household
            push!(frame, (
                identity.experiment_id, identity.formulation_id,
                identity.structural_instance_id, identity.parallel_task_id,
                entry.replication_id, string(entry.controller), string(entry.fairness),
                entry.resource, diagnostics.applicable_diagnostic, j,
                household.pv_allocation, diagnostics.pv_rate[j],
                diagnostics.pv_proportional_target[j], diagnostics.pv_deviation[j],
                household.savings, diagnostics.savings_rate[j],
                diagnostics.savings_proportional_target[j], diagnostics.savings_deviation[j],
                diagnostics.static_share_target[j], diagnostics.static_share_deviation[j],
                household.pv_order_statistic, household.savings_order_statistic,
                diagnostics.sorted_pv[j], diagnostics.sorted_savings[j],
                diagnostics.cumulative_pv_order[j], diagnostics.cumulative_savings_order[j],
                diagnostics.min_pv, diagnostics.min_savings,
                diagnostics.lexicographic_pv_shortfall,
                diagnostics.lexicographic_savings_shortfall,
            ))
        end
    end
    return frame
end

# -------------------------------------------------------------------------------------
# execution_provenance.csv  (stage 10)
#
# Everything that describes HOW a run executed rather than WHAT it computed: wall clock, solver
# time, worker, retry. Kept in its own file precisely so a sequential run and a parallel run can
# be compared for scientific equality without these fields taking part (plan section 4.9). No
# scientific row key ever references them.
# -------------------------------------------------------------------------------------

function execution_provenance_frame(
    config::OOSExperimentConfig,
    metrics::Vector{ReplicationMetrics},
    identity::OOSRunIdentity;
    worker::Int=0,
    retry::Int=0,
)
    frame = DataFrame(
        ExperimentID=String[], ParallelTaskID=String[], ShardID=String[],
        Replication=Int[], Controller=String[], Fairness=String[],
        Worker=Int[], Retry=Int[],
        TotalBuildTimeSec=Float64[], TotalSolveTimeSec=Float64[],
        OptimizationFailures=Int[], PhysicalViolations=Int[],
        CompletionStatus=String[], FailureMessage=String[],
    )
    for entry in metrics
        push!(frame, (
            identity.experiment_id, identity.parallel_task_id, identity.shard_id,
            entry.replication_id, string(entry.controller), string(entry.fairness),
            worker, retry,
            entry.total_build_time_sec, entry.total_solve_time_sec,
            entry.optimization_failures, entry.physical_violations,
            entry.completed ? "completed" : "aborted", entry.failure_message,
        ))
    end
    return frame
end

# -------------------------------------------------------------------------------------
# solve_provenance.csv  (stage 11)
#
# Per-phase timing and memory. It lives here, and NOT in `solve_log.csv`, for the same reason
# `execution_provenance.csv` exists: these numbers legitimately differ between two runs that
# computed exactly the same thing, so keeping them in a scientific file made byte-equality
# impossible to claim. Stage 12 measures runtime from this file.
# -------------------------------------------------------------------------------------

function solve_provenance_frame(
    config::OOSExperimentConfig,
    runs::Vector{ReplicationRun},
    identity::OOSRunIdentity,
)
    frame = DataFrame(
        ExperimentID=String[], ParallelTaskID=String[],
        Replication=Int[], Controller=String[], Fairness=String[],
        Period=Int[], Phase=Int[], PhaseLabel=String[],
        BuildTimeSec=Float64[], SolveWallTimeSec=Float64[], SolverTimeSec=Float64[],
        PeakMemoryMB=Float64[],
    )
    for run in runs, record in run.records
        for phase in record.result.phases
            push!(frame, (
                identity.experiment_id, identity.parallel_task_id,
                record.replication_id, string(record.controller), string(record.fairness),
                record.period, phase.phase, phase.label,
                record.result.build_time_sec, phase.wall_time_sec, phase.solver_time_sec,
                record.result.statistics.peak_memory_mb,
            ))
        end
    end
    return frame
end

# -------------------------------------------------------------------------------------
# configuration_summary.csv  (pooled over replications)
# -------------------------------------------------------------------------------------

function configuration_summary_frame(
    config::OOSExperimentConfig,
    summaries::Vector{ConfigurationPEASummary},
)
    frame = DataFrame(
        ExperimentID=String[], FormulationID=String[],
        Controller=String[], Fairness=String[], Resource=String[],
        Replications=Int[], CompletedReplications=Int[], PeriodsSolved=Int[],
        ConfigPEAToleranceActivations=Int[], ConfigPEAToleranceActivationRate=Float64[],
        ConfigPEAToleranceMeanActive=Float64[], ConfigPEAToleranceMeanAllPeriods=Float64[],
        ConfigPEAToleranceMax=Float64[], ConfigPEAStrictFeasiblePeriods=Int[],
    )
    for summary in summaries
        push!(frame, (
            config.experiment_id, config.formulation_id,
            string(summary.controller), string(summary.fairness), summary.resource,
            summary.replications, summary.completed_replications, summary.periods_solved,
            summary.activations, summary.activation_rate,
            summary.mean_active, summary.mean_all_periods, summary.maximum_tolerance,
            summary.strict_feasible_periods,
        ))
    end
    return frame
end

# -------------------------------------------------------------------------------------
# Paired statistics and model audit
# -------------------------------------------------------------------------------------

function paired_statistics_frame(config::OOSExperimentConfig, summaries::Vector{PairedSummary})
    frame = DataFrame(
        ExperimentID=String[], FormulationID=String[], Metric=String[],
        Baseline=String[], Comparison=String[], Observations=Int[],
        Mean=Float64[], StandardDeviation=Float64[], StandardError=Float64[],
        ConfidenceLow=Float64[], ConfidenceHigh=Float64[],
        ComparisonKind=String[], MeanRelativePercent=Float64[],
        ZeroDenominatorObservations=Int[], RelativeDenominatorFloor=Float64[],
    )
    for summary in summaries
        push!(frame, (
            config.experiment_id, config.formulation_id, summary.label,
            summary.baseline, summary.comparison, summary.observations,
            summary.mean, summary.standard_deviation, summary.standard_error,
            summary.confidence_low, summary.confidence_high,
            summary.comparison_kind, summary.mean_relative_percent,
            summary.zero_denominator_observations, OOS_RELATIVE_COMPARATOR_FLOOR,
        ))
    end
    return frame
end

function model_audit_frame(config::OOSExperimentConfig, audits::Vector{ModelAudit})
    frame = DataFrame(
        FormulationID=String[], Label=String[], Controller=String[], Passed=Bool[],
        ExpectedModeNodes=Int[], GeneratedModeBinaries=Int[], UniquePolicyModes=Int[],
        LegacyHouseholdModeBinaries=Int[],
        Variables=Int[], Constraints=Int[], Nonzeros=Int[],
        FailedChecks=String[], LPPath=String[], MPSPath=String[],
    )
    for audit in audits
        failed = join([finding.name for finding in audit.findings if !finding.passed], ";")
        push!(frame, (
            config.formulation_id, audit.label, string(audit.controller), audit.passed,
            audit.expected_mode_nodes, audit.generated_mode_binaries, audit.unique_policy_modes,
            audit.legacy_household_mode_binaries,
            audit.variables, audit.constraints, audit.nonzeros,
            failed, audit.lp_path, audit.mps_path,
        ))
    end
    return frame
end

# -------------------------------------------------------------------------------------
# 18.6 experiment_config.json
# -------------------------------------------------------------------------------------

_json_escape(text::AbstractString) = replace(
    String(text), '\\' => "\\\\", '"' => "\\\"", '\n' => "\\n", '\r' => "\\r", '\t' => "\\t",
)

function _json_value(value)
    if value === nothing
        return "null"
    elseif value isa Bool
        return value ? "true" : "false"
    elseif value isa Integer
        return string(value)
    elseif value isa AbstractFloat
        return isfinite(value) ? string(value) : "null"
    elseif value isa Symbol
        return "\"$(_json_escape(string(value)))\""
    elseif value isa AbstractString
        return "\"$(_json_escape(value))\""
    elseif value isa AbstractVector
        return "[" * join((_json_value(item) for item in value), ",") * "]"
    elseif value isa AbstractDict
        pairs = ["\"$(_json_escape(string(k)))\":$(_json_value(value[k]))" for k in sort(collect(keys(value)); by=string)]
        return "{" * join(pairs, ",") * "}"
    end
    return "\"$(_json_escape(string(value)))\""
end

"""Pretty-print a nested dictionary as JSON without adding a package dependency."""
function _json_pretty(value, indent::Int=0)
    pad = repeat("  ", indent)
    inner = repeat("  ", indent + 1)
    if value isa AbstractDict
        isempty(value) && return "{}"
        keys_sorted = sort(collect(keys(value)); by=string)
        body = join(
            ["$inner\"$(_json_escape(string(k)))\": $(_json_pretty(value[k], indent + 1))"
             for k in keys_sorted],
            ",\n",
        )
        return "{\n$body\n$pad}"
    elseif value isa AbstractVector && !isempty(value) && any(item -> item isa AbstractDict, value)
        body = join(["$inner$(_json_pretty(item, indent + 1))" for item in value], ",\n")
        return "[\n$body\n$pad]"
    end
    return _json_value(value)
end

"""
Complete resolved configuration and reproducibility metadata.

Records the formulation ID, the code commit, the experiment-prompt version, the instance and
algorithm seeds, the solver version, the tolerances, the date, the hardware, the operating
system and every controller and fairness parameter.
"""
function experiment_config_dictionary(
    config::OOSExperimentConfig,
    template::OOSInstanceTemplate;
    gate_reports::Vector{GateReport}=GateReport[],
    audits::Vector{ModelAudit}=ModelAudit[],
    extra::Dict{String,Any}=Dict{String,Any}(),
)
    document = Dict{String,Any}(
        "output_schema_version" => OOS_OUTPUT_SCHEMA_VERSION,
        "pea_solve_sequence_version" => OOS_OUTPUT_SCHEMA_VERSION,
        "formulation_id" => config.formulation_id,
        "formulation_variant" => string(config.formulation_variant),
        "mode_node_convention" => string(OOS_MODE_NODE_CONVENTION),
        "experiment_id" => config.experiment_id,
        "prompt_version" => config.prompt_version,
        "code_commit" => _git_commit(),
        "code_dirty" => _git_dirty(),
        "date_utc" => string(now_utc_string()),
        "julia_version" => string(VERSION),
        "project_toml_sha1" => _file_digest(joinpath(OOS_REPO_ROOT, "Project.toml")),
        "manifest_toml_sha1" => _file_digest(joinpath(OOS_REPO_ROOT, "Manifest.toml")),
        "manifest_julia_version" => _manifest_julia_version(),
        "solver" => _solver_description(),
        "hardware" => Dict{String,Any}(
            "cpu" => string(Sys.cpu_info()[1].model),
            "cpu_threads" => Sys.CPU_THREADS,
            "total_memory_gb" => round(Sys.total_memory() / 2^30, digits=2),
            "machine" => string(Sys.MACHINE),
        ),
        "operating_system" => Dict{String,Any}(
            "kernel" => string(Sys.KERNEL),
            "description" => _os_description(),
        ),
        "seeds" => Dict{String,Any}(
            "experiment_seed" => config.experiment_seed,
            "instance_seed" => deterministic_seed(
                config.in_sample_stages, config.in_sample_children,
                config.in_sample_periods_per_stage, config.households,
                config.instance_file, config.theta, config.avg_demand, config.dev_demand;
                demand_profile=config.demand_profile,
            ),
            "oos_stream" => "oos_path",
            # Stage 5 retired the `lookahead` stream, whose key included the controller. The
            # conditional support is now keyed by (experiment seed, replication, rolling start)
            # only, so the three methods are views of one object rather than three samples.
            "conditional_support_stream" => OOS_LOOKAHEAD_SUPPORT_STREAM,
            "conditional_support_seed_keys" =>
                ["experiment_seed", "oos_replication", "rolling_start"],
            "conditional_support_seed_exclusions" =>
                ["controller", "fairness_policy", "solver_phase", "worker", "retry",
                 "execution_order"],
            "in_sample_stream" => "in_sample",
            "demand_profile_stream" => "demand_profiles",
            "fairness_excluded_from_seed" => true,
            "controller_excluded_from_seed" => true,
        ),
        # Abstract temporal contract. Counted in MODEL PERIODS: this section deliberately
        # contains no period duration and no calendar cycle, because a period has no clock-time
        # meaning in this experiment. The repository instance horizon stays separately reported
        # as `instance.horizon` (= template.T) and is never renamed or reinterpreted here.
        "temporal_structure" => Dict{String,Any}(
            "period_semantics" => "abstract model period; no clock-time interpretation is implied",
            "period_unit" => "model periods",
            "evaluation_horizon" => config.evaluation_horizon,
            "lookahead_horizon" => config.lookahead_horizon,
            "implementation_step" => config.implementation_step,
            "known_prefix_length" => known_prefix_length(config),
            "rolling_solve_count" => rolling_solve_count(config),
            "rolling_iteration_starts" => rolling_iteration_starts(config),
            "required_period_support_end" => required_period_support_end(config),
            "realized_period_end" => realized_period_end(config),
            # Auditability of the final block: it may legitimately run past the evaluation
            # horizon, and only its evaluated portion contributes to reported metrics.
            "final_rolling_iteration_start" => final_rolling_iteration_start(config),
            "final_implementation_block" =>
                collect(implementation_block(config, final_rolling_iteration_start(config))),
            "final_evaluation_block" =>
                collect(evaluation_block(config, final_rolling_iteration_start(config))),
            "final_lookahead_window" =>
                collect(lookahead_periods(config, final_rolling_iteration_start(config))),
            # Kept separate from every endpoint above: T0 is the repository instance horizon and
            # the length of the repeated base deterministic profile, never the evaluation or
            # support horizon. It is recorded exactly once, under this name; the repetition rule
            # itself is identified by the mapping fields below. No second key restates it, and
            # deliberately none of them carries a clock-time or calendar word.
            "repository_instance_horizon" => template.T,
            "period_mapping_name" => OOS_PERIOD_MAPPING_NAME,
            "period_mapping_version" => OOS_PERIOD_MAPPING_VERSION,
            # Honest scope marker. Stage 4 wired the loop, the look-ahead window, the
            # optimization horizon and the terminal target; stage 6 wired the known prefix and
            # multi-period implementation blocks, so every admissible `h` is now simulated.
            "contract_status" => "wired_rolling_blocks: the simulator iterates the rolling " *
                                 "starts, every solve spans exactly lookahead_horizon abstract " *
                                 "periods, the terminal state of charge binds at the end of " *
                                 "each window, the complete known prefix of length " *
                                 "implementation_step is revealed to every controller before it " *
                                 "optimizes, and the whole committed block is implemented and " *
                                 "validated while only its intersection with 1:H is evaluated",
        ),
        "controllers" => [string(controller) for controller in config.controller_set],
        "fairness_rules" => [string(policy) for policy in config.fairness_set],
        "configuration_count" => configuration_count(config),
        "oos_replications" => config.oos_replications,
        "controller_parameters" => Dict{String,Any}(
            # DEPRECATED SINCE STAGE 5. `TWO_STAGE_RH` no longer draws its own scenarios: it uses
            # the leaf paths and leaf probabilities of the one common conditional support, whose
            # leaf count follows `multistage_branching` and `multistage_periods_per_stage`. The
            # configured value is preserved for provenance and is not used for generation; the
            # campaign leaf count is a stage-12 calibration decision.
            "two_stage_scenarios" => config.two_stage_scenarios,
            "two_stage_scenarios_drives_generation" => false,
            "two_stage_leaves_derived_from" => "common_conditional_support",
            "multistage_branching" => config.multistage_branching,
            "multistage_periods_per_stage" => config.multistage_periods_per_stage,
        ),
        "fairness_parameters" => Dict{String,Any}(
            "fairness_abs_tol" => config.fairness_abs_tol,
            "sa_fairness_abs_tol" => config.sa_fairness_abs_tol,
            "lex_eps_abs" => config.lex_eps_abs,
            "sa_denominator_floor" => OOS_SA_DENOMINATOR_FLOOR,
            "pea_denominator_floor" => OOS_PEA_DENOMINATOR_FLOOR,
            "pea_tolerance_mode" => string(config.pea_tolerance_mode),
            "pea_tolerance_numeric_eps_kwh" => config.pea_tolerance_numeric_eps,
            "pea_tolerance_numeric_eps_unit" => "kWh (same unit as epsilon_pea; " *
                                               "added to epsilon_pea_star in the Phase-II cap)",
            "pea_tolerance_activation_threshold" => OOS_PEA_ACTIVATION_THRESHOLD,
            "pea_tolerance_unit" => "kWh (horizon-total PV allocation band)",
            "pea_recovery_solves_per_recovered_period" => 4,
            "pea_recovery_solve_sequence" =>
                ["strict", "diagnostic_physical", "phase1_min_tolerance", "phase2_operational"],
            "pea_solves_per_strict_feasible_period" => 1,
            "fairness_abs_tol_deprecated" => true,
        ),
        "tolerances" => Dict{String,Any}(
            "flow_tol" => config.flow_tol,
            "feasibility_tol" => config.feasibility_tol,
            "integrality_tol" => config.integrality_tol,
        ),
        "solver_settings" => Dict{String,Any}(
            "time_limit_sec" => config.solver_time_limit_sec,
            "threads" => config.solver_threads,
            "mip_gap" => config.solver_mip_gap,
        ),
        "instance" => Dict{String,Any}(
            "id" => template.id,
            "file" => template.instance_file,
            "households" => template.J,
            "horizon" => template.T,
            "delta" => template.delta,
            "e_c" => template.e_c,
            "e_d" => template.e_d,
            "s_I" => template.s_I,
            "s_min" => template.s_min,
            "s_max" => template.s_max,
            "f_under_charge_limit" => template.f_under,
            "f_bar_discharge_limit" => template.f_bar,
            "mu" => template.mu,
            "beta" => template.beta,
            "theta" => template.theta,
            "avg_demand" => config.avg_demand,
            "dev_demand" => config.dev_demand,
            "demand_profile" => config.demand_profile,
            "battery_scale" => config.battery_scale,
            "pv_scale" => config.pv_scale,
            "household_profiles" => [model.profile for model in template.demand_models],
            "metadata" => Dict{String,Any}(string(k) => v for (k, v) in template.metadata),
        ),
        "uncertainty_process" => Dict{String,Any}(
            "pv_ar_coefficient" => OOS_PV_AR_COEFFICIENT,
            "pv_ma_coefficient" => OOS_PV_MA_COEFFICIENT,
            "stochastic_prices" => false,
            "pea_repair_per_period" => true,
        ),
        "warm_starts" => Dict{String,Any}(
            "enabled" => config.use_warm_starts,
            "idle_mode_value" => OOS_IDLE_MODE_VALUE,
            "allow_legacy_conversion" => config.allow_legacy_conversion,
        ),
        "validation" => Dict{String,Any}(
            "require_shared_battery_validation" => config.require_shared_battery_validation,
            "export_representative_models" => config.export_representative_models,
            "gates" => [
                Dict{String,Any}(
                    "passed" => report.passed,
                    "checks" => [
                        Dict{String,Any}("name" => check.name, "passed" => check.passed,
                                         "detail" => check.detail)
                        for check in report.checks
                    ],
                )
                for report in gate_reports
            ],
            "model_audits" => [
                Dict{String,Any}(
                    "label" => audit.label,
                    "passed" => audit.passed,
                    "expected_mode_nodes" => audit.expected_mode_nodes,
                    "generated_mode_binaries" => audit.generated_mode_binaries,
                    "unique_policy_modes" => audit.unique_policy_modes,
                    "legacy_household_mode_binaries" => audit.legacy_household_mode_binaries,
                    "variables" => audit.variables,
                    "constraints" => audit.constraints,
                    "nonzeros" => audit.nonzeros,
                    "lp_path" => audit.lp_path,
                    "mps_path" => audit.mps_path,
                )
                for audit in audits
            ],
        ),
        "output_directory" => config.output_directory,
    )
    for (key, value) in extra
        document[key] = value
    end
    return document
end

"""Short content digest of a file, used to pin the environment in the metadata."""
_file_digest(path::AbstractString) = try
    isfile(path) ? bytes2hex(codeunits(string(hash(read(path, String)), base=16)))[1:16] : "unavailable"
catch
    "unavailable"
end

"""Julia version the Manifest was resolved for; the scripts select this channel."""
_manifest_julia_version() = try
    path = joinpath(OOS_REPO_ROOT, "Manifest.toml")
    isfile(path) || return "unavailable"
    for line in eachline(path)
        m = match(r"^julia_version\s*=\s*\"(.*)\"", line)
        m === nothing || return m.captures[1]
    end
    "unavailable"
catch
    "unavailable"
end

now_utc_string() = try
    Dates.format(Dates.now(Dates.UTC), "yyyy-mm-ddTHH:MM:SS") * "Z"
catch
    "unavailable"
end

_git_commit() = try
    strip(read(`git rev-parse HEAD`, String))
catch
    "unavailable"
end

_git_dirty() = try
    !isempty(strip(read(`git status --porcelain`, String)))
catch
    true
end

_solver_description() = try
    "CPLEX " * string(CPLEX.version())
catch
    try
        model = Model(CPLEX.Optimizer)
        set_silent(model)
        "CPLEX " * string(MOI.get(model, MOI.SolverVersion()))
    catch
        "CPLEX (versión no disponible)"
    end
end

_os_description() = try
    if isfile("/etc/os-release")
        line = first(filter(l -> startswith(l, "PRETTY_NAME="), readlines("/etc/os-release")))
        strip(replace(split(line, "=", limit=2)[2], '"' => ""))
    else
        string(Sys.KERNEL)
    end
catch
    string(Sys.KERNEL)
end

# -------------------------------------------------------------------------------------
# Writer
# -------------------------------------------------------------------------------------

"""
Column priority that defines the canonical row order of every output frame.

Stage 11 found that two SERIAL runs differing only in the order of the controller/policy loop
produced byte-different CSVs with identical content, because rows were written in production
order. That would have made the stage-13 "identical merged content" gate impossible to satisfy
honestly. Sorting every frame by its scientific key before writing makes the files
order-invariant BY CONSTRUCTION rather than by luck.

Only the columns a frame actually has are used, in this order. Execution provenance never
appears here: it is not a scientific key.
"""
const OOS_CANONICAL_ROW_ORDER = [
    "StructuralInstanceID", "ParallelTaskID", "ExperimentID", "FormulationID",
    "Metric", "Baseline", "Comparison", "ComparisonKind",
    "Label", "Replication", "Controller", "Fairness",
    "RollingStart", "Period", "Phase", "PhaseLabel", "House",
]

"""Sort a frame into the canonical row order, using whichever key columns it carries."""
function canonical_row_sort(frame::DataFrame)
    keys = [column for column in OOS_CANONICAL_ROW_ORDER if column in names(frame)]
    isempty(keys) && return frame
    return sort(frame, keys)
end

"""Write every campaign artefact. Existing model-result directories are never touched."""
function write_campaign_outputs(
    config::OOSExperimentConfig,
    template::OOSInstanceTemplate,
    runs::Vector{ReplicationRun},
    metrics::Vector{ReplicationMetrics},
    summaries::Vector{PairedSummary},
    audits::Vector{ModelAudit},
    gate_reports::Vector{GateReport};
    validation_text::String="",
    configuration_summaries::Vector{ConfigurationPEASummary}=ConfigurationPEASummary[],
    identity::Union{Nothing,OOSRunIdentity}=nothing,
    worker::Int=0,
    retry::Int=0,
    write_aggregates::Bool=true,
)
    ensure_output_directory(config)
    written = String[]
    # The identity is a deterministic function of the configuration and the instance, so a caller
    # that does not supply one gets exactly the same object the campaign would have built.
    resolved_identity = identity === nothing ?
        run_identity(
            config, OOSRollingContext(config, template),
            resolve_static_share_table_placeholder(config, template), 0,
        ) : identity

    for (key, frame) in (
        (:replication_summary,
         replication_summary_frame(config, metrics, resolved_identity)),
        (:household_summary, household_summary_frame(config, metrics, resolved_identity)),
        (:run_identity, run_identity_frame(config, metrics, resolved_identity)),
        (:fairness_diagnostics, fairness_diagnostics_frame(config, metrics, resolved_identity)),
        (:execution_provenance,
         execution_provenance_frame(config, metrics, resolved_identity; worker=worker,
                                    retry=retry)),
        (:solve_provenance, solve_provenance_frame(config, runs, resolved_identity)),
        (:period_actions, period_actions_frame(config, runs, resolved_identity)),
        (:battery_operation, battery_operation_frame(config, runs, resolved_identity)),
        (:solve_log, solve_log_frame(config, runs, resolved_identity)),
        (:pea_recovery, pea_recovery_frame(config, runs, resolved_identity)),
        (:model_audit, model_audit_frame(config, audits)),
    )
        path = output_path(config, key)
        CSV.write(path, canonical_row_sort(frame))
        push!(written, path)
    end

    # Campaign aggregates. A SHARD sets `write_aggregates=false`: it holds one replication of one
    # paired base, so pooling over replications inside it is meaningless and concatenating the
    # result across shards would produce one row per shard instead of one pooled row. The merge
    # recomputes them once, from the merged replication-level rows.
    if write_aggregates
        for (key, frame) in (
            (:configuration_summary,
             configuration_summary_frame(config, configuration_summaries)),
            (:paired_statistics, paired_statistics_frame(config, summaries)),
        )
            path = output_path(config, key)
            CSV.write(path, canonical_row_sort(frame))
            push!(written, path)
        end
    end

    failures = failed_solve_log_frame(config, runs)
    if nrow(failures) > 0
        path = joinpath(config.output_directory, "solve_failures.csv")
        CSV.write(path, canonical_row_sort(failures))
        push!(written, path)
    end

    document = experiment_config_dictionary(
        config, template; gate_reports=gate_reports, audits=audits,
    )
    config_path = output_path(config, :experiment_config)
    open(config_path, "w") do io
        write(io, _json_pretty(document), "\n")
    end
    push!(written, config_path)

    if !isempty(validation_text)
        report_path = output_path(config, :validation_report)
        open(report_path, "w") do io
            write(io, validation_text)
        end
        push!(written, report_path)
    end

    return written
end

# -------------------------------------------------------------------------------------
# Retained two-argument frame shapes
#
# Callers that hold only the configuration and the runs get the placeholder identity, so the
# stage-10 columns are always well formed. The campaign and stage 13 always pass their real one.
# -------------------------------------------------------------------------------------

period_actions_frame(config::OOSExperimentConfig, runs::Vector{ReplicationRun}) =
    period_actions_frame(config, runs, placeholder_run_identity(config))
battery_operation_frame(config::OOSExperimentConfig, runs::Vector{ReplicationRun}) =
    battery_operation_frame(config, runs, placeholder_run_identity(config))
solve_log_frame(config::OOSExperimentConfig, runs::Vector{ReplicationRun}) =
    solve_log_frame(config, runs, placeholder_run_identity(config))
pea_recovery_frame(config::OOSExperimentConfig, runs::Vector{ReplicationRun}) =
    pea_recovery_frame(config, runs, placeholder_run_identity(config))
