# =====================================================================================
# Manifest-driven task runner, isolated shards and deterministic merge (stage 13).
#
# SCOPE, per the approved decision of 2026-08-07: this is the deterministic serial kernel plus
# the shard and merge machinery. There is NO Julia coordinator and no dynamic assignment.
# Concurrency is obtained by launching independent Julia processes over disjoint task subsets
# (`scripts/oos/run_oos_task.sh --shard-index i --shards N`), which is why every property that
# makes that safe has to live here rather than in a scheduler:
#
#   * a task is identified by `(PairedBaseID, OOSReplicationID)` and by nothing else, so the same
#     task re-run anywhere produces the same identifier;
#   * a task writes into its OWN directory and never appends to a shared file;
#   * a shard is committed atomically — contents first, marker last — so a crash leaves an
#     unmarked directory that can never be mistaken for a finished one;
#   * re-running a finished task is idempotent when its content matches and a reported CONFLICT
#     when it does not; and
#   * the merge order is the manifest's, never the order in which tasks finished.
#
# One task deliberately bundles BOTH battery levels, all three controllers, all six fairness
# policies and every rolling start of its replication. Splitting any of those across processes
# would break the pairing the design depends on.
# =====================================================================================

"""
One schedulable unit of the campaign.

`specs` holds every structural instance that shares this task's `paired_base_id` — that is, both
battery levels of the same `(base instance, structural draw, demand regime, uncertainty level)`
cell. They are evaluated together, on the same out-of-sample trajectory, because the design
compares them as a matched pair.
"""
struct OOSTask
    task_id::String
    paired_base_id::String
    replication::Int
    specs::Vector{OOSStructuralInstanceSpec}
end

task_instance_count(task::OOSTask) = length(task.specs)

"""
Enumerate every campaign task from a structural catalog, in canonical order.

`replications` is a parameter, never a constant: `R` stays a decision made at simulation time.
The ordering is `canonical_merge_order` over the task identifiers, so the task list — and
therefore the merged dataset — is independent of the order the catalog happened to produce.
"""
function oos_tasks_from_specs(
    specs::AbstractVector{OOSStructuralInstanceSpec},
    replications::Int,
)
    replications >= 1 || error("Se requiere al menos una réplica; se recibió $replications.")
    grouped = Dict{String,Vector{OOSStructuralInstanceSpec}}()
    for spec in specs
        push!(get!(grouped, spec.paired_base_id, OOSStructuralInstanceSpec[]), spec)
    end
    tasks = OOSTask[]
    for paired_base_id in sort(collect(keys(grouped))), replication in 1:replications
        bundle = sort(grouped[paired_base_id]; by=spec -> spec.structural_instance_id)
        push!(tasks, OOSTask(
            parallel_task_id(paired_base_id, replication), paired_base_id, replication, bundle,
        ))
    end
    return sort(tasks; by=task -> task.task_id)
end

"""Task identifiers of a catalog, in the canonical order the merge will use."""
oos_task_ids(specs::AbstractVector{OOSStructuralInstanceSpec}, replications::Int) =
    [task.task_id for task in oos_tasks_from_specs(specs, replications)]

"""
Select this process's share of the task list, without any coordination.

`shard_index` is one-based and `shards` is the process count. The partition is a deterministic
stride over the canonical order, so `N` processes launched independently cover the task list
exactly once between them, with no communication and no shared cursor.
"""
function tasks_for_shard(tasks::AbstractVector{OOSTask}, shard_index::Int, shards::Int)
    shards >= 1 || error("El número de procesos debe ser >= 1; se recibió $shards.")
    1 <= shard_index <= shards || error(
        "shard_index=$shard_index está fuera de 1:$shards."
    )
    return [task for (position, task) in enumerate(tasks) if mod1(position, shards) == shard_index]
end

