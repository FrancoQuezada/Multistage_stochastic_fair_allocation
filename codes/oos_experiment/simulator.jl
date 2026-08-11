# =====================================================================================
# Sequential out-of-sample simulator.
#
# For every replication and rolling start: reveal the current realization, construct the
# common look-ahead information structure over the FIXED moving window `t : t+L-1`, solve the
# selected fairness model, extract the ordered block of committed actions, validate each one,
# implement them in order, and update the physical and fairness states after each.
#
# STAGE 4. The loop runs over `rolling_iteration_starts(config)` and every optimization spans
# exactly `lookahead_horizon` abstract periods. It no longer iterates `1:template.T` over the
# shrinking interval `t:template.T`, and the terminal state-of-charge target now binds at the
# end of each moving window rather than permanently at the repository horizon.
#
# STAGE 6. At each rolling start the COMPLETE known prefix `t : t+h-1` is revealed in one step,
# before any controller optimizes, so none can be handed more realized information than another.
# One solve then produces the whole ordered block of committed actions, which are validated and
# implemented period by period with the physical and fairness state advancing after each. A final
# non-divisible block may run past `H`: it is committed and validated in full, and only its
# intersection with `1:H` produces records and enters the reported metrics.
#
# PARALLEL READINESS (plan section 4.9). `simulate_configuration` is a self-contained serial
# kernel: it reads an immutable `OOSRollingContext`, an immutable path and an immutable
# look-ahead cache, and writes only into its own freshly allocated `SimulationState`. Two
# invocations share nothing mutable, so they cannot interfere in any order.
#
# Configurations never share mutable state, and the previous mode is never carried as an
# optimization state: no switching cost, startup cost, minimum duration or transition rule
# exists in the common mathematical model, so the previous mode is stored for reporting only.
# =====================================================================================

"""One implemented period of one configuration."""
struct PeriodRecord
    replication_id::Int
    controller::ControllerKind
    fairness::FairnessPolicy
    period::Int
    realized_pv::Float64
    realized_demand::Vector{Float64}
    action::PeriodAction
    household_cost::Vector{Float64}
    cumulative_pv::Vector{Float64}
    cumulative_demand::Vector{Float64}
    cumulative_cost::Vector{Float64}
    cumulative_benchmark::Vector{Float64}
    soc_before::Float64
    soc_after::Float64
    validation::ActionValidation
    result::ControllerResult
    lookahead_nodes::Int
    lookahead_scenarios::Int

    """
    Identifier of the conditional support this action's look-ahead was derived from.

    Stage 5: the three controllers at one rolling start report the SAME value, which is what
    makes the common-support claim auditable from the records rather than only from the code.
    It reaches the result CSVs in stage 10, which owns the output schema.
    """
    scenario_support_id::String

    """
    Rolling start whose solve committed this period (stage 10).

    With `h = 1` it equals `period`; with `h > 1` several records share one rolling start, which
    is what lets an analysis group a committed block back together. The block boundaries
    themselves are derivable from it through `implementation_block` / `evaluation_block`, so they
    are not stored twice.
    """
    rolling_start::Int
end

"""One completed (or aborted) configuration: replication x controller x fairness rule."""
struct ReplicationRun
    replication_id::Int
    controller::ControllerKind
    fairness::FairnessPolicy
    completed::Bool
    periods_completed::Int
    records::Vector{PeriodRecord}
    final_state::SimulationState
    failure_message::String
    optimization_failures::Int
    physical_violations::Int
    total_build_time_sec::Float64
    total_solve_time_sec::Float64

    """Raw per-period PEA band in kWh, one entry per solved period. Preserved so the
    configuration-level pooled statistics can be reproduced from the outputs."""
    pea_tolerances::Vector{Float64}
    pea_strict_feasible_periods::Int
end

# -------------------------------------------------------------------------------------
# Instance template
# -------------------------------------------------------------------------------------

