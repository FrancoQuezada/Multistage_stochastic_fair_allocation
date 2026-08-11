# =====================================================================================
# R0..R8  Fixed moving look-ahead (OOS redesign stage 4)
#
# Stage 4 replaced the shrinking interval `t:template.T` with a fixed `L`-period window anchored
# at each rolling start, moved the terminal state-of-charge target to the end of that window, and
# made the physical model, the realized cost accounting and the fairness aggregates read their
# prices from the stage-3 extended support.
#
# These sets check that contract. They run inside `tests/oos/runtests.jl` and reuse its helpers
# (`test_config`, `TEST_INSTANCE`, `replay_state`, `solve_at`).
#
# Everything here is bounded: small household counts, one replication, and single-controller
# configurations wherever the property under test does not depend on the controller.
# =====================================================================================

"""Small stage-4 configuration; `L` is the quantity most of these sets vary."""
rolling_config(; kwargs...) = test_config(;
    experiment_seed=90_210, households=3, oos_replications=1,
    controller_set=[DETERMINISTIC_RH], fairness_set=[NONE], kwargs...)

# =====================================================================================
# R0 Temporal endpoints are distinct and correctly ordered
# =====================================================================================

@testset "R0 temporal endpoints are distinct and correctly ordered" begin
    T0 = 24
    for H in (1, 5, 12, 24, 37), L in (1, 3, 8, 24, 30), h in (1,)
        h <= min(H, L) || continue
        config = rolling_config(
            evaluation_horizon=H, lookahead_horizon=L, implementation_step=h,
        )
        starts = rolling_iteration_starts(config)
        final_start = final_rolling_iteration_start(config)
        support_end = required_period_support_end(config)
        realized_end = realized_period_end(config)

        @test starts == collect(1:h:H)
        @test final_start == last(starts)
        @test support_end == final_start + L - 1
        @test realized_end == final_start + h - 1

        # The two orderings `rolling_context.jl` and `simulator.jl` depend on.
        @test realized_end >= H
        @test realized_end <= support_end
        # The materialized endpoint retains the whole base profile even for a short contract.
        @test max(T0, support_end) >= T0
    end

    # The default contract: 24 evaluated periods, each with a full 24-period window, so data must
    # exist through period 47 while only 24 periods are ever realized.
    default = rolling_config()
    @test default.evaluation_horizon == 24
    @test default.lookahead_horizon == 24
    @test default.implementation_step == 1
    @test required_period_support_end(default) == 47
    @test realized_period_end(default) == 24
    # H, L, T_support and T_realized are four separate quantities, not aliases of `template.T`.
    @test length(unique((
        default.evaluation_horizon, required_period_support_end(default),
    ))) == 2
end

# =====================================================================================
# R1 The rolling context binds the contract, the instance and the extended support
# =====================================================================================