"""
Run one task to completion and commit its shard.

The serial kernel. For every structural instance of the task it materializes the instance, builds
the rolling context, resolves the share table, samples the task's out-of-sample trajectory, builds
the ONE common conditional support per rolling start, and evaluates every controller × policy on
it. Nothing in here depends on which process it runs in or on what any other task is doing.

Returns the shard's content digest. Re-running a task whose shard is already committed and whose
content matches is a no-op that returns the same digest; a mismatch is reported as a conflict
rather than overwritten.
"""
function run_oos_task(
    base_config::OOSExperimentConfig,
    task::OOSTask;
    shard_root::AbstractString,
    worker::Int=0,
    retry::Int=0,
    verbose::Bool=false,
)
    directory = shard_directory(shard_root, task.task_id)
    if shard_is_complete(directory)
        marker = canonical_json_parse(read(shard_completion_marker(directory), String))
        recorded = get(marker, "content_digest", "")
        actual = shard_content_digest(directory)
        recorded == actual || error(
            "El shard $(task.task_id) ya estaba comprometido pero su contenido cambió: el " *
            "marcador registra $recorded y el directorio produce $actual. Se reporta el " *
            "conflicto en lugar de sobrescribirlo."
        )
        verbose && println("  [YA COMPLETO] ", task.task_id)
        return actual
    end

    # Write into a temporary sibling and rename, so a crash never leaves a half-written directory
    # under the task's own name.
    #
    # The staging name carries the PROCESS ID. The fan-out is meant to run over disjoint task
    # subsets, but an operator who relaunches a shard while the previous one is still alive
    # breaks that precondition, and a shared staging name turns that mistake into silent
    # corruption: each process deletes the other's half-written directory and the survivor
    # commits a mixture. With a per-process name the two never touch the same bytes, and the
    # loser of the rename falls through to the digest comparison below — the same idempotency
    # check a deliberate re-run gets.
    staging = string(directory, ".partial.", getpid())
    isdir(staging) && rm(staging; recursive=true)
    mkpath(staging)

    # One output directory PER STRUCTURAL INSTANCE, concatenated into the shard afterwards.
    # A task bundles both battery levels, and they share every other key — replication,
    # controller, policy, period — so writing them through one identity would stamp both with the
    # same `StructuralInstanceID` and make the two levels indistinguishable in the output. The
    # scientific row key includes the structural instance precisely because a replication number
    # is unique only within one.
    instance_directories = String[]

    for spec in task.specs
        materialized = materialize_structural_instance(base_config, spec)
        config = materialized.config
        instance_template = materialized.template
        support = build_period_data_support(
            instance_template, required_period_support_end(config))
        context = OOSRollingContext(config, instance_template, support)
        provider = RepositoryUncertaintyProvider(instance_template; data_support=support)
        share_table = resolve_static_share_table(
            instance_template, provider, materialized.legacy_in_sample_tree,
            in_sample_rng(config); period_end=rolling_data_end(context),
        )
        path = sample_oos_path(
            provider, rolling_realized_end(context),
            oos_path_rng(config, task.replication); replication_id=task.replication,
        )
        cache = cache_lookahead_trees(provider, context, path)
        runs = ReplicationRun[]
        metrics = ReplicationMetrics[]
        for policy in config.fairness_set, controller in config.controller_set
            run = simulate_configuration(
                context, path, cache, controller, policy, share_table; verbose=false)
            push!(runs, run)
            push!(metrics, compute_replication_metrics(
                instance_template, run, config; share_table=share_table))
        end
        identity = run_identity(
            config, context, share_table, task.replication;
            structural_instance_id=spec.structural_instance_id,
            paired_base_id=spec.paired_base_id,
            deterministic_data_id=spec.deterministic_data_id,
            demand_assignment_id=spec.demand_assignment_id,
        )
        instance_directory = joinpath(staging, spec.structural_instance_id)
        mkpath(instance_directory)
        write_campaign_outputs(
            OOSExperimentConfig(;
                _task_runner_keywords(config)..., output_directory=instance_directory),
            instance_template, runs, metrics, campaign_statistics(metrics),
            ModelAudit[], GateReport[];
            configuration_summaries=configuration_pea_summaries(metrics),
            identity=identity, worker=worker, retry=retry, write_aggregates=false,
        )
        push!(instance_directories, instance_directory)
        verbose && println("  ", spec.structural_instance_id, ": ",
                           count(run -> run.completed, runs), "/", length(runs), " completas")
    end

    _concatenate_into_shard(instance_directories, staging)

    # Another process may have committed this very task while we were computing it. Removing its
    # directory to install ours would destroy a valid, already-inventoried shard, so the loser
    # keeps its own work out of the way and defers to the committed content — accepting it when
    # the digests agree and reporting a conflict when they do not.
    if shard_is_complete(directory)
        marker = canonical_json_parse(read(shard_completion_marker(directory), String))
        recorded = get(marker, "content_digest", "")
        ours = shard_content_digest(staging)
        rm(staging; recursive=true)
        recorded == shard_content_digest(directory) && recorded == ours && return recorded
        error(
            "El shard $(task.task_id) fue comprometido por otro proceso mientras este lo " *
            "calculaba, y el contenido no coincide: el marcador registra $recorded y este " *
            "proceso produjo $ours. Se reporta el conflicto en lugar de sobrescribirlo."
        )
    end
    isdir(directory) && rm(directory; recursive=true)
    mv(staging, directory)
    return commit_shard(directory, task.task_id)