"""
Build the read-only instance template from the repository's verified instance pipeline.

`generateInstance` and `scaleInstance!` supply the physical parameters, the price matrix and
the deterministic PV profile. The stochastic structure is owned by the uncertainty provider,
whose household demand models are drawn once ex ante from a dedicated stream.

`household_profiles` is an additive escape hatch for the structural instance catalog
(`structural_catalog.jl`): when a vector of profile labels is supplied, the household demand
models are built from it verbatim and NOTHING is re-sampled. The default `nothing` keeps the
legacy behaviour exactly — the same `assign_demand_models` draw from the same
`demand_profile_rng` stream, and the same `metadata` contents — so the single-instance campaign is
unaffected.

`repository_seed_override` is likewise structural-only. `nothing` preserves the repository's
theta-dependent legacy seed exactly; the structural catalog supplies its uncertainty-independent
deterministic-base seed explicitly. The override is never inferred from the campaign configuration.
"""
function build_instance_template(
    config::OOSExperimentConfig;
    household_profiles::Union{Nothing,AbstractVector{<:AbstractString}}=nothing,
    repository_seed_override::Union{Nothing,Int}=nothing,
)
    isfile(config.instance_file) || error("No existe el archivo de instancia: $(config.instance_file)")
    instance = generateInstance(
        config.in_sample_stages, config.in_sample_children, config.in_sample_periods_per_stage,
        config.households, config.instance_file, config.theta, config.avg_demand, config.dev_demand;
        pv_scale=config.pv_scale, demand_profile=config.demand_profile,
        repository_seed_override=repository_seed_override,
    )
    scaleInstance!(instance; battery_scale=config.battery_scale)

    T = instance.T
    length(instance.pv_det) >= T || error(
        "El perfil determinista de PV tiene $(length(instance.pv_det)) períodos y se requieren $T."
    )
    demand_models = if household_profiles === nothing
        assign_demand_models(
            config.households, T, config.avg_demand, config.dev_demand,
            config.demand_profile, demand_profile_rng(config),
        )
    else
        length(household_profiles) == config.households || error(
            "Se recibieron $(length(household_profiles)) perfiles fijos y la configuración " *
            "declara $(config.households) hogares."
        )
        structural_demand_models(
            household_profiles, T, config.avg_demand, config.dev_demand,
        )
    end
    metadata = Dict{String,Any}(
        "instance_id" => instance.id,
        "instance_file" => config.instance_file,
        "in_sample_tree" => "S=$(config.in_sample_stages),C=$(config.in_sample_children),P=$(config.in_sample_periods_per_stage)",
        "in_sample_nodes" => instance.tree.V,
        "battery_scale" => config.battery_scale,
        "pv_scale" => config.pv_scale,
        "demand_profile" => config.demand_profile,
        "household_profiles" => [model.profile for model in demand_models],
    )
    # Added only on the structural path, so the legacy default template metadata — and therefore
    # `experiment_config.json` — is byte-identical to before.
    if household_profiles !== nothing
        metadata["household_profile_source"] = "structural_catalog_fixed_assignment"
    end
    if repository_seed_override !== nothing
        metadata["repository_generator_seed_source"] =
            "structural_deterministic_base_explicit_override"
        metadata["actual_repository_generator_seed"] = repository_seed_override
    end

    template = OOSInstanceTemplate(
        instance.id, config.instance_file, instance.J, T,
        instance.delta, instance.e_c, instance.e_d, instance.s_I, instance.s_min, instance.s_max,
        instance.f_under, instance.f_bar, instance.mu, instance.beta,
        Matrix{Float64}(instance.nu[:, 1:T]), collect(instance.pv_det[1:T]), config.theta,
        demand_models, metadata,
    )
    # Exact API compatibility on the ordinary path: retain the accepted three-field NamedTuple.
    # Only an explicit structural override adds the fourth, unambiguous actual-seed field.
    if repository_seed_override === nothing
        return (template=template, in_sample_tree=instance.tree, instance=instance)
    end
    return (
        template=template,
        in_sample_tree=instance.tree,
        instance=instance,
        actual_repository_generator_seed=repository_seed_override,
    )
end

# -------------------------------------------------------------------------------------
# Common look-ahead construction and caching
# -------------------------------------------------------------------------------------

"""
Assert that the realized trajectory covers every period the contract will commit.

Stage 6 implements the COMPLETE block `t : t+h-1` at every rolling start, including a final block
that runs past the evaluation horizon. The realized path must therefore reach
`realized_period_end(config)`, and a path built for a different contract is rejected by naming
both endpoints rather than by indexing off its end.
"""
function assert_realized_path_covers_blocks(config::OOSExperimentConfig, path::OOSPath)
    required = realized_period_end(config)
    path.horizon >= required || error(
        "La trayectoria realizada cubre $(path.horizon) períodos y el contrato temporal " *
        "(H=$(config.evaluation_horizon), h=$(config.implementation_step)) compromete hasta " *
        "el período $required."
    )
    return nothing
end

"""
Build the controller's look-ahead structure for one `(replication, rolling start)` pair.

`horizon_end` is the end of the fixed moving window, `t + L - 1`, not the repository horizon.

STAGE 5. This no longer samples per controller. It generates the one conditional support of this
`(replication, rolling start)` — from a stream keyed by `(experiment_seed, replication, rolling
start)` and by nothing else — and returns the requested controller's VIEW of it. All three
methods therefore share the same leaf paths and leaf probabilities, and all six fairness rules
under any controller share the identical object.

Callers that need several views of the same support should build it once with
`build_common_conditional_support` rather than calling this repeatedly, which is what
`cache_common_supports` does.
"""
function build_lookahead_tree(
    provider::RepositoryUncertaintyProvider,
    config::OOSExperimentConfig,
    controller::ControllerKind,
    history::ObservedHistory,
    period::Int,
    horizon_end::Int,
    replication_id::Int,
)
    support = build_common_conditional_support(
        provider, config, history, period, horizon_end, replication_id,
    )
    return support_view(support, controller)
