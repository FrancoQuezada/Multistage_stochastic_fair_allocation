# =====================================================================================
# CS0..CS8  Common conditional stochastic support (OOS redesign stage 5)
#
# The claim under test is plan section 4.3: at one rolling start the three methods are derived
# from ONE conditional stochastic object, so the only thing that differs between them is the
# information structure. Before this stage they drew unrelated Monte Carlo samples from a stream
# keyed by the controller, which confounded the comparison the whole experiment exists to make.
#
# These sets run inside `tests/oos/runtests.jl` and reuse its helpers.
# =====================================================================================

"""Small stage-5 configuration; `multistage_branching` sets the common leaf count."""
support_config(; kwargs...) = test_config(;
    experiment_seed=515_151, households=3, oos_replications=1,
    controller_set=[DETERMINISTIC_RH, TWO_STAGE_RH, MULTISTAGE_RH], kwargs...)

"""The one support of `(replication 1, rolling start t)` for a configuration."""
function support_at(common, config, t::Int)
    path = common.oos_paths[1]
    history = ObservedHistory(t, collect(path.pv[1:t]), collect(path.demand[:, 1:t]))
    return build_common_conditional_support(
        common.provider, config, history, t, lookahead_end_period(config, t),
        path.replication_id,
    )
end

"""Root-to-leaf `(pv, demand)` paths of a look-ahead, in a comparable canonical order."""
leaf_paths(tree::LookaheadTree) = sort([
    ([tree.pv[n] for n in scenario], [tree.demand[:, n] for n in scenario])
    for scenario in tree.scenarios
]; by=first)

# =====================================================================================
# CS0 The support seed excludes the controller, structurally
# =====================================================================================

@testset "CS0 the support seed excludes the controller" begin
    config = support_config()

    # The retired stream is gone, name and all.
    @test !isdefined(@__MODULE__, :lookahead_rng)
    module_sources = join(
        read(joinpath(REPO_ROOT, "codes", "oos_experiment", f), String)
        for f in ("simulator.jl", "common_support.jl", "uncertainty_provider.jl")
    )
    @test !occursin("lookahead_rng(", module_sources)

    # The key is (experiment seed, replication, rolling start) and nothing else.
    @test lookahead_support_seed(config.experiment_seed, 3, 5) ==
          oos_stream_seed(config.experiment_seed, OOS_LOOKAHEAD_SUPPORT_STREAM, 3, 5)
    @test lookahead_support_seed(config.experiment_seed, 3, 5) ==
          lookahead_support_seed(config.experiment_seed, 3, 5)
    @test lookahead_support_seed(config.experiment_seed, 3, 5) !=
          lookahead_support_seed(config.experiment_seed, 4, 5)
    @test lookahead_support_seed(config.experiment_seed, 3, 5) !=
          lookahead_support_seed(config.experiment_seed, 3, 6)
    @test lookahead_support_seed(config.experiment_seed, 3, 5) !=
          lookahead_support_seed(config.experiment_seed + 1, 3, 5)
    @test_throws ErrorException lookahead_support_seed(config.experiment_seed, 1, 0)

    # The signature cannot accept a controller, a policy, a worker or an ordering, so no future
    # edit can leak one in by accident.
    signature = only(methods(lookahead_support_seed)).sig.parameters[2:end]
    @test length(signature) == 3
    @test all(t -> t === Int, signature)

    # Legacy and structural conditional-support streams stay separate, exactly as `oos_path` and
    # `structural_oos_path` do.
    @test OOS_LOOKAHEAD_SUPPORT_STREAM == "lookahead_support"
    @test OOS_LOOKAHEAD_SUPPORT_STREAM != OOS_CONDITIONAL_SUPPORT_STREAM
    @test oos_stream_seed(4242, OOS_LOOKAHEAD_SUPPORT_STREAM, 1, 1) !=
          oos_stream_seed(4242, OOS_CONDITIONAL_SUPPORT_STREAM, 1, 1)

    # The campaign metadata states the contract.
    template = build_instance_template(config).template
    seeds = experiment_config_dictionary(config, template)["seeds"]
    @test seeds["conditional_support_stream"] == OOS_LOOKAHEAD_SUPPORT_STREAM
    @test seeds["conditional_support_seed_keys"] ==
          ["experiment_seed", "oos_replication", "rolling_start"]
    @test "controller" in seeds["conditional_support_seed_exclusions"]
    @test "fairness_policy" in seeds["conditional_support_seed_exclusions"]
    @test seeds["controller_excluded_from_seed"]
    @test !haskey(seeds, "lookahead_stream")
end

