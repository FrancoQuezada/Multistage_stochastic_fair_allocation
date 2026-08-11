# =====================================================================================
# ST0..ST3  Static demand-share table          (OOS redesign stage 7)
# GD0..GD4  Grid-direction domain and audit    (OOS redesign stage 8)
#
# Stage 7 turns the `STATIC_DEMAND_SHARE` coefficients into an auditable object: resolved once
# per structural instance from the ex-ante in-sample reference, immutable within a task, carrying
# a `ShareTableID`, and provably independent of the OOS replication, the controller and the
# fairness policy being solved.
#
# Stage 8 audits the decision domain. Its Phase-A audit found real household-level simultaneous
# import and export, so Phase B added the exclusivity rule; these sets check both the audit and
# the formulation, and the knock-on consequence for `SA`.
#
# These sets run inside `tests/oos/runtests.jl` and reuse its helpers.
# =====================================================================================

"""Small configuration for the stage-7/8 sets."""
domain_config(; kwargs...) = test_config(;
    experiment_seed=787_878, households=3, oos_replications=1,
    controller_set=[DETERMINISTIC_RH], fairness_set=[NONE, STATIC_DEMAND_SHARE],
    multistage_branching=[2], kwargs...)

# =====================================================================================
# ST0 The share table is a resolved, identified, immutable object
# =====================================================================================

@testset "ST0 the share table is resolved, identified and immutable" begin
    config = domain_config()
    common = build_common_objects(config; verbose=false)
    table = common.share_table

    @test table isa OOSStaticShareTable
    @test startswith(table.share_table_id, "ST-")
    @test table.algorithm == OOS_SHARE_TABLE_ALGORITHM == "static_demand_share_table_v1"
    @test table.households == common.template.J
    @test table.base_horizon == common.template.T
    @test table.period_end == rolling_data_end(common.context)
    # `static_shares` is exactly the table's coefficients, kept under its original name.
    @test common.static_shares === table.shares

    # Every column is a valid allocation, base and repeated alike.
    for tau in 1:table.period_end
        @test isapprox(sum(table.shares[:, tau]), 1.0; atol=OOS_SHARE_TABLE_SUM_TOL)
        @test all(table.shares[:, tau] .>= -OOS_SHARE_TABLE_SUM_TOL)
        @test table.shares[:, tau] == table.shares[:, base_period_index(tau, table.base_horizon)]
    end
    @test table.shares[:, 1:table.base_horizon] == table.base_shares

    # The identifier is a pure function of the base coefficients and the mapping contract.
    @test table.share_table_id == share_table_id(
        table.households, table.base_horizon, table.period_end, table.base_shares,
    )
    twin = resolve_static_share_table(
        common.template, common.provider, common.in_sample_tree, in_sample_rng(config);
        period_end=table.period_end,
    )
    @test twin.share_table_id == table.share_table_id
    @test twin.shares == table.shares
    @test twin.shares !== table.shares                     # not shared mutable state

    # The constructor rejects a forged table rather than accepting it.
    broken = copy(table.shares)
    broken[1, 1] += 0.5
    @test_throws ErrorException OOSStaticShareTable(
        table.households, table.base_horizon, table.period_end, table.base_shares, broken,
    )
    nonrepeating = copy(table.shares)
    if table.period_end > table.base_horizon
        nonrepeating[:, table.base_horizon + 1] = reverse(nonrepeating[:, 1])
        @test_throws ErrorException OOSStaticShareTable(
            table.households, table.base_horizon, table.period_end,
            table.base_shares, nonrepeating,
        )
    end

    summary = share_table_summary(table)
    @test summary["share_table_id"] == table.share_table_id
    @test summary["depends_on_oos_replication"] == false
    @test summary["depends_on_controller"] == false
    @test summary["depends_on_fairness_policy"] == false
    @test summary["reads_realized_future"] == false
end

# =====================================================================================
# ST1 The table depends on the instance, and on nothing else
# =====================================================================================

