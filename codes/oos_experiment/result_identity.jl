# =====================================================================================
# Scientific identity of a result, and the shard interfaces (OOS redesign stage 10).
#
# Until this stage a result row could be read only by reconstructing hidden configuration: which
# structural instance it came from, which conditional support the decision used, which committed
# block the period belonged to, and against what its cost should be compared. Stage 10 makes all
# of that explicit and stable.
#
# TWO SEPARATIONS ARE STRUCTURAL HERE, not conventions:
#
#   1. Scientific identity versus execution provenance. Everything in `OOSRunIdentity` is a
#      deterministic function of the configuration and the instance. Worker number, retry count,
#      wall-clock and solver time live in a SEPARATE file and never key a scientific row. That is
#      what lets a sequential run and a parallel run be compared for equality (plan section 4.9).
#
#   2. Interface versus activation. The shard directory layout, the atomic completion protocol,
#      the conflict detection and the canonical merge order are DEFINED here and exercised by the
#      tests. No worker, scheduler or concurrent writer exists: that is stage 13.
# =====================================================================================

"""
The risk criterion the current objective implements.

The economic objective is expected remaining operating cost, so the criterion is risk-neutral
expectation. It is written to every result row because plan section 4.7 forbids inferring a risk
measure from a method name: `MULTISTAGE_RH` is an information structure, not a risk attitude.
"""
const OOS_OBJECTIVE_CRITERION = "risk_neutral_expectation"

"""Placeholder identity used on the single-instance path, before the manifest drives the run."""
const OOS_SINGLE_INSTANCE_STRUCTURAL_ID = "SI-single-instance"

"""Prefix of a parallel task identifier."""
const OOS_TASK_ID_PREFIX = "TK"

"""File written inside a shard directory when, and only when, the shard is complete."""
const OOS_SHARD_COMPLETION_MARKER = "_COMPLETE"

"""
Everything needed to identify one result scientifically, and nothing that identifies a run.

Every field is a deterministic function of the configuration and the instance. Two processes
building this for the same task produce the same object, which is exactly why it may key a row
while `worker`, `retry` and any timing may not.

The structural fields are degenerate on the single-instance path: they carry
`OOS_SINGLE_INSTANCE_STRUCTURAL_ID` and the base instance identity rather than a manifest row.
Stage 13 supplies the real ones. The column exists from stage 10 so the schema does not change
again when it does.
"""
struct OOSRunIdentity
    experiment_id::String
    formulation_id::String
    formulation_variant::String

    # --- structural identity -------------------------------------------------------------
    structural_instance_id::String
    paired_base_id::String
    deterministic_data_id::String
    demand_assignment_id::String
    share_table_id::String
    repository_instance_id::String

    # --- temporal contract, six separate quantities ---------------------------------------
    repository_instance_horizon::Int
    base_profile_length::Int
    evaluation_horizon::Int
    lookahead_horizon::Int
    implementation_step::Int
    required_period_support_end::Int
    realized_period_end::Int

    # --- objective and risk ----------------------------------------------------------------
    objective_criterion::String

    # --- parallel-task identity (defined now, scheduled in stage 13) -----------------------
    parallel_task_id::String
    shard_id::String
end

"""
Build the identity of one campaign run.

`replication` is part of the task identity because the approved schedulable unit is
`(PairedBaseID, OOSReplicationID)` (plan section 4.9). The controller and the fairness policy are
deliberately NOT: one task evaluates all of them, so folding either into the task identity would
split a bundle the design requires to stay intact.
"""
function run_identity(
    config::OOSExperimentConfig,
    context::OOSRollingContext,
    share_table::OOSStaticShareTable,
    replication::Int;
    structural_instance_id::AbstractString=OOS_SINGLE_INSTANCE_STRUCTURAL_ID,
    paired_base_id::AbstractString=OOS_SINGLE_INSTANCE_STRUCTURAL_ID,
    deterministic_data_id::AbstractString=OOS_SINGLE_INSTANCE_STRUCTURAL_ID,
    demand_assignment_id::AbstractString=OOS_SINGLE_INSTANCE_STRUCTURAL_ID,
)
    template = context.template
    task = parallel_task_id(paired_base_id, replication)
    return OOSRunIdentity(
        config.experiment_id,
        config.formulation_id,
        string(config.formulation_variant),
        String(structural_instance_id),
        String(paired_base_id),
        String(deterministic_data_id),
        String(demand_assignment_id),
        share_table.share_table_id,
        template.id,
        template.T,
        template.T,
        config.evaluation_horizon,
        config.lookahead_horizon,
        config.implementation_step,
        required_period_support_end(config),
        realized_period_end(config),
        OOS_OBJECTIVE_CRITERION,
        task,
        task,
    )