end

"""
Concatenate the per-structural-instance directories into the shard, then remove them.

The same concatenation the campaign-level merge performs, applied one level down: rows in
canonical order, so a shard is byte-identical regardless of the order its instances were
evaluated in.
"""
function _concatenate_into_shard(
    instance_directories::AbstractVector{String},
    staging::AbstractString,
)
    ordered = sort(instance_directories)
    file_names = sort(unique(reduce(vcat, [
        [file for file in readdir(directory) if endswith(file, ".csv")]
        for directory in ordered
    ])))
    for file in file_names
        frames = DataFrame[]
        for directory in ordered
            path = joinpath(directory, file)
            isfile(path) && push!(frames, CSV.read(path, DataFrame))
        end
        isempty(frames) && continue
        CSV.write(joinpath(staging, file),
                  canonical_row_sort(reduce(vcat, frames; cols=:union)))
    end
    metadata = joinpath(first(ordered), "experiment_config.json")
    isfile(metadata) && cp(metadata, joinpath(staging, "experiment_config.json"); force=true)
    for directory in ordered
        rm(directory; recursive=true)
    end
    return staging
end

"""Configuration keywords, so the shard writer can be pointed at the staging directory."""
_task_runner_keywords(config::OOSExperimentConfig) = (
    name => getfield(config, name)
    for name in fieldnames(OOSExperimentConfig) if name !== :output_directory
)

# -------------------------------------------------------------------------------------
# Manifest-driven task enumeration
# -------------------------------------------------------------------------------------

"""
Rebuild the structural design recorded in a manifest document.

Reads the levels back out of `design` rather than from the environment, so the campaign cannot
drift from the catalog that was generated and validated. Every field the design needs is stored
in the manifest; nothing is defaulted here.
"""
function oos_design_from_manifest(document::AbstractDict)
    design = document["design"]
    batteries = design["battery_level_scales"]
    thetas = design["uncertainty_level_thetas"]
    return OOSStructuralDesignConfig(
        base_instance_files=[String(file) for file in design["base_instance_files"]],
        experiment_seed=Int(design["experiment_seed"]),
        structural_draws_per_cell=Int(design["structural_draws_per_cell"]),
        battery_scales=battery_scale_map(
            Float64(batteries[string(LOW_BATTERY)]),
            Float64(batteries[string(HIGH_BATTERY)]),
        ),
        uncertainty_thetas=uncertainty_theta_map(
            Float64(thetas[string(LOW_UNCERTAINTY)]),
            Float64(thetas[string(HIGH_UNCERTAINTY)]),
        ),
        households=Int(design["households"]),
        avg_demand=Float64(design["avg_demand"]),
        dev_demand=Float64(design["dev_demand"]),
        pv_scale=Float64(design["pv_scale"]),
        oos_replications=Int(design["oos_replication_count"]),
        evaluation_horizon=Int(design["evaluation_horizon"]),
        lookahead_horizon=Int(design["lookahead_horizon"]),
        implementation_step=Int(design["implementation_step"]),
        in_sample_stages=Int(design["in_sample_stages"]),
        in_sample_children=Int(design["in_sample_children"]),
        in_sample_periods_per_stage=Int(design["in_sample_periods_per_stage"]),
        repository_demand_profile=String(design["repository_demand_profile"]),
    )
end