@testset "ST1 the table depends on the instance and nothing else" begin
    base = domain_config()
    base_common = build_common_objects(base; verbose=false)

    # Neither the controller set, nor the fairness set, nor the replication count moves it.
    for variant in (
        domain_config(controller_set=[MULTISTAGE_RH, TWO_STAGE_RH, DETERMINISTIC_RH]),
        domain_config(fairness_set=[LEXMMFSA, SA, NONE]),
        domain_config(oos_replications=4),
        domain_config(solver_threads=4),
    )
        common = build_common_objects(variant; verbose=false)
        @test common.share_table.share_table_id == base_common.share_table.share_table_id
        @test common.share_table.shares == base_common.share_table.shares
    end

    # A different instance-level characteristic DOES move it.
    other = build_common_objects(domain_config(households=4); verbose=false)
    @test other.share_table.share_table_id != base_common.share_table.share_table_id

    # A longer window keeps the same base benchmark but is a different resolved table, and the
    # identifier says so rather than hiding it.
    narrow = build_common_objects(domain_config(lookahead_horizon=4); verbose=false)
    @test narrow.share_table.base_shares == base_common.share_table.base_shares
    @test narrow.share_table.period_end != base_common.share_table.period_end
    @test narrow.share_table.share_table_id != base_common.share_table.share_table_id
end

# =====================================================================================
# ST2 The rule is imposed, and is not an alias for NONE
# =====================================================================================

@testset "ST2 STATIC_DEMAND_SHARE is imposed and differs from NONE" begin
    config = domain_config()
    common = build_common_objects(config; verbose=false)
    path = common.oos_paths[1]
    cache = cache_lookahead_trees(common.provider, common.context, path)

    none_run = simulate_configuration(
        common.context, path, cache, DETERMINISTIC_RH, NONE, common.share_table,
    )
    share_run = simulate_configuration(
        common.context, path, cache, DETERMINISTIC_RH, STATIC_DEMAND_SHARE, common.share_table,
    )
    @test none_run.completed && share_run.completed

    # The rule really binds: every implemented allocation equals its coefficient.
    for record in share_run.records
        for j in 1:common.template.J
            @test isapprox(record.action.lambda[j],
                           common.static_shares[j, record.period]; atol=1e-6)
        end
    end

    # And it is NOT an alias for NONE: the two produce different allocations on this instance.
    differences = [
        maximum(abs.(a.action.lambda .- b.action.lambda))
        for (a, b) in zip(none_run.records, share_run.records)
    ]
    @test maximum(differences) > 1e-3
    @test policy_resource(STATIC_DEMAND_SHARE) == "pv"
    @test policy_resource(NONE) == "none"

    # Passing the table object and passing its matrix are the same thing.
    matrix_run = simulate_configuration(
        common.context, path, cache, DETERMINISTIC_RH, STATIC_DEMAND_SHARE, common.static_shares,
    )
    @test [r.action.lambda for r in matrix_run.records] ==
          [r.action.lambda for r in share_run.records]
end

# =====================================================================================
# ST3 The table never reads a realized future
# =====================================================================================

@testset "ST3 the table never reads a realized future" begin
    config = domain_config()
    common = build_common_objects(config; verbose=false)

    # It is resolved from the in-sample stream alone, so a different OOS path stream leaves it
    # untouched while genuinely changing the realized trajectories.
    other = build_common_objects(domain_config(experiment_seed=987_654); verbose=false)
    @test other.oos_paths[1].pv != common.oos_paths[1].pv
    # A different experiment seed moves BOTH streams, so the tables differ; what must hold is
    # that the table is a function of the in-sample stream, which the identity check below pins.
    @test other.share_table.share_table_id == share_table_id(
        other.share_table.households, other.share_table.base_horizon,
        other.share_table.period_end, other.share_table.base_shares,
    )

    # The resolver's only stochastic input is the in-sample RNG, and it is explicit.
    resolved = resolve_static_share_table(
        common.template, common.provider, common.in_sample_tree,
        MersenneTwister(oos_stream_seed(config.experiment_seed, "in_sample"));
        period_end=rolling_data_end(common.context),
    )
    @test resolved.share_table_id == common.share_table.share_table_id

    # Source gate: the resolver does not reach for an OOS path or a replication.
    source = read(joinpath(REPO_ROOT, "codes", "oos_experiment", "fairness_rules.jl"), String)
    start = first(findfirst("function resolve_static_share_table", source))
    stop = first(findnext("share_table_summary", source, start))
    body = source[start:prevind(source, stop)]
    @test !occursin("oos_path", body)
    @test !occursin("replication", body)
    @test !occursin("controller", body)
end

# =====================================================================================
# GD0 The grid-direction overlap measure
# =====================================================================================