end

"""
Precompute every look-ahead structure of one replication, one per `(rolling start, controller)`.

The observed history at rolling start `t` is exactly the out-of-sample prefix and does not depend
on the implemented actions, so the cache is exact rather than approximate: all configurations of
this replication consume literally the same look-ahead objects.

Each window spans `t : lookahead_end_period(config, t)`, which is `L` abstract periods for every
start including the last one. The window can reach past the repository horizon; the context's
extended support is what makes that well defined.
"""
function cache_lookahead_trees(
    provider::RepositoryUncertaintyProvider,
    context::OOSRollingContext,
    path::OOSPath,
)
    config = context.config
    assert_realized_path_covers_blocks(config, path)
    supports = Dict{Int,OOSCommonConditionalSupport}()
    trees = Dict{Tuple{Int,ControllerKind},LookaheadTree}()
    for t in rolling_iteration_starts(config)
        horizon_end = lookahead_end_period(config, t)
        assert_supported_period(context, horizon_end)
        # The history covers the COMPLETE known prefix `1 : t+h-1`, which is what every
        # controller of this rolling start conditions on.
        prefix_end = last(implementation_block(config, t))
        history = ObservedHistory(
            prefix_end, collect(path.pv[1:prefix_end]), collect(path.demand[:, 1:prefix_end]),
        )
        # ONE support per rolling start. Every controller of this start is a view of it, so the
        # three methods cannot differ through their sampling.
        support = build_common_conditional_support(
            provider, config, history, t, horizon_end, path.replication_id,
        )
        supports[t] = support
        for controller in config.controller_set
            trees[(t, controller)] = support_view(support, controller)
        end
    end
    return OOSLookaheadCache(supports, trees)
end

"""Retained pre-stage-4 call shape; it materializes the context the new signature needs."""
cache_lookahead_trees(
    provider::RepositoryUncertaintyProvider,
    config::OOSExperimentConfig,
    template::OOSInstanceTemplate,
    path::OOSPath,
) = cache_lookahead_trees(provider, OOSRollingContext(config, template), path)

# -------------------------------------------------------------------------------------
# One configuration
# -------------------------------------------------------------------------------------

