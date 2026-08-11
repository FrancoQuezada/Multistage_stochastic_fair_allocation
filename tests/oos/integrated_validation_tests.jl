# =====================================================================================
# IV0..IV6  Integrated validation and reproducibility (OOS redesign stage 11)
#
# The acceptance gate of plan section 7 (Stage 11) is three claims:
#
#   * a bounded end-to-end run passes every gate;
#   * reordered and resumed SERIAL execution produces identical shards and merged content; and
#   * downstream recomputation reproduces the reported summaries.
#
# Everything here runs on the serial kernel, deliberately, and BEFORE any concurrency exists.
# The order invariances are established first so that when stage 13 turns on real processes,
# a disagreement can only come from the scheduling — never from the science.
#
# These sets run inside `tests/oos/runtests.jl` and reuse its helpers.
# =====================================================================================

"""Bounded stage-11 configuration: the full 18-configuration matrix on a short horizon."""
integration_config(; kwargs...) = test_config(;
    experiment_seed=111_111, households=3, oos_replications=2,
    evaluation_horizon=6, lookahead_horizon=4,
    multistage_branching=[2], two_stage_scenarios=2, kwargs...)

"""
Run one bounded campaign serially and write it, with the replication and configuration order
under the caller's control.

`replication_order` and `combination_order` let a test permute the loops without touching the
science: every configuration is still simulated from the same immutable context, path and cache.
"""
function integration_run(; replication_order=nothing, combination_order=nothing,
                         directory=mktempdir(; prefix="oos_iv_"), worker::Int=0, kwargs...)
    resolved = integration_config(; output_directory=directory, kwargs...)
    common = build_common_objects(resolved; verbose=false)
    combinations = vec([(c, p) for c in resolved.controller_set, p in resolved.fairness_set])
    combination_order === nothing || (combinations = combinations[combination_order])
    replications = collect(eachindex(common.oos_paths))
    replication_order === nothing || (replications = replications[replication_order])

    runs = ReplicationRun[]
    metrics = ReplicationMetrics[]
    for index in replications
        path = common.oos_paths[index]
        cache = cache_lookahead_trees(common.provider, common.context, path)
        for (controller, policy) in combinations
            run = simulate_configuration(common.context, path, cache, controller, policy,
                                         common.share_table)
            push!(runs, run)
            push!(metrics, compute_replication_metrics(
                common.template, run, resolved; share_table=common.share_table))
        end
    end
    write_campaign_outputs(
        resolved, common.template, runs, metrics, campaign_statistics(metrics),
        ModelAudit[], GateReport[];
        configuration_summaries=configuration_pea_summaries(metrics),
        identity=run_identity(resolved, common.context, common.share_table, 0),
        worker=worker,
    )
    return (directory=directory, config=resolved, common=common, runs=runs, metrics=metrics)
end

"""Deterministic digest of the SCIENTIFIC content of a result directory."""
function scientific_digest(directory::AbstractString)
    # The provenance files are excluded on purpose: they are the ones that legitimately differ
    # between a sequential run and a parallel one. The exclusion list comes from the CODE
    # (`OOS_PROVENANCE_FILES`), never from a literal here, so a new provenance file cannot be
    # silently swept into the scientific comparison or silently left out of it.
    files = sort([
        file for file in readdir(directory)
        if isfile(joinpath(directory, file)) && endswith(file, ".csv") &&
           !(file in OOS_PROVENANCE_FILES)
    ])
    payload = Dict{String,Any}(
        "files" => [
            Dict{String,Any}("name" => f,
                             "digest" => oos_stable_digest(read(joinpath(directory, f), String)))
            for f in files
        ],
    )
    return oos_stable_digest(canonical_json(payload))
end

const IV_BASELINE = integration_run()

# =====================================================================================
# IV0 A bounded end-to-end run passes every gate
# =====================================================================================