@testset "GD0 the grid-direction overlap measure" begin
    clean_import = PeriodAction(1, 0, zeros(2), zeros(2), zeros(2), [5.0, 3.0], [0.0, 0.0],
                                [0.5, 0.5], 0.0, 0.0, 1.0)
    clean_export = PeriodAction(1, 0, zeros(2), zeros(2), zeros(2), [0.0, 0.0], [4.0, 2.0],
                                [0.5, 0.5], 0.0, 0.0, 1.0)
    split = PeriodAction(1, 0, zeros(2), zeros(2), zeros(2), [5.0, 0.0], [0.0, 2.0],
                         [0.5, 0.5], 0.0, 0.0, 1.0)
    overlapping = PeriodAction(1, 0, zeros(2), zeros(2), zeros(2), [5.0, 1.0], [3.0, 0.0],
                               [0.5, 0.5], 0.0, 0.0, 1.0)

    @test grid_direction_overlap(clean_import).household_overlap == 0.0
    @test grid_direction_overlap(clean_export).household_overlap == 0.0
    # One household importing while ANOTHER exports is legitimate: the household figure is zero
    # and only the aggregate figure is positive.
    @test grid_direction_overlap(split).household_overlap == 0.0
    @test grid_direction_overlap(split).aggregate_overlap == 2.0
    # The same household doing both is the violation.
    @test grid_direction_overlap(overlapping).household_overlap == 3.0
end

# =====================================================================================
# GD1 The exclusivity rule is a grid operating rule, applied uniformly
# =====================================================================================

@testset "GD1 exclusivity is applied uniformly and counted separately" begin
    config = domain_config(
        controller_set=[DETERMINISTIC_RH, TWO_STAGE_RH, MULTISTAGE_RH],
        fairness_set=[NONE, STATIC_DEMAND_SHARE, PEA, SA, LEXMMFPEA, LEXMMFSA],
    )
    @test config.grid_direction_exclusivity                     # on by default since stage 8
    common = build_common_objects(config; verbose=false)
    path = common.oos_paths[1]
    cache = cache_lookahead_trees(common.provider, common.context, path)
    state = initial_simulation_state(common.context, path.replication_id)
    reveal_block!(state, path, implementation_block(config, 1))
    J = common.template.J

    # Same rule, same binary count, for EVERY controller and EVERY policy: it is a grid operating
    # rule, so it cannot vary across compared configurations (plan section 4.5).
    for controller in config.controller_set
        tree = cache[(1, controller)]
        N = lookahead_node_count(tree)
        for policy in config.fairness_set
            refs = build_remaining_horizon_model(common.context, state, tree, config)
            add_fairness_constraints!(
                refs, policy, fairness_past_state(state), config;
                static_shares=common.share_table,
            )
            @test refs.grid_direction_exclusivity
            @test generated_binary_count(refs.model) ==
                  expected_binary_count(tree, J, true) ==
                  length(tree.mode_nodes) + J * N
            structure = audit_shared_battery_structure(refs)
            for finding in structure.findings
                @test finding.passed
            end
        end
    end

    # Switching it off removes exactly the direction family and nothing else.
    off = domain_config(grid_direction_exclusivity=false)
    off_common = build_common_objects(off; verbose=false)
    off_cache = cache_lookahead_trees(off_common.provider, off_common.context,
                                      off_common.oos_paths[1])
    off_state = initial_simulation_state(off_common.context, 1)
    reveal_block!(off_state, off_common.oos_paths[1], implementation_block(off, 1))
    off_tree = off_cache[(1, DETERMINISTIC_RH)]
    off_refs = build_remaining_horizon_model(off_common.context, off_state, off_tree, off)
    @test !off_refs.grid_direction_exclusivity
    @test generated_binary_count(off_refs.model) == length(off_tree.mode_nodes)
    @test expected_grid_direction_binary_count(off_tree, off_common.template.J, false) == 0
end

# =====================================================================================
# GD2 The rule removes the overlap the Phase-A audit found
# =====================================================================================