@testset "R1 the rolling context binds contract, instance and extended support" begin
    config = rolling_config()
    template = build_instance_template(config).template
    context = OOSRollingContext(config, template)

    @test context.config === config
    @test context.template === template
    @test rolling_base_cycle(context) == template.T == 24
    @test rolling_support_end(context) == required_period_support_end(config) == 47
    @test rolling_data_end(context) == 47
    @test rolling_realized_end(context) == 24

    # `template.nu` is untouched and still exactly J x T0: the extension lives in the support.
    @test size(template.nu) == (template.J, template.T)
    @test size(rolling_price_matrix(context)) == (template.J, 47)

    # Prices are exact on the base horizon and exact repeats after it — `==`, not a tolerance.
    for j in 1:template.J
        for tau in 1:template.T
            @test rolling_price(context, j, tau) == template.nu[j, tau]
        end
        # 47 is the last materialized period here (T0 = 24, support end 47), so `2 * T0 = 48`
        # is deliberately absent: it is checked below as an out-of-range lookup.
        for tau in (template.T + 1, template.T + 5, 2 * template.T - 1, 47)
            @test rolling_price(context, j, tau) ==
                  template.nu[j, base_period_index(tau, template.T)]
        end
    end

    # Out-of-range lookups are named, not silent.
    @test_throws ErrorException rolling_price(context, 1, 48)
    @test_throws ErrorException rolling_price(context, 1, 0)
    @test_throws ErrorException rolling_price(context, template.J + 1, 1)
    @test_throws ErrorException assert_supported_period(context, 48)
    @test assert_supported_period(context, 47) == 47

    # A support that does not match the contract or the instance is rejected at construction.
    short = build_period_data_support(template, 30)
    @test_throws ErrorException OOSRollingContext(config, template, short)
    exact = build_period_data_support(template, required_period_support_end(config))
    @test OOSRollingContext(config, template, exact) isa OOSRollingContext

    # Purity and reproducibility: two contexts built independently agree on every value.
    twin = OOSRollingContext(config, template)
    @test rolling_price_matrix(twin) == rolling_price_matrix(context)
    @test rolling_price_matrix(twin) !== rolling_price_matrix(context)   # not shared state
    @test twin.support.pv_det == context.support.pv_det

    # A bare template is still an admissible priced source, capped at the base horizon.
    @test priced_template(template) === template
    @test priced_matrix(template) === template.nu
    @test priced_realized_end(template) == template.T
    @test priced_realized_end(context) == 24
    @test assert_priced_period(template, template.T) == template.T
    @test_throws ErrorException assert_priced_period(template, template.T + 1)
end

# =====================================================================================
# R2 Every solve spans exactly L abstract periods
# =====================================================================================

@testset "R2 every solve spans exactly L abstract periods" begin
    for L in (1, 6, 24)
        config = rolling_config(lookahead_horizon=L)
        common = build_common_objects(config; verbose=false)
        path = common.oos_paths[1]
        cache = cache_lookahead_trees(common.provider, common.context, path)

        @test length(cache) == rolling_solve_count(config) * length(config.controller_set)
        for t in rolling_iteration_starts(config)
            tree = cache[(t, DETERMINISTIC_RH)]
            @test tree.first_period == t
            @test tree.last_period == t + L - 1
            @test tree.last_period - tree.first_period + 1 == L
            # Never the shrinking interval.
            @test tree.last_period == lookahead_end_period(config, t)
        end

        # The LAST evaluated period still gets a full window; this is the property the shrinking
        # horizon could not provide.
        final = cache[(final_rolling_iteration_start(config), DETERMINISTIC_RH)]
        @test final.last_period - final.first_period + 1 == L
        @test final.last_period == required_period_support_end(config)
    end

    # With the default contract the later windows genuinely reach past the repository horizon.
    config = rolling_config()
    common = build_common_objects(config; verbose=false)
    cache = cache_lookahead_trees(common.provider, common.context, common.oos_paths[1])
    beyond = [t for t in rolling_iteration_starts(config)
              if cache[(t, DETERMINISTIC_RH)].last_period > common.template.T]
    @test !isempty(beyond)
    @test minimum(beyond) == 2
    @test cache[(24, DETERMINISTIC_RH)].last_period == 47
end

# =====================================================================================
# R3 The terminal state-of-charge target binds at the window end, and only there
# =====================================================================================