# =====================================================================================
# CS1 One support per rolling start; the three methods are views of it
# =====================================================================================

@testset "CS1 the three methods are views of one support" begin
    config = support_config(multistage_branching=[2, 2])
    common = build_common_objects(config; verbose=false)
    cache = cache_lookahead_trees(common.provider, common.context, common.oos_paths[1])

    # One support per rolling start — the controller is not part of the key.
    @test length(cache.supports) == rolling_solve_count(config)
    @test length(cache) == rolling_solve_count(config) * 3
    @test Set(keys(cache.supports)) == Set(rolling_iteration_starts(config))

    for t in (1, 7, 24)
        support = cached_support(cache, t)
        @test support.rolling_start == t
        @test support.first_period == t
        @test support.last_period == lookahead_end_period(config, t)
        @test support_period_count(support) == config.lookahead_horizon
        @test support_leaf_count(support) == 4          # branching [2, 2]
        @test support.seed_stream == OOS_LOOKAHEAD_SUPPORT_STREAM
        @test support.seed ==
              lookahead_support_seed(config.experiment_seed, 1, t)
        @test isapprox(sum(support.leaf_probability), 1.0; atol=1e-12)

        multistage = cache[(t, MULTISTAGE_RH)]
        two_stage = cache[(t, TWO_STAGE_RH)]
        deterministic = cache[(t, DETERMINISTIC_RH)]

        # THE central claim: identical leaf paths and identical leaf probabilities.
        @test leaf_paths(multistage) == leaf_paths(two_stage)
        @test sort(scenario_probabilities(multistage)) == sort(scenario_probabilities(two_stage))
        @test lookahead_scenario_count(multistage) == lookahead_scenario_count(two_stage) == 4

        # Same window, same controller labels, same realized root.
        for tree in (multistage, two_stage, deterministic)
            @test tree.first_period == t
            @test tree.last_period == lookahead_end_period(config, t)
            @test tree.pv[tree.root] == multistage.pv[multistage.root]
            @test tree.demand[:, tree.root] == multistage.demand[:, multistage.root]
        end
        @test multistage.controller === MULTISTAGE_RH
        @test two_stage.controller === TWO_STAGE_RH
        @test deterministic.controller === DETERMINISTIC_RH
    end

    # Rebuilding the support reproduces it exactly, in any order and with any solver threads.
    forward = [support_at(common, config, t) for t in (1, 5, 9)]
    backward = reverse([support_at(common, config, t) for t in reverse((1, 5, 9))])
    for (a, b) in zip(forward, backward)
        @test a.scenario_support_id == b.scenario_support_id
        @test a.tree.pv == b.tree.pv
        @test a.tree.demand == b.tree.demand
        @test a.leaf_probability == b.leaf_probability
    end
end

# =====================================================================================
# CS2 The deterministic view is exactly the probability-weighted mean of those leaves
# =====================================================================================

@testset "CS2 the deterministic view is the weighted mean of the same leaves" begin
    config = support_config(multistage_branching=[3, 2])
    common = build_common_objects(config; verbose=false)
    support = support_at(common, config, 1)
    @test support_leaf_count(support) == 6

    multistage = multistage_support_view(support)
    deterministic = deterministic_support_view(support)
    @test lookahead_node_count(deterministic) == support_period_count(support)
    @test lookahead_scenario_count(deterministic) == 1

    households = common.template.J
    expected_pv = zeros(support_period_count(support))
    expected_demand = zeros(households, support_period_count(support))
    for (index, scenario) in enumerate(multistage.scenarios)
        weight = multistage.probability[scenario[end]]
        for (k, node) in enumerate(scenario)
            expected_pv[k] += weight * multistage.pv[node]
            for j in 1:households
                expected_demand[j, k] += weight * multistage.demand[j, node]
            end
        end
    end
    # The root is copied verbatim, not averaged, so it is exact rather than round-off close.
    @test deterministic.pv[1] == multistage.pv[multistage.root]
    @test deterministic.demand[:, 1] == multistage.demand[:, multistage.root]
    for k in 2:support_period_count(support)
        @test isapprox(deterministic.pv[k], expected_pv[k]; rtol=1e-12, atol=1e-12)
        for j in 1:households
            @test isapprox(deterministic.demand[j, k], expected_demand[j, k];
                           rtol=1e-12, atol=1e-12)
        end
    end

    # It is NOT the analytic conditional mean any more: that path is what stage 5 replaced.
    path = common.oos_paths[1]
    history = ObservedHistory(1, collect(path.pv[1:1]), collect(path.demand[:, 1:1]))
    analytic = conditional_mean_path(common.provider, history, 1, support.last_period)
    @test analytic.pv[1] == deterministic.pv[1]
    @test analytic.pv != deterministic.pv

    # Averaging preserves the per-period PEA feasibility each leaf already satisfies, so no
    # second repair is applied — and none is needed.
    for k in 1:support_period_count(support)
        @test sum(deterministic.demand[:, k]) >= deterministic.pv[k] - 1e-8
    end
