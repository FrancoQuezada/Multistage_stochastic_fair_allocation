# =====================================================================================
# Common conditional stochastic support (OOS redesign stage 5).
#
# Before this stage each controller sampled its own look-ahead from a stream keyed by
# `(experiment_seed, replication, period, controller)`. Two-stage and multistage therefore saw
# unrelated Monte Carlo draws, and the deterministic controller followed an analytic conditional
# mean generated separately from both. Any measured difference between the three methods mixed
# the effect of the information structure with the effect of having received different samples.
#
# Stage 5 generates ONE conditional multistage support per
#
#     (structural instance, uncertainty level, OOS replication, rolling start)
#
# and derives all three methods from it (plan section 4.3):
#
#   MULTISTAGE_RH    the complete tree, with its intermediate nonanticipativity
#   TWO_STAGE_RH     the SAME leaf paths and leaf probabilities, without intermediate
#                    nonanticipativity after the known prefix
#   DETERMINISTIC_RH the probability-weighted mean of those same leaves, period by period
#
# The controller is structurally absent from the seed, and so are the fairness policy, the solver
# phase, the worker and the execution order. What remains is exactly the information structure,
# which is the quantity the experiment is trying to measure.
#
# PARALLEL READINESS (plan section 4.9). A support object is immutable once built, carries no RNG
# and is a pure function of its seed key. The cache below is task-local and read-only, so one
# support is reused literally across both battery variants, all three controllers and all six
# fairness policies without any of them being able to perturb another.
# =====================================================================================

"""
Random stream of the conditional support on the single-instance path.

It replaces the retired `lookahead` stream, whose key included the controller. The
manifest-driven structural path has its own richer key and its own stream name
(`OOS_CONDITIONAL_SUPPORT_STREAM = "conditional_support"` in `structural_catalog.jl`), exactly as
the legacy `oos_path` stream coexists with the structural `structural_oos_path`.
"""
const OOS_LOOKAHEAD_SUPPORT_STREAM = "lookahead_support"

"""Identifier prefix of a conditional support object."""
const OOS_SCENARIO_SUPPORT_ID_PREFIX = "SS"

"""Length of the digest inside a `ScenarioSupportID`."""
const OOS_SCENARIO_SUPPORT_DIGEST_LENGTH = 12

"""
Seed of the conditional support at one rolling start of one replication.

Keys: experiment seed, replication, rolling start.

Excludes, structurally rather than by convention: the controller, the fairness policy, the solver
phase, the worker, the retry count and the execution order. The controller exclusion is the whole
point of this stage.
"""
function lookahead_support_seed(
    experiment_seed::Int,
    replication_id::Int,
    rolling_start::Int,
)
    rolling_start >= 1 || error(
        "El inicio de iteración debe ser >= 1; se recibió $rolling_start."
    )
    return oos_stream_seed(
        experiment_seed, OOS_LOOKAHEAD_SUPPORT_STREAM, replication_id, rolling_start,
    )
end

"""RNG of the conditional support at one rolling start of one replication."""
lookahead_support_rng(config::OOSExperimentConfig, replication_id::Int, rolling_start::Int) =
    MersenneTwister(lookahead_support_seed(config.experiment_seed, replication_id, rolling_start))

"""
One conditional stochastic support, shared by every method at one rolling start.

`tree` is the multistage object: a genuine filtration in which two scenarios that share a history
share the same node, hence the same shared-battery mode variable. The two-stage and deterministic
representations are *views* of it, never independent samples.

Immutable and reusable: the three view builders below allocate fresh `LookaheadTree`s and never
write back into the support.
"""
struct OOSCommonConditionalSupport
    scenario_support_id::String
    replication_id::Int
    rolling_start::Int
    first_period::Int
    last_period::Int
    seed_stream::String
    seed::Int
    branching::Vector{Int}
    periods_per_stage::Vector{Int}

    """
    Length `h` of the deterministic initial information stage. Its periods carry the realized
    known prefix, are common to every scenario and to every method, and branching cannot begin
    before `first_period + known_prefix`.
    """
    known_prefix::Int

    tree::ConditionalTree
    leaf_nodes::Vector{Int}
    leaf_probability::Vector{Float64}
end

"""Number of leaves, i.e. the common scenario count every method is derived from."""
support_leaf_count(support::OOSCommonConditionalSupport) = length(support.leaf_nodes)

"""Number of abstract periods the support spans."""
support_period_count(support::OOSCommonConditionalSupport) =
    support.last_period - support.first_period + 1