@testset "R3 the terminal target binds at the window end and only there" begin
    config = rolling_config(lookahead_horizon=6)
    common = build_common_objects(config; verbose=false)
    path = common.oos_paths[1]
    cache = cache_lookahead_trees(common.provider, common.context, path)
    state = initial_simulation_state(common.context, path.replication_id)
    reveal_period!(state, path, 1)
    tree = cache[(1, DETERMINISTIC_RH)]
    refs = build_remaining_horizon_model(common.context, state, tree, config)

    # The constraint family exists exactly on the nodes of the window's LAST period.
    terminal = refs.model[:terminal_soc]
    constrained = [n for n in tree.nodes if tree.calendar_period[n] == tree.last_period]
    @test length(terminal) == length(constrained)
    @test !isempty(constrained)
    @test all(tree.calendar_period[n] == tree.last_period for n in constrained)
    @test tree.last_period == 6 != common.template.T

    # The three-argument convenience form uses the context's own configuration.
    twin = build_remaining_horizon_model(common.context, state, tree)
    @test length(twin.model[:terminal_soc]) == length(terminal)
    # A configuration whose temporal contract disagrees with the context is refused.
    @test_throws ErrorException build_remaining_horizon_model(
        common.context, state, tree, rolling_config(lookahead_horizon=8),
    )

    # Realized side: with h = 1 < L no implemented action is ever the window end, so none of them
    # carries a terminal requirement.
    run = simulate_configuration(
        common.context, path, cache, DETERMINISTIC_RH, NONE, common.static_shares,
    )
    @test run.completed
    @test all(r.validation.residuals.terminal == 0.0 for r in run.records)
    @test all(r.result.residuals.terminal == 0.0 for r in run.records)
    # The state of charge left at the end of the evaluation horizon is an OUTCOME, and is not
    # required to equal s_I. It must still be physically admissible.
    final_soc = last(run.records).soc_after
    @test common.template.s_min - config.feasibility_tol <= final_soc
    @test final_soc <= common.template.s_max + config.feasibility_tol

    # The degenerate contract L = 1 makes the window end coincide with the implemented period, and
    # then the requirement does bind on the realized action.
    unit = rolling_config(lookahead_horizon=1)
    unit_common = build_common_objects(unit; verbose=false)
    unit_cache = cache_lookahead_trees(
        unit_common.provider, unit_common.context, unit_common.oos_paths[1],
    )
    unit_run = simulate_configuration(
        unit_common.context, unit_common.oos_paths[1], unit_cache, DETERMINISTIC_RH, NONE,
        unit_common.static_shares,
    )
    @test unit_run.completed
    for record in unit_run.records
        @test isapprox(record.soc_after, unit_common.template.s_I; atol=unit.feasibility_tol)
    end
end

# =====================================================================================
# R4 Extended prices reach the model and the realized accounting
# =====================================================================================

@testset "R4 extended prices reach the model and the realized accounting" begin
    config = rolling_config()
    common = build_common_objects(config; verbose=false)
    template = common.template
    T0 = template.T
    path = common.oos_paths[1]
    cache = cache_lookahead_trees(common.provider, common.context, path)

    # A window that reaches past T0: at t = 24 the model covers 24:47.
    state = replay_state(common, simulate_configuration(
        common.context, path, cache, DETERMINISTIC_RH, NONE, common.static_shares,
    ), 23)
    @test state.period == 24
    tree = cache[(24, DETERMINISTIC_RH)]
    @test tree.last_period == 47
    refs = build_remaining_horizon_model(common.context, state, tree, config)

    # The import coefficient of `node_cost` is `delta * price(j, tau)` at every node, including
    # the ones after the repository horizon.
    checked_beyond = 0
    for n in tree.nodes
        tau = tree.calendar_period[n]
        for j in 1:template.J
            expected = template.delta * template.nu[j, base_period_index(tau, T0)]
            @test isapprox(coefficient(refs.node_cost[j, n], refs.I[j, n]), expected; rtol=1e-12)
        end
        tau > T0 && (checked_beyond += 1)
    end
    @test checked_beyond > 0

    # Realized accounting uses the same prices. Since h = 1 and H = T0 here, every implemented
    # period lies inside the base horizon, so the extended and base matrices must agree exactly.
    run = simulate_configuration(
        common.context, path, cache, DETERMINISTIC_RH, NONE, common.static_shares,
    )
    for j in 1:template.J
        @test isapprox(
            run.final_state.cumulative_all_grid_cost[j],
            sum(template.delta * template.nu[j, r.period] * r.realized_demand[j]
                for r in run.records);
            atol=1e-8,
        )
    end

    # A bare template cannot price this window and says so instead of failing obscurely.
    @test_throws ErrorException build_remaining_horizon_model(template, state, tree, config)
    @test_throws ErrorException scenario_aggregates(template, tree)
    # ...while the context can, and its aggregates price the tail with the repeated base entries.
    aggregates = scenario_aggregates(common.context, tree)
    manual = sum(
        template.delta * template.nu[1, base_period_index(tree.calendar_period[n], T0)] *
        tree.demand[1, n]
        for n in tree.scenarios[1]
    )
    @test isapprox(aggregates.benchmark[1, 1], manual; rtol=1e-12)
