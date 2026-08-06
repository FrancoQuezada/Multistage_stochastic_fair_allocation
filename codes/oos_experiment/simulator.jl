# =====================================================================================
# Sequential out-of-sample simulator.
#
# For every replication and period: reveal the current realization, construct the
# controller-specific remaining-horizon information structure, solve the selected fairness
# model, extract the current shared mode and physical flows, validate the action, implement
# only the current period, and update the physical and fairness states.
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
"""
function build_instance_template(config::OOSExperimentConfig)
    isfile(config.instance_file) || error("No existe el archivo de instancia: $(config.instance_file)")
    instance = generateInstance(
        config.in_sample_stages, config.in_sample_children, config.in_sample_periods_per_stage,
        config.households, config.instance_file, config.theta, config.avg_demand, config.dev_demand;
        pv_scale=config.pv_scale, demand_profile=config.demand_profile,
    )
    scaleInstance!(instance; battery_scale=config.battery_scale)

    T = instance.T
    length(instance.pv_det) >= T || error(
        "El perfil determinista de PV tiene $(length(instance.pv_det)) períodos y se requieren $T."
    )
    demand_models = assign_demand_models(
        config.households, T, config.avg_demand, config.dev_demand,
        config.demand_profile, demand_profile_rng(config),
    )
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

    template = OOSInstanceTemplate(
        instance.id, config.instance_file, instance.J, T,
        instance.delta, instance.e_c, instance.e_d, instance.s_I, instance.s_min, instance.s_max,
        instance.f_under, instance.f_bar, instance.mu, instance.beta,
        Matrix{Float64}(instance.nu[:, 1:T]), collect(instance.pv_det[1:T]), config.theta,
        demand_models, metadata,
    )
    return (template=template, in_sample_tree=instance.tree, instance=instance)
end

# -------------------------------------------------------------------------------------
# Common look-ahead construction and caching
# -------------------------------------------------------------------------------------

"""
Build the controller's look-ahead structure for one `(replication, period)` pair.

The random stream depends on `(experiment_seed, replication_id, period, controller_kind)` and
never on the allocation/fairness rule, so all six rules under one controller receive exactly
the same forecast, scenario set or tree.
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
    rng = lookahead_rng(config, replication_id, period, controller)
    if controller === DETERMINISTIC_RH
        forecast = conditional_mean_path(provider, history, period, horizon_end)
        return deterministic_lookahead_tree(forecast)
    elseif controller === TWO_STAGE_RH
        scenarios = conditional_scenario_paths(
            provider, history, period, horizon_end, config.two_stage_scenarios, rng,
        )
        return two_stage_lookahead_tree(
            history.pv[period], collect(history.demand[:, period]),
            scenarios, period, horizon_end,
        )
    elseif controller === MULTISTAGE_RH
        spec = BranchingSpec(config.multistage_branching, config.multistage_periods_per_stage)
        conditional = conditional_scenario_tree(provider, history, period, horizon_end, spec, rng)
        return lookahead_from_conditional_tree(conditional, MULTISTAGE_RH)
    end
    error("Controlador no soportado: $controller.")
end

"""
Precompute every look-ahead structure of one replication.

The observed history at period `t` is exactly the out-of-sample prefix and does not depend on
the implemented actions, so the cache is exact rather than approximate: all configurations of
this replication consume literally the same look-ahead objects.
"""
function cache_lookahead_trees(
    provider::RepositoryUncertaintyProvider,
    config::OOSExperimentConfig,
    template::OOSInstanceTemplate,
    path::OOSPath,
)
    cache = Dict{Tuple{Int,ControllerKind},LookaheadTree}()
    for t in 1:template.T
        history = ObservedHistory(t, collect(path.pv[1:t]), collect(path.demand[:, 1:t]))
        for controller in config.controller_set
            cache[(t, controller)] = build_lookahead_tree(
                provider, config, controller, history, t, template.T, path.replication_id,
            )
        end
    end
    return cache
end

# -------------------------------------------------------------------------------------
# One configuration
# -------------------------------------------------------------------------------------

"""
Simulate one configuration: replication x controller x allocation/fairness rule.

Aborts the configuration on the first invalid solve or physical violation, keeping the partial
records and diagnostics. There is no fallback action, no action copied from another
controller, and no clipped action.
"""
function simulate_configuration(
    template::OOSInstanceTemplate,
    config::OOSExperimentConfig,
    path::OOSPath,
    lookahead_cache::Dict{Tuple{Int,ControllerKind},LookaheadTree},
    controller::ControllerKind,
    fairness::FairnessPolicy,
    static_shares::Matrix{Float64};
    verbose::Bool=false,
)
    state = initial_simulation_state(template, path.replication_id)
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

    for t in 1:template.T
        reveal_period!(state, path, t)
        observation = PeriodObservation(t, path.pv[t], collect(path.demand[:, t]))
        tree = lookahead_cache[(t, controller)]

        mip_start = nothing
        if config.use_warm_starts && previous_tree !== nothing && previous_flows !== nothing
            mip_start = try
                derive_mode_start_from_previous(
                    previous_tree, previous_flows.charge, previous_flows.discharge, tree;
                    flow_tol=config.flow_tol,
                )
            catch
                nothing
            end
        end

        result = solve_current_action(
            template, state, observation, tree, controller, fairness, config;
            mip_start=mip_start, static_shares=static_shares,
        )
        total_build += result.build_time_sec
        total_solve += result.solve_time_sec

        if !result.solved || result.action === nothing
            optimization_failures += 1
            failure = "Período $t: $(result.failure_message)"
            verbose && println("    [FALLA] ", failure)
            break
        end

        action = result.action
        validation = validate_period_action(template, state, action, config)
        if !validation.valid
            physical_violations += 1
            failure = "Período $t: acción implementada inválida :: " *
                      join(validation.violations, " | ")
            verbose && println("    [FALLA] ", failure)
            break
        end

        push!(pea_tolerances, result.pea.tolerance_used)
        result.pea.applicable && result.pea.strict_feasible && (pea_strict_feasible_periods += 1)

        household_cost = action_household_costs(template, action)
        # Only the current-period action is implemented; every future decision is discarded.
        apply_action!(state, template, action, validation.soc_after)

        push!(records, PeriodRecord(
            path.replication_id, controller, fairness, t,
            path.pv[t], collect(path.demand[:, t]), action, household_cost,
            copy(state.cumulative_pv), copy(state.cumulative_demand),
            copy(state.cumulative_operating_cost), copy(state.cumulative_all_grid_cost),
            result.soc_before, validation.soc_after, validation, result,
            lookahead_node_count(tree), lookahead_scenario_count(tree),
        ))

        previous_tree = tree
        previous_flows = result.plan_aggregate_flows
    end

    completed = length(records) == template.T && isempty(failure)
    return ReplicationRun(
        path.replication_id, controller, fairness, completed, length(records), records,
        state, failure, optimization_failures, physical_violations, total_build, total_solve,
        pea_tolerances, pea_strict_feasible_periods,
    )
end
