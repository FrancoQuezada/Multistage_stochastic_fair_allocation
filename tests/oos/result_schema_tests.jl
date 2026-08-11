# =====================================================================================
# OS0..OS5  Output schema, identifiers and policy-aligned metrics (OOS redesign stage 10)
#
# The acceptance gate of plan section 7 (Stage 10) is four claims:
#
#   * no percentage lacks a comparator;
#   * no fairness statistic is presented as validating an incompatible policy;
#   * `NONE` and `STATIC_DEMAND_SHARE` remain separately identifiable; and
#   * existing outputs are backward compatible or migrated through an explicit schema version.
#
# These sets check each one directly, plus the identity and shard interfaces that carry them.
#
# They run inside `tests/oos/runtests.jl` and reuse its helpers.
# =====================================================================================

"""Small stage-10 configuration: the full 18-configuration matrix on a short window."""
schema_config(; kwargs...) = test_config(;
    experiment_seed=101_010, households=3, oos_replications=1, lookahead_horizon=4,
    multistage_branching=[2], two_stage_scenarios=2, kwargs...)

"""Write a complete v3 output directory and return `(directory, config, common, metrics)`."""
function schema_outputs(; kwargs...)
    directory = mktempdir(; prefix="oos_schema_")
    config = schema_config(; output_directory=directory, kwargs...)
    common = build_common_objects(config; verbose=false)
    runs = ReplicationRun[]
    metrics = ReplicationMetrics[]
    for path in common.oos_paths
        cache = cache_lookahead_trees(common.provider, common.context, path)
        for policy in config.fairness_set, controller in config.controller_set
            run = simulate_configuration(common.context, path, cache, controller, policy,
                                         common.share_table)
            push!(runs, run)
            push!(metrics, compute_replication_metrics(
                common.template, run, config; share_table=common.share_table))
        end
    end
    write_campaign_outputs(
        config, common.template, runs, metrics, campaign_statistics(metrics),
        ModelAudit[], GateReport[];
        configuration_summaries=configuration_pea_summaries(metrics),
        identity=run_identity(config, common.context, common.share_table, 0),
    )
    return (directory=directory, config=config, common=common, metrics=metrics, runs=runs)
end

const SCHEMA_OUTPUTS = schema_outputs()

# =====================================================================================
# OS0 A written directory validates as schema v3
# =====================================================================================

@testset "OS0 a written directory validates as schema v3" begin
    validation = validate_output_directory(
        SCHEMA_OUTPUTS.directory; expected_configurations=18,
    )
    for issue in blocking_issues(validation)
        @info "blocking schema issue" file = issue.file detail = issue.detail
    end
    @test isempty(blocking_issues(validation))
    @test validation.passed
    @test validation.metadata["output_schema_version"] == "3"
    @test OOS_OUTPUT_SCHEMA_VERSION == 3

    # Every declared file exists and is non-empty, including the three stage-10 additions.
    for file in keys(OOS_REQUIRED_COLUMNS)
        @test isfile(joinpath(SCHEMA_OUTPUTS.directory, file))
        @test validation.files[file] > 0
    end
    for file in OOS_SCHEMA_V3_FILES
        @test haskey(OOS_REQUIRED_COLUMNS, file)
        @test validation.files[file] > 0
    end
end

# =====================================================================================
# OS1 No percentage lacks a comparator
# =====================================================================================