@testset "IV0 a bounded end-to-end run passes every gate" begin
    validation = validate_output_directory(
        IV_BASELINE.directory; expected_configurations=18,
    )
    for issue in blocking_issues(validation)
        @info "blocking issue" file = issue.file detail = issue.detail
    end
    @test isempty(blocking_issues(validation))
    @test validation.passed

    # Every configuration completed, and every implemented action was physically valid.
    @test length(IV_BASELINE.runs) == 36              # 18 configurations x 2 replications
    @test all(run -> run.completed, IV_BASELINE.runs)
    @test all(run -> all(r -> r.validation.valid, run.records), IV_BASELINE.runs)
    @test all(run -> run.physical_violations == 0, IV_BASELINE.runs)

    # The shared-battery formulation gates are preserved, not superseded.
    structure_report = run_shared_battery_micro_gate(IV_BASELINE.config)
    @test structure_report.passed
    fairness_report = run_controller_fairness_gate(
        IV_BASELINE.common.context, IV_BASELINE.common.provider,
        IV_BASELINE.common.share_table,
    )
    @test fairness_report.passed

    # No household imported and exported at the same information state.
    audits = [audit_grid_direction(run, IV_BASELINE.config) for run in IV_BASELINE.runs]
    @test grid_direction_gate(audits, IV_BASELINE.config.formulation_id).passed
end

# =====================================================================================
# IV1 Downstream recomputation reproduces the reported summaries
# =====================================================================================

@testset "IV1 downstream recomputation reproduces the summaries" begin
    report = recompute_from_period_rows(IV_BASELINE.directory)
    for mismatch in report.mismatches[1:min(5, end)]
        @info "recomputation mismatch" key = mismatch.key reported = mismatch.reported recomputed = mismatch.recomputed
    end
    @test report.passed
    @test isempty(report.mismatches)
    @test report.configurations == 36
    # The check is only meaningful if it actually compared something substantial.
    @test length(report.quantities) > 500
    @test all(q -> q.within_tolerance, report.quantities)

    # It is an INDEPENDENT path: it must not reach for the campaign's own accumulators.
    source = read(
        joinpath(REPO_ROOT, "codes", "oos_experiment", "independent_recompute.jl"), String)
    @test !occursin("compute_replication_metrics", source)
    @test !occursin("policy_fairness_diagnostics", source)
    @test !occursin("realized_pv_deviation", source)
    @test !occursin("realized_savings_deviation", source)

    # And it has teeth: a corrupted period row must be detected.
    corrupted = mktempdir(; prefix="oos_iv_corrupt_")
    for file in readdir(IV_BASELINE.directory)
        source_path = joinpath(IV_BASELINE.directory, file)
        isfile(source_path) && cp(source_path, joinpath(corrupted, file))
    end
    frame = CSV.read(joinpath(corrupted, "period_actions.csv"), DataFrame)
    frame[1, :HouseholdCost] += 1000.0
    CSV.write(joinpath(corrupted, "period_actions.csv"), frame)
    detected = recompute_from_period_rows(corrupted)
    @test !detected.passed
    @test !isempty(detected.mismatches)
    @test any(m -> occursin("TotalOperatingCost", m.key), detected.mismatches)
end

# =====================================================================================
# IV2 Controller and fairness ordering do not change any result
# =====================================================================================

@testset "IV2 controller and fairness ordering do not change any result" begin
    reversed = integration_run(; combination_order=18:-1:1)
    @test scientific_digest(reversed.directory) == scientific_digest(IV_BASELINE.directory)

    # And the same claim stated on the values rather than on a digest, so a hash collision or a
    # formatting coincidence cannot make it pass.
    baseline = Dict(
        (m.replication_id, m.controller, m.fairness) => m for m in IV_BASELINE.metrics)
    for entry in reversed.metrics
        reference = baseline[(entry.replication_id, entry.controller, entry.fairness)]
        @test entry.completed == reference.completed
        @test entry.total_operating_cost == reference.total_operating_cost
        @test entry.total_savings == reference.total_savings
        @test entry.sorted_household_pv == reference.sorted_household_pv
        @test entry.terminal_soc == reference.terminal_soc
    end
end

# =====================================================================================
# IV3 Replication order and simulated worker assignment do not change any result
# =====================================================================================