end

# =====================================================================================
# CS3 Nonanticipativity is the ONLY structural difference
# =====================================================================================

@testset "CS3 nonanticipativity is the only structural difference" begin
    config = support_config(multistage_branching=[2, 2])
    common = build_common_objects(config; verbose=false)
    support = support_at(common, config, 1)
    multistage = multistage_support_view(support)
    two_stage = two_stage_support_view(support)

    # Multistage: distinct scenarios share their common history, so they share nodes.
    shared_multistage = intersect(Set(multistage.scenarios[1]), Set(multistage.scenarios[2]))
    @test length(shared_multistage) > 1
    @test multistage.root in shared_multistage
    @test lookahead_node_count(multistage) < lookahead_node_count(two_stage)

    # Two-stage: the root is the only shared node; recourse is scenario-specific afterwards.
    for a in 1:4, b in 1:4
        a < b || continue
        @test intersect(Set(two_stage.scenarios[a]), Set(two_stage.scenarios[b])) ==
              Set([two_stage.root])
    end
    @test lookahead_node_count(two_stage) ==
          1 + 4 * (support_period_count(support) - 1)

    # One shared-battery mode per information state in each, so the model-size difference is a
    # consequence of the information structure and of nothing else.
    @test length(multistage.mode_nodes) == lookahead_node_count(multistage)
    @test length(two_stage.mode_nodes) == lookahead_node_count(two_stage)
end

# =====================================================================================
# CS4 ScenarioSupportID identifies the support, not the method
# =====================================================================================

@testset "CS4 the ScenarioSupportID identifies the support, not the method" begin
    # Bounded on purpose: this set simulates the full controller x policy matrix, and the claim
    # under test — that the identifier tracks the support and not the method — needs several
    # rolling starts, not a long horizon.
    config = support_config(
        multistage_branching=[2, 2], fairness_set=[NONE, PEA],
        evaluation_horizon=6, lookahead_horizon=6,
    )
    common = build_common_objects(config; verbose=false)
    cache = cache_lookahead_trees(common.provider, common.context, common.oos_paths[1])

    ids = [cached_support_id(cache, t) for t in rolling_iteration_starts(config)]
    @test all(startswith(id, "SS-") for id in ids)
    @test length(unique(ids)) == length(ids)              # one per rolling start

    # Recomputable as a pure function of the seed contract and the resolved geometry.
    support = cached_support(cache, 3)
    @test support.scenario_support_id == scenario_support_id(
        support.seed_stream, support.seed, support.first_period, support.last_period,
        support.branching, support.periods_per_stage,
        length(support.tree.parent), support_leaf_count(support),
    )

    # Different replication -> different support.
    other = build_common_conditional_support(
        common.provider, config,
        ObservedHistory(3, collect(common.oos_paths[1].pv[1:3]),
                        collect(common.oos_paths[1].demand[:, 1:3])),
        3, lookahead_end_period(config, 3), 999,
    )
    @test other.scenario_support_id != support.scenario_support_id

    # Propagated to the records, and EQUAL across controllers and fairness policies.
    runs = Dict(
        (c, p) => simulate_configuration(
            common.context, common.oos_paths[1], cache, c, p, common.static_shares,
        )
        for c in config.controller_set, p in config.fairness_set
    )
    reference = runs[(DETERMINISTIC_RH, NONE)]
    @test all(r.scenario_support_id == cached_support_id(cache, r.period)
              for r in reference.records)
    for (_, run) in runs
        run.completed || continue
        @test [r.scenario_support_id for r in run.records] ==
              [r.scenario_support_id for r in reference.records[1:length(run.records)]]
    end
end

# =====================================================================================
# CS5 The realized root and the observed history are common to every method
# =====================================================================================

@testset "CS5 every method receives the same realized information" begin
    config = support_config(multistage_branching=[2, 2])
    common = build_common_objects(config; verbose=false)
    path = common.oos_paths[1]
    cache = cache_lookahead_trees(common.provider, common.context, path)

    for t in rolling_iteration_starts(config)
        for controller in config.controller_set
            tree = cache[(t, controller)]
            # The root IS the realization, verbatim, for all three.
            @test tree.pv[tree.root] == path.pv[t]
            @test tree.demand[:, tree.root] == path.demand[:, t]
            @test tree.calendar_period[tree.root] == t
        end
    end

    # No method sees beyond its own window, and all three stop at the same period.
    ends = unique(cache[(5, c)].last_period for c in config.controller_set)
    @test length(ends) == 1
    @test only(ends) == lookahead_end_period(config, 5)