@testset "OS1 no percentage lacks a comparator" begin
    frame = CSV.read(joinpath(SCHEMA_OUTPUTS.directory, "paired_statistics.csv"), DataFrame)
    @test "ComparisonKind" in names(frame)
    @test "MeanRelativePercent" in names(frame)
    @test Set(unique(frame.ComparisonKind)) == Set(["level", "difference"])

    differences = filter(r -> r.ComparisonKind == "difference", frame)
    levels = filter(r -> r.ComparisonKind == "level", frame)
    @test nrow(differences) > 0 && nrow(levels) > 0

    # Every percentage names BOTH sides it compares.
    for row in eachrow(differences)
        @test row.Baseline != "-" && !isempty(row.Baseline)
        @test row.Comparison != "-" && !isempty(row.Comparison)
        @test row.Baseline != row.Comparison
    end
    # A level row has no comparator, so it never reports one.
    @test all(isnan, levels.MeanRelativePercent)
    @test all(row -> row.Comparison == "-", eachrow(levels))

    # The zero-denominator rule is stated in the data, not left to the reader.
    @test all(frame.RelativeDenominatorFloor .== OOS_RELATIVE_COMPARATOR_FLOOR)
    @test all(frame.ZeroDenominatorObservations .>= 0)
    # An excluded observation is counted, never reported as an infinite percentage.
    @test all(isfinite(x) || isnan(x) for x in frame.MeanRelativePercent)

    # The arithmetic itself: an excluded baseline is dropped and counted.
    relative, excluded = paired_relative_differences([100.0, 0.0, 50.0], [110.0, 5.0, 25.0])
    @test excluded == 1
    @test length(relative) == 2
    @test isapprox(relative[1], 10.0; rtol=1e-12)
    @test isapprox(relative[2], -50.0; rtol=1e-12)
end

# =====================================================================================
# OS2 No fairness statistic validates an incompatible policy
# =====================================================================================

@testset "OS2 no fairness statistic validates an incompatible policy" begin
    frame = CSV.read(joinpath(SCHEMA_OUTPUTS.directory, "fairness_diagnostics.csv"), DataFrame)
    @test "ApplicableDiagnostic" in names(frame)

    expected = Dict(
        "NONE" => "descriptive_only",
        "STATIC_DEMAND_SHARE" => "static_share_residual",
        "PEA" => "proportional_pv",
        "SA" => "proportional_savings",
        "LEXMMFPEA" => "lexicographic_pv",
        "LEXMMFSA" => "lexicographic_savings",
    )
    for row in eachrow(frame)
        @test row.ApplicableDiagnostic == expected[String(row.Fairness)]
    end
    # Every policy of the matrix appears, so the mapping is exhaustive rather than incidental.
    @test Set(String.(unique(frame.Fairness))) == Set(keys(expected))
    for (policy, diagnostic) in expected
        @test applicable_fairness_diagnostic(parse_fairness_policy(policy)) == diagnostic
    end

    # Every family is COMPUTED for every policy — they are comparable — but only one is named as
    # validating it. That is the distinction the gate is about.
    for column in ("PVDeviation", "SavingsDeviation", "StaticShareDeviation",
                   "LexicographicPVShortfall", "LexicographicSavingsShortfall")
        @test column in names(frame)
    end
    # `NONE` is the sharpest case: its allocations are outcomes of a DEGENERATE optimum, so no
    # column may be read as a violation of a rule it does not impose.
    none_rows = filter(r -> r.Fairness == "NONE", frame)
    @test nrow(none_rows) > 0
    @test all(none_rows.ApplicableDiagnostic .== "descriptive_only")

    # The max-min shortfall is a resource-unit gap, not a dispersion ratio, and it is zero for a
    # perfectly equal allocation.
    @test lexicographic_shortfall([5.0, 5.0, 5.0]) == 0.0
    @test isapprox(lexicographic_shortfall([0.0, 6.0, 6.0]), 4.0; rtol=1e-12)
    @test isnan(lexicographic_shortfall(Float64[]))
end

# =====================================================================================
# OS3 `NONE` and `STATIC_DEMAND_SHARE` stay separately identifiable
# =====================================================================================

@testset "OS3 NONE and STATIC_DEMAND_SHARE stay separately identifiable" begin
    identity_frame = CSV.read(joinpath(SCHEMA_OUTPUTS.directory, "run_identity.csv"), DataFrame)
    policies = Set(String.(unique(identity_frame.Fairness)))
    @test "NONE" in policies && "STATIC_DEMAND_SHARE" in policies

    none_rows = filter(r -> r.Fairness == "NONE", identity_frame)
    share_rows = filter(r -> r.Fairness == "STATIC_DEMAND_SHARE", identity_frame)
    @test nrow(none_rows) > 0 && nrow(share_rows) > 0
    # Distinct resource, distinct diagnostic family: they can never be merged by a group-by.
    @test all(none_rows.Resource .== "none")
    @test all(share_rows.Resource .== "pv")
    @test all(none_rows.ApplicableDiagnostic .== "descriptive_only")
    @test all(share_rows.ApplicableDiagnostic .== "static_share_residual")
    @test policy_resource(NONE) != policy_resource(STATIC_DEMAND_SHARE)
