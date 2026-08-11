# =====================================================================================
# TR0..TR7  Manifest-driven campaign runner, shards and deterministic merge (stage 13)
#
# The acceptance gate of plan section 7 (Stage 13) is that the same bounded catalog, run
# serially, in two processes, in another admissible number of processes, with the task order
# shuffled, and interrupted-then-resumed, produces the same merged scientific content. These
# sets establish the properties that make that true, plus the two that make it *checkable*:
# the merge refuses an incomplete set, and the campaign aggregates are recomputed at merge time
# rather than concatenated.
#
# The stage-13 decision (plan section 11, 2026-08-07) removed the Julia coordinator: concurrency
# comes from independent processes over disjoint task subsets. So every safety property lives in
# the partition and the commit, and is testable without spawning anything.
#
# These sets run inside `tests/oos/runtests.jl` and reuse its helpers.
# =====================================================================================

"""Bounded stage-13 catalog: 1 base instance, K=1, R=2 -> 8 instances, 4 paired bases, 8 tasks."""
function shard_setup(; replications::Int=2)
    instance = joinpath(OOS_CODES_DIRECTORY, "inst", "inst2020", "Drahi_1.csv")
    base_config = test_config(
        experiment_seed=12345, households=3, oos_replications=replications,
        evaluation_horizon=4, lookahead_horizon=4,
        multistage_branching=[2], two_stage_scenarios=2, instance_file=instance)
    design = OOSStructuralDesignConfig(
        base_instance_files=[instance], experiment_seed=12345,
        structural_draws_per_cell=1,
        battery_scales=battery_scale_map(15.876190, 47.622222),
        uncertainty_thetas=uncertainty_theta_map(0.0625, 0.1953125),
        households=3, oos_replications=replications,
        evaluation_horizon=4, lookahead_horizon=4)
    specs = structural_instance_specs(design)
    return (base_config=base_config, design=design, specs=specs,
            tasks=oos_tasks_from_specs(specs, replications))
end

"""Digest of a merged directory's SCIENTIFIC content, excluding execution provenance."""
function shard_scientific_digest(directory)
    files = sort([f for f in readdir(directory)
                  if endswith(f, ".csv") && !(f in OOS_PROVENANCE_FILES)])
    return oos_stable_digest(canonical_json(Dict{String,Any}("files" => [
        Dict{String,Any}("name" => f,
                         "digest" => oos_stable_digest(read(joinpath(directory, f), String)))
        for f in files])))
end

"""Run tasks across `shards` simulated processes, honouring the given order and skip list."""
function shard_campaign(setup, tasks, shards; root=mktempdir(prefix="oos_tr_"), skip=String[])
    for index in 1:shards
        for task in tasks_for_shard(tasks, index, shards)
            task.task_id in skip && continue
            run_oos_task(setup.base_config, task; shard_root=root, worker=index)
        end
    end
    return root
end

@testset "TR0 task enumeration is canonical and pairing-preserving" begin
    setup = shard_setup()
    tasks = setup.tasks
    ids = [task.task_id for task in tasks]

    @test length(setup.specs) == 8                      # 1 base x 2 x 2 x 2 x K=1
    @test length(tasks) == 8                            # 4 paired bases x R=2
    @test ids == canonical_merge_order(ids)             # enumeration order IS merge order
    @test length(unique(ids)) == length(ids)

    # A task bundles BOTH battery levels of its paired base. Splitting them across processes
    # would break the pairing the whole design rests on, so this is a structural requirement,
    # not a packing convenience.
    for task in tasks
        @test length(task.specs) == 2
        @test sort([string(spec.battery_level) for spec in task.specs]) ==
              sort([string(LOW_BATTERY), string(HIGH_BATTERY)])
        @test length(unique([spec.paired_base_id for spec in task.specs])) == 1
        @test all(spec.paired_base_id == task.paired_base_id for spec in task.specs)
    end

    # Every (paired base, replication) appears exactly once.
    pairing_keys = [(task.paired_base_id, task.replication) for task in tasks]
    @test length(unique(pairing_keys)) == length(pairing_keys)
end