end

# =====================================================================================
# R5 Static demand shares are extended through the one centralized mapping
#
# The mechanical half of stage 7, pulled forward because stage 4 cannot run without it.
# =====================================================================================

@testset "R5 static demand shares are extended through the centralized mapping" begin
    config = rolling_config(fairness_set=[NONE, STATIC_DEMAND_SHARE])
    common = build_common_objects(config; verbose=false)
    template = common.template
    T0 = template.T
    shares = common.static_shares

    @test size(shares) == (template.J, rolling_data_end(common.context)) == (3, 47)
    # Every column is a valid allocation, before and after the base horizon.
    for tau in axes(shares, 2)
        @test isapprox(sum(shares[:, tau]), 1.0; atol=1e-12)
        @test all(shares[:, tau] .>= -1e-12)
    end
    # After T0 the table repeats its own base columns exactly.
    for tau in (T0 + 1, T0 + 7, 2 * T0 - 1, 47)
        @test shares[:, tau] == shares[:, base_period_index(tau, T0)]
    end

    # The extension helper preserves the base table exactly and rejects a bad request.
    base = shares[:, 1:T0]
    @test extend_static_demand_shares(base, T0, 47) == shares
    @test extend_static_demand_shares(base, T0, T0) == base
    @test_throws ErrorException extend_static_demand_shares(base, T0, T0 - 1)
    @test_throws ErrorException extend_static_demand_shares(base, T0 + 1, 47)

    # The table depends on neither the replication nor the controller; only its WIDTH follows the
    # temporal contract, and the base columns are invariant to it.
    narrow_config = rolling_config(
        fairness_set=[NONE, STATIC_DEMAND_SHARE], lookahead_horizon=4,
    )
    narrow = build_common_objects(narrow_config; verbose=false)
    @test size(narrow.static_shares, 2) == rolling_data_end(narrow.context) == 27
    @test size(narrow.static_shares, 2) < size(shares, 2)
    @test narrow.static_shares[:, 1:T0] == shares[:, 1:T0]

    # A contract shorter than the base horizon still retains the whole base profile, because the
    # materialized endpoint is `max(T0, required)`.
    tiny = build_common_objects(
        rolling_config(fairness_set=[NONE], evaluation_horizon=5, lookahead_horizon=3);
        verbose=false,
    )
    @test required_period_support_end(tiny.context.config) == 7
    @test size(tiny.static_shares, 2) == rolling_data_end(tiny.context) == T0
    @test tiny.static_shares[:, 1:T0] == shares[:, 1:T0]

    # The rule is actually imposed on a window that reaches past T0.
    path = common.oos_paths[1]
    cache = cache_lookahead_trees(common.provider, common.context, path)
    baseline = simulate_configuration(
        common.context, path, cache, DETERMINISTIC_RH, NONE, common.static_shares,
    )
    state = replay_state(common, baseline, 23)
    tree = cache[(24, DETERMINISTIC_RH)]
    @test tree.last_period > T0
    refs = build_remaining_horizon_model(common.context, state, tree, config)
    add_fairness_constraints!(
        refs, STATIC_DEMAND_SHARE, fairness_past_state(state), config; static_shares=shares,
    )
    optimize!(refs.model)
    @test has_values(refs.model)
    for n in tree.nodes, j in 1:template.J
        @test isapprox(value(refs.lambda[j, n]), shares[j, tree.calendar_period[n]]; atol=1e-9)
    end

    # A table that does not cover the window is rejected by naming the gap.
    @test_throws ErrorException add_fairness_constraints!(
        build_remaining_horizon_model(common.context, state, tree, config),
        STATIC_DEMAND_SHARE, fairness_past_state(state), config;
        static_shares=shares[:, 1:T0],
    )