end

# =====================================================================================
# OS4 The identity is complete, deterministic, and free of execution provenance
# =====================================================================================

@testset "OS4 the identity is deterministic and free of execution provenance" begin
    config = SCHEMA_OUTPUTS.config
    common = SCHEMA_OUTPUTS.common
    identity = run_identity(config, common.context, common.share_table, 3)

    # Deterministic: rebuilt from the same inputs it is identical, field for field.
    twin = run_identity(config, common.context, common.share_table, 3)
    @test identity == twin
    # The task identity carries the replication and NOT the controller or the policy: one task
    # evaluates all of them (plan section 4.9).
    @test identity.parallel_task_id != run_identity(
        config, common.context, common.share_table, 4).parallel_task_id
    @test occursin("-r3", identity.parallel_task_id)
    @test !occursin("DETERMINISTIC", identity.parallel_task_id)
    @test !occursin("PEA", identity.parallel_task_id)

    # The six temporal quantities are separate fields, not derived from one another at read time.
    @test identity.repository_instance_horizon == common.template.T
    @test identity.evaluation_horizon == config.evaluation_horizon
    @test identity.lookahead_horizon == config.lookahead_horizon
    @test identity.implementation_step == config.implementation_step
    @test identity.required_period_support_end == required_period_support_end(config)
    @test identity.realized_period_end == realized_period_end(config)
    @test identity.objective_criterion == OOS_OBJECTIVE_CRITERION == "risk_neutral_expectation"
    @test identity.share_table_id == common.share_table.share_table_id

    # No execution field can enter it: the struct has no such member.
    for forbidden in (:worker, :retry, :wall_clock, :solver_time, :execution_order)
        @test !(forbidden in fieldnames(OOSRunIdentity))
    end
    # And they live in their own file instead.
    provenance = CSV.read(
        joinpath(SCHEMA_OUTPUTS.directory, "execution_provenance.csv"), DataFrame)
    for column in ("Worker", "Retry", "TotalBuildTimeSec", "TotalSolveTimeSec")
        @test column in names(provenance)
    end
    # Those columns appear in NO scientific file — and neither does any TIMING column, which is
    # what stage 11 completed: a runtime number legitimately differs between two runs that
    # computed the same thing, so a scientific file carrying one can never be compared for
    # byte equality.
    for file in ("run_identity.csv", "fairness_diagnostics.csv", "period_actions.csv",
                 "replication_summary.csv", "solve_log.csv", "paired_statistics.csv")
        columns = names(CSV.read(joinpath(SCHEMA_OUTPUTS.directory, file), DataFrame))
        @test !("Worker" in columns)
        @test !("Retry" in columns)
        for timing in ("BuildTimeSec", "SolveWallTimeSec", "SolverTimeSec",
                       "TotalBuildTimeSec", "TotalSolveTimeSec", "PeakMemoryMB")
            @test !(timing in columns)
        end
    end
    # They live in the two provenance files instead.
    solve_provenance = CSV.read(
        joinpath(SCHEMA_OUTPUTS.directory, "solve_provenance.csv"), DataFrame)
    for column in ("BuildTimeSec", "SolveWallTimeSec", "SolverTimeSec", "PeakMemoryMB")
        @test column in names(solve_provenance)
    end
    # And no scientific statistic is a runtime metric.
    statistics = CSV.read(joinpath(SCHEMA_OUTPUTS.directory, "paired_statistics.csv"), DataFrame)
    @test !any(occursin("solve_time", String(m)) for m in statistics.Metric)

    # The scientific row key is stable and carries no execution detail.
    key = scientific_row_key(identity, DETERMINISTIC_RH, PEA, 7)
    @test key == scientific_row_key(twin, DETERMINISTIC_RH, PEA, 7)
    @test key[end] == 7
end