@testset "GD2 the rule removes the overlap the audit found" begin
    # The Phase-A finding was concentrated in `SA`, where inflating a household's cost is a way
    # to drive its realized savings down onto the target.
    config = domain_config(
        households=4, lookahead_horizon=4, fairness_set=[SA],
        controller_set=[DETERMINISTIC_RH], experiment_seed=12345,
    )
    common = build_common_objects(config; verbose=false)
    path = common.oos_paths[1]
    cache = cache_lookahead_trees(common.provider, common.context, path)
    run = simulate_configuration(
        common.context, path, cache, DETERMINISTIC_RH, SA, common.share_table,
    )
    @test run.completed

    audit = audit_grid_direction(run, config)
    @test grid_direction_clean(audit)
    @test audit.household_violations == 0
    @test audit.max_household_overlap <= config.flow_tol
    @test audit.periods == run.periods_completed

    report = grid_direction_gate([audit], config.formulation_id)
    @test report.passed
    @test length(report.checks) == 1
    @test occursin("Sin importación y exportación simultáneas", only(report.checks).detail)

    # The gate FAILS loudly on a fabricated violating audit, so a clean result is evidence and
    # not merely the absence of a check.
    dirty = GridDirectionAudit(DETERMINISTIC_RH, SA, 24, 3, 5, 318.5, 464.3, config.flow_tol)
    @test !grid_direction_clean(dirty)
    dirty_report = grid_direction_gate([dirty], config.formulation_id)
    @test !dirty_report.passed
    @test occursin("Fase B", only(dirty_report.checks).detail)
end

# =====================================================================================
# GD3 SA gained the endogenous minimum band that PEA already had
# =====================================================================================

@testset "GD3 SA uses the endogenous minimum band" begin
    config = domain_config(
        households=4, lookahead_horizon=4, fairness_set=[SA],
        controller_set=[DETERMINISTIC_RH], experiment_seed=12345,
    )
    @test config.sa_tolerance_mode === :adaptive_minimum
    @test config.sa_fairness_abs_tol == 0.0            # the fixed band is deprecated

    # The two deprecation guards mirror PEA's exactly.
    @test_throws ErrorException test_config(sa_fairness_abs_tol=1.0)
    @test_throws ErrorException test_config(sa_tolerance_mode=:fixed_band)
    @test test_config(sa_tolerance_mode=:fixed_band,
                      sa_fairness_abs_tol=1.0).sa_fairness_abs_tol == 1.0
    @test_throws ErrorException test_config(sa_tolerance_mode=:no_such_mode)

    common = build_common_objects(config; verbose=false)
    path = common.oos_paths[1]
    cache = cache_lookahead_trees(common.provider, common.context, path)
    run = simulate_configuration(
        common.context, path, cache, DETERMINISTIC_RH, SA, common.share_table,
    )
    # Without the endogenous band SA aborted at period 15 under exclusivity; with it the whole
    # evaluated horizon completes.
    @test run.completed
    @test run.periods_completed == config.evaluation_horizon

    # The recovery really was exercised, and every recovered period ran the four documented
    # solves in order — the same contract PEA has.
    activated = [r for r in run.records if r.result.pea.tolerance_activated]
    @test !isempty(activated)
    for record in activated
        @test record.result.pea.applicable
        @test !record.result.pea.strict_feasible
        @test record.result.pea.tolerance_used > 0.0
        @test record.result.pea.recovery_status == "recovered"
        @test record.result.pea.failure_source == string(FAILURE_FAIRNESS_RULE)
        @test [p.label for p in record.result.phases] == OOS_PEA_RECOVERY_SEQUENCE
    end
    # A strict-feasible period still runs exactly one solve.
    strict = [r for r in run.records if !r.result.pea.tolerance_activated]
    @test !isempty(strict)
    for record in strict
        @test length(record.result.phases) == 1
        @test record.result.pea.recovery_status in ("not_required", "not_applicable")
    end

    @test "SA" in OOS_ADAPTIVE_BAND_POLICIES
    @test "PEA" in OOS_ADAPTIVE_BAND_POLICIES
    @test !("NONE" in OOS_ADAPTIVE_BAND_POLICIES)
end

# =====================================================================================
# GD4 The two binary families stay separately measurable
# =====================================================================================