"""
Deterministic identifier of one conditional support.

Built from the seed contract and the resolved tree geometry, through the canonical JSON writer
and the repository's persisted digest, so it is stable across processes and Julia versions. It
deliberately contains no controller, fairness policy, worker or ordering information: two
controllers at the same rolling start must report the SAME `ScenarioSupportID`, which is what
makes the common-support claim auditable from the outputs.
"""
function scenario_support_id(
    seed_stream::AbstractString,
    seed::Int,
    first_period::Int,
    last_period::Int,
    branching::AbstractVector{Int},
    periods_per_stage::AbstractVector{Int},
    node_count::Int,
    leaf_count::Int,
)
    payload = Dict{String,Any}(
        "seed_stream" => String(seed_stream),
        "seed" => seed,
        "first_period" => first_period,
        "last_period" => last_period,
        "branching" => collect(branching),
        "periods_per_stage" => collect(periods_per_stage),
        "nodes" => node_count,
        "leaves" => leaf_count,
    )
    digest = oos_stable_digest(canonical_json(payload))
    return string(
        OOS_SCENARIO_SUPPORT_ID_PREFIX, "-",
        digest[1:min(OOS_SCENARIO_SUPPORT_DIGEST_LENGTH, length(digest))],
    )
end

"""
Generate the one conditional support of a `(replication, rolling start)` pair.

`history` must end at `rolling_start`, so the support is conditioned on the enlarged realized
history exactly as the rolling contract requires. A fresh support is generated at every rolling
start: the experiment never keeps one tree for a whole replication and never prunes or updates a
previous tree in place (plan section 4.2).

`rng` is explicit. Callers that do not supply one get the documented seed, which is the only
thing that makes the object reproducible and order-independent.
"""
function build_common_conditional_support(
    provider::RepositoryUncertaintyProvider,
    config::OOSExperimentConfig,
    history::ObservedHistory,
    rolling_start::Int,
    horizon_end::Int,
    replication_id::Int;
    rng::Union{Nothing,AbstractRNG}=nothing,
)
    seed = lookahead_support_seed(config.experiment_seed, replication_id, rolling_start)
    generator = rng === nothing ? MersenneTwister(seed) : rng
    spec = BranchingSpec(config.multistage_branching, config.multistage_periods_per_stage)
    prefix = known_prefix_length(config)
    tree = conditional_scenario_tree(
        provider, history, rolling_start, horizon_end, spec, generator; known_prefix=prefix,
    )

    leaf_nodes = [scenario[end] for scenario in tree.scenarios]
    leaf_probability = [tree.probability[leaf] for leaf in leaf_nodes]
    total = sum(leaf_probability)
    abs(total - 1.0) <= sqrt(eps()) * max(1.0, length(leaf_probability)) || error(
        "Las probabilidades de hoja del soporte común suman $total en lugar de 1."
    )

    resolved_periods, resolved_branching = multistage_stage_layout_with_prefix(
        horizon_end - rolling_start + 1, config.multistage_branching,
        config.multistage_periods_per_stage, prefix,
    )
    identifier = scenario_support_id(
        OOS_LOOKAHEAD_SUPPORT_STREAM, seed, rolling_start, horizon_end,
        resolved_branching, resolved_periods, length(tree.parent), length(leaf_nodes),
    )

    return OOSCommonConditionalSupport(
        identifier, replication_id, rolling_start, rolling_start, horizon_end,
        OOS_LOOKAHEAD_SUPPORT_STREAM, seed,
        resolved_branching, resolved_periods, prefix,
        tree, leaf_nodes, leaf_probability,
    )
end

"""
Nodes of the deterministic known prefix, from the root to its last period, in order.

The prefix is branch-free by construction, so this chain is unique; the check below is what
makes that a verified property of the object rather than an assumption of its consumers.
"""
function support_prefix_nodes(support::OOSCommonConditionalSupport)
    tree = support.tree
    nodes = Int[first(first(tree.scenarios))]
    for offset in 1:(support.known_prefix - 1)
        period = support.first_period + offset
        children = [n for n in eachindex(tree.parent) if tree.parent[n] == last(nodes)]
        length(children) == 1 || error(
            "El prefijo conocido debe ser una cadena determinista; el nodo $(last(nodes)) " *
            "tiene $(length(children)) hijos en el período $period."
        )
        child = only(children)
        tree.calendar_period[child] == period || error(
            "El nodo $child del prefijo está en el período $(tree.calendar_period[child]) y se " *
            "esperaba $period."
        )
        push!(nodes, child)
    end
    return nodes
end

# -------------------------------------------------------------------------------------
# The three derived views
# -------------------------------------------------------------------------------------

