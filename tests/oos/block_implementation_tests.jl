# =====================================================================================
# B0..B6  Arbitrary implementation blocks and known prefixes (OOS redesign stage 6)
#
# Stage 6 generalizes observation, nonanticipativity, action extraction, implementation and the
# state update from `h = 1` to every admissible implementation step. The properties that must
# hold, from plan sections 4.1 and 6:
#
#   * the complete known prefix `t : t+h-1` is revealed to EVERY controller before it optimizes;
#   * that prefix is deterministic and common to every scenario, and branching begins at `t+h`;
#   * the whole committed block is extracted and implemented, in order;
#   * the physical and fairness state advance sequentially inside the block;
#   * a final non-divisible block runs past `H`, is committed and validated in full, and only its
#     intersection with `1:H` is recorded and evaluated; and
#   * `h = 1` is an exact regression of the stage-5 behaviour.
#
# These sets run inside `tests/oos/runtests.jl` and reuse its helpers.
# =====================================================================================

"""Small stage-6 configuration."""
block_config(; kwargs...) = test_config(;
    experiment_seed=606_060, households=3, oos_replications=1,
    controller_set=[DETERMINISTIC_RH], fairness_set=[NONE],
    multistage_branching=[2, 2], kwargs...)

"""Run one configuration end to end and return `(common, cache, run)`."""
function block_run(config; controller=DETERMINISTIC_RH, policy=NONE)
    common = build_common_objects(config; verbose=false)
    cache = cache_lookahead_trees(common.provider, common.context, common.oos_paths[1])
    run = simulate_configuration(
        common.context, common.oos_paths[1], cache, controller, policy, common.static_shares,
    )
    return (common=common, cache=cache, run=run)
end

# =====================================================================================
# B0 The known prefix is deterministic, common and exactly `h` periods long
# =====================================================================================

@testset "B0 the known prefix is deterministic and common" begin
    for h in (1, 3, 4, 10)
        config = block_config(implementation_step=h,
                              controller_set=[DETERMINISTIC_RH, TWO_STAGE_RH, MULTISTAGE_RH])
        common = build_common_objects(config; verbose=false)
        path = common.oos_paths[1]
        cache = cache_lookahead_trees(common.provider, common.context, path)

        for t in rolling_iteration_starts(config)
            support = cached_support(cache, t)
            @test support.known_prefix == h == known_prefix_length(config)
            # The prefix is a chain: exactly one node per committed period.
            prefix = support_prefix_nodes(support)
            @test length(prefix) == h
            @test [support.tree.calendar_period[n] for n in prefix] ==
                  collect(implementation_block(config, t))
            # It carries the REALIZED values, not sampled ones.
            for (offset, node) in enumerate(prefix)
                period = t + offset - 1
                @test support.tree.pv[node] == path.pv[period]
                @test support.tree.demand[:, node] == path.demand[:, period]
                @test support.tree.probability[node] == 1.0
            end
            # Branching begins no earlier than `t + h`: the whole prefix has probability one.
            first_branch = minimum(
                support.tree.calendar_period[n]
                for n in eachindex(support.tree.parent)
                if support.tree.probability[n] < 1.0;
                init = support.last_period + 1,
            )
            @test first_branch >= t + h

            # All three views agree on the prefix, node for node.
            trees = [cache[(t, c)] for c in config.controller_set]
            for tree in trees, offset in 1:h
                period = t + offset - 1
                node = tree.root
                for _ in 2:offset
                    children = [n for n in tree.nodes if tree.parent[n] == node]
                    @test length(children) == 1
                    node = only(children)
                end
                @test tree.calendar_period[node] == period
                @test tree.pv[node] == path.pv[period]
                @test tree.demand[:, node] == path.demand[:, period]
            end
        end
    end
end

# =====================================================================================
# B1 `h = 1` is an exact regression of the stage-5 behaviour
# =====================================================================================

@testset "B1 h = 1 is an exact regression" begin
    config = block_config(implementation_step=1,
                          controller_set=[DETERMINISTIC_RH, TWO_STAGE_RH, MULTISTAGE_RH])
    common = build_common_objects(config; verbose=false)
    cache = cache_lookahead_trees(common.provider, common.context, common.oos_paths[1])

    # The prefix collapses to the root, and the layout is the one the configuration asks for
    # rather than a prefix-driven one.
    support = cached_support(cache, 1)
    @test support.known_prefix == 1
    @test support_prefix_nodes(support) == [1]
    @test support.periods_per_stage == [8, 8, 8]
    @test support.branching == [2, 2]
    @test multistage_stage_layout_with_prefix(24, [2, 2], Int[], 1) ==
          multistage_stage_layout(24, [2, 2], Int[])

    for controller in config.controller_set
        run = simulate_configuration(
            common.context, common.oos_paths[1], cache, controller, NONE, common.static_shares,
        )
        @test run.completed
        @test run.periods_completed == config.evaluation_horizon == 24
        @test [r.period for r in run.records] == collect(1:24)
        @test length(run.pea_tolerances) == rolling_solve_count(config) == 24
        # One committed action per solve.
        @test all(length(r.result.block_actions) == 1 for r in run.records)
        @test all(r.result.action === first(r.result.block_actions) for r in run.records)
    end