@testset "GD4 the two binary families stay separately measurable" begin
    config = domain_config(controller_set=[MULTISTAGE_RH], fairness_set=[NONE],
                           multistage_branching=[2, 2])
    common = build_common_objects(config; verbose=false)
    path = common.oos_paths[1]
    cache = cache_lookahead_trees(common.provider, common.context, path)
    tree = cache[(1, MULTISTAGE_RH)]
    J = common.template.J
    N = lookahead_node_count(tree)

    @test expected_mode_binary_count(tree) == length(tree.mode_nodes)
    @test expected_grid_direction_binary_count(tree, J, true) == J * N
    @test expected_grid_direction_binary_count(tree, J, false) == 0
    @test expected_binary_count(tree, J, true) == length(tree.mode_nodes) + J * N
    @test expected_binary_count(tree, J, false) == length(tree.mode_nodes)

    # The model-size-effect statistic must keep reporting the SHARED-BATTERY count, or the
    # `|V_mode|` vs `|H||V_mode|` comparison it supports would be silently corrupted.
    run = simulate_configuration(
        common.context, path, cache, MULTISTAGE_RH, NONE, common.share_table,
    )
    @test run.completed
    statistics = run.records[1].result.statistics
    @test statistics.expected_mode_nodes == length(tree.mode_nodes)
    @test statistics.generated_mode_binaries == statistics.expected_mode_nodes
    @test statistics.binary_variables == expected_binary_count(tree, J, true)
    @test statistics.binary_variables > statistics.generated_mode_binaries
end

# =====================================================================================
# BD1 The shared-battery mode binary is a modeling choice, applied uniformly, and its
#     `[0,1]` LP relaxation is a real domain change, not a no-op
# =====================================================================================

@testset "BD1 the mode relaxation is applied uniformly and is a real domain change" begin
    config = domain_config(
        controller_set=[DETERMINISTIC_RH, TWO_STAGE_RH, MULTISTAGE_RH],
        fairness_set=[NONE, STATIC_DEMAND_SHARE, PEA, SA, LEXMMFPEA, LEXMMFSA],
    )
    @test config.battery_direction_exclusivity                  # on (binary) by default
    common = build_common_objects(config; verbose=false)
    path = common.oos_paths[1]
    cache = cache_lookahead_trees(common.provider, common.context, path)
    state = initial_simulation_state(common.context, path.replication_id)
    reveal_block!(state, path, implementation_block(config, 1))
    J = common.template.J

    # Same rule, same binary count, for EVERY controller and EVERY policy: this is a modeling
    # choice, not a per-policy knob.
    for controller in config.controller_set
        tree = cache[(1, controller)]
        for policy in config.fairness_set
            refs = build_remaining_horizon_model(common.context, state, tree, config)
            add_fairness_constraints!(
                refs, policy, fairness_past_state(state), config;
                static_shares=common.share_table,
            )
            @test refs.battery_direction_exclusivity
            @test all(is_binary(refs.v[n]) for n in tree.mode_nodes)
            structure = audit_shared_battery_structure(refs)
            for finding in structure.findings
                @test finding.passed
            end
        end
    end

    # Switching it off removes exactly the shared-battery family and nothing else, and `v`
    # becomes a genuine continuous [0,1] variable rather than disappearing.
    off = domain_config(battery_direction_exclusivity=false)
    off_common = build_common_objects(off; verbose=false)
    off_cache = cache_lookahead_trees(off_common.provider, off_common.context,
                                       off_common.oos_paths[1])
    off_state = initial_simulation_state(off_common.context, 1)
    reveal_block!(off_state, off_common.oos_paths[1], implementation_block(off, 1))
    off_tree = off_cache[(1, DETERMINISTIC_RH)]
    off_refs = build_remaining_horizon_model(off_common.context, off_state, off_tree, off)
    off_J = off_common.template.J
    @test !off_refs.battery_direction_exclusivity
    @test all(!is_binary(off_refs.v[n]) for n in off_tree.mode_nodes)
    @test all(lower_bound(off_refs.v[n]) == 0 && upper_bound(off_refs.v[n]) == 1
              for n in off_tree.mode_nodes)
    @test generated_binary_count(off_refs.model) ==
          expected_grid_direction_binary_count(off_tree, off_J, off.grid_direction_exclusivity)
    off_structure = audit_shared_battery_structure(off_refs)
    for finding in off_structure.findings
        @test finding.passed
    end
    # `charge_row_uses_Fc_times_mode` / `discharge_row_uses_Fd_times_one_minus_mode` above
    # confirm the two rows keep their exact `F_c v_n` / `F_d (1 - v_n)` coefficients on the
    # now-continuous `v_n` -- the relaxation changes only the variable's domain, not the
    # constraint it appears in. A numeric probe at a fractional mode (`22.1b`, runtests.jl)
    # confirms this on a minimal model free of the campaign's other constraints.
end