@testset "TR1 the stride partition needs no coordination" begin
    setup = shard_setup()
    tasks = setup.tasks

    for shards in (1, 2, 3, 4, 8, 16)
        parts = [tasks_for_shard(tasks, index, shards) for index in 1:shards]
        recovered = sort([task.task_id for part in parts for task in part])
        # Complete: every task lands somewhere. Disjoint: none lands twice. Both hold for a
        # shard count that exceeds the task count, which is what makes over-provisioning safe.
        @test recovered == sort([task.task_id for task in tasks])
        for a in 1:shards, b in (a + 1):shards
            @test isempty(intersect([t.task_id for t in parts[a]],
                                    [t.task_id for t in parts[b]]))
        end
        # Deterministic: the same index yields the same subset, with no shared state consulted.
        @test [t.task_id for t in tasks_for_shard(tasks, 1, shards)] ==
              [t.task_id for t in parts[1]]
    end

    @test_throws Exception tasks_for_shard(tasks, 0, 4)
    @test_throws Exception tasks_for_shard(tasks, 5, 4)
end

@testset "TR2 a committed shard is atomic and idempotent" begin
    setup = shard_setup()
    task = first(setup.tasks)
    root = mktempdir(prefix="oos_tr2_")

    digest = run_oos_task(setup.base_config, task; shard_root=root)
    directory = shard_directory(root, task.task_id)
    @test shard_is_complete(directory)
    # Staging is named per process, so check that NO staging sibling survives a success.
    @test isempty(filter(startswith(basename(directory) * ".partial"), readdir(root)))
    @test shard_content_digest(directory) == digest

    # Re-running a committed task is accepted and changes nothing: the campaign can be resumed
    # by simply re-issuing every task.
    before = shard_scientific_digest(directory)
    @test run_oos_task(setup.base_config, task; shard_root=root) == digest
    @test shard_scientific_digest(directory) == before

    # A shard whose contents were altered after commit is a CONFLICT, never a silent overwrite.
    open(joinpath(directory, "period_actions.csv"), "a") do io
        println(io, "fila,espuria")
    end
    @test_throws Exception run_oos_task(setup.base_config, task; shard_root=root)
end

@testset "TR3 the merge refuses an incomplete or unknown set" begin
    setup = shard_setup()
    tasks = setup.tasks
    ids = [task.task_id for task in tasks]
    root = shard_campaign(setup, tasks, 2; skip=[ids[2], ids[5]])

    refused = merge_oos_shards(root, mktempdir(prefix="oos_tr3a_"), ids)
    @test !refused.merged
    @test occursin("faltan", refused.detail)
    @test occursin(ids[2], refused.detail)
    @test occursin(ids[5], refused.detail)

    # Refusal must produce NOTHING. A partial dataset that looks analyzable is worse than none.
    destination = mktempdir(prefix="oos_tr3b_")
    merge_oos_shards(root, destination, ids)
    @test isempty([f for f in readdir(destination) if endswith(f, ".csv")])

    # A shard nobody asked for is also a refusal: it means the shard root and the manifest
    # disagree about what campaign this is — leftovers from a previous run in the same
    # directory, or a merge requested with a smaller R than the shards were produced with.
    # Ignoring it would publish a dataset smaller than the evidence on disk.
    complete_root = shard_campaign(setup, tasks, 1)
    stranger = merge_oos_shards(complete_root, mktempdir(prefix="oos_tr3c_"), ids[1:(end - 1)])
    @test !stranger.merged
    @test occursin("no esperados", stranger.detail)
    @test occursin(ids[end], stranger.detail)
end

@testset "TR4 merged content is invariant to how the campaign was scheduled" begin
    setup = shard_setup()
    tasks = setup.tasks
    ids = [task.task_id for task in tasks]

    serial = mktempdir(prefix="oos_tr4_serial_")
    @test merge_oos_shards(shard_campaign(setup, tasks, 1), serial, ids).merged
    reference = shard_scientific_digest(serial)

    for shards in (2, 3)
        destination = mktempdir(prefix="oos_tr4_p$(shards)_")
        @test merge_oos_shards(shard_campaign(setup, tasks, shards), destination, ids).merged
        @test shard_scientific_digest(destination) == reference
    end

    # Task order shuffled inside the processes.
    shuffled = tasks[[3, 1, 6, 2, 8, 4, 7, 5]]
    destination = mktempdir(prefix="oos_tr4_shuffled_")
    @test merge_oos_shards(shard_campaign(setup, shuffled, 3), destination, ids).merged
    @test shard_scientific_digest(destination) == reference

    # Interrupted, then resumed by re-issuing everything.
    partial = shard_campaign(setup, tasks, 2; skip=[ids[2], ids[5]])
    shard_campaign(setup, tasks, 2; root=partial)
    resumed = mktempdir(prefix="oos_tr4_resumed_")
    @test merge_oos_shards(partial, resumed, ids).merged
    @test shard_scientific_digest(resumed) == reference