end

# =====================================================================================
# B2 Arbitrary steps commit and implement the whole block
# =====================================================================================

@testset "B2 arbitrary steps commit and implement the whole block" begin
    for h in (2, 3, 4, 6, 8, 12)
        config = block_config(implementation_step=h)
        outcome = block_run(config)
        run = outcome.run
        @test run.completed
        @test run.periods_completed == config.evaluation_horizon == 24
        @test [r.period for r in run.records] == collect(1:24)
        # One solve per rolling start, but its tolerance decision is recorded once per period it
        # covers (pea_tolerances is period-counted, matching PeriodsSolved), so the length is 24
        # regardless of h, not rolling_solve_count(config) = div(24, h).
        @test length(run.pea_tolerances) == config.evaluation_horizon == 24
        # Each solve produced the whole block.
        for t in rolling_iteration_starts(config)
            record = run.records[t]
            @test length(record.result.block_actions) == h
            @test [a.period for a in record.result.block_actions] ==
                  collect(implementation_block(config, t))
        end
        # Every implemented action is physically valid and the state chains through the block.
        soc = outcome.common.template.s_I
        for record in run.records
            @test record.validation.valid
            @test isapprox(record.soc_before, soc; atol=1e-9)
            soc = record.soc_after
        end
    end
end

# =====================================================================================
# B3 A non-divisible final block runs past `H`, is validated, and is not evaluated
# =====================================================================================

@testset "B3 the final non-divisible block is committed but not evaluated" begin
    # The plan's worked example: H = 24, h = 10 -> starts [1, 11, 21], final block 21:30.
    config = block_config(evaluation_horizon=24, lookahead_horizon=24, implementation_step=10)
    @test rolling_iteration_starts(config) == [1, 11, 21]
    @test implementation_block(config, 21) == 21:30
    @test evaluation_block(config, 21) == 21:24
    @test realized_period_end(config) == 30
    @test required_period_support_end(config) == 44

    outcome = block_run(config)
    common, run = outcome.common, outcome.run
    @test common.oos_paths[1].horizon == 30          # realized through the final committed period
    @test run.completed

    # Recorded: exactly 1:H. Committed: 1:30.
    @test run.periods_completed == 24
    @test [r.period for r in run.records] == collect(1:24)
    @test !any(r.period > 24 for r in run.records)

    final_record = run.records[end]
    @test length(final_record.result.block_actions) == 10
    @test [a.period for a in final_record.result.block_actions] == collect(21:30)
    # The periods past H were implemented — the state advanced through all of them — even though
    # none of them produced a record.
    @test run.final_state.period == 31
    @test run.final_state.revealed_periods == 30

    # Cumulative bookkeeping therefore includes the committed tail, and the metrics say the
    # evaluated horizon is complete.
    metrics = compute_replication_metrics(common.template, run, config)
    @test metrics.completed
    @test metrics.horizon_covered == 1.0
    @test metrics.periods_completed == 24

    # The block is never silently truncated for decision construction.
    @test length(run.records[end].result.block_actions) == config.implementation_step
end

# =====================================================================================
# B4 No controller receives more or less realized information than another
# =====================================================================================

@testset "B4 every controller receives the same known prefix" begin
    config = block_config(implementation_step=4,
                          controller_set=[DETERMINISTIC_RH, TWO_STAGE_RH, MULTISTAGE_RH],
                          fairness_set=[NONE, STATIC_DEMAND_SHARE])
    common = build_common_objects(config; verbose=false)
    path = common.oos_paths[1]
    cache = cache_lookahead_trees(common.provider, common.context, path)

    # One support, one prefix, shared by every method.
    for t in rolling_iteration_starts(config)
        ids = unique(cached_support_id(cache, t) for _ in config.controller_set)
        @test length(ids) == 1
        prefixes = [
            [tree.pv[n] for n in tree.scenarios[1][1:4]]
            for tree in (cache[(t, c)] for c in config.controller_set)
        ]
        @test length(unique(prefixes)) == 1
        @test prefixes[1] == collect(path.pv[t:(t+3)])
    end

    # A state whose revealed history is shorter than the block is rejected rather than solved.
    state = initial_simulation_state(common.context, path.replication_id)
    reveal_period!(state, path, 1)
    tree = cache[(1, DETERMINISTIC_RH)]
    observation = PeriodObservation(1, path.pv[1], collect(path.demand[:, 1]))
    @test_throws ErrorException solve_current_action(
        common.context, state, observation, tree, DETERMINISTIC_RH, NONE, config;
        static_shares=common.static_shares, implementation_block=1:4,
    )

    # `reveal_block!` is the only way the prefix becomes visible, and it is symmetric.
    fresh = initial_simulation_state(common.context, path.replication_id)
    reveal_block!(fresh, path, 1:4)
    @test fresh.revealed_periods == 4
    @test fresh.period == 1                       # revealing does not implement
    history = observed_history(fresh)
    @test history.periods == 4
    @test history.pv == collect(path.pv[1:4])
    # It refuses a block that does not start where the state stands, or a repeated reveal.
    @test_throws ErrorException reveal_block!(fresh, path, 1:4)
    @test_throws ErrorException reveal_block!(
        initial_simulation_state(common.context, 1), path, 2:5,
    )
