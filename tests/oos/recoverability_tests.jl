# =====================================================================================
# RC0..RC4  Block recoverability and warm starts (OOS redesign stage 9)
#
# Stage 6 made one solve commit `h` periods, so the state handed to the next solve is the product
# of `h` sequential transitions. Stage 9 makes that hand-off checkable rather than assumed, and
# adapts the warm start to a window that MOVES.
#
# The prohibitions are as much the point as the checks: no clipping onto a bound, no rounding, no
# controller substitution, no fallback action, and a failed warm start is a performance problem
# and never permission to change the model or the implemented action.
#
# These sets run inside `tests/oos/runtests.jl` and reuse its helpers.
# =====================================================================================

"""Small stage-9 configuration."""
recovery_config(; kwargs...) = test_config(;
    experiment_seed=909_090, households=3, oos_replications=1,
    controller_set=[MULTISTAGE_RH], fairness_set=[NONE],
    multistage_branching=[2, 2], kwargs...)

# =====================================================================================
# RC0 The recoverability check accepts a legitimate hand-off
# =====================================================================================

@testset "RC0 the recoverability check accepts a legitimate hand-off" begin
    for h in (1, 4, 10)
        config = recovery_config(implementation_step=h)
        common = build_common_objects(config; verbose=false)
        path = common.oos_paths[1]
        cache = cache_lookahead_trees(common.provider, common.context, path)
        run = simulate_configuration(
            common.context, path, cache, MULTISTAGE_RH, NONE, common.share_table,
        )
        # A run that completes has, by construction, passed the check at every rolling start.
        @test run.completed
        @test run.periods_completed == config.evaluation_horizon

        # Re-run the check explicitly on the final block so the property is asserted, not
        # inferred from the absence of a failure.
        final_start = final_rolling_iteration_start(config)
        block = implementation_block(config, final_start)
        actions = run.records[end].result.block_actions
        entry = run.records[findfirst(r -> r.period == first(block), run.records)].soc_before
        report = check_state_recoverability(
            common.context, run.final_state, block, entry, actions, config,
        )
        @test report.recoverable
        @test isempty(report.violations)
        @test report.period == last(block) + 1
        @test report.replay_residual <= max(1, length(block)) * config.feasibility_tol
        @test report.soc_bound_residual <= config.feasibility_tol
    end
end

# =====================================================================================
# RC1 It rejects each way the hand-off can be wrong, and names which
# =====================================================================================

@testset "RC1 it rejects a broken hand-off and names the reason" begin
    config = recovery_config(implementation_step=4)
    common = build_common_objects(config; verbose=false)
    path = common.oos_paths[1]
    cache = cache_lookahead_trees(common.provider, common.context, path)
    run = simulate_configuration(
        common.context, path, cache, MULTISTAGE_RH, NONE, common.share_table,
    )
    @test run.completed
    block = implementation_block(config, 1)
    actions = run.records[1].result.block_actions
    entry = common.template.s_I

    # Replay the first block into a fresh state so the checks below have a real hand-off.
    state = initial_simulation_state(common.context, path.replication_id)
    reveal_block!(state, path, block)
    for record in run.records[1:length(block)]
        apply_action!(state, common.context, record.action, record.soc_after)
    end
    @test check_state_recoverability(
        common.context, state, block, entry, actions, config).recoverable

    # 1. Discontinuity: the state is not standing after the block.
    shifted = initial_simulation_state(common.context, path.replication_id)
    reveal_block!(shifted, path, block)
    for record in run.records[1:(length(block) - 1)]
        apply_action!(shifted, common.context, record.action, record.soc_after)
    end
    broken = check_state_recoverability(common.context, shifted, block, entry, actions, config)
    @test !broken.recoverable
    @test any(occursin("quedó en el período", v) for v in broken.violations)

    # 2. Inadmissibility: a carried state of charge outside the physical window.
    outside = initial_simulation_state(common.context, path.replication_id)
    reveal_block!(outside, path, block)
    for record in run.records[1:length(block)]
        apply_action!(outside, common.context, record.action, record.soc_after)
    end
    outside.soc_before = common.template.s_max + 10.0
    report = check_state_recoverability(common.context, outside, block, entry, actions, config)
    @test !report.recoverable
    @test any(occursin("fuera de", v) for v in report.violations)
    @test report.soc_bound_residual > config.feasibility_tol

    # 3. Drift: the carried value is not what replaying the implemented flows produces.
    drifted = initial_simulation_state(common.context, path.replication_id)
    reveal_block!(drifted, path, block)
    for record in run.records[1:length(block)]
        apply_action!(drifted, common.context, record.action, record.soc_after)
    end
    drifted.soc_before += 1.0
    report = check_state_recoverability(common.context, drifted, block, entry, actions, config)
    @test !report.recoverable
    @test any(occursin("Reaplicar los flujos", v) for v in report.violations)
    @test report.replay_residual > config.feasibility_tol

    # 4. A block whose action count disagrees with its length.
    report = check_state_recoverability(
        common.context, state, block, entry, actions[1:(end - 1)], config,
    )
    @test !report.recoverable
    @test any(occursin("comprometió", v) for v in report.violations)

    # The check never repairs: the state it was handed is unchanged afterwards.
    before = drifted.soc_before
    check_state_recoverability(common.context, drifted, block, entry, actions, config)
    @test drifted.soc_before == before