end

@testset "TR5 aggregates are recomputed at merge time, not concatenated" begin
    setup = shard_setup()
    tasks = setup.tasks
    ids = [task.task_id for task in tasks]
    root = shard_campaign(setup, tasks, 1)

    # A shard is row-level data. Emitting an aggregate over replications inside one is
    # meaningless, because a shard holds exactly ONE replication of one paired base.
    for task in tasks
        contents = readdir(shard_directory(root, task.task_id))
        @test !("configuration_summary.csv" in contents)
        @test !("paired_statistics.csv" in contents)
        @test "replication_summary.csv" in contents
    end

    directory = mktempdir(prefix="oos_tr5_")
    @test merge_oos_shards(root, directory, ids).merged
    @test isfile(joinpath(directory, "configuration_summary.csv"))
    @test isfile(joinpath(directory, "paired_statistics.csv"))

    # One POOLED row per configuration, not one per shard — the defect this replaced.
    summary = CSV.read(joinpath(directory, "configuration_summary.csv"), DataFrame)
    configurations = unique([(r.Controller, r.Fairness) for r in eachrow(summary)])
    @test nrow(summary) == length(configurations)

    # And the pooled counts must agree with the raw bands they claim to summarize.
    recovery = CSV.read(joinpath(directory, "pea_recovery.csv"), DataFrame)
    for row in eachrow(summary)
        bands = filter(r -> r.Controller == row.Controller && r.Fairness == row.Fairness,
                       recovery)
        @test row.PeriodsSolved == nrow(bands)
    end
end

@testset "TR6 pairing is (structural instance, replication), never the replication alone" begin
    setup = shard_setup()
    ids = [task.task_id for task in setup.tasks]
    directory = mktempdir(prefix="oos_tr6_")
    @test merge_oos_shards(shard_campaign(setup, setup.tasks, 1), directory, ids).merged

    replications = CSV.read(joinpath(directory, "replication_summary.csv"), DataFrame)
    @test "StructuralInstanceID" in names(replications)

    # The same replication number appears under several structural instances. That is exactly
    # why the number alone cannot be a pairing key: it would difference unrelated instances.
    instances_per_replication = Dict{Int,Set{String}}()
    for row in eachrow(replications)
        push!(get!(instances_per_replication, Int(row.Replication), Set{String}()),
              String(row.StructuralInstanceID))
    end
    @test all(length(v) > 1 for v in values(instances_per_replication))

    # A paired difference is therefore taken over (instance, replication) cells, and each cell
    # must be complete for both sides of the comparison.
    cells = unique([(String(r.StructuralInstanceID), Int(r.Replication))
                    for r in eachrow(replications)])
    statistics = CSV.read(joinpath(directory, "paired_statistics.csv"), DataFrame)
    differences = filter(r -> r.ComparisonKind == "difference", statistics)
    @test nrow(differences) > 0
    @test all(r.Observations <= length(cells) for r in eachrow(differences))
    @test any(r.Observations == length(cells) for r in eachrow(differences))
end

@testset "TR7 the manifest is the campaign's authority" begin
    setup = shard_setup()
    path = joinpath(mktempdir(prefix="oos_tr7_"), "structural_manifest.json")
    generate_structural_manifest(setup.base_config, setup.design, path;
                                 write_companions=false, verbose=false)

    enumeration = oos_tasks_from_manifest(path)
    @test [task.task_id for task in enumeration.tasks] == [t.task_id for t in setup.tasks]
    @test enumeration.design.experiment_seed == setup.design.experiment_seed
    @test [s.structural_instance_id for s in enumeration.specs] ==
          [s.structural_instance_id for s in setup.specs]

    # R stays a parameter: a pilot runs fewer replications of the SAME catalog, without
    # regenerating or re-validating anything.
    pilot = oos_tasks_from_manifest(path; replications=1)
    @test length(pilot.tasks) == 4
    @test [s.structural_instance_id for s in pilot.specs] ==
          [s.structural_instance_id for s in setup.specs]

    # A manifest whose recorded identifiers do not match the regenerated catalog is refused.
    # This is the check that makes "manifest-driven" mean something: it proves the code about
    # to run reproduces the catalog that was validated.
    document = canonical_json_parse(read(path, String))
    document["structural_instances"][1]["structural_instance_id"] = "SI-inventado"
    tampered = joinpath(dirname(path), "tampered.json")
    write(tampered, structural_manifest_text(document))
    @test_throws Exception oos_tasks_from_manifest(tampered)
end