@testset "IV3 replication order and worker assignment do not change any result" begin
    shuffled = integration_run(; replication_order=[2, 1])
    @test scientific_digest(shuffled.directory) == scientific_digest(IV_BASELINE.directory)

    # Every scientific file is byte-identical; only the provenance ones move.
    for file in readdir(IV_BASELINE.directory)
        (isfile(joinpath(IV_BASELINE.directory, file)) && endswith(file, ".csv")) || continue
        file in OOS_PROVENANCE_FILES && continue
        @test read(joinpath(shuffled.directory, file), String) ==
              read(joinpath(IV_BASELINE.directory, file), String)
    end

    # A different simulated worker changes ONLY the execution-provenance file.
    other_worker = integration_run(; worker=7)
    @test scientific_digest(other_worker.directory) == scientific_digest(IV_BASELINE.directory)
    provenance = CSV.read(
        joinpath(other_worker.directory, "execution_provenance.csv"), DataFrame)
    @test all(provenance.Worker .== 7)
    baseline_provenance = CSV.read(
        joinpath(IV_BASELINE.directory, "execution_provenance.csv"), DataFrame)
    @test all(baseline_provenance.Worker .== 0)
    # Which is exactly why the scientific digest excludes it.
    @test read(joinpath(other_worker.directory, "execution_provenance.csv"), String) !=
          read(joinpath(IV_BASELINE.directory, "execution_provenance.csv"), String)
end

# =====================================================================================
# IV4 Interruption and resumption produce identical shards
# =====================================================================================

@testset "IV4 interruption and resumption produce identical shards" begin
    config = integration_config()
    common = build_common_objects(config; verbose=false)
    tasks = [
        parallel_task_id(OOS_SINGLE_INSTANCE_STRUCTURAL_ID, index)
        for index in eachindex(common.oos_paths)
    ]

    """Write one replication's rows into its own shard directory and commit it."""
    function write_shard(root, index)
        task = tasks[index]
        directory = shard_directory(root, task)
        mkpath(directory)
        path = common.oos_paths[index]
        cache = cache_lookahead_trees(common.provider, common.context, path)
        runs = ReplicationRun[]
        for policy in config.fairness_set, controller in config.controller_set
            push!(runs, simulate_configuration(common.context, path, cache, controller, policy,
                                               common.share_table))
        end
        identity = run_identity(config, common.context, common.share_table, index)
        CSV.write(joinpath(directory, "period_actions.csv"),
                  period_actions_frame(config, runs, identity))
        return commit_shard(directory, task)
    end

    # A complete run.
    complete_root = mktempdir(; prefix="oos_iv_shards_")
    complete_digests = [write_shard(complete_root, index) for index in eachindex(tasks)]
    inventory = inventory_shards(complete_root, tasks)
    @test shard_inventory_ready(inventory)
    @test inventory.complete == tasks

    # An INTERRUPTED run: the first task committed, the second left mid-write with no marker.
    interrupted_root = mktempdir(; prefix="oos_iv_interrupted_")
    write_shard(interrupted_root, 1)
    partial = shard_directory(interrupted_root, tasks[2])
    mkpath(partial)
    write(joinpath(partial, "period_actions.csv"), "truncated,row\n")
    partial_inventory = inventory_shards(interrupted_root, tasks)
    @test !shard_inventory_ready(partial_inventory)
    @test partial_inventory.complete == [tasks[1]]
    @test partial_inventory.incomplete == [tasks[2]]

    # RESUMPTION: redo the unfinished task. The resumed shard is byte-identical to the one the
    # uninterrupted run produced, so an interruption leaves no trace in the science.
    rm(partial; recursive=true)
    resumed_digest = write_shard(interrupted_root, 2)
    @test resumed_digest == complete_digests[2]
    resumed_inventory = inventory_shards(interrupted_root, tasks)
    @test shard_inventory_ready(resumed_inventory)
    for (index, task) in enumerate(tasks)
        @test read(joinpath(shard_directory(interrupted_root, task), "period_actions.csv"),
                   String) ==
              read(joinpath(shard_directory(complete_root, task), "period_actions.csv"), String)
        @test shard_content_digest(shard_directory(interrupted_root, task)) ==
              complete_digests[index]
    end

    # Re-running an ALREADY COMPLETE task is idempotent, not a conflict.
    @test write_shard(complete_root, 1) == complete_digests[1]
    @test shard_inventory_ready(inventory_shards(complete_root, tasks))

    # The merged order is the manifest's, whatever order the shards were produced in.
    @test canonical_merge_order(reverse(tasks)) == canonical_merge_order(tasks)