"""
`MULTISTAGE_RH` view: the complete tree, with its intermediate nonanticipativity intact.
"""
multistage_support_view(support::OOSCommonConditionalSupport) =
    lookahead_from_conditional_tree(support.tree, MULTISTAGE_RH, support_leaf_count(support))

"""
`TWO_STAGE_RH` view: the SAME leaf paths and leaf probabilities, with intermediate
nonanticipativity removed after the root.

Each root-to-leaf path of the multistage tree becomes one independent future chain carrying that
leaf's probability. No value is resampled and no probability is renormalized: the two structures
are two readings of one object, which is exactly what isolates the information structure.
"""
function two_stage_support_view(support::OOSCommonConditionalSupport)
    tree = support.tree
    root = first(first(tree.scenarios))
    root_pv = tree.pv[root]
    root_demand = collect(tree.demand[:, root])

    scenarios = ScenarioPath[]
    for (index, path) in enumerate(tree.scenarios)
        length(path) == support_period_count(support) || error(
            "El escenario $index del soporte común cubre $(length(path)) nodos y la ventana " *
            "tiene $(support_period_count(support)) períodos."
        )
        push!(scenarios, ScenarioPath(
            support.first_period, support.last_period, support.leaf_probability[index],
            [tree.pv[n] for n in path], tree.demand[:, path],
        ))
    end
    return two_stage_lookahead_tree(
        root_pv, root_demand, scenarios, support.first_period, support.last_period;
        known_prefix=support.known_prefix,
    )
end

"""
`DETERMINISTIC_RH` view: the probability-weighted mean of the same leaves, period by period.

    pv_mean[k]        = sum_s p_s * pv_s[k]
    demand_mean[j, k] = sum_s p_s * demand_s[j, k]

Entry 1 is copied verbatim from the observed root rather than averaged, so the realized current
period stays exact rather than acquiring round-off from a weighted sum of identical values.

No PEA repair is applied here, and applying one would be wrong. Every leaf was already repaired
when it was sampled, so each satisfies `sum_j D_j >= C`; averaging preserves the inequality, and
repairing again would move the mean away from the leaves it must be derived from.
"""
function deterministic_support_view(support::OOSCommonConditionalSupport)
    tree = support.tree
    n = support_period_count(support)
    households = size(tree.demand, 1)
    pv = zeros(n)
    demand = zeros(households, n)

    for (index, path) in enumerate(tree.scenarios)
        weight = support.leaf_probability[index]
        for (k, node) in enumerate(path)
            pv[k] += weight * tree.pv[node]
            for j in 1:households
                demand[j, k] += weight * tree.demand[j, node]
            end
        end
    end

    root = first(first(tree.scenarios))
    pv[1] = tree.pv[root]
    demand[:, 1] .= @view tree.demand[:, root]

    return deterministic_lookahead_tree(
        ForecastPath(support.first_period, support.last_period, pv, demand),
    )
end

"""Derive the view one controller consumes from the common support."""
function support_view(support::OOSCommonConditionalSupport, controller::ControllerKind)
    controller === MULTISTAGE_RH && return multistage_support_view(support)
    controller === TWO_STAGE_RH && return two_stage_support_view(support)
    controller === DETERMINISTIC_RH && return deterministic_support_view(support)
    error("Controlador no soportado: $controller.")
end

# -------------------------------------------------------------------------------------
# Task-local cache
# -------------------------------------------------------------------------------------

"""
Read-only, task-local cache of one replication's conditional supports and derived views.

One support per rolling start — the controller is NOT part of the key — plus the three views
derived from it. Indexing with `(rolling_start, controller)` returns the view, which keeps the
simulator and the existing fixtures on their familiar call shape while the object behind it is
now shared.

Nothing here is worker-global or mutable after construction, so the same cache can be handed to
every battery variant, controller and fairness policy of a task.
"""
struct OOSLookaheadCache
    supports::Dict{Int,OOSCommonConditionalSupport}
    trees::Dict{Tuple{Int,ControllerKind},LookaheadTree}
end

Base.getindex(cache::OOSLookaheadCache, key::Tuple{Int,ControllerKind}) = cache.trees[key]
Base.haskey(cache::OOSLookaheadCache, key::Tuple{Int,ControllerKind}) = haskey(cache.trees, key)
Base.length(cache::OOSLookaheadCache) = length(cache.trees)
Base.keys(cache::OOSLookaheadCache) = keys(cache.trees)

"""The support every controller at `rolling_start` was derived from."""
cached_support(cache::OOSLookaheadCache, rolling_start::Int) = cache.supports[rolling_start]

"""`ScenarioSupportID` shared by every method at one rolling start."""
cached_support_id(cache::OOSLookaheadCache, rolling_start::Int) =
    cache.supports[rolling_start].scenario_support_id