end

"""
Deterministic identifier of one schedulable task: `(PairedBaseID, OOSReplicationID)`.

Contains no controller, no fairness policy, no worker, no retry and no ordering. A task that is
re-run — on another worker, in another order, after an interruption — produces the same
identifier, which is what makes a repeated shard recognizable as the same scientific content
rather than as a new one.
"""
parallel_task_id(paired_base_id::AbstractString, replication::Int) =
    string(OOS_TASK_ID_PREFIX, "-", paired_base_id, "-r", replication)

"""
Share table used when a caller writes outputs without supplying an identity.

Resolving the real table needs the provider and the in-sample tree, which a bare writer call does
not have. The placeholder carries a uniform table of the right shape, so the `ShareTableID`
column is well formed and clearly NOT the campaign's — the campaign path always passes its real
identity, and stage 13 always will.
"""
function resolve_static_share_table_placeholder(
    config::OOSExperimentConfig,
    template::OOSInstanceTemplate,
)
    period_end = max(template.T, required_period_support_end(config))
    base = fill(1.0 / template.J, template.J, template.T)
    shares = extend_static_demand_shares(base, template.T, period_end)
    return OOSStaticShareTable(template.J, template.T, period_end, base, shares)
end

"""
Identity for a caller that has only the configuration.

Every temporal and objective field is exact — they come from the configuration — while the
structural and instance fields carry the single-instance placeholder. It exists so a frame
builder can always emit a well-formed identity column; the campaign and stage 13 always pass
their real identity instead.
"""
function placeholder_run_identity(config::OOSExperimentConfig)
    task = parallel_task_id(OOS_SINGLE_INSTANCE_STRUCTURAL_ID, 0)
    return OOSRunIdentity(
        config.experiment_id, config.formulation_id, string(config.formulation_variant),
        OOS_SINGLE_INSTANCE_STRUCTURAL_ID, OOS_SINGLE_INSTANCE_STRUCTURAL_ID,
        OOS_SINGLE_INSTANCE_STRUCTURAL_ID, OOS_SINGLE_INSTANCE_STRUCTURAL_ID,
        "ST-unresolved", "unresolved",
        0, 0,
        config.evaluation_horizon, config.lookahead_horizon, config.implementation_step,
        required_period_support_end(config), realized_period_end(config),
        OOS_OBJECTIVE_CRITERION, task, task,
    )
end

"""Stable scientific key of one result row, in canonical order."""
scientific_row_key(identity::OOSRunIdentity, controller, fairness, period::Int) = (
    identity.structural_instance_id, identity.parallel_task_id,
    string(controller), string(fairness), period,
)

# -------------------------------------------------------------------------------------
# Shard interfaces — defined here, scheduled in stage 13
# -------------------------------------------------------------------------------------

"""Directory one task writes its isolated outputs into. One task, one directory, never shared."""
shard_directory(root::AbstractString, task_id::AbstractString) = joinpath(root, task_id)

"""Path of a shard's completion marker."""
shard_completion_marker(shard_dir::AbstractString) =
    joinpath(shard_dir, OOS_SHARD_COMPLETION_MARKER)

"""`true` when a shard directory carries a completion marker, i.e. it was committed."""
shard_is_complete(shard_dir::AbstractString) = isfile(shard_completion_marker(shard_dir))