end

# =====================================================================================
# B5 The stage layout keeps the prefix branch-free
# =====================================================================================

@testset "B5 the stage layout keeps the prefix branch-free" begin
    # When the configured first stage already covers the prefix, the layout is untouched.
    @test multistage_stage_layout_with_prefix(24, [2, 2], Int[], 8) ==
          multistage_stage_layout(24, [2, 2], Int[])
    @test multistage_stage_layout_with_prefix(24, [2, 2], Int[], 1)[1] == [8, 8, 8]

    # When it does not, stage 1 grows to exactly the prefix and later stages give up periods in
    # order; the total is preserved.
    periods, branching = multistage_stage_layout_with_prefix(24, [2, 2], Int[], 10)
    @test periods == [10, 6, 8]
    @test branching == [2, 2]
    @test sum(periods) == 24

    # A stage emptied by the prefix is dropped together with the branching factor that would
    # have entered it, so the layout stays well defined.
    periods, branching = multistage_stage_layout_with_prefix(9, [2, 2, 2], Int[], 8)
    @test periods[1] == 8
    @test sum(periods) == 9
    @test length(branching) == length(periods) - 1
    @test all(p -> p >= 1, periods)

    # The degenerate contract `h = L`: one deterministic chain, no branching, one leaf.
    periods, branching = multistage_stage_layout_with_prefix(6, [2, 2], Int[], 6)
    @test periods == [6]
    @test isempty(branching)

    config = block_config(evaluation_horizon=6, lookahead_horizon=6, implementation_step=6,
                          controller_set=[DETERMINISTIC_RH, TWO_STAGE_RH, MULTISTAGE_RH])
    common = build_common_objects(config; verbose=false)
    cache = cache_lookahead_trees(common.provider, common.context, common.oos_paths[1])
    support = cached_support(cache, 1)
    @test support_leaf_count(support) == 1
    @test support.known_prefix == 6
    # With no future to represent, the three structures coincide.
    for controller in config.controller_set
        tree = cache[(1, controller)]
        @test lookahead_node_count(tree) == 6
        @test lookahead_scenario_count(tree) == 1
        @test tree.pv == cache[(1, DETERMINISTIC_RH)].pv
    end

    @test_throws ErrorException multistage_stage_layout_with_prefix(6, [2], Int[], 7)
    @test_throws ErrorException multistage_stage_layout_with_prefix(6, [2], Int[], 0)
end

# =====================================================================================
# B6 The block is implemented sequentially, and a bad block is attributed
# =====================================================================================

@testset "B6 the block is implemented sequentially and failures are attributed" begin
    config = block_config(implementation_step=6)
    outcome = block_run(config)
    common, run = outcome.common, outcome.run
    template = common.template
    @test run.completed

    # The state advances period by period INSIDE the block: each record's `soc_before` is the
    # previous record's `soc_after`, across block boundaries as well as within them.
    soc = template.s_I
    for record in run.records
        @test isapprox(record.soc_before, soc; atol=1e-9)
        expected = induced_soc(template, soc, record.action.aggregate_charge,
                               record.action.aggregate_discharge)
        @test isapprox(record.soc_after, expected; atol=1e-9)
        soc = record.soc_after
    end

    # Cumulative quantities equal a direct recomputation over every implemented period.
    for j in 1:template.J
        @test isapprox(
            run.final_state.cumulative_pv[j],
            sum(r.action.p[j] for r in run.records); atol=1e-8,
        )
    end

    # Extraction is refused, with an attributable message, when the block leaves the window or
    # does not start at the root.
    path = common.oos_paths[1]
    cache = outcome.cache
    state = initial_simulation_state(common.context, path.replication_id)
    reveal_block!(state, path, 1:6)
    tree = cache[(1, DETERMINISTIC_RH)]
    refs = build_remaining_horizon_model(common.context, state, tree, config)
    optimize!(refs.model)
    @test has_values(refs.model)

    actions, message = extract_block_actions(refs, config, 1:6)
    @test actions !== nothing && length(actions) == 6
    @test [a.period for a in actions] == collect(1:6)

    beyond, beyond_message = extract_block_actions(refs, config, 1:(tree.last_period + 1))
    @test beyond === nothing
    @test occursin("excede la ventana", beyond_message)

    misaligned, misaligned_message = extract_block_actions(refs, config, 2:7)
    @test misaligned === nothing
    @test occursin("no empieza en la raíz", misaligned_message)

    # A block that reaches past the deterministic prefix has no unique committed action and is
    # reported as such rather than resolved by picking a scenario.
    branched, branched_message = extract_block_actions(
        refs, config, 1:(config.implementation_step + 1),
    )
    if branched === nothing
        @test occursin("cadena determinista", branched_message)
    else
        # Only admissible when the configured first stage happens to extend past the prefix.
        @test length(branched) == config.implementation_step + 1
    end
end