"""
Enumerate the campaign's tasks from a saved structural manifest.

The specs are regenerated from the recorded design and then **checked against the identifiers the
manifest actually stored**, in order. That check is the point of going through the manifest: it
proves the code about to run reproduces the catalog that was validated, instead of quietly
enumerating a different one. A single mismatched identifier aborts the campaign.

`replications` defaults to the manifest's own `oos_replication_count`. `R` stays a parameter, so a
pilot can run fewer replications of the same catalog without regenerating anything.
"""
function oos_tasks_from_manifest(
    path::AbstractString;
    replications::Union{Nothing,Int}=nothing,
)
    isfile(path) || error("No existe el manifiesto estructural: $path")
    document = canonical_json_parse(read(String(path), String))
    document isa AbstractDict ||
        error("El manifiesto no es un objeto JSON: $path")

    design = oos_design_from_manifest(document)
    specs = structural_instance_specs(design)

    recorded = [String(entry["structural_instance_id"])
                for entry in document["structural_instances"]]
    regenerated = [spec.structural_instance_id for spec in specs]
    if regenerated != recorded
        divergence = findfirst(
            index -> index > length(recorded) || index > length(regenerated) ||
                     recorded[index] != regenerated[index],
            1:max(length(recorded), length(regenerated)),
        )
        error(
            "El catálogo regenerado no coincide con el manifiesto $(path): " *
            "$(length(recorded)) instancias registradas, $(length(regenerated)) regeneradas, " *
            "primera divergencia en la posición $(divergence). La campaña se niega a correr " *
            "sobre un catálogo distinto del que se validó."
        )
    end

    count = replications === nothing ? design.oos_replications : replications
    return (
        design=design,
        specs=specs,
        tasks=oos_tasks_from_specs(specs, count),
        manifest_id=String(document["manifest_id"]),
    )
end

# -------------------------------------------------------------------------------------
# Campaign aggregates, produced ONCE at merge time
# -------------------------------------------------------------------------------------