"""
Content digest of a finished shard: every file it contains, by name, with its bytes.

Two shards of the same task with identical scientific content produce identical digests, which is
how a repeated execution is accepted as idempotent rather than treated as a conflict. The marker
itself is excluded, since it carries the digest.
"""
function shard_content_digest(shard_dir::AbstractString)
    isdir(shard_dir) || error("No existe el directorio de shard: $shard_dir")
    entries = sort([
        file for file in readdir(shard_dir)
        if isfile(joinpath(shard_dir, file)) && file != OOS_SHARD_COMPLETION_MARKER
    ])
    payload = Dict{String,Any}(
        "files" => [
            Dict{String,Any}("name" => file, "digest" =>
                oos_stable_digest(read(joinpath(shard_dir, file), String)))
            for file in entries
        ],
    )
    return oos_stable_digest(canonical_json(payload))
end

"""
Commit a shard atomically: write, then mark.

The marker is written LAST and carries the content digest. A directory without a marker is
incomplete by definition — a crash mid-write leaves no marker, so a partial shard can never be
mistaken for a finished one. Nothing appends to a shared aggregate file; only the coordinator
merges, and only complete shards.
"""
function commit_shard(shard_dir::AbstractString, task_id::AbstractString)
    isdir(shard_dir) || error("No existe el directorio de shard: $shard_dir")
    digest = shard_content_digest(shard_dir)
    payload = canonical_json(Dict{String,Any}(
        "parallel_task_id" => String(task_id),
        "content_digest" => digest,
        "marker_version" => 1,
    ))
    open(shard_completion_marker(shard_dir), "w") do io
        write(io, payload, "\n")
    end
    return digest
end

"""Outcome of inspecting a shard root before merging."""
struct ShardInventory
    complete::Vector{String}
    incomplete::Vector{String}
    missing_tasks::Vector{String}
    conflicting::Vector{String}

    """
    Committed shards the caller did not ask for.

    A shard root that holds a task outside the expected set means the root and the manifest
    disagree about which campaign this is — leftovers from a previous run in the same directory,
    or a merge requested with a smaller `R` than the shards were produced with. Silently ignoring
    it would publish a dataset smaller than the evidence on disk, so it is refused like any other
    inventory defect.
    """
    unexpected::Vector{String}
end

shard_inventory_ready(inventory::ShardInventory) =
    isempty(inventory.incomplete) && isempty(inventory.missing_tasks) &&
    isempty(inventory.conflicting) && isempty(inventory.unexpected)

"""
Inspect a shard root against the tasks the manifest expects.

Reports, without repairing: complete shards, incomplete ones (present but unmarked), tasks with
no directory at all, and directories whose marker digest disagrees with their current contents.
A conflicting shard is reported rather than silently overwritten — repeated execution is accepted
only when the scientific content is identical.
"""
function inventory_shards(root::AbstractString, expected_tasks::AbstractVector{<:AbstractString})
    complete = String[]
    incomplete = String[]
    missing_tasks = String[]
    conflicting = String[]
    for task in expected_tasks
        directory = shard_directory(root, task)
        if !isdir(directory)
            push!(missing_tasks, task)
        elseif !shard_is_complete(directory)
            push!(incomplete, task)
        else
            marker = canonical_json_parse(read(shard_completion_marker(directory), String))
            if get(marker, "content_digest", "") != shard_content_digest(directory)
                push!(conflicting, task)
            else
                push!(complete, task)
            end
        end
    end
    wanted = Set(String.(expected_tasks))
    unexpected = sort([
        entry for entry in readdir(root)
        if !(entry in wanted) && isdir(joinpath(root, entry)) &&
           shard_is_complete(joinpath(root, entry))
    ])
    return ShardInventory(complete, incomplete, missing_tasks, conflicting, unexpected)
end

"""
Canonical merge order of a set of tasks.

Sorted by identifier, which is a pure function of `(PairedBaseID, OOSReplicationID)`. The order
is therefore the manifest's, never the order in which tasks happened to finish — that is the
property that makes a merged dataset independent of worker count and scheduling.
"""
canonical_merge_order(task_ids::AbstractVector{<:AbstractString}) = sort(collect(task_ids))