end

# =====================================================================================
# R6 The rolling simulation is a self-contained serial kernel
#
# Parallel readiness (plan section 4.9): independent invocations must not interfere, and neither
# controller order, fairness order nor invocation order may change any scientific value.
# =====================================================================================

@testset "R6 the rolling simulation is a self-contained serial kernel" begin
    config = rolling_config(
        controller_set=[DETERMINISTIC_RH, TWO_STAGE_RH],
        fairness_set=[NONE, STATIC_DEMAND_SHARE], two_stage_scenarios=2,
    )
    common = build_common_objects(config; verbose=false)
    path = common.oos_paths[1]
    cache = cache_lookahead_trees(common.provider, common.context, path)

    combos = [(c, p) for c in config.controller_set, p in config.fairness_set] |> vec
    forward = Dict(
        combo => simulate_configuration(
            common.context, path, cache, combo[1], combo[2], common.static_shares,
        )
        for combo in combos
    )
    backward = Dict(
        combo => simulate_configuration(
            common.context, path, cache, combo[1], combo[2], common.static_shares,
        )
        for combo in reverse(combos)
    )

    for combo in combos
        left, right = forward[combo], backward[combo]
        @test left.completed == right.completed
        @test left.periods_completed == right.periods_completed
        for (a, b) in zip(left.records, right.records)
            @test a.period == b.period
            @test a.action.shared_battery_mode == b.action.shared_battery_mode
            @test a.action.p == b.action.p
            @test a.action.z == b.action.z
            @test a.action.y == b.action.y
            @test a.soc_after == b.soc_after
        end
        @test left.final_state.cumulative_operating_cost ==
              right.final_state.cumulative_operating_cost
    end

    # Nothing the kernel reads was mutated by running it.
    @test rolling_price_matrix(common.context) ==
          build_period_data_support(common.template, 47).nu
    @test path.pv == common.oos_paths[1].pv
    @test length(cache) == rolling_solve_count(config) * length(config.controller_set)
    # A fresh context reproduces the run bit for bit.
    replayed = simulate_configuration(
        OOSRollingContext(config, common.template), path, cache,
        DETERMINISTIC_RH, NONE, common.static_shares,
    )
    reference = forward[(DETERMINISTIC_RH, NONE)]
    @test replayed.periods_completed == reference.periods_completed
    @test replayed.final_state.cumulative_operating_cost ==
          reference.final_state.cumulative_operating_cost
end

# =====================================================================================
# R7 Evaluation is measured against the contract, not against the repository horizon
# =====================================================================================