"""
Recompute the two campaign aggregates from the merged replication-level rows.

They cannot be concatenated from the shards: each aggregates OVER replications, and a shard holds
exactly one replication of one paired base, so a per-shard aggregate is meaningless and stacking
them yields one row per shard instead of one pooled row.

**The pairing key is `(StructuralInstanceID, OOSReplicationID)`, not the replication alone.** With
a structural design a replication number identifies a trajectory only within one instance, so
pairing on the number by itself would difference rows from unrelated instances. This is also the
unit plan section 8 requires the final analysis to use.

Like `independent_recompute.jl`, this reads columns and does arithmetic; it shares no accumulator
with the campaign's own aggregation.
"""
function recompute_campaign_aggregates(directory::AbstractString)
    replications = CSV.read(joinpath(directory, "replication_summary.csv"), DataFrame)
    recovery_path = joinpath(directory, "pea_recovery.csv")
    recovery = isfile(recovery_path) ? CSV.read(recovery_path, DataFrame) : nothing

    experiment = isempty(replications) ? "" : String(first(replications.ExperimentID))
    formulation = isempty(replications) ? "" : String(first(replications.FormulationID))

    # --- configuration_summary.csv : pooled over every replication of every instance ---------
    summary = DataFrame(
        ExperimentID=String[], FormulationID=String[],
        Controller=String[], Fairness=String[], Resource=String[],
        Replications=Int[], CompletedReplications=Int[], PeriodsSolved=Int[],
        ConfigPEAToleranceActivations=Int[], ConfigPEAToleranceActivationRate=Float64[],
        ConfigPEAToleranceMeanActive=Float64[], ConfigPEAToleranceMeanAllPeriods=Float64[],
        ConfigPEAToleranceMax=Float64[], ConfigPEAStrictFeasiblePeriods=Int[],
    )
    configurations = sort(unique([
        (String(row.Controller), String(row.Fairness)) for row in eachrow(replications)
    ]))
    for (controller, fairness) in configurations
        rows = filter(
            r -> String(r.Controller) == controller && String(r.Fairness) == fairness,
            replications,
        )
        bands = Float64[]
        strict = 0
        if recovery !== nothing
            recovery_rows = filter(
                r -> String(r.Controller) == controller && String(r.Fairness) == fairness,
                recovery,
            )
            bands = Float64.(recovery_rows.PEA_Tolerance_Used_kWh)
            strict = count(r -> r.PEA_Strict_Feasible === true, eachrow(recovery_rows))
        end
        active = [band for band in bands if band > OOS_PEA_ACTIVATION_THRESHOLD]
        push!(summary, (
            experiment, formulation, controller, fairness,
            isempty(rows) ? "" : String(first(rows.Resource)),
            nrow(rows), count(r -> r.CompletionStatus == "completed", eachrow(rows)),
            length(bands),
            length(active),
            isempty(bands) ? 0.0 : length(active) / length(bands),
            isempty(active) ? 0.0 : sum(active) / length(active),
            isempty(bands) ? 0.0 : sum(bands) / length(bands),
            isempty(bands) ? 0.0 : maximum(bands),
            strict,
        ))
    end
    CSV.write(joinpath(directory, "configuration_summary.csv"), canonical_row_sort(summary))

    # --- paired_statistics.csv : differences within matched (instance, replication) pairs -----
    metrics = [
        ("total_operating_cost", :TotalOperatingCost),
        ("total_savings", :TotalSavings),
        ("max_pv_relative_deviation", :MaxPVRelativeDeviation),
        ("max_savings_relative_deviation", :MaxSavingsRelativeDeviation),
        ("min_household_pv", :MinHouseholdPV),
        ("min_household_savings", :MinHouseholdSavings),
    ]
    indexed = Dict{Tuple{String,Int,String,String},Any}()
    for row in eachrow(replications)
        indexed[(String(row.StructuralInstanceID), Int(row.Replication),
                 String(row.Controller), String(row.Fairness))] = row
    end
    pairs_available = sort(unique([
        (String(row.StructuralInstanceID), Int(row.Replication)) for row in eachrow(replications)
    ]))
    controllers = sort(unique(String.(replications.Controller)))
    policies = sort(unique(String.(replications.Fairness)))

    statistics = PairedSummary[]
    value_of(entry, column) = Float64(getproperty(entry, column))
    completed(entry) = entry.CompletionStatus == "completed"

    for (name, column) in metrics
        # Levels, one per configuration.
        for controller in controllers, policy in policies
            values = Float64[]
            for key in pairs_available
                entry = get(indexed, (key[1], key[2], controller, policy), nothing)
                entry === nothing && continue
                completed(entry) || continue
                push!(values, value_of(entry, column))
            end
            push!(statistics, summarize_sample(
                values, "$(name)__level", "$(controller)|$(policy)", "-"))
        end
        # Paired differences, holding one factor fixed.
        for (label, outer, inner) in (
            ("controller_difference", policies, controllers),
            ("fairness_difference", controllers, policies),
        )
            for fixed in outer, a in eachindex(inner), b in eachindex(inner)
                a < b || continue
                differences = Float64[]
                baselines = Float64[]
                comparisons = Float64[]
                for key in pairs_available
                    left_key = label == "controller_difference" ?
                        (key[1], key[2], inner[a], fixed) : (key[1], key[2], fixed, inner[a])
                    right_key = label == "controller_difference" ?
                        (key[1], key[2], inner[b], fixed) : (key[1], key[2], fixed, inner[b])
                    left = get(indexed, left_key, nothing)
                    right = get(indexed, right_key, nothing)
                    (left === nothing || right === nothing) && continue
                    (completed(left) && completed(right)) || continue
                    base = value_of(left, column)
                    comparison = value_of(right, column)
                    push!(baselines, base)
                    push!(comparisons, comparison)
                    push!(differences, comparison - base)
                end
                relative, excluded = paired_relative_differences(baselines, comparisons)
                names = label == "controller_difference" ?
                    ("$(inner[a])|$(fixed)", "$(inner[b])|$(fixed)") :
                    ("$(fixed)|$(inner[a])", "$(fixed)|$(inner[b])")
                push!(statistics, summarize_sample(
                    differences, "$(name)__$(label)", names[1], names[2];
                    comparison_kind="difference", relative_values=relative,
                    zero_denominator_observations=excluded))
            end
        end
    end

    frame = DataFrame(
        ExperimentID=String[], FormulationID=String[], Metric=String[],
        Baseline=String[], Comparison=String[], Observations=Int[],
        Mean=Float64[], StandardDeviation=Float64[], StandardError=Float64[],
        ConfidenceLow=Float64[], ConfidenceHigh=Float64[],
        ComparisonKind=String[], MeanRelativePercent=Float64[],
        ZeroDenominatorObservations=Int[], RelativeDenominatorFloor=Float64[],
    )
    for entry in statistics
        push!(frame, (
            experiment, formulation, entry.label, entry.baseline, entry.comparison,
            entry.observations, entry.mean, entry.standard_deviation, entry.standard_error,
            entry.confidence_low, entry.confidence_high,
            entry.comparison_kind, entry.mean_relative_percent,
            entry.zero_denominator_observations, OOS_RELATIVE_COMPARATOR_FLOOR,
        ))
    end
    CSV.write(joinpath(directory, "paired_statistics.csv"), canonical_row_sort(frame))

    return (
        configurations=nrow(summary),
        paired_rows=nrow(frame),
        matched_pairs=length(pairs_available),
    )
