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

function replication_summary_frame(config::OOSExperimentConfig, metrics::Vector{ReplicationMetrics})
    frame = DataFrame(
        ExperimentID=String[], Replication=Int[], Controller=String[], Fairness=String[],
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
        TotalBuildTimeSec=Float64[], TotalSolveTimeSec=Float64[],
        OptimizationFailures=Int[], PhysicalViolations=Int[],
        FailureMessage=String[],
    )
    for entry in metrics
        push!(frame, (
            config.experiment_id, entry.replication_id, string(entry.controller),
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
            entry.total_build_time_sec, entry.total_solve_time_sec,
            entry.optimization_failures, entry.physical_violations,
            entry.failure_message,
        ))
    end
    return frame
end

# -------------------------------------------------------------------------------------
# 18.2 household_summary.csv
# -------------------------------------------------------------------------------------

function household_summary_frame(config::OOSExperimentConfig, metrics::Vector{ReplicationMetrics})
    frame = DataFrame(
        ExperimentID=String[], Replication=Int[], Controller=String[], Fairness=String[],
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
            config.experiment_id, entry.replication_id, string(entry.controller),
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

function period_actions_frame(config::OOSExperimentConfig, runs::Vector{ReplicationRun})
    frame = DataFrame(
        FormulationID=String[], Replication=Int[], Controller=String[], Fairness=String[],
        Period=Int[], House=Int[],
        RealizedPV=Float64[], RealizedDemand=Float64[],
        ImplementedP=Float64[], ImplementedZ=Float64[], ImplementedY=Float64[],
        ImplementedI=Float64[], ImplementedG=Float64[], ImplementedLambda=Float64[],
        HouseholdCost=Float64[],
        CumulativePV=Float64[], CumulativeDemand=Float64[],
        CumulativeCost=Float64[], CumulativeAllGridCost=Float64[], CumulativeSavings=Float64[],
        SharedBatteryMode=Int[],
    )
    for run in runs, record in run.records
        for j in eachindex(record.action.p)
            push!(frame, (
                config.formulation_id, record.replication_id, string(record.controller),
                string(record.fairness), record.period, j,
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

function battery_operation_frame(config::OOSExperimentConfig, runs::Vector{ReplicationRun})
    frame = DataFrame(
        FormulationID=String[], Replication=Int[], Controller=String[], Fairness=String[],
        Period=Int[], RealizedNode=Int[],
        SharedBatteryMode=Int[], AggregateCharge=Float64[], AggregateDischarge=Float64[],
        StateOfChargeBefore=Float64[], StateOfChargeAfter=Float64[],
        ChargingLinkResidual=Float64[], DischargingLinkResidual=Float64[],
        SimultaneousFlowFlag=Bool[], SimultaneousFlowResidual=Float64[],
        IntegralityResidual=Float64[], BatteryTransitionResidual=Float64[],
        StateOfChargeBoundResidual=Float64[], TerminalResidual=Float64[],
    )
    for run in runs, record in run.records
        residuals = record.validation.residuals
        push!(frame, (
            config.formulation_id, record.replication_id, string(record.controller),
            string(record.fairness), record.period,
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

function solve_log_frame(config::OOSExperimentConfig, runs::Vector{ReplicationRun})
    frame = DataFrame(
        Replication=Int[], Period=Int[], Controller=String[], Fairness=String[],
        FormulationID=String[], Phase=Int[], PhaseLabel=String[],
        TerminationStatus=String[], PrimalStatus=String[],
        Objective=Float64[], ObjectiveBound=Float64[],
        BuildTimeSec=Float64[], SolveWallTimeSec=Float64[], SolverTimeSec=Float64[],
        BinaryVariables=Int[], ContinuousVariables=Int[], TotalVariables=Int[],
        Constraints=Int[], Nonzeros=Int[],
        ExpectedModeNodes=Int[], GeneratedModeBinaries=Int[], UniquePolicyModes=Int[],
        LegacyHouseholdModeBinaries=Int[],
        LookaheadNodes=Int[], LookaheadScenarios=Int[],
        PresolveReducedVariables=Int[], PresolveReducedConstraints=Int[],
        RootRelaxation=Float64[], BranchAndBoundNodes=Int[], FinalGap=Float64[],
        PeakMemoryMB=Float64[],
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
                string(record.fairness), config.formulation_id, phase.phase, phase.label,
                phase.termination_status, phase.primal_status,
                phase.objective_value, phase.objective_bound,
                result.build_time_sec, phase.wall_time_sec, phase.solver_time_sec,
                phase.binary_variables, phase.continuous_variables, phase.variables,
                phase.constraints, phase.nonzeros,
                statistics.expected_mode_nodes, statistics.generated_mode_binaries,
                statistics.unique_policy_modes, legacy,
                record.lookahead_nodes, record.lookahead_scenarios,
                statistics.presolve_reduced_variables, statistics.presolve_reduced_constraints,
                phase.root_relaxation, phase.branch_and_bound_nodes, phase.final_gap,
                statistics.peak_memory_mb,
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
function pea_recovery_frame(config::OOSExperimentConfig, runs::Vector{ReplicationRun})
    frame = DataFrame(
        FormulationID=String[], Replication=Int[], Controller=String[], Fairness=String[],
        Resource=String[], Period=Int[],
        PEA_Applicable=Bool[], PEA_Strict_Feasible=Bool[],
        PEA_Tolerance_Activated=Bool[], PEA_Tolerance_Used_kWh=Float64[],
        PEA_Strict_Status=String[], PEA_Phase1_Status=String[], PEA_Phase2_Status=String[],
        PEA_Recovery_Status=String[], Failure_Source=String[],
        PEA_Tolerance_Mode=String[], PEA_Tolerance_Numeric_Eps_kWh=Float64[],
    )
    for run in runs, record in run.records
        pea = record.result.pea
        push!(frame, (
            config.formulation_id, record.replication_id, string(record.controller),
            string(record.fairness), policy_resource(record.fairness), record.period,
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
    )
    for summary in summaries
        push!(frame, (
            config.experiment_id, config.formulation_id, summary.label,
            summary.baseline, summary.comparison, summary.observations,
            summary.mean, summary.standard_deviation, summary.standard_error,
            summary.confidence_low, summary.confidence_high,
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
            "lookahead_stream" => "lookahead",
            "in_sample_stream" => "in_sample",
            "demand_profile_stream" => "demand_profiles",
            "fairness_excluded_from_seed" => true,
        ),
        "controllers" => [string(controller) for controller in config.controller_set],
        "fairness_rules" => [string(policy) for policy in config.fairness_set],
        "configuration_count" => configuration_count(config),
        "oos_replications" => config.oos_replications,
        "controller_parameters" => Dict{String,Any}(
            "two_stage_scenarios" => config.two_stage_scenarios,
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
)
    ensure_output_directory(config)
    written = String[]

    for (key, frame) in (
        (:replication_summary, replication_summary_frame(config, metrics)),
        (:household_summary, household_summary_frame(config, metrics)),
        (:period_actions, period_actions_frame(config, runs)),
        (:battery_operation, battery_operation_frame(config, runs)),
        (:solve_log, solve_log_frame(config, runs)),
        (:pea_recovery, pea_recovery_frame(config, runs)),
        (:configuration_summary, configuration_summary_frame(config, configuration_summaries)),
        (:paired_statistics, paired_statistics_frame(config, summaries)),
        (:model_audit, model_audit_frame(config, audits)),
    )
        path = output_path(config, key)
        CSV.write(path, frame)
        push!(written, path)
    end

    failures = failed_solve_log_frame(config, runs)
    if nrow(failures) > 0
        path = joinpath(config.output_directory, "solve_failures.csv")
        CSV.write(path, failures)
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