"""
Simulate one configuration: replication x controller x allocation/fairness rule.

One solve per rolling start over the fixed `L`-period moving window; one implemented period per
solve. Aborts the configuration on the first invalid solve or physical violation, keeping the
partial records and diagnostics. There is no fallback action, no action copied from another
controller, and no clipped action.

Self-contained serial kernel: everything it reads is immutable and everything it writes lives in
its own `SimulationState`, so independent invocations cannot interfere.
"""
function simulate_configuration(
    context::OOSRollingContext,
    path::OOSPath,
    lookahead_cache::OOSLookaheadCache,
    controller::ControllerKind,
    fairness::FairnessPolicy,
    static_shares::Union{Matrix{Float64},OOSStaticShareTable};
    verbose::Bool=false,
)
    config = context.config
    assert_realized_path_covers_blocks(config, path)
    state = initial_simulation_state(context, path.replication_id)
    records = PeriodRecord[]
    failure = ""
    optimization_failures = 0
    physical_violations = 0
    # One entry per solved period; 0.0 whenever the strict rule held or PEA does not apply.
    pea_tolerances = Float64[]
    pea_strict_feasible_periods = 0
    total_build = 0.0
    total_solve = 0.0
    previous_tree = nothing
    previous_flows = nothing

    aborted = false
    for t in rolling_iteration_starts(config)
        block = implementation_block(config, t)
        evaluated = evaluation_block(config, t)
        # The COMPLETE known prefix is revealed once, before any controller optimizes, so no
        # controller can receive more or less realized information than another.
        reveal_block!(state, path, block)
        observation = PeriodObservation(t, path.pv[t], collect(path.demand[:, t]))
        tree = lookahead_cache[(t, controller)]

        mip_start = nothing
        if config.use_warm_starts && previous_tree !== nothing && previous_flows !== nothing
            # A warm start is solver guidance. If deriving one fails for any reason the solve
            # proceeds cold: the mathematical model and the implemented action are identical
            # either way, and stage 9 forbids a failed start from changing either.
            mip_start = try
                derive_mode_start_from_previous(
                    previous_tree, previous_flows.charge, previous_flows.discharge, tree;
                    flow_tol=config.flow_tol,
                ).start
            catch
                nothing
            end
        end

        result = solve_current_action(
            context, state, observation, tree, controller, fairness, config;
            mip_start=mip_start, static_shares=static_shares,
            implementation_block=block,
        )
        total_build += result.build_time_sec
        total_solve += result.solve_time_sec

        if !result.solved || isempty(result.block_actions)
            optimization_failures += 1
            failure = "Bloque $block: $(result.failure_message)"
            verbose && println("    [FALLA] ", failure)
            break
        end
        length(result.block_actions) == length(block) || error(
            "El solve del bloque $block devolvió $(length(result.block_actions)) acciones."
        )

        # One solve per rolling start, but the tolerance/feasibility decision it produces governs
        # every period the block implements. `pea_tolerances` and `pea_strict_feasible_periods`
        # are period-counted (they feed configuration_summary.csv's PeriodsSolved and the
        # downstream reader's independent per-period recomputation), so with h > 1 the block's
        # single decision is recorded once per EVALUATED period, not once per solve — recording
        # it once per block silently undercounted by a factor of h whenever h > 1.
        for _ in 1:length(evaluated)
            push!(pea_tolerances, result.pea.tolerance_used)
        end
        result.pea.applicable && result.pea.strict_feasible &&
            (pea_strict_feasible_periods += length(evaluated))

        # Implement the block period by period, updating the physical and fairness state after
        # each one. EVERY committed period is validated, including any that runs past `H`; only
        # the evaluated portion produces a record.
        entry_soc = state.soc_before
        for (offset, action) in enumerate(result.block_actions)
            period = first(block) + offset - 1
            action.period == period || error(
                "La acción $offset del bloque corresponde al período $(action.period) y se " *
                "esperaba $period."
            )
            validation = validate_period_action(
                context, state, action, config; lookahead_end=tree.last_period,
            )
            if !validation.valid
                physical_violations += 1
                failure = "Período $period del bloque $block: acción implementada inválida :: " *
                          join(validation.violations, " | ")
                verbose && println("    [FALLA] ", failure)
                aborted = true
                break
            end

            household_cost = action_household_costs(context, action)
            # Captured BEFORE the state advances: this is the state of charge entering THIS
            # period, not the one entering the block. With `h > 1` the two differ for every
            # period after the first, and `result.soc_before` is the block's entering value.
            period_soc_before = state.soc_before
            apply_action!(state, context, action, validation.soc_after)

            if period in evaluated
                push!(records, PeriodRecord(
                    path.replication_id, controller, fairness, period,
                    path.pv[period], collect(path.demand[:, period]), action, household_cost,
                    copy(state.cumulative_pv), copy(state.cumulative_demand),
                    copy(state.cumulative_operating_cost), copy(state.cumulative_all_grid_cost),
                    period_soc_before, validation.soc_after, validation, result,
                    lookahead_node_count(tree), lookahead_scenario_count(tree),
                    cached_support_id(lookahead_cache, t), t,
                ))
            end
        end
        aborted && break

        # STAGE 9. The state that will be handed to the next rolling solve must be exactly the
        # one this block produced: continuous, admissible, and reproducible by replaying the
        # implemented flows. An unrecoverable state stops the configuration; nothing is repaired.
        recoverability = check_state_recoverability(
            context, state, block, entry_soc, result.block_actions, config,
        )
        if !recoverability.recoverable
            physical_violations += 1
            failure = "Bloque $block: el estado transportado al siguiente solve no es " *
                      "recuperable :: " * join(recoverability.violations, " | ")
            verbose && println("    [FALLA] ", failure)
            break
        end

        previous_tree = tree
        previous_flows = result.plan_aggregate_flows
    end

    # One record per EVALUATED period. The committed periods beyond `H` of a final non-divisible
    # block were implemented and validated, but they never enter the reported metrics.
    completed = length(records) == config.evaluation_horizon && isempty(failure)
    return ReplicationRun(
        path.replication_id, controller, fairness, completed, length(records), records,
        state, failure, optimization_failures, physical_violations, total_build, total_solve,
        pea_tolerances, pea_strict_feasible_periods,
    )
end

"""Retained pre-stage-4 call shape; it materializes the context the new signature needs."""
simulate_configuration(
    template::OOSInstanceTemplate,
    config::OOSExperimentConfig,
    path::OOSPath,
    lookahead_cache::OOSLookaheadCache,
    controller::ControllerKind,
    fairness::FairnessPolicy,
    static_shares::Union{Matrix{Float64},OOSStaticShareTable};
    verbose::Bool=false,
) = simulate_configuration(
    OOSRollingContext(config, template), path, lookahead_cache, controller, fairness,
    static_shares; verbose=verbose,
)