end

"""Outcome of merging a shard root into one campaign dataset."""
struct MergeReport
    shard_root::String
    output_directory::String
    merged::Bool
    inventory::ShardInventory
    files::Dict{String,Int}
    detail::String
end

"""
Merge every complete shard into one dataset, in canonical manifest order.

Refuses to merge unless the inventory is clean: a missing, unfinished or conflicting shard stops
the merge and is named. A partial dataset silently presented as complete is exactly the failure
this stage exists to prevent.

Rows are concatenated in `canonical_merge_order` and then sorted again by the writer's canonical
row order, so the merged file is byte-identical regardless of how the shards were produced or in
what order they finished.
"""
function merge_oos_shards(
    shard_root::AbstractString,
    output_directory::AbstractString,
    expected_tasks::AbstractVector{<:AbstractString},
)
    inventory = inventory_shards(shard_root, expected_tasks)
    if !shard_inventory_ready(inventory)
        detail = join(filter(!isempty, [
            isempty(inventory.missing_tasks) ? "" :
                "faltan $(length(inventory.missing_tasks)): " *
                join(first(inventory.missing_tasks, 5), ", "),
            isempty(inventory.incomplete) ? "" :
                "incompletos $(length(inventory.incomplete)): " *
                join(first(inventory.incomplete, 5), ", "),
            isempty(inventory.conflicting) ? "" :
                "en conflicto $(length(inventory.conflicting)): " *
                join(first(inventory.conflicting, 5), ", "),
            isempty(inventory.unexpected) ? "" :
                "no esperados $(length(inventory.unexpected)): " *
                join(first(inventory.unexpected, 5), ", "),
        ]), " | ")
        return MergeReport(
            String(shard_root), String(output_directory), false, inventory,
            Dict{String,Int}(), detail,
        )
    end

    mkpath(output_directory)
    order = canonical_merge_order(inventory.complete)
    counts = Dict{String,Int}()
    aggregate_files = ("configuration_summary.csv", "paired_statistics.csv")
    file_names = sort(unique(reduce(vcat, [
        [file for file in readdir(shard_directory(shard_root, task))
         if endswith(file, ".csv") && !(file in aggregate_files)]
        for task in order
    ])))
    for file in file_names
        frames = DataFrame[]
        for task in order
            path = joinpath(shard_directory(shard_root, task), file)
            isfile(path) || continue
            push!(frames, CSV.read(path, DataFrame))
        end
        isempty(frames) && continue
        merged = canonical_row_sort(reduce(vcat, frames; cols=:union))
        CSV.write(joinpath(output_directory, file), merged)
        counts[file] = nrow(merged)
    end

    # The configuration metadata of the first shard describes the campaign; copy it verbatim so
    # the merged directory is a readable result directory rather than a pile of CSVs.
    metadata = joinpath(shard_directory(shard_root, first(order)), "experiment_config.json")
    isfile(metadata) && cp(metadata, joinpath(output_directory, "experiment_config.json");
                           force=true)

    aggregates = recompute_campaign_aggregates(output_directory)
    counts["configuration_summary.csv"] = aggregates.configurations
    counts["paired_statistics.csv"] = aggregates.paired_rows

    return MergeReport(
        String(shard_root), String(output_directory), true, inventory, counts,
        "fusionados $(length(order)) shards en orden canónico de manifiesto; agregados " *
        "recomputados sobre $(aggregates.matched_pairs) pares (instancia, réplica)",
    )
end