end

# =====================================================================================
# RC2 The warm start follows the window as it moves
# =====================================================================================

@testset "RC2 the warm start follows the moving window" begin
    for h in (1, 4, 10)
        config = recovery_config(implementation_step=h, use_warm_starts=true)
        common = build_common_objects(config; verbose=false)
        path = common.oos_paths[1]
        cache = cache_lookahead_trees(common.provider, common.context, path)
        starts = rolling_iteration_starts(config)
        length(starts) >= 2 || continue

        previous = cache[(starts[1], MULTISTAGE_RH)]
        following = cache[(starts[2], MULTISTAGE_RH)]
        # A fixed window of length L shifted by h overlaps on exactly L - h periods.
        @test lookahead_window_overlap(previous, following) ==
              config.lookahead_horizon - h

        state = initial_simulation_state(common.context, path.replication_id)
        reveal_block!(state, path, implementation_block(config, starts[1]))
        refs = build_remaining_horizon_model(common.context, state, previous, config)
        optimize!(refs.model)
        @test has_values(refs.model)
        flows = aggregate_flows_from_solution(refs)

        derived = derive_mode_start_from_previous(
            previous, flows.charge, flows.discharge, following; flow_tol=config.flow_tol,
        )
        # Every mode node of the NEW window gets a value; the ones inside the overlap carry the
        # previous solve's flows and the h newly entered ones fall back to the idle default.
        @test mode_start_length(derived.start) == length(following.mode_nodes)
        @test Set(derived.start.nodes) == Set(following.mode_nodes)
        @test derived.carried_nodes + derived.fresh_nodes == length(following.mode_nodes)
        @test derived.carried_nodes > 0
        @test all(v in (0.0, 1.0) for v in derived.start.values)
        @test derived.start.source == "current_formulation"
    end
end

# =====================================================================================
# RC3 Cold and warm runs are semantically equivalent
# =====================================================================================

@testset "RC3 cold and warm runs are semantically equivalent" begin
    for h in (1, 4)
        cold_config = recovery_config(implementation_step=h, use_warm_starts=false)
        warm_config = recovery_config(implementation_step=h, use_warm_starts=true)
        cold_common = build_common_objects(cold_config; verbose=false)
        warm_common = build_common_objects(warm_config; verbose=false)

        # The warm-start flag is solver guidance: it must not touch a single scientific input.
        @test warm_common.oos_paths[1].pv == cold_common.oos_paths[1].pv
        @test warm_common.share_table.share_table_id == cold_common.share_table.share_table_id

        cold_cache = cache_lookahead_trees(
            cold_common.provider, cold_common.context, cold_common.oos_paths[1])
        warm_cache = cache_lookahead_trees(
            warm_common.provider, warm_common.context, warm_common.oos_paths[1])
        for t in rolling_iteration_starts(cold_config)
            @test cached_support_id(warm_cache, t) == cached_support_id(cold_cache, t)
        end

        # `NONE` imposes no distributive rule, so the split of the community PV among households
        # is a DEGENERATE optimum: total cost depends on the aggregates alone and any split with
        # the same total is equally optimal. Cold and warm legitimately land on different vertices
        # of that optimal face — observed here as exact permutations of one another with identical
        # sums. Equivalence is therefore asserted on the quantities the study reports, and the
        # degeneracy is asserted explicitly rather than tolerated silently.
        cold = simulate_configuration(cold_common.context, cold_common.oos_paths[1], cold_cache,
                                      MULTISTAGE_RH, NONE, cold_common.share_table)
        warm = simulate_configuration(warm_common.context, warm_common.oos_paths[1], warm_cache,
                                      MULTISTAGE_RH, NONE, warm_common.share_table)
        @test cold.completed && warm.completed
        @test cold.periods_completed == warm.periods_completed

        @test isapprox(sum(cold.final_state.cumulative_operating_cost),
                       sum(warm.final_state.cumulative_operating_cost); rtol=1e-6)
        for (a, b) in zip(cold.records, warm.records)
            @test a.period == b.period
            @test isapprox(a.soc_after, b.soc_after; atol=1e-6)
            @test isapprox(a.action.aggregate_charge, b.action.aggregate_charge; atol=1e-5)
            @test isapprox(a.action.aggregate_discharge, b.action.aggregate_discharge; atol=1e-5)
            # The community total is pinned even when its split is not.
            @test isapprox(sum(a.action.p), sum(b.action.p); atol=1e-5)
            # The shared mode may differ ONLY at an idle period, where both aggregate flows are
            # zero, the binary is unconstrained and `OOS_IDLE_MODE_VALUE` breaks the tie. Anywhere
            # the battery actually moves, the mode is determined and must agree.
            idle = max(a.action.aggregate_charge, a.action.aggregate_discharge) <=
                   cold_config.flow_tol
            if !idle
                @test a.action.shared_battery_mode == b.action.shared_battery_mode
            end
        end

        # Under a policy that DOES pin the split, the two runs agree household by household, so
        # the difference above is degeneracy and not a warm-start effect on the decision.
        pinned_cold = simulate_configuration(
            cold_common.context, cold_common.oos_paths[1], cold_cache,
            MULTISTAGE_RH, STATIC_DEMAND_SHARE, cold_common.share_table)
        pinned_warm = simulate_configuration(
            warm_common.context, warm_common.oos_paths[1], warm_cache,
            MULTISTAGE_RH, STATIC_DEMAND_SHARE, warm_common.share_table)
        @test pinned_cold.completed && pinned_warm.completed
        for (a, b) in zip(pinned_cold.records, pinned_warm.records)
            @test isapprox(a.action.p, b.action.p; atol=1e-5)
            @test isapprox(a.action.lambda, b.action.lambda; atol=1e-6)
        end
        @test isapprox(sum(pinned_cold.final_state.cumulative_operating_cost),
                       sum(pinned_warm.final_state.cumulative_operating_cost); rtol=1e-6)
    end