@testset "R7 evaluation is measured against the contract" begin
    # A contract shorter than the repository horizon: 10 evaluated periods on a T0 = 24 instance.
    config = rolling_config(evaluation_horizon=10, lookahead_horizon=6)
    common = build_common_objects(config; verbose=false)
    template = common.template
    @test config.evaluation_horizon < template.T

    path = common.oos_paths[1]
    @test path.horizon == rolling_realized_end(common.context) == 10
    cache = cache_lookahead_trees(common.provider, common.context, path)
    run = simulate_configuration(
        common.context, path, cache, DETERMINISTIC_RH, NONE, common.static_shares,
    )
    @test run.completed
    @test run.periods_completed == rolling_solve_count(config) == 10
    @test run.periods_completed != template.T
    @test last(run.records).period == config.evaluation_horizon

    metrics = compute_replication_metrics(template, run, config)
    @test metrics.completed
    @test metrics.horizon_covered == 1.0          # complete against H, not against T0
    @test !isnan(metrics.realized_alpha)          # horizon-total diagnostics are meaningful
    @test length(metrics.households) == template.J

    # A run that stops early is still labelled partial.
    truncated = ReplicationRun(
        run.replication_id, run.controller, run.fairness, false, 4, run.records[1:4],
        run.final_state, "probe", 0, 0, 0.0, 0.0, Float64[], 0,
    )
    partial = compute_replication_metrics(template, truncated, config)
    @test !partial.completed
    @test partial.horizon_covered == 0.4
    @test isnan(partial.realized_alpha)
end

# =====================================================================================
# R8 The temporal contract reaches the campaign metadata
#
# MIGRATED IN STAGE 6. This set used to assert that `implementation_step > 1` failed fast. Stage 6
# implements it, so what remains here is the metadata contract; the block behaviour itself is
# covered by the `B0`–`B6` sets.
# =====================================================================================

@testset "R8 the temporal contract reaches the campaign metadata" begin
    for h in (1, 2, 4, 10)
        config = rolling_config(implementation_step=h)
        @test config.implementation_step == h
        @test rolling_iteration_starts(config) == collect(1:h:24)
    end

    stepped = rolling_config(implementation_step=4)
    common = build_common_objects(stepped; verbose=false)
    @test rolling_realized_end(common.context) == 24

    document = experiment_config_dictionary(stepped, common.template)
    temporal = document["temporal_structure"]
    @test occursin("wired_rolling_blocks", temporal["contract_status"])
    @test temporal["implementation_step"] == 4
    @test temporal["known_prefix_length"] == 4
    @test temporal["realized_period_end"] == realized_period_end(stepped)
    @test temporal["required_period_support_end"] == required_period_support_end(stepped)
    @test temporal["repository_instance_horizon"] == common.template.T
    @test temporal["final_lookahead_window"] ==
          collect(lookahead_periods(stepped, final_rolling_iteration_start(stepped)))
    @test !haskey(temporal, "implementation_step_supported")
end

# =====================================================================================
# R9 Source gate: the campaign path never prices from a bare template
# =====================================================================================

@testset "R9 the campaign path prices through the rolling context" begin
    directory = joinpath(REPO_ROOT, "codes", "oos_experiment")

    # No layer may index the base `J x T0` price matrix by an abstract period any more. The only
    # sanctioned readers are the support builder (which extends it), the provider's consistency
    # check and the template constructor. The gate is literal, so even a docstring may not spell
    # the indexing form — that keeps it from rotting into a comment-only assertion.
    sanctioned = ("period_support.jl", "uncertainty_provider.jl", "simulator.jl")
    for file in readdir(directory; join=true)
        endswith(file, ".jl") || continue
        basename(file) in sanctioned && continue
        text = read(file, String)
        @test !occursin("template.nu[", text)
    end

    # The simulator loop iterates the rolling starts and never the repository horizon.
    simulator = read(joinpath(directory, "simulator.jl"), String)
    @test occursin("for t in rolling_iteration_starts(config)", simulator)
    @test !occursin("for t in 1:template.T", simulator)

    # The terminal target is written against the window end, not against `template.T`.
    physical = read(joinpath(directory, "physical_model.jl"), String)
    @test occursin("tau[n] == tree.last_period", physical)
    @test !occursin("tau[n] == template.T", physical)

    # The extension of the share table reuses the centralized mapping instead of restating it.
    fairness = read(joinpath(directory, "fairness_rules.jl"), String)
    @test occursin("base_period_index", fairness)
    @test !occursin("mod1", fairness)
end