end

# =====================================================================================
# IV5 Adversarial: injected inconsistencies are detected, not absorbed
# =====================================================================================

@testset "IV5 injected inconsistencies are detected" begin
    # A tampered shard is reported as a conflict rather than accepted.
    root = mktempdir(; prefix="oos_iv_adv_")
    task = parallel_task_id("PB-adv", 1)
    directory = shard_directory(root, task)
    mkpath(directory)
    write(joinpath(directory, "rows.csv"), "a\n1\n")
    commit_shard(directory, task)
    @test shard_inventory_ready(inventory_shards(root, [task]))
    write(joinpath(directory, "rows.csv"), "a\n2\n")
    @test inventory_shards(root, [task]).conflicting == [task]

    # A results directory missing a required column fails the schema reader.
    broken = mktempdir(; prefix="oos_iv_broken_")
    for file in readdir(IV_BASELINE.directory)
        source = joinpath(IV_BASELINE.directory, file)
        isfile(source) && cp(source, joinpath(broken, file))
    end
    frame = CSV.read(joinpath(broken, "replication_summary.csv"), DataFrame)
    select!(frame, Not(:HorizonCovered))
    CSV.write(joinpath(broken, "replication_summary.csv"), frame)
    validation = validate_output_directory(broken; expected_configurations=18)
    @test !validation.passed
    @test any(issue -> occursin("HorizonCovered", issue.detail), blocking_issues(validation))

    # A physically impossible action is rejected by the validator, with the violation named.
    common = IV_BASELINE.common
    template = common.template
    path = common.oos_paths[1]
    state = initial_simulation_state(common.context, path.replication_id)
    reveal_block!(state, path, 1:1)
    impossible = PeriodAction(
        1, 1, zeros(template.J), zeros(template.J), fill(1e5, template.J),
        zeros(template.J), zeros(template.J), fill(1.0 / template.J, template.J),
        0.0, 1e5 * template.J, template.s_I,
    )
    outcome = validate_period_action(
        common.context, state, impossible, IV_BASELINE.config; lookahead_end=4)
    @test !outcome.valid
    @test !isempty(outcome.violations)
end

# =====================================================================================
# IV6 Property checks over randomized admissible configurations
# =====================================================================================

@testset "IV6 property checks over randomized admissible configurations" begin
    generator = MersenneTwister(11_111)
    for _ in 1:40
        H = rand(generator, 1:30)
        L = rand(generator, 1:30)
        h = rand(generator, 1:min(H, L))
        config = integration_config(
            evaluation_horizon=H, lookahead_horizon=L, implementation_step=h)

        starts = rolling_iteration_starts(config)
        # The temporal contract holds for every admissible triple, not only the defaults.
        @test starts == collect(1:h:H)
        @test rolling_solve_count(config) == length(starts)
        @test known_prefix_length(config) == h
        final = final_rolling_iteration_start(config)
        @test last(implementation_block(config, final)) == realized_period_end(config)
        @test last(lookahead_periods(config, final)) == required_period_support_end(config)
        # The two orderings the simulator relies on.
        @test realized_period_end(config) >= H
        @test realized_period_end(config) <= required_period_support_end(config)
        # Every evaluated block stays inside 1:H, and their union is exactly 1:H.
        evaluated = reduce(vcat, [collect(evaluation_block(config, t)) for t in starts])
        @test evaluated == collect(1:H)
        # Every committed block has exactly h periods and starts where it should.
        for t in starts
            block = implementation_block(config, t)
            @test length(block) == h
            @test first(block) == t
            @test length(lookahead_periods(config, t)) == L
        end
    end

    # An inadmissible triple is rejected rather than silently corrected.
    @test_throws ErrorException integration_config(evaluation_horizon=0)
    @test_throws ErrorException integration_config(lookahead_horizon=0)
    @test_throws ErrorException integration_config(
        evaluation_horizon=4, lookahead_horizon=4, implementation_step=5)
end