end

# =====================================================================================
# RC4 No silent repair anywhere on the implementation path
# =====================================================================================

@testset "RC4 no silent repair on the implementation path" begin
    directory = joinpath(REPO_ROOT, "codes", "oos_experiment")
    simulator = read(joinpath(directory, "simulator.jl"), String)
    controllers = read(joinpath(directory, "controllers.jl"), String)

    # The implemented action is never clamped or rounded onto a bound. `min(max(...))` is
    # deliberately NOT forbidden: it appears in `model_side_residuals` as the simultaneous-flow
    # MEASUREMENT `min(max(charge,0), max(discharge,0))`, which reports a violation rather than
    # removing one. The gate targets the operation that would actually repair.
    for source in (simulator, controllers)
        @test !occursin("clamp(", source)
    end
    # Repair is also structurally impossible: `PeriodAction` is immutable, so no layer can edit
    # an extracted action in place even by accident.
    @test !ismutabletype(PeriodAction)
    @test !ismutabletype(ActionValidation)

    # An invalid action, and an unrecoverable hand-off, each stop the configuration. Matched on
    # the CODE rather than on prose: a message can be reworded, but the abort path cannot be
    # removed without deleting these calls.
    @test occursin("acción implementada inválida", simulator)
    @test occursin("check_state_recoverability", simulator)
    @test occursin("recoverability.recoverable", simulator)
    @test occursin("recoverability.violations", simulator)
    @test occursin("physical_violations += 1", simulator)
    # A failed warm start falls back to solving COLD, never to another action.
    @test occursin("mip_start = try", simulator)
    @test occursin(r"catch\s+nothing", simulator)

    # The PEA/SA diagnostic model exists only to attribute a failure; its solution is never used.
    @test occursin("Estrictamente diagnóstico", controllers) ||
          occursin("nunca se extrae", controllers) ||
          occursin("su solución es nunca", controllers) ||
          occursin("never extracted", controllers)

    # A deliberately invalid action is rejected, with the violation named.
    config = recovery_config(implementation_step=1)
    common = build_common_objects(config; verbose=false)
    path = common.oos_paths[1]
    state = initial_simulation_state(common.context, path.replication_id)
    reveal_block!(state, path, 1:1)
    template = common.template
    bad = PeriodAction(
        1, 1, zeros(template.J), zeros(template.J), zeros(template.J),
        fill(1e6, template.J), zeros(template.J), fill(1.0 / template.J, template.J),
        0.0, 0.0, template.s_I,
    )
    validation = validate_period_action(common.context, state, bad, config; lookahead_end=24)
    @test !validation.valid
    @test !isempty(validation.violations)
    # And it is reported, not silently corrected: the action object is untouched.
    @test bad.I == fill(1e6, template.J)
end