# =====================================================================================
# OS5 Shard interfaces, and the explicit v2 migration
# =====================================================================================

@testset "OS5 shard interfaces and the explicit v2 migration" begin
    root = mktempdir(; prefix="oos_shards_")
    task = parallel_task_id("PB-example", 2)
    directory = shard_directory(root, task)
    mkpath(directory)
    write(joinpath(directory, "rows.csv"), "a,b\n1,2\n")

    # A directory without a marker is INCOMPLETE by definition, so a crash mid-write can never
    # be mistaken for a finished shard.
    @test !shard_is_complete(directory)
    inventory = inventory_shards(root, [task])
    @test inventory.incomplete == [task]
    @test !shard_inventory_ready(inventory)

    digest = commit_shard(directory, task)
    @test shard_is_complete(directory)
    @test digest == shard_content_digest(directory)
    ready = inventory_shards(root, [task])
    @test ready.complete == [task]
    @test shard_inventory_ready(ready)

    # A missing task is reported, not ignored.
    with_missing = inventory_shards(root, [task, parallel_task_id("PB-example", 9)])
    @test length(with_missing.missing_tasks) == 1
    @test !shard_inventory_ready(with_missing)

    # Content that changed after the marker is a CONFLICT, reported rather than overwritten.
    write(joinpath(directory, "rows.csv"), "a,b\n1,3\n")
    conflicted = inventory_shards(root, [task])
    @test conflicted.conflicting == [task]
    @test !shard_inventory_ready(conflicted)
    # Re-committing identical content is idempotent: same bytes, same digest.
    write(joinpath(directory, "rows.csv"), "a,b\n1,2\n")
    @test commit_shard(directory, task) == digest

    # The merge order is the manifest's, never the completion order.
    @test canonical_merge_order(["TK-b-r1", "TK-a-r2", "TK-a-r1"]) ==
          ["TK-a-r1", "TK-a-r2", "TK-b-r1"]
    @test canonical_merge_order(reverse(["TK-a-r1", "TK-a-r2", "TK-b-r1"])) ==
          canonical_merge_order(["TK-a-r1", "TK-a-r2", "TK-b-r1"])

    # --- explicit v2 -> v3 migration -----------------------------------------------------
    legacy = mktempdir(; prefix="oos_legacy_")
    for file in readdir(SCHEMA_OUTPUTS.directory)
        source = joinpath(SCHEMA_OUTPUTS.directory, file)
        isfile(source) && cp(source, joinpath(legacy, file))
    end
    # Make it look like a v2 directory: declare v2 and remove the stage-10 files.
    metadata_path = joinpath(legacy, "experiment_config.json")
    text = read(metadata_path, String)
    write(metadata_path, replace(text, "\"output_schema_version\": 3" =>
                                       "\"output_schema_version\": 2"))
    for file in OOS_SCHEMA_V3_FILES
        rm(joinpath(legacy, file); force=true)
    end

    migrated = validate_output_directory(legacy; expected_configurations=18)
    # Readable, with the absence reported as a WARNING that names the version — never silently
    # reinterpreted and never an error.
    @test migrated.metadata["output_schema_version"] == "2"
    @test isempty([
        issue for issue in blocking_issues(migrated)
        if issue.file in OOS_SCHEMA_V3_FILES
    ])
    warnings = [issue for issue in migrated.issues if issue.severity === :warning]
    @test any(issue -> issue.file in OOS_SCHEMA_V3_FILES, warnings)
    @test any(issue -> occursin("esquema v3", issue.detail), warnings)

    # A directory that CLAIMS v3 but lacks the files is an error, so the migration cannot be
    # used to smuggle an incomplete v3 directory through.
    broken = mktempdir(; prefix="oos_broken_")
    for file in readdir(SCHEMA_OUTPUTS.directory)
        source = joinpath(SCHEMA_OUTPUTS.directory, file)
        isfile(source) && cp(source, joinpath(broken, file))
    end
    rm(joinpath(broken, "run_identity.csv"); force=true)
    strict = validate_output_directory(broken; expected_configurations=18)
    @test !strict.passed
    @test any(issue -> issue.file == "run_identity.csv", blocking_issues(strict))
end