end

# =====================================================================================
# CS6 Results are invariant to controller and fairness ordering
# =====================================================================================

@testset "CS6 results are invariant to controller and fairness ordering" begin
    config = support_config(
        multistage_branching=[2], fairness_set=[NONE, STATIC_DEMAND_SHARE],
    )
    common = build_common_objects(config; verbose=false)
    path = common.oos_paths[1]
    cache = cache_lookahead_trees(common.provider, common.context, path)

    combos = vec([(c, p) for c in config.controller_set, p in config.fairness_set])
    forward = Dict(k => simulate_configuration(
        common.context, path, cache, k[1], k[2], common.static_shares) for k in combos)
    backward = Dict(k => simulate_configuration(
        common.context, path, cache, k[1], k[2], common.static_shares) for k in reverse(combos))

    for k in combos
        a, b = forward[k], backward[k]
        @test a.completed == b.completed
        @test a.periods_completed == b.periods_completed
        @test a.final_state.cumulative_operating_cost == b.final_state.cumulative_operating_cost
        for (x, y) in zip(a.records, b.records)
            @test x.action.p == y.action.p
            @test x.action.shared_battery_mode == y.action.shared_battery_mode
            @test x.scenario_support_id == y.scenario_support_id
        end
    end

    # A rebuilt cache reproduces the same supports, so reuse is an optimization and not a
    # source of the agreement above.
    rebuilt = cache_lookahead_trees(common.provider, common.context, path)
    for t in rolling_iteration_starts(config)
        @test cached_support_id(rebuilt, t) == cached_support_id(cache, t)
        @test rebuilt[(t, MULTISTAGE_RH)].pv == cache[(t, MULTISTAGE_RH)].pv
    end
end

# =====================================================================================
# CS7 The leaf count follows the common support, not `two_stage_scenarios`
# =====================================================================================

@testset "CS7 the leaf count follows the common support" begin
    for (branching, leaves) in ([2] => 2, [2, 2] => 4, [3] => 3, [2, 3] => 6)
        config = support_config(
            multistage_branching=branching, two_stage_scenarios=17,
            controller_set=[TWO_STAGE_RH, MULTISTAGE_RH], fairness_set=[NONE],
        )
        common = build_common_objects(config; verbose=false)
        support = support_at(common, config, 1)
        @test support_leaf_count(support) == leaves
        @test lookahead_scenario_count(two_stage_support_view(support)) == leaves
        @test lookahead_scenario_count(multistage_support_view(support)) == leaves
        @test leaves != config.two_stage_scenarios
    end

    # The configured value is preserved for provenance and flagged as no longer driving anything.
    config = support_config(two_stage_scenarios=17)
    template = build_instance_template(config).template
    parameters = experiment_config_dictionary(config, template)["controller_parameters"]
    @test parameters["two_stage_scenarios"] == 17
    @test parameters["two_stage_scenarios_drives_generation"] == false
    @test parameters["two_stage_leaves_derived_from"] == "common_conditional_support"
end

# =====================================================================================
# CS8 A fresh support is generated at every rolling start
# =====================================================================================

@testset "CS8 a fresh support is generated at every rolling start" begin
    config = support_config(multistage_branching=[2], controller_set=[MULTISTAGE_RH],
                            fairness_set=[NONE])
    common = build_common_objects(config; verbose=false)
    cache = cache_lookahead_trees(common.provider, common.context, common.oos_paths[1])

    # Distinct objects with distinct seeds: the experiment does not keep one tree per
    # replication, and it does not prune or update the previous tree in place.
    seeds = [cached_support(cache, t).seed for t in rolling_iteration_starts(config)]
    @test length(unique(seeds)) == length(seeds)
    first_tree = cache[(1, MULTISTAGE_RH)]
    second_tree = cache[(2, MULTISTAGE_RH)]
    @test first_tree.first_period == 1 && second_tree.first_period == 2
    @test first_tree.pv != second_tree.pv

    # Each is conditioned on the enlarged realized history: its root is that period's
    # realization, and the support is rebuilt rather than shifted.
    path = common.oos_paths[1]
    @test second_tree.pv[second_tree.root] == path.pv[2]
    @test cached_support(cache, 2).rolling_start == 2
end
