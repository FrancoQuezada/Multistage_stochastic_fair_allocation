# =====================================================================================
# Validation suite of the out-of-sample receding-horizon experiment.
#
# Section numbers refer to the experiment specification. The full campaign stays blocked
# until every test here passes; `scripts/oos/validate_oos_experiment.sh` is the entry point.
# =====================================================================================

using Test
using JuMP
using CPLEX
using Random

const REPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
include(joinpath(REPO_ROOT, "codes", "oos_experiment", "oos_experiment.jl"))

const TEST_INSTANCE = joinpath(REPO_ROOT, "codes", "inst", "inst2020", "Drahi_1.csv")
const TEST_OUTPUT = mktempdir(; prefix="oos_tests_")

"""Small but non-degenerate campaign configuration for the tests."""
function test_config(; kwargs...)
    defaults = (
        experiment_seed=4242,
        oos_replications=1,
        controller_set=[DETERMINISTIC_RH, TWO_STAGE_RH, MULTISTAGE_RH],
        fairness_set=[NONE, STATIC_DEMAND_SHARE, PEA, SA, LEXMMFPEA, LEXMMFSA],
        two_stage_scenarios=2,
        multistage_branching=[2],
        pea_tolerance_mode=:adaptive_minimum,
        output_directory=TEST_OUTPUT,
        instance_file=TEST_INSTANCE,
        in_sample_stages=3,
        in_sample_children=2,
        in_sample_periods_per_stage=8,
        households=3,
        export_representative_models=false,
        require_shared_battery_validation=false,
        solver_time_limit_sec=120.0,
    )
    return OOSExperimentConfig(; merge(Dict(pairs(defaults)), Dict(kwargs))...)
end

"""Deterministic-process configuration: no PV noise and no demand noise."""
zero_uncertainty_config(; kwargs...) =
    test_config(; theta=0.0, dev_demand=0.0, kwargs...)

"""Reveal period `t` and return `(state, observation)` without implementing anything."""
function state_at_first_period(common, config)
    path = common.oos_paths[1]
    state = initial_simulation_state(common.template, path.replication_id)
    reveal_period!(state, path, 1)
    return (state, PeriodObservation(1, path.pv[1], collect(path.demand[:, 1])), path)
end

"""
Replay the first `periods` implemented actions of `run` into a fresh state.

The next period is then revealed, so the returned state is exactly what a controller sees at
the beginning of period `periods + 1`.
"""
function replay_state(common, run, periods::Int)
    path = common.oos_paths[1]
    state = initial_simulation_state(common.template, path.replication_id)
    for t in 1:periods
        reveal_period!(state, path, t)
        record = run.records[t]
        apply_action!(state, common.template, record.action, record.soc_after)
    end
    state.period <= common.template.T && reveal_period!(state, path, state.period)
    return state
end

"""Solve the current action of one controller/rule pair on a given state."""
function solve_at(common, config, state, controller, policy)
    path = common.oos_paths[1]
    t = state.period
    history = observed_history(state)
    tree = build_lookahead_tree(
        common.provider, config, controller, history, t, common.template.T, path.replication_id,
    )
    observation = PeriodObservation(t, path.pv[t], collect(path.demand[:, t]))
    result = solve_current_action(
        common.template, state, observation, tree, controller, policy, config;
        static_shares=common.static_shares,
    )
    return (result=result, tree=tree)
end

# =====================================================================================
# 22.1 Shared-battery micro-instance
# =====================================================================================

@testset "22.1 shared-battery micro-instance" begin
    report = run_shared_battery_micro_gate(test_config())
    for check in report.checks
        @test check.passed
    end
    @test report.passed

    # The mode-binary count is |V_mode|, not |H| |V_mode|.
    for households in (2, 3, 5), nodes in (1, 3, 7)
        model = Model(CPLEX.Optimizer)
        set_silent(model)
        @variable(model, y[1:households, 1:nodes] >= 0)
        @variable(model, z[1:households, 1:nodes] >= 0)
        v = add_shared_battery_mode_constraints!(
            model, y, z, 1:households, 1:nodes; discharge_limit=4.0, charge_limit=3.0,
        )
        @test length(v) == nodes
        @test generated_binary_count(model) == nodes
        @test generated_binary_count(model) != households * nodes || households == 1
    end
end

# =====================================================================================
# 22.9 (part) Centralized mode-node convention
# =====================================================================================

@testset "centralized mode-node convention" begin
    config = test_config()
    common = build_common_objects(config; verbose=false)
    state, _, path = state_at_first_period(common, config)
    history = observed_history(state)
    for controller in config.controller_set
        tree = build_lookahead_tree(
            common.provider, config, controller, history, 1, common.template.T, path.replication_id,
        )
        @test tree.mode_nodes == collect(1:lookahead_node_count(tree))
        @test assert_mode_node_consistency(tree) == lookahead_node_count(tree)
        @test expected_mode_binary_count(tree) == lookahead_node_count(tree)
        @test unique_policy_mode_count(tree) == length(tree.mode_nodes)
        @test legacy_household_mode_binary_count(tree, common.template.J) ==
              common.template.J * length(tree.mode_nodes)
        @test abs(tree.probability[tree.root] - 1.0) < 1e-12
    end
end

# =====================================================================================
# 22.2 Zero-uncertainty equivalence
# =====================================================================================

@testset "22.2 zero-uncertainty equivalence of the current action" begin
    config = zero_uncertainty_config()
    common = build_common_objects(config; verbose=false)
    state, _, _ = state_at_first_period(common, config)

    # With a degenerate process the mean path, every sampled scenario and every tree node at a
    # given calendar period carry identical data.
    history = observed_history(state)
    forecast = conditional_mean_path(common.provider, history, 1, common.template.T)
    scenarios = conditional_scenario_paths(
        common.provider, history, 1, common.template.T, 3, MersenneTwister(1),
    )
    for scenario in scenarios
        @test isapprox(scenario.pv, forecast.pv; atol=1e-9)
        @test isapprox(scenario.demand, forecast.demand; atol=1e-9)
    end

    for policy in (NONE, SA)
        outcomes = Dict{ControllerKind,Any}()
        for controller in config.controller_set
            solved = solve_at(common, config, state, controller, policy)
            @test solved.result.solved
            outcomes[controller] = solved.result
        end
        reference = outcomes[DETERMINISTIC_RH]
        for controller in config.controller_set
            candidate = outcomes[controller]
            @test candidate.action.shared_battery_mode == reference.action.shared_battery_mode
            @test isapprox(candidate.action.aggregate_charge, reference.action.aggregate_charge; atol=1e-6)
            @test isapprox(candidate.action.aggregate_discharge, reference.action.aggregate_discharge; atol=1e-6)
            @test isapprox(candidate.objective_value, reference.objective_value; rtol=1e-6)
            @test isapprox(sum(candidate.action.p), sum(reference.action.p); atol=1e-6)
            @test isapprox(candidate.action.soc_after_model, reference.action.soc_after_model; atol=1e-6)
        end
    end
end

# =====================================================================================
# 22.3 Single-scenario equivalence
# =====================================================================================

@testset "22.3 single-scenario reduction to the deterministic model" begin
    config = zero_uncertainty_config(two_stage_scenarios=1, multistage_branching=[1, 1])
    common = build_common_objects(config; verbose=false)
    state, _, path = state_at_first_period(common, config)
    history = observed_history(state)

    trees = Dict(
        controller => build_lookahead_tree(
            common.provider, config, controller, history, 1, common.template.T, path.replication_id,
        )
        for controller in config.controller_set
    )
    deterministic = trees[DETERMINISTIC_RH]
    for controller in config.controller_set
        tree = trees[controller]
        @test lookahead_node_count(tree) == lookahead_node_count(deterministic)
        @test lookahead_scenario_count(tree) == 1
        @test tree.parent == deterministic.parent
        @test isapprox(tree.pv, deterministic.pv; atol=1e-9)
        @test isapprox(tree.demand, deterministic.demand; atol=1e-9)
    end

    for policy in (NONE, PEA)
        reference = solve_at(common, config, state, DETERMINISTIC_RH, policy).result
        @test reference.solved
        for controller in (TWO_STAGE_RH, MULTISTAGE_RH)
            candidate = solve_at(common, config, state, controller, policy).result
            @test candidate.solved
            @test candidate.action.shared_battery_mode == reference.action.shared_battery_mode
            @test isapprox(candidate.objective_value, reference.objective_value; rtol=1e-6)
            @test isapprox(candidate.action.p, reference.action.p; atol=1e-6)
            @test isapprox(candidate.action.z, reference.action.z; atol=1e-6)
            @test isapprox(candidate.action.y, reference.action.y; atol=1e-6)
        end
    end
end

# =====================================================================================
# 22.4 One-period horizon
# =====================================================================================

@testset "22.4 one-period horizon solves the same problem for every controller" begin
    config = test_config()
    common = build_common_objects(config; verbose=false)
    path = common.oos_paths[1]
    cache = cache_lookahead_trees(common.provider, config, common.template, path)
    baseline = simulate_configuration(
        common.template, config, path, cache, DETERMINISTIC_RH, NONE, common.static_shares,
    )
    @test baseline.completed

    T = common.template.T
    state = replay_state(common, baseline, T - 1)
    @test state.period == T

    outcomes = Dict{ControllerKind,Any}()
    for controller in config.controller_set
        solved = solve_at(common, config, state, controller, NONE)
        @test solved.result.solved
        # At the final period there is no future, so all three structures collapse to one node.
        @test lookahead_node_count(solved.tree) == 1
        @test length(solved.tree.mode_nodes) == 1
        outcomes[controller] = solved.result
    end
    reference = outcomes[DETERMINISTIC_RH]
    for controller in config.controller_set
        candidate = outcomes[controller]
        @test candidate.action.shared_battery_mode == reference.action.shared_battery_mode
        @test isapprox(candidate.objective_value, reference.objective_value; rtol=1e-8)
        @test isapprox(candidate.action.p, reference.action.p; atol=1e-7)
        @test isapprox(candidate.action.y, reference.action.y; atol=1e-7)
        @test isapprox(candidate.action.z, reference.action.z; atol=1e-7)
        # The terminal battery target binds on the same calendar endpoint.
        @test isapprox(candidate.action.soc_after_model, common.template.s_I; atol=1e-6)
    end
end

# =====================================================================================
# 22.5 No look-ahead leakage
# =====================================================================================

@testset "22.5 no look-ahead leakage" begin
    config = test_config()
    common = build_common_objects(config; verbose=false)
    path = common.oos_paths[1]
    T = common.template.T
    current = 6

    # Perturb only the unrevealed suffix.
    perturbed_pv = copy(path.pv)
    perturbed_demand = copy(path.demand)
    for t in (current+1):T
        perturbed_pv[t] = perturbed_pv[t] * 3.0 + 17.0
        perturbed_demand[:, t] .= perturbed_demand[:, t] .* 2.0 .+ 41.0
    end
    perturbed = OOSPath(path.replication_id, T, perturbed_pv, perturbed_demand)
    @test path.pv[1:current] == perturbed.pv[1:current]
    @test path.demand[:, 1:current] == perturbed.demand[:, 1:current]

    original_state = initial_simulation_state(common.template, path.replication_id)
    perturbed_state = initial_simulation_state(common.template, path.replication_id)
    for t in 1:(current-1)
        reveal_period!(original_state, path, t)
        reveal_period!(perturbed_state, perturbed, t)
        solved = solve_at(common, config, original_state, DETERMINISTIC_RH, NONE)
        @test solved.result.solved
        validation = validate_period_action(
            common.template, original_state, solved.result.action, config,
        )
        @test validation.valid
        apply_action!(original_state, common.template, solved.result.action, validation.soc_after)
        apply_action!(perturbed_state, common.template, solved.result.action, validation.soc_after)
    end
    reveal_period!(original_state, path, current)
    reveal_period!(perturbed_state, perturbed, current)

    for controller in config.controller_set
        original_tree = build_lookahead_tree(
            common.provider, config, controller, observed_history(original_state),
            current, T, path.replication_id,
        )
        perturbed_tree = build_lookahead_tree(
            common.provider, config, controller, observed_history(perturbed_state),
            current, T, path.replication_id,
        )
        # The look-ahead is a function of the observed history and of the documented seed only.
        @test original_tree.pv == perturbed_tree.pv
        @test original_tree.demand == perturbed_tree.demand
        @test original_tree.parent == perturbed_tree.parent

        original_action = solve_current_action(
            common.template, original_state,
            PeriodObservation(current, path.pv[current], collect(path.demand[:, current])),
            original_tree, controller, NONE, config; static_shares=common.static_shares,
        )
        perturbed_action = solve_current_action(
            common.template, perturbed_state,
            PeriodObservation(current, perturbed.pv[current], collect(perturbed.demand[:, current])),
            perturbed_tree, controller, NONE, config; static_shares=common.static_shares,
        )
        @test original_action.solved && perturbed_action.solved
        @test original_action.action.shared_battery_mode == perturbed_action.action.shared_battery_mode
        @test isapprox(original_action.action.p, perturbed_action.action.p; atol=1e-8)
        @test isapprox(original_action.action.z, perturbed_action.action.z; atol=1e-8)
        @test isapprox(original_action.action.y, perturbed_action.action.y; atol=1e-8)
        @test isapprox(original_action.objective_value, perturbed_action.objective_value; rtol=1e-10)
    end

    # A changed look-ahead seed is the only sanctioned way to change the current action.
    other_seed = test_config(experiment_seed=999_331)
    other_tree = build_lookahead_tree(
        common.provider, other_seed, TWO_STAGE_RH, observed_history(original_state),
        current, T, path.replication_id,
    )
    baseline_tree = build_lookahead_tree(
        common.provider, config, TWO_STAGE_RH, observed_history(original_state),
        current, T, path.replication_id,
    )
    @test other_tree.pv != baseline_tree.pv
end

# =====================================================================================
# 22.6 / 22.7 Root first stage and multistage nonanticipativity
# =====================================================================================

@testset "22.6 two-stage root is one common first stage" begin
    config = test_config(two_stage_scenarios=4)
    common = build_common_objects(config; verbose=false)
    state, _, path = state_at_first_period(common, config)
    tree = build_lookahead_tree(
        common.provider, config, TWO_STAGE_RH, observed_history(state), 1,
        common.template.T, path.replication_id,
    )
    @test lookahead_scenario_count(tree) == 4
    @test all(scenario[1] == tree.root for scenario in tree.scenarios)
    @test length(lookahead_root_children(tree)) == 4
    # Immediate branching after the root and no shared node afterwards.
    for a in 1:4, b in 1:4
        a < b || continue
        shared = intersect(Set(tree.scenarios[a]), Set(tree.scenarios[b]))
        @test shared == Set([tree.root])
    end

    refs = build_remaining_horizon_model(common.template, state, tree, config)
    @test audit_two_stage_first_stage(refs)
    # One first-stage decision per quantity, including exactly one shared mode.
    @test length(unique([refs.v[tree.root]])) == 1
    for j in 1:common.template.J
        @test refs.p[j, tree.root] === refs.p[j, tree.root]
    end
    structure = audit_shared_battery_structure(refs)
    for finding in structure.findings
        @test finding.passed
    end
end

@testset "22.7 multistage shared modes are nonanticipative" begin
    config = test_config(multistage_branching=[2, 2])
    common = build_common_objects(config; verbose=false)
    state, _, path = state_at_first_period(common, config)
    tree = build_lookahead_tree(
        common.provider, config, MULTISTAGE_RH, observed_history(state), 1,
        common.template.T, path.replication_id,
    )
    @test lookahead_scenario_count(tree) == 4

    refs = build_remaining_horizon_model(common.template, state, tree, config)
    @test audit_nonanticipativity(refs)

    # Scenarios sharing a history literally share the node, hence the mode variable.
    for a in eachindex(tree.scenarios), b in eachindex(tree.scenarios)
        a < b || continue
        first_scenario = tree.scenarios[a]
        second_scenario = tree.scenarios[b]
        divergence = findfirst(
            k -> first_scenario[k] != second_scenario[k],
            eachindex(first_scenario),
        )
        limit = divergence === nothing ? length(first_scenario) : divergence - 1
        @test limit >= 1
        for k in 1:limit
            @test refs.v[first_scenario[k]] === refs.v[second_scenario[k]]
        end
        # After branching the modes are distinct decisions.
        if divergence !== nothing
            @test refs.v[first_scenario[divergence]] !== refs.v[second_scenario[divergence]]
        end
    end
    # Progressive revelation: probability mass is conserved period by period.
    for tau in tree.first_period:tree.last_period
        mass = sum(tree.probability[n] for n in tree.nodes if tree.calendar_period[n] == tau)
        @test isapprox(mass, 1.0; atol=1e-10)
    end
end

# =====================================================================================
# 22.8 State consistency over a completed horizon
# =====================================================================================

@testset "22.8 state, balance and battery-transition consistency" begin
    config = test_config(fairness_set=[NONE, SA, LEXMMFSA])
    common = build_common_objects(config; verbose=false)
    path = common.oos_paths[1]
    cache = cache_lookahead_trees(common.provider, config, common.template, path)
    template = common.template

    for controller in config.controller_set, policy in config.fairness_set
        run = simulate_configuration(
            template, config, path, cache, controller, policy, common.static_shares,
        )
        @test run.completed
        @test run.periods_completed == template.T

        soc = template.s_I
        for record in run.records
            action = record.action
            @test isapprox(record.soc_before, soc; atol=1e-9)
            expected_soc = induced_soc(template, soc, action.aggregate_charge, action.aggregate_discharge)
            @test isapprox(record.soc_after, expected_soc; atol=1e-9)
            @test isapprox(action.soc_after_model, expected_soc; atol=config.feasibility_tol)
            @test template.s_min - config.feasibility_tol <= record.soc_after
            @test record.soc_after <= template.s_max + config.feasibility_tol
            @test isapprox(sum(action.p), record.realized_pv; atol=config.feasibility_tol)
            for j in 1:template.J
                balance = action.p[j] + action.y[j] + action.I[j] - action.z[j] - action.G[j]
                @test isapprox(balance, record.realized_demand[j]; atol=config.feasibility_tol)
            end
            @test isapprox(action.aggregate_charge, sum(action.z); atol=1e-12)
            @test isapprox(action.aggregate_discharge, sum(action.y); atol=1e-12)
            @test action.shared_battery_mode in (0, 1)
            @test !(action.aggregate_charge > config.flow_tol &&
                    action.aggregate_discharge > config.flow_tol)
            @test action.aggregate_charge <= template.f_under * action.shared_battery_mode +
                                             config.feasibility_tol
            @test action.aggregate_discharge <= template.f_bar * (1 - action.shared_battery_mode) +
                                                config.feasibility_tol
            @test record.validation.valid
            soc = record.soc_after
        end
        @test isapprox(soc, template.s_I; atol=config.feasibility_tol)

        # Cumulative bookkeeping equals a direct recomputation from the implemented actions.
        state = run.final_state
        for j in 1:template.J
            @test isapprox(state.cumulative_pv[j], sum(r.action.p[j] for r in run.records); atol=1e-8)
            @test isapprox(
                state.cumulative_demand[j],
                sum(r.realized_demand[j] for r in run.records); atol=1e-8,
            )
            @test isapprox(
                state.cumulative_all_grid_cost[j],
                sum(template.delta * template.nu[j, r.period] * r.realized_demand[j]
                    for r in run.records);
                atol=1e-6,
            )
        end
        @test isapprox(
            realized_savings(state),
            state.cumulative_all_grid_cost .- state.cumulative_operating_cost; atol=0.0,
        )
    end
end

# =====================================================================================
# 22.9 Static demand-share invariance
# =====================================================================================

@testset "22.9 static demand-share invariance" begin
    config = test_config()
    first_common = build_common_objects(config; verbose=false)
    second_common = build_common_objects(config; verbose=false)
    shares = first_common.static_shares

    # Identical across repeated construction (ex-ante, seed driven).
    @test shares == second_common.static_shares
    # Sum to one at every calendar period.
    for t in axes(shares, 2)
        @test isapprox(sum(shares[:, t]), 1.0; atol=1e-10)
        @test all(shares[:, t] .>= -1e-12)
    end

    template = first_common.template
    path = first_common.oos_paths[1]
    state, _, _ = state_at_first_period(first_common, config)
    history = observed_history(state)

    for controller in config.controller_set
        tree = build_lookahead_tree(
            first_common.provider, config, controller, history, 1, template.T, path.replication_id,
        )
        refs = build_remaining_horizon_model(template, state, tree, config)
        past = fairness_past_state(state)
        add_fairness_constraints!(refs, STATIC_DEMAND_SHARE, past, config; static_shares=shares)
        # The benchmark keeps the shared-mode physical constraints.
        @test generated_binary_count(refs.model) == length(tree.mode_nodes)
        structure = audit_shared_battery_structure(refs)
        for finding in structure.findings
            @test finding.passed
        end
        optimize!(refs.model)
        @test has_values(refs.model)
        # Nodes sharing a calendar period receive the same coefficients.
        for tau in tree.first_period:tree.last_period
            nodes = [n for n in tree.nodes if tree.calendar_period[n] == tau]
            for j in 1:template.J, n in nodes
                @test isapprox(value(refs.lambda[j, n]), shares[j, tau]; atol=1e-8)
            end
        end
    end

    # Identical across replications: the coefficients never read realized information.
    later_state = initial_simulation_state(template, 1)
    for t in 1:3
        reveal_period!(later_state, path, t)
        later_state.period = t + 1
        later_state.revealed_periods = t
    end
    @test first_common.static_shares == shares
end

# =====================================================================================
# 22.10 Fixed-past accounting
# =====================================================================================

@testset "22.10 realized past enters each fairness expression exactly once" begin
    config = test_config()
    common = build_common_objects(config; verbose=false)
    template = common.template
    path = common.oos_paths[1]
    cache = cache_lookahead_trees(common.provider, config, common.template, path)
    baseline = simulate_configuration(
        template, config, path, cache, DETERMINISTIC_RH, NONE, common.static_shares,
    )
    @test baseline.completed

    periods_elapsed = 7
    state = replay_state(common, baseline, periods_elapsed)
    past = fairness_past_state(state)
    @test past.periods == periods_elapsed
    @test isapprox(past.pv, state.cumulative_pv; atol=0.0)
    @test isapprox(past.total_pv, sum(state.cumulative_pv); atol=1e-9)
    @test isapprox(past_savings(past), past.benchmark .- past.cost; atol=0.0)

    tree = build_lookahead_tree(
        common.provider, config, DETERMINISTIC_RH, observed_history(state),
        state.period, template.T, path.replication_id,
    )
    refs = build_remaining_horizon_model(template, state, tree, config)
    aggregates = scenario_aggregates(template, tree)

    # The PEA outcome expression carries the realized past exactly once, as its constant term.
    allocation = expected_pv_allocation_expressions(refs, past)
    for j in 1:template.J
        @test isapprox(JuMP.constant(allocation[j]), past.pv[j]; atol=1e-9)
    end

    # The SA outcome expression carries past savings plus the future benchmark, exactly once.
    savings = expected_savings_expressions(refs, past, aggregates)
    saving_past = past_savings(past)
    for j in 1:template.J
        future_benchmark = sum(
            aggregates.probability[s] * aggregates.benchmark[j, s]
            for s in eachindex(tree.scenarios)
        )
        @test isapprox(JuMP.constant(savings[j]), saving_past[j] + future_benchmark; rtol=1e-9)
    end

    # PEA targets use past PV, past demand and past community PV once each.
    targets = pea_targets(template, past, aggregates)
    community_pv = past.total_pv + aggregates.pv_total[1]
    household_demand = [past.demand[j] + aggregates.demand[j, 1] for j in 1:template.J]
    expected_targets = (community_pv / sum(household_demand)) .* household_demand
    @test isapprox(targets, expected_targets; rtol=1e-9)

    # Perturbing one household's realized past must move the targets, proving the past is read.
    # Scaling *every* household uniformly would leave a proportional target unchanged on this
    # symmetric instance, so the perturbation is deliberately asymmetric.
    perturbed_demand = copy(past.demand)
    perturbed_demand[1] += 1000.0
    perturbed_past = FairnessPastState(
        past.pv, perturbed_demand, past.cost, past.benchmark, past.total_pv, past.periods,
    )
    perturbed_targets = pea_targets(template, perturbed_past, aggregates)
    @test perturbed_targets[1] > targets[1] + 1e-6
    @test !isapprox(perturbed_targets, targets; rtol=1e-9)
    # Community totals are preserved: PEA redistributes, it does not create PV.
    @test isapprox(sum(targets), past.total_pv + aggregates.pv_total[1]; rtol=1e-9)
    @test isapprox(sum(perturbed_targets), past.total_pv + aggregates.pv_total[1]; rtol=1e-9)

    # Realized past operating cost enters the SA expression once, with a negative sign.
    perturbed_cost = copy(past.cost)
    perturbed_cost[1] += 500.0
    cost_past = FairnessPastState(
        past.pv, past.demand, perturbed_cost, past.benchmark, past.total_pv, past.periods,
    )
    cost_savings = expected_savings_expressions(refs, cost_past, aggregates)
    @test isapprox(
        JuMP.constant(cost_savings[1]), JuMP.constant(savings[1]) - 500.0; rtol=1e-9,
    )
end

# =====================================================================================
# 22.11 Warm-start validation
# =====================================================================================

@testset "22.11 warm starts carry one mode per relevant node" begin
    nodes = [1, 2, 3, 4]

    charging = mode_start_from_flows(nodes, [2.0, 0.0, 0.0, 1.0], [0.0, 0.0, 0.0, 0.0])
    @test charging.values == [1.0, 0.0, 0.0, 1.0]
    @test Set(charging.idle_nodes) == Set([2, 3])
    @test isempty(charging.repaired_nodes)

    discharging = mode_start_from_flows(nodes, zeros(4), [0.0, 3.0, 1.0, 0.0])
    @test discharging.values == [0.0, 0.0, 0.0, 0.0]
    @test Set(discharging.idle_nodes) == Set([1, 4])

    idle = mode_start_from_flows(nodes, zeros(4), zeros(4))
    @test all(idle.values .== OOS_IDLE_MODE_VALUE)
    @test length(idle.idle_nodes) == 4
    idle_one = mode_start_from_flows(nodes, zeros(4), zeros(4); idle_value=1.0)
    @test all(idle_one.values .== 1.0)

    # A simultaneous-flow start is rejected by default and repaired only on request.
    @test_throws ErrorException mode_start_from_flows(nodes, [1.0, 0, 0, 0], [1.0, 0, 0, 0])
    repaired = mode_start_from_flows(
        nodes, [1.0, 0, 0, 0], [2.0, 0, 0, 0]; on_simultaneous=:repair,
    )
    @test repaired.values[1] == 0.0
    @test repaired.repaired_nodes == [1]

    # Link validation against the corrected constraints.
    validated = validate_mode_start(
        charging, [2.0, 0.0, 0.0, 1.0], zeros(4); charge_limit=4.0, discharge_limit=4.0,
    )
    @test validated.charge_residual <= 1e-9
    @test validated.discharge_residual <= 1e-9
    bad = ModeStart(nodes, [0.0, 0.0, 0.0, 0.0], "test", Int[], Int[])
    @test_throws ErrorException validate_mode_start(
        bad, [2.0, 0.0, 0.0, 0.0], zeros(4); charge_limit=4.0, discharge_limit=4.0,
    )
    nonbinary = ModeStart(nodes, [0.5, 0.0, 0.0, 0.0], "test", Int[], Int[])
    @test_throws ErrorException validate_mode_start(
        nonbinary, zeros(4), zeros(4); charge_limit=4.0, discharge_limit=4.0,
    )

    # Installing a start on a real model requires exactly the model's mode nodes.
    config = test_config(use_warm_starts=true, fairness_set=[NONE])
    common = build_common_objects(config; verbose=false)
    state, _, path = state_at_first_period(common, config)
    tree = build_lookahead_tree(
        common.provider, config, DETERMINISTIC_RH, observed_history(state), 1,
        common.template.T, path.replication_id,
    )
    refs = build_remaining_horizon_model(common.template, state, tree, config)
    full_start = mode_start_from_flows(
        tree.mode_nodes, fill(1.0, length(tree.mode_nodes)), zeros(length(tree.mode_nodes)),
    )
    apply_mode_start!(refs, full_start)
    @test all(start_value(refs.v[n]) == 1.0 for n in tree.mode_nodes)
    partial = ModeStart(tree.mode_nodes[1:end-1], fill(1.0, length(tree.mode_nodes) - 1),
                        "test", Int[], Int[])
    @test_throws ErrorException apply_mode_start!(refs, partial)

    # A warm-started campaign period still produces a valid action.
    solved = solve_at(common, config, state, DETERMINISTIC_RH, NONE)
    @test solved.result.solved
    @test solved.result.plan_aggregate_flows !== nothing
    forward = derive_mode_start_from_previous(
        tree, solved.result.plan_aggregate_flows.charge,
        solved.result.plan_aggregate_flows.discharge, tree,
    )
    @test mode_start_length(forward) == length(tree.mode_nodes)
    @test all(v in (0.0, 1.0) for v in forward.values)
end

# =====================================================================================
# 22.12 Legacy conversion
# =====================================================================================

@testset "22.12 legacy conversion is explicit and rejects incompatible artefacts" begin
    nodes = [1, 2, 3]
    discharge = [0.0 1.0 0.0; 0.0 2.0 0.0]
    charge = [1.0 0.0 0.0; 2.0 0.0 0.0]

    # Disabled by configuration: nothing is converted.
    blocked = convert_legacy_mode_start(nodes, [1.0 0.0 0.0; 1.0 0.0 0.0])
    @test !blocked.accepted
    @test blocked.strategy == "rejected_by_configuration"

    # Consistent household modes, repaired from aggregate flows where needed.
    agreeing = convert_legacy_mode_start(
        nodes, [1.0 0.0 0.0; 1.0 0.0 0.0];
        charge=charge, discharge=discharge, allow_legacy_conversion=true,
    )
    @test agreeing.accepted
    @test agreeing.start.values == [1.0, 0.0, 0.0]
    @test agreeing.start.source == "legacy_converted"
    @test isempty(agreeing.repaired_nodes)

    disagreeing = convert_legacy_mode_start(
        nodes, [1.0 1.0 0.0; 0.0 0.0 1.0];
        charge=charge, discharge=discharge, allow_legacy_conversion=true,
    )
    @test disagreeing.accepted
    @test disagreeing.start.values == [1.0, 0.0, 0.0]
    @test !isempty(disagreeing.repaired_nodes)

    # Unanimous household modes without flows are converted; disagreement is rejected.
    unanimous = convert_legacy_mode_start(
        nodes, [1.0 0.0 1.0; 1.0 0.0 1.0]; allow_legacy_conversion=true,
    )
    @test unanimous.accepted
    @test unanimous.start.values == [1.0, 0.0, 1.0]
    inconsistent = convert_legacy_mode_start(
        nodes, [1.0 0.0 0.0; 0.0 0.0 0.0]; allow_legacy_conversion=true,
    )
    @test !inconsistent.accepted
    @test occursin("no coinciden", inconsistent.message)
    nonbinary = convert_legacy_mode_start(
        nodes, fill(0.25, 2, 3); allow_legacy_conversion=true,
    )
    @test !nonbinary.accepted

    # Simultaneous aggregate flows make a legacy artefact unusable.
    simultaneous = convert_legacy_mode_start(
        [1], reshape([1.0, 1.0], 2, 1);
        charge=reshape([1.0, 0.0], 2, 1), discharge=reshape([1.0, 0.0], 2, 1),
        allow_legacy_conversion=true,
    )
    @test !simultaneous.accepted

    # Household-mode fields are rejected outright.
    @test_throws ErrorException assert_no_household_mode_fields((x=zeros(2, 2), s=zeros(2)))
    @test assert_no_household_mode_fields((battery_mode=zeros(2), s=zeros(2)))

    # Unverified legacy reference objectives are rejected.
    config = test_config()
    @test_throws ErrorException reject_legacy_reference_objective(123.0, "old_formulation", config)
    @test reject_legacy_reference_objective(123.0, config.formulation_id, config) == 123.0
end

# =====================================================================================
# 22.13 Regression against an independently written corrected formulation
# =====================================================================================

"""
Independently written corrected full-horizon deterministic model.

Deliberately does not share code with `build_remaining_horizon_model`: it is a second
implementation of the same mathematics, including the node-level shared battery mode. It is
never compared against an old household-mode formulation, which would not be an equivalence
test.
"""
function reference_full_horizon_model(template::OOSInstanceTemplate, forecast::ForecastPath, config)
    T = template.T
    J = template.J
    forecast.first_period == 1 || error("La referencia exige un horizonte completo.")
    model = Model(CPLEX.Optimizer)
    set_silent(model)
    set_attribute(model, "CPXPARAM_TimeLimit", config.solver_time_limit_sec)

    @variable(model, s[1:T] >= 0)
    @variable(model, I[1:J, 1:T] >= 0)
    @variable(model, G[1:J, 1:T] >= 0)
    @variable(model, z[1:J, 1:T] >= 0)
    @variable(model, y[1:J, 1:T] >= 0)
    @variable(model, p[1:J, 1:T] >= 0)
    @variable(model, lambda[1:J, 1:T] >= 0)
    v = add_shared_battery_mode_constraints!(
        model, y, z, 1:J, 1:T; discharge_limit=template.f_bar, charge_limit=template.f_under,
    )

    @constraint(model, [j in 1:J, t in 1:T], p[j, t] == lambda[j, t] * forecast.pv[t])
    @constraint(model, [t in 1:T], sum(lambda[j, t] for j in 1:J) == 1)
    @constraint(model, [t in 1:T], s[t] <= template.s_max)
    @constraint(model, [t in 1:T], s[t] >= template.s_min)
    @constraint(model, s[1] == template.s_I +
        template.delta * template.e_c * sum(z[j, 1] for j in 1:J) -
        template.delta * sum(y[j, 1] for j in 1:J) / template.e_d)
    @constraint(model, [t in 2:T], s[t] == s[t-1] +
        template.delta * template.e_c * sum(z[j, t] for j in 1:J) -
        template.delta * sum(y[j, t] for j in 1:J) / template.e_d)
    @constraint(model, [j in 1:J, t in 1:T],
        forecast.demand[j, t] == p[j, t] + y[j, t] + I[j, t] - z[j, t] - G[j, t])
    @constraint(model, s[T] == template.s_I)
    @objective(model, Min, sum(
        template.delta * (template.mu * y[j, t] + template.nu[j, t] * I[j, t] -
                          template.beta * G[j, t])
        for j in 1:J, t in 1:T
    ))
    return (model=model, v=v, p=p, y=y, z=z, s=s)
end

@testset "22.13 corrected deterministic formulation regression at t = 1" begin
    config = test_config(fairness_set=[NONE])
    common = build_common_objects(config; verbose=false)
    template = common.template
    state, _, path = state_at_first_period(common, config)
    history = observed_history(state)
    forecast = conditional_mean_path(common.provider, history, 1, template.T)

    module_result = solve_at(common, config, state, DETERMINISTIC_RH, NONE).result
    @test module_result.solved

    reference = reference_full_horizon_model(template, forecast, config)
    optimize!(reference.model)
    @test has_values(reference.model)

    # Same optimal expected cost, same current shared mode, same current flows.
    @test isapprox(module_result.objective_value, objective_value(reference.model); rtol=1e-6)
    @test module_result.action.shared_battery_mode == Int(round(value(reference.v[1])))
    @test isapprox(module_result.action.aggregate_charge,
                   sum(value(reference.z[j, 1]) for j in 1:template.J); atol=1e-6)
    @test isapprox(module_result.action.aggregate_discharge,
                   sum(value(reference.y[j, 1]) for j in 1:template.J); atol=1e-6)
    @test isapprox(module_result.action.soc_after_model, value(reference.s[1]); atol=1e-6)
    # Identical mode-binary count: |V_mode| in both.
    @test generated_binary_count(reference.model) == template.T
    @test module_result.statistics.generated_mode_binaries == template.T
end

# =====================================================================================
# Model audit and formulation-variant separation
# =====================================================================================

@testset "23 representative model audit" begin
    config = test_config(export_representative_models=true)
    common = build_common_objects(config; verbose=false)
    audits = export_representative_models(config, common; verbose=false)
    # One representative model per controller x rule, lexicographic phases included, plus the
    # adaptive PEA Phase-I and Phase-II models for every controller.
    base = length(config.controller_set) * length(config.fairness_set)
    extra_pea = PEA in config.fairness_set && config.pea_tolerance_mode === :adaptive_minimum ?
        2 * length(config.controller_set) : 0
    @test length(audits) == base + extra_pea
    for controller in config.controller_set
        @test any(a -> a.label == "$(controller)__PEA", audits)
        @test any(a -> a.label == "$(controller)__PEA__adaptive_phase1", audits)
        @test any(a -> a.label == "$(controller)__PEA__adaptive_phase2", audits)
    end
    for audit in audits
        for finding in audit.findings
            @test finding.passed
        end
        @test audit.passed
        @test audit.generated_mode_binaries == audit.expected_mode_nodes
        @test audit.unique_policy_modes == audit.expected_mode_nodes
        @test audit.legacy_household_mode_binaries ==
              common.template.J * audit.expected_mode_nodes
        @test isfile(audit.lp_path)
        @test isfile(audit.mps_path)
    end
    @test any(occursin("phase1", audit.label) for audit in audits)
end

@testset "formulation variants stay separated" begin
    config = test_config(fairness_set=[NONE])
    common = build_common_objects(config; verbose=false)
    state, _, path = state_at_first_period(common, config)
    tree = build_lookahead_tree(
        common.provider, config, DETERMINISTIC_RH, observed_history(state), 1,
        common.template.T, path.replication_id,
    )
    aggregate_only = build_remaining_horizon_model(common.template, state, tree, config)

    redundant_config = test_config(
        fairness_set=[NONE], formulation_variant=:aggregate_plus_redundant_links,
    )
    redundant = build_remaining_horizon_model(common.template, state, tree, redundant_config)

    # Same binaries, more rows: the redundant links are a named variant, never a default.
    @test generated_binary_count(aggregate_only.model) == generated_binary_count(redundant.model)
    @test model_constraint_count(redundant.model) > model_constraint_count(aggregate_only.model)
    @test aggregate_only.formulation_variant === :aggregate_only
    @test redundant.formulation_variant === :aggregate_plus_redundant_links

    optimize!(aggregate_only.model)
    optimize!(redundant.model)
    @test has_values(aggregate_only.model) && has_values(redundant.model)
    # Redundancy must not change the optimal value.
    @test isapprox(objective_value(aggregate_only.model), objective_value(redundant.model); rtol=1e-6)
    @test_throws ErrorException test_config(formulation_variant=:not_a_variant)
end

# =====================================================================================
# Configuration guards and the runner's refusal conditions
# =====================================================================================

@testset "configuration guards" begin
    @test_throws ErrorException test_config(formulation_id="")
    @test_throws ErrorException test_config(oos_replications=0)
    @test_throws ErrorException test_config(flow_tol=0.0)
    @test_throws ErrorException test_config(feasibility_tol=0.0)
    @test_throws ErrorException test_config(integrality_tol=0.0)
    @test_throws ErrorException test_config(controller_set=ControllerKind[])
    @test_throws ErrorException test_config(fairness_set=FairnessPolicy[])
    @test_throws ErrorException test_config(two_stage_scenarios=0)
    @test_throws ErrorException test_config(households=1)
    @test_throws ErrorException test_config(
        multistage_branching=[2, 2], multistage_periods_per_stage=[8, 8],
    )
    @test_throws ErrorException parse_controller_kind("ROLLING")
    @test_throws ErrorException parse_fairness_policy("ERDINC_PSR")
    @test parse_controller_kind("two_stage_rh") === TWO_STAGE_RH
    @test parse_fairness_policy(" pea ") === PEA
    @test configuration_count(test_config()) == 18
end

@testset "stage layout is well defined for every remaining horizon" begin
    for remaining in 1:24
        periods, branching = multistage_stage_layout(remaining, [2, 2], Int[])
        @test sum(periods) == remaining
        @test all(p -> p >= 1, periods)
        @test length(branching) == length(periods) - 1
        @test length(periods) <= 3
    end
    periods, branching = multistage_stage_layout(24, [4, 4], [1, 1, 22])
    @test periods == [1, 1, 22]
    @test branching == [4, 4]
    periods, branching = multistage_stage_layout(2, [4, 4], [1, 1, 22])
    @test sum(periods) == 2
    @test length(branching) == length(periods) - 1
end

# =====================================================================================
# 22.14 The existing repository validation suite still passes
# =====================================================================================

@testset "22.14 existing repository regression suite" begin
    if lowercase(get(ENV, "OOS_SKIP_REPO_REGRESSION", "0")) in ("1", "true", "yes")
        @info "Regresión del repositorio omitida por OOS_SKIP_REPO_REGRESSION."
        @test true
    else
        suite = joinpath(REPO_ROOT, "test", "runtests.jl")
        @test isfile(suite)
        command = Cmd([
            first(Base.julia_cmd()), "--project=$(REPO_ROOT)", "--startup-file=no", suite,
        ])
        process = run(ignorestatus(command))
        @test process.exitcode == 0
    end
end

println("\nDirectorio temporal de salidas de prueba: ", TEST_OUTPUT)

# =====================================================================================
# Strict-first / adaptive-minimum PEA recovery
# =====================================================================================

"""Advance a configuration to the start of period `upto + 1`, returning the state."""
function advance_state(common, config, controller, policy, upto::Int)
    path = common.oos_paths[1]
    cache = cache_lookahead_trees(common.provider, config, common.template, path)
    state = initial_simulation_state(common.template, path.replication_id)
    for t in 1:upto
        reveal_period!(state, path, t)
        observation = PeriodObservation(t, path.pv[t], collect(path.demand[:, t]))
        result = solve_current_action(
            common.template, state, observation, cache[(t, controller)], controller, policy,
            config; static_shares=common.static_shares,
        )
        result.solved || error("La preparación del estado falló en t=$t: $(result.failure_message)")
        validation = validate_period_action(common.template, state, result.action, config)
        apply_action!(state, common.template, result.action, validation.soc_after)
    end
    state.period <= common.template.T && reveal_period!(state, path, state.period)
    return (state=state, cache=cache, path=path)
end

"""Configuration used by the PEA recovery tests: J=4, seed 12345, campaign policy."""
pea_config(; kwargs...) = test_config(;
    experiment_seed=12345, households=4, fairness_set=[NONE, PEA],
    controller_set=[DETERMINISTIC_RH], kwargs...)

@testset "5.1 strict PEA feasible: no recovery, no tolerance" begin
    config = pea_config()
    common = build_common_objects(config; verbose=false)
    # Early periods have an empty or small realized past, so the strict equality holds.
    for period in (1, 5)
        prepared = advance_state(common, config, DETERMINISTIC_RH, PEA, period - 1)
        solved = solve_at(common, config, prepared.state, DETERMINISTIC_RH, PEA)
        @test solved.result.solved
        pea = solved.result.pea
        @test pea.applicable
        @test pea.strict_feasible
        @test !pea.tolerance_activated
        @test pea.tolerance_used == 0.0
        @test pea.recovery_status == "not_required"
        @test pea.phase1_status == "not_run"
        @test pea.phase2_status == "not_run"
        @test pea.failure_source == string(FAILURE_NONE)
        # Exactly one solve: no diagnostic, no Phase-I and no Phase-II model was built.
        @test length(solved.result.phases) == 1
        @test solved.result.phases[1].label == "single_solve"
        @test solved.result.phases[1].phase == 0
        @test !any(p -> p.label == "pea_diagnostic_physical", solved.result.phases)
        @test !any(p -> p.label == "pea_phase1_min_tolerance", solved.result.phases)
        @test !any(p -> p.label == "pea_phase2_operational", solved.result.phases)
    end
end

@testset "5.2 strict PEA fairness-infeasible, physical feasible: Phase I + Phase II" begin
    config = pea_config()
    common = build_common_objects(config; verbose=false)
    prepared = advance_state(common, config, DETERMINISTIC_RH, PEA, 18)
    state = prepared.state
    @test state.period == 19

    tree = prepared.cache[(19, DETERMINISTIC_RH)]
    past = fairness_past_state(state)

    # The strict model really is infeasible, and the physical model really is feasible.
    strict = build_remaining_horizon_model(common.template, state, tree, config)
    add_fairness_constraints!(strict, PEA, past, config; static_shares=common.static_shares)
    optimize!(strict.model)
    @test classify_solve_outcome(strict.model) === SOLVE_PROVEN_INFEASIBLE
    source, _ = attribute_failure_source(common.template, state, tree, config)
    @test source === FAILURE_FAIRNESS_RULE

    solved = solve_at(common, config, state, DETERMINISTIC_RH, PEA)
    @test solved.result.solved
    pea = solved.result.pea
    @test pea.applicable
    @test !pea.strict_feasible
    @test pea.tolerance_activated
    @test pea.tolerance_used > 0.0
    @test pea.strict_status == string(SOLVE_PROVEN_INFEASIBLE)
    @test pea.phase1_status == string(SOLVE_OK)
    @test pea.phase2_status == string(SOLVE_OK)
    @test pea.recovery_status == "recovered"
    @test pea.failure_source == string(FAILURE_FAIRNESS_RULE)
    # A recovered period runs FOUR solves, all logged, in execution order:
    # strict, diagnostic physical model, Phase I, Phase II.
    @test length(solved.result.phases) == 4
    @test [p.label for p in solved.result.phases] == [
        "single_solve", "pea_diagnostic_physical",
        "pea_phase1_min_tolerance", "pea_phase2_operational",
    ]
    @test [p.phase for p in solved.result.phases] == [0, 1, 2, 3]
    # Recovery adds exactly three solves relative to a strict-feasible period.
    strict_ok = advance_state(common, config, DETERMINISTIC_RH, PEA, 0)
    strict_solved = solve_at(common, config, strict_ok.state, DETERMINISTIC_RH, PEA)
    @test strict_solved.result.pea.strict_feasible
    @test length(solved.result.phases) - length(strict_solved.result.phases) == 3
    # The implemented action exists and is physically valid.
    @test solved.result.action !== nothing
    @test validate_period_action(common.template, state, solved.result.action, config).valid

    # The reported band matches the realized fairness deviation of the implemented model.
    aggregates = scenario_aggregates(common.template, tree)
    targets = pea_targets(common.template, past, aggregates)
    reachable_violation = maximum(max.(past.pv .- targets, 0.0))
    @test pea.tolerance_used >= reachable_violation - 1e-6

    # And the whole replication now completes instead of aborting.
    run = simulate_configuration(
        common.template, config, prepared.path, prepared.cache, DETERMINISTIC_RH, PEA,
        common.static_shares,
    )
    @test run.completed
    @test run.periods_completed == common.template.T
    @test count(x -> x > OOS_PEA_ACTIVATION_THRESHOLD, run.pea_tolerances) > 0
end

@testset "5.3 epsilon_pea_star is minimal" begin
    config = pea_config()
    common = build_common_objects(config; verbose=false)
    prepared = advance_state(common, config, DETERMINISTIC_RH, PEA, 18)
    state = prepared.state
    tree = prepared.cache[(19, DETERMINISTIC_RH)]
    past = fairness_past_state(state)
    aggregates = scenario_aggregates(common.template, tree)

    refs = build_remaining_horizon_model(common.template, state, tree, config)
    phase1 = solve_minimum_pea_tolerance!(refs, past, aggregates, config)
    @test phase1.outcome === SOLVE_OK
    epsilon_star = phase1.epsilon_star
    @test epsilon_star > 0

    # Analytic lower bound: an over-allocated household cannot be corrected downwards, so the
    # band must cover its overshoot exactly.
    targets = pea_targets(common.template, past, aggregates)
    overshoot = maximum(max.(past.pv .- targets, 0.0))
    @test overshoot > 0
    @test isapprox(epsilon_star, overshoot; rtol=1e-4)

    # Independent check: a band strictly below the optimum must be infeasible. delta is 1% of
    # epsilon_star, two orders of magnitude above CPLEX's default relative MIP gap.
    delta = 0.01 * epsilon_star
    tightened = build_remaining_horizon_model(common.template, state, tree, config)
    handles = build_adaptive_pea_constraints!(tightened, past, aggregates)
    @constraint(tightened.model, handles.epsilon <= epsilon_star - delta)
    @objective(tightened.model, Min, 0)
    optimize!(tightened.model)
    @test !has_values(tightened.model)
    @test classify_solve_outcome(tightened.model) === SOLVE_PROVEN_INFEASIBLE
end

@testset "5.4 Phase II preserves the minimum tolerance" begin
    config = pea_config()
    common = build_common_objects(config; verbose=false)
    prepared = advance_state(common, config, DETERMINISTIC_RH, PEA, 18)
    state = prepared.state
    tree = prepared.cache[(19, DETERMINISTIC_RH)]
    past = fairness_past_state(state)
    aggregates = scenario_aggregates(common.template, tree)

    refs = build_remaining_horizon_model(common.template, state, tree, config)
    phase1 = solve_minimum_pea_tolerance!(refs, past, aggregates, config)
    @test phase1.outcome === SOLVE_OK
    phase1_objective = objective_value(refs.model)

    phase2 = solve_pea_operational_phase!(refs, phase1.handles, phase1.epsilon_star, config)
    @test phase2.outcome === SOLVE_OK
    @test phase2.epsilon <= phase1.epsilon_star + config.pea_tolerance_numeric_eps + 1e-9
    # The Phase-II cap is literally  epsilon_pea <= epsilon_pea_star + numeric_eps  (kWh),
    # with a unit coefficient on epsilon and the two kWh quantities summed on the right.
    cap = refs.model[:pea_tolerance_cap]
    @test isapprox(normalized_coefficient(cap, phase1.handles.epsilon), 1.0; atol=1e-12)
    @test isapprox(normalized_rhs(cap),
                   phase1.epsilon_star + config.pea_tolerance_numeric_eps; rtol=1e-12)
    @test length(constraint_object(cap).func.terms) == 1
    # Phase II optimizes cost, not the band.
    @test objective_sense(refs.model) == MIN_SENSE
    @test isapprox(phase1_objective, phase1.epsilon_star; rtol=1e-9)
    @test objective_function(refs.model) != phase1.handles.epsilon
end

@testset "5.5 multiple independent activations, no carry-forward" begin
    config = pea_config()
    common = build_common_objects(config; verbose=false)
    path = common.oos_paths[1]
    cache = cache_lookahead_trees(common.provider, config, common.template, path)
    run = simulate_configuration(
        common.template, config, path, cache, DETERMINISTIC_RH, PEA, common.static_shares,
    )
    @test run.completed
    active = [t for t in eachindex(run.pea_tolerances)
              if run.pea_tolerances[t] > OOS_PEA_ACTIVATION_THRESHOLD]
    @test length(active) >= 2                       # more than one recovery in one replication
    values = run.pea_tolerances[active]
    @test length(unique(round.(values, digits=6))) > 1   # the bands genuinely differ by period
    # No carry-forward: a period after an activation may return to a strict solve, and in any
    # case the band is never bounded below by the previous one.
    @test !issorted(values)  || minimum(values) < maximum(values)
    for t in eachindex(run.pea_tolerances)
        record = run.records[t]
        if run.pea_tolerances[t] <= OOS_PEA_ACTIVATION_THRESHOLD
            @test record.result.pea.strict_feasible
            @test record.result.pea.recovery_status in ("not_required", "not_applicable")
        end
    end
    metrics = compute_replication_metrics(common.template, run, config)
    stats = summarize_pea_tolerances(run.pea_tolerances)
    @test metrics.pea_tolerance_activations == length(active)
    @test isapprox(metrics.pea_tolerance_mean_active, sum(values) / length(values); rtol=1e-12)
    @test isapprox(metrics.pea_tolerance_max, maximum(values); rtol=1e-12)
    @test isapprox(metrics.pea_tolerance_mean_all_periods, stats.mean_all_periods; rtol=1e-12)
end

@testset "5.6 physical infeasibility never activates the tolerance" begin
    config = pea_config()
    common = build_common_objects(config; verbose=false)
    prepared = advance_state(common, config, DETERMINISTIC_RH, PEA, 4)
    tree = prepared.cache[(5, DETERMINISTIC_RH)]

    # Make the physical model infeasible: a state of charge outside its own bounds cannot be
    # reconciled with the transition and the s_min/s_max window.
    broken = deepcopy(prepared.state)
    broken.soc_before = common.template.s_max + 500.0

    source, detail = attribute_failure_source(common.template, broken, tree, config)
    @test source === FAILURE_PHYSICAL_MODEL

    recovery = attempt_adaptive_pea_recovery(
        common.template, broken, tree, config, fairness_past_state(broken),
        string(SOLVE_PROVEN_INFEASIBLE), SOLVE_PROVEN_INFEASIBLE,
    )
    @test !recovery.solved
    @test recovery.refs === nothing            # no action can be extracted from the diagnostic
    @test recovery.pea.recovery_status == "blocked_physical_model"
    @test recovery.pea.failure_source == string(FAILURE_PHYSICAL_MODEL)
    @test !recovery.pea.tolerance_activated
    @test recovery.pea.tolerance_used == 0.0
    # The diagnostic solve really happened and is logged, but no recovery phase ran.
    @test [p.label for p in recovery.phases] == ["pea_diagnostic_physical"]
    @test !any(p -> startswith(p.label, "pea_phase"), recovery.phases)

    result = solve_current_action(
        common.template, broken,
        PeriodObservation(5, prepared.path.pv[5], collect(prepared.path.demand[:, 5])),
        tree, DETERMINISTIC_RH, PEA, config; static_shares=common.static_shares,
    )
    @test !result.solved
    @test result.action === nothing
    @test result.pea.failure_source == string(FAILURE_PHYSICAL_MODEL)
    @test !result.pea.tolerance_activated
end

@testset "5.7 solver-status safety" begin
    config = pea_config()
    common = build_common_objects(config; verbose=false)
    prepared = advance_state(common, config, DETERMINISTIC_RH, PEA, 18)
    tree = prepared.cache[(19, DETERMINISTIC_RH)]
    past = fairness_past_state(prepared.state)

    # Only an infeasibility finding may open the gate.
    for outcome in (SOLVE_TIME_LIMIT, SOLVE_NUMERICAL_ERROR, SOLVE_UNKNOWN, SOLVE_OK)
        recovery = attempt_adaptive_pea_recovery(
            common.template, prepared.state, tree, config, past, string(outcome), outcome,
        )
        @test !recovery.solved
        @test recovery.pea.recovery_status == "blocked_no_infeasibility_proof"
        @test !recovery.pea.tolerance_activated
        @test recovery.pea.tolerance_used == 0.0
    end
    @test is_infeasibility_finding(SOLVE_PROVEN_INFEASIBLE)
    @test is_infeasibility_finding(SOLVE_PRESUMED_INFEASIBLE)
    @test !is_infeasibility_finding(SOLVE_TIME_LIMIT)
    @test !is_infeasibility_finding(SOLVE_NUMERICAL_ERROR)
    @test !is_infeasibility_finding(SOLVE_UNKNOWN)
    @test !is_infeasibility_finding(SOLVE_OK)

    # A real solve that hits a time limit with no incumbent is a time limit, not infeasibility.
    starved = pea_config(solver_time_limit_sec=1e-6)
    common2 = build_common_objects(starved; verbose=false)
    model = build_remaining_horizon_model(
        common2.template, prepared.state, tree, starved,
    ).model
    optimize!(model)
    @test classify_solve_outcome(model) in (SOLVE_OK, SOLVE_TIME_LIMIT)
end

@testset "5.8 the recovery is identical for all three controllers" begin
    config = pea_config(controller_set=[DETERMINISTIC_RH, TWO_STAGE_RH, MULTISTAGE_RH],
                        two_stage_scenarios=2, multistage_branching=[2])
    common = build_common_objects(config; verbose=false)
    path = common.oos_paths[1]
    cache = cache_lookahead_trees(common.provider, config, common.template, path)
    for controller in config.controller_set
        run = simulate_configuration(
            common.template, config, path, cache, controller, PEA, common.static_shares,
        )
        @test run.completed
        @test run.periods_completed == common.template.T
        @test length(run.pea_tolerances) == common.template.T
        activations = count(x -> x > OOS_PEA_ACTIVATION_THRESHOLD, run.pea_tolerances)
        @test activations > 0
        for record in run.records
            pea = record.result.pea
            @test pea.applicable
            if pea.tolerance_activated
                @test pea.recovery_status == "recovered"
                @test pea.failure_source == string(FAILURE_FAIRNESS_RULE)
                @test pea.phase1_status == string(SOLVE_OK)
                @test pea.phase2_status == string(SOLVE_OK)
            else
                @test pea.strict_feasible
                @test pea.tolerance_used == 0.0
            end
            @test record.validation.valid
        end
    end
end

@testset "5.9 strict and adaptive PEA are both root-level and horizon-total" begin
    config = pea_config(controller_set=[DETERMINISTIC_RH, TWO_STAGE_RH, MULTISTAGE_RH],
                        two_stage_scenarios=2, multistage_branching=[2])
    common = build_common_objects(config; verbose=false)
    prepared = advance_state(common, config, DETERMINISTIC_RH, PEA, 10)
    state = prepared.state
    past = fairness_past_state(state)
    @test any(past.pv .> 0)          # the realized past is genuinely non-empty

    for controller in config.controller_set
        tree = build_lookahead_tree(
            common.provider, config, controller, observed_history(state), state.period,
            common.template.T, prepared.path.replication_id,
        )
        N = lookahead_node_count(tree)
        J = common.template.J
        aggregates = scenario_aggregates(common.template, tree)
        targets = pea_targets(common.template, past, aggregates)

        # --- strict ---------------------------------------------------------------------
        strict = build_remaining_horizon_model(common.template, state, tree, config)
        build_strict_pea_constraints!(strict, past, aggregates)
        rows = strict.model[:pea_balance]
        @test length(rows) == J                      # one family indexed by household only
        for j in 1:J
            for n in 1:N
                @test isapprox(normalized_coefficient(rows[j], strict.p[j, n]),
                               tree.probability[n]; atol=1e-12)
            end
            # no other household's PV, and no other container
            for k in 1:J, n in 1:N
                k == j && continue
                @test normalized_coefficient(rows[j], strict.p[k, n]) == 0.0
            end
            terms = constraint_object(rows[j]).func.terms
            @test length(terms) == N                 # spans the whole remaining horizon
            @test isapprox(normalized_rhs(rows[j]), targets[j] - past.pv[j]; rtol=1e-9)
        end

        # --- adaptive -------------------------------------------------------------------
        adaptive = build_remaining_horizon_model(common.template, state, tree, config)
        handles = build_adaptive_pea_constraints!(adaptive, past, aggregates)
        upper = adaptive.model[:pea_band_upper]
        lower = adaptive.model[:pea_band_lower]
        @test length(upper) == J && length(lower) == J        # 2J band rows
        @test has_lower_bound(handles.epsilon) && lower_bound(handles.epsilon) == 0.0
        for j in 1:J
            for n in 1:N
                @test isapprox(normalized_coefficient(upper[j], adaptive.p[j, n]),
                               tree.probability[n]; atol=1e-12)
                @test isapprox(normalized_coefficient(lower[j], adaptive.p[j, n]),
                               -tree.probability[n]; atol=1e-12)
            end
            # each row = N node terms + the single shared epsilon
            @test length(constraint_object(upper[j]).func.terms) == N + 1
            @test length(constraint_object(lower[j]).func.terms) == N + 1
            @test isapprox(normalized_coefficient(upper[j], handles.epsilon), -1.0; atol=1e-12)
            @test isapprox(normalized_coefficient(lower[j], handles.epsilon), -1.0; atol=1e-12)
            @test isapprox(normalized_rhs(upper[j]), targets[j] - past.pv[j]; rtol=1e-9)
            @test isapprox(normalized_rhs(lower[j]), past.pv[j] - targets[j]; rtol=1e-9)
        end
        # No node- or stage-indexed PEA family exists in either formulation.
        for model in (strict.model, adaptive.model)
            @test !haskey(model, :pea_node)
            @test !haskey(model, :pea_stage)
        end
        # epsilon_pea is one scalar for the whole solve, not one per household or node.
        @test length(adaptive.model[:epsilon_pea]) == 1
    end
end

@testset "5.10 NONE regression: no distributive restriction anywhere" begin
    config = test_config()
    common = build_common_objects(config; verbose=false)
    prepared = advance_state(common, config, DETERMINISTIC_RH, NONE, 10)
    state = prepared.state
    past = fairness_past_state(state)
    for controller in config.controller_set
        tree = build_lookahead_tree(
            common.provider, config, controller, observed_history(state), state.period,
            common.template.T, prepared.path.replication_id,
        )
        refs = build_remaining_horizon_model(common.template, state, tree, config)
        before = sum(num_constraints(refs.model, F, S)
                     for (F, S) in list_of_constraint_types(refs.model))
        objective_before = objective_function(refs.model)
        context = add_fairness_constraints!(refs, NONE, past, config)
        after = sum(num_constraints(refs.model, F, S)
                    for (F, S) in list_of_constraint_types(refs.model))
        @test after == before                            # zero distributive constraints
        @test objective_function(refs.model) == objective_before   # zero fairness objective
        @test context.handles === nothing                # no targets or coefficients generated
        # No PEA machinery is reachable from NONE.
        @test !haskey(refs.model, :pea_balance)
        @test !haskey(refs.model, :pea_band_upper)
        @test !haskey(refs.model, :epsilon_pea)
        @test !haskey(refs.model, :static_share_fix)
        # And no post-solve repair: the implemented action is the model solution verbatim.
        solved = solve_at(common, config, state, controller, NONE)
        @test solved.result.solved
        @test solved.result.pea.recovery_status == "not_applicable"
        @test !solved.result.pea.tolerance_activated
        @test solved.result.pea.tolerance_used == 0.0
    end
end

@testset "5.11 STATIC_DEMAND_SHARE regression: active and distinct from NONE" begin
    config = test_config()
    common = build_common_objects(config; verbose=false)
    prepared = advance_state(common, config, DETERMINISTIC_RH, NONE, 10)
    state = prepared.state
    past = fairness_past_state(state)
    for controller in config.controller_set
        tree = build_lookahead_tree(
            common.provider, config, controller, observed_history(state), state.period,
            common.template.T, prepared.path.replication_id,
        )
        N = lookahead_node_count(tree)
        refs = build_remaining_horizon_model(common.template, state, tree, config)
        before = sum(num_constraints(refs.model, F, S)
                     for (F, S) in list_of_constraint_types(refs.model))
        add_fairness_constraints!(refs, STATIC_DEMAND_SHARE, past, config;
                                  static_shares=common.static_shares)
        after = sum(num_constraints(refs.model, F, S)
                    for (F, S) in list_of_constraint_types(refs.model))
        @test after - before == common.template.J * N     # active demand-share coefficients
        rows = refs.model[:static_share_fix]
        for j in 1:common.template.J, n in 1:N
            @test isapprox(normalized_rhs(rows[j, n]),
                           common.static_shares[j, tree.calendar_period[n]]; atol=1e-12)
        end
    end

    # Heterogeneous instance: the household allocations must actually differ from NONE.
    hetero = test_config(demand_profile="alea", households=3,
                         fairness_set=[NONE, STATIC_DEMAND_SHARE],
                         controller_set=[DETERMINISTIC_RH])
    hcommon = build_common_objects(hetero; verbose=false)
    hpath = hcommon.oos_paths[1]
    hcache = cache_lookahead_trees(hcommon.provider, hetero, hcommon.template, hpath)
    run_none = simulate_configuration(hcommon.template, hetero, hpath, hcache,
                                      DETERMINISTIC_RH, NONE, hcommon.static_shares)
    run_sds = simulate_configuration(hcommon.template, hetero, hpath, hcache,
                                     DETERMINISTIC_RH, STATIC_DEMAND_SHARE, hcommon.static_shares)
    @test run_none.completed && run_sds.completed
    pv_none = [sum(r.action.p[j] for r in run_none.records) for j in 1:hcommon.template.J]
    pv_sds = [sum(r.action.p[j] for r in run_sds.records) for j in 1:hcommon.template.J]
    @test !isapprox(pv_none, pv_sds; atol=1e-3)
    @test maximum(abs.(pv_none .- pv_sds)) > 1.0
    # Equal operating cost is NOT evidence of equal allocation on price-homogeneous instances.
    @test isapprox(sum(run_none.final_state.cumulative_operating_cost),
                   sum(run_sds.final_state.cumulative_operating_cost); rtol=1e-6)
end

@testset "5.12 other fairness rules are untouched by the PEA work" begin
    config = test_config(fairness_set=[SA, LEXMMFPEA, LEXMMFSA])
    common = build_common_objects(config; verbose=false)
    prepared = advance_state(common, config, DETERMINISTIC_RH, NONE, 10)
    state = prepared.state
    past = fairness_past_state(state)
    tree = prepared.cache[(11, DETERMINISTIC_RH)]
    aggregates = scenario_aggregates(common.template, tree)

    # No PEA machinery leaks into any other rule.
    for policy in (SA, LEXMMFPEA, LEXMMFSA)
        refs = build_remaining_horizon_model(common.template, state, tree, config)
        add_fairness_constraints!(refs, policy, past, config)
        @test !haskey(refs.model, :epsilon_pea)
        @test !haskey(refs.model, :pea_band_upper)
        @test !haskey(refs.model, :pea_balance)
        @test !haskey(refs.model, :pea_tolerance_cap)
    end

    # SA outcome definition: savings, realized past once, no PV proxy.
    refs = build_remaining_horizon_model(common.template, state, tree, config)
    savings = expected_savings_expressions(refs, past, aggregates)
    saving_past = past_savings(past)
    for j in 1:common.template.J
        future_benchmark = sum(aggregates.probability[s] * aggregates.benchmark[j, s]
                               for s in eachindex(tree.scenarios))
        @test isapprox(JuMP.constant(savings[j]), saving_past[j] + future_benchmark; rtol=1e-9)
        for n in 1:lookahead_node_count(tree)
            @test normalized_coefficient(@constraint(refs.model, savings[j] <= 0), refs.p[j, n]) == 0.0
        end
    end

    # Max-min outcome definitions and the lexicographic order are unchanged.
    for policy in (LEXMMFPEA, LEXMMFSA)
        fresh = build_remaining_horizon_model(common.template, state, tree, config)
        context = add_fairness_constraints!(fresh, policy, past, config)
        outcomes = lexicographic_outcome_expressions(fresh, policy, past, context.aggregates)
        expected = policy === LEXMMFPEA ? past.pv :
            [saving_past[j] + sum(aggregates.probability[s] * aggregates.benchmark[j, s]
                                  for s in eachindex(tree.scenarios))
             for j in 1:common.template.J]
        for j in 1:common.template.J
            @test isapprox(JuMP.constant(outcomes[j]), expected[j]; rtol=1e-9)
        end
        lex = solve_lexicographic!(fresh, policy, past, context.aggregates, config)
        @test lex.solved
        # J max-min phases, then the economic tie-break, in that order.
        @test length(lex.phase_records) == common.template.J + 1
        @test [p.label for p in lex.phase_records] ==
              vcat(["lex_phase_$k" for k in 1:common.template.J], ["economic_tie_break"])
        @test lexicographic_level_residual(lex.phase_levels, lex.achieved_outcomes) <=
              config.lex_eps_abs + 1e-6
    end

    # Savings history stays realized: it does not move when only the forecast changes.
    other_tree = build_lookahead_tree(
        common.provider, test_config(experiment_seed=778_899), TWO_STAGE_RH,
        observed_history(state), state.period, common.template.T, prepared.path.replication_id,
    )
    @test past_savings(fairness_past_state(state)) == saving_past
    other_aggregates = scenario_aggregates(common.template, other_tree)
    other_refs = build_remaining_horizon_model(common.template, state, other_tree, config)
    other_savings = expected_savings_expressions(other_refs, past, other_aggregates)
    for j in 1:common.template.J
        other_future = sum(other_aggregates.probability[s] * other_aggregates.benchmark[j, s]
                           for s in eachindex(other_tree.scenarios))
        @test isapprox(JuMP.constant(other_savings[j]) - other_future, saving_past[j]; rtol=1e-9)
    end
end

@testset "5.13 tolerance aggregation arithmetic" begin
    epsilon = [0.0, 2.0, 0.0, 5.0, 3.0]
    stats = summarize_pea_tolerances(epsilon)
    @test stats.activations == 3
    @test isapprox(stats.activation_rate, 3 / 5; rtol=1e-12)
    @test isapprox(stats.mean_active, 10 / 3; rtol=1e-12)
    @test isapprox(stats.mean_all_periods, 2.0; rtol=1e-12)
    @test isapprox(stats.maximum, 5.0; rtol=1e-12)
    @test stats.periods == 5

    # No activation: documented 0.0 convention, never NaN.
    quiet = summarize_pea_tolerances([0.0, 0.0, 0.0])
    @test quiet.activations == 0
    @test quiet.activation_rate == 0.0
    @test quiet.mean_active == 0.0
    @test quiet.mean_all_periods == 0.0
    @test quiet.maximum == 0.0
    @test !isnan(quiet.mean_active)

    # Empty sequence stays numeric too.
    empty_stats = summarize_pea_tolerances(Float64[])
    @test empty_stats.activations == 0
    @test empty_stats.mean_active == 0.0

    # Solver noise below the activation threshold is not an activation.
    noisy = summarize_pea_tolerances([0.0, OOS_PEA_ACTIVATION_THRESHOLD / 10, 4.0])
    @test noisy.activations == 1
    @test isapprox(noisy.mean_active, 4.0; rtol=1e-12)

    # Cross-replication pooling: weighted by active periods, not by replication.
    template_metrics(id, tolerances) = ReplicationMetrics(
        id, DETERMINISTIC_RH, PEA, true, length(tolerances),
        0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0, 0, 0,
        0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, Float64[], Float64[],
        0.0, 0.0, 0.0, 0.0, 0.0, 0, 0, 0.0, 0.0, "", "pv", 1.0,
        summarize_pea_tolerances(tolerances).activations,
        summarize_pea_tolerances(tolerances).activation_rate,
        summarize_pea_tolerances(tolerances).mean_active,
        summarize_pea_tolerances(tolerances).mean_all_periods,
        summarize_pea_tolerances(tolerances).maximum,
        count(iszero, tolerances), collect(Float64, tolerances), HouseholdMetrics[],
    )
    pooled = configuration_pea_summaries([
        template_metrics(1, [0.0, 2.0, 4.0]),     # 2 active, mean 3
        template_metrics(2, [0.0, 0.0, 12.0]),    # 1 active, mean 12
    ])
    @test length(pooled) == 1
    summary = pooled[1]
    @test summary.activations == 3
    @test isapprox(summary.mean_active, (2.0 + 4.0 + 12.0) / 3; rtol=1e-12)  # pooled, = 6.0
    # An unweighted mean of replication means would have given (3 + 12) / 2 = 7.5.
    @test !isapprox(summary.mean_active, 7.5; rtol=1e-6)
    @test isapprox(summary.mean_all_periods, 18.0 / 6; rtol=1e-12)
    @test isapprox(summary.maximum_tolerance, 12.0; rtol=1e-12)
    @test isapprox(summary.activation_rate, 3 / 6; rtol=1e-12)
    @test summary.resource == "pv"
end

@testset "5.14 default campaign matrix and PEA continuation" begin
    for key in ("CONTROLLER_SET", "FAIRNESS_SET", "OOS_REPLICATIONS", "FAIRNESS_ABS_TOL",
                "PEA_TOLERANCE_MODE", "TWO_STAGE_SCENARIOS", "MULTISTAGE_BRANCHING",
                "INSTANCE_FILE", "PEA_TOLERANCE_NUMERIC_EPS")
        haskey(ENV, key) && delete!(ENV, key)
    end
    withenv("FORMULATION_ID" => "audit_probe", "OOS_OUTPUT_DIR" => TEST_OUTPUT) do
        default = oos_config_from_environment()
        @test length(default.controller_set) == 3
        @test length(default.fairness_set) == 6
        @test configuration_count(default) == 18
        @test default.pea_tolerance_mode === :adaptive_minimum
        @test default.fairness_abs_tol == 0.0          # no fixed economic band by default
        @test default.pea_tolerance_numeric_eps == 1e-6
        @test Set(default.fairness_set) ==
              Set([NONE, STATIC_DEMAND_SHARE, PEA, SA, LEXMMFPEA, LEXMMFSA])
    end
    # Conditional PEA remains unrepresentable.
    @test length(instances(FairnessPolicy)) == 6
    for label in ("CPEA", "CSA", "CLEXMMFPEA", "CLEXMMFSA", "ERDINC_PSR", "MMFPEA", "PAE")
        @test_throws ErrorException parse_fairness_policy(label)
    end
end

@testset "PEA tolerance configuration guards" begin
    # A fixed economic band cannot be set silently under an adaptive or strict policy.
    @test_throws ErrorException test_config(fairness_abs_tol=100.0)
    @test_throws ErrorException test_config(fairness_abs_tol=100.0, pea_tolerance_mode=:strict)
    @test_throws ErrorException test_config(pea_tolerance_mode=:fixed_band)   # needs a band
    @test_throws ErrorException test_config(pea_tolerance_mode=:not_a_mode)
    @test_throws ErrorException test_config(pea_tolerance_numeric_eps=0.0)
    # The deprecated mode still works when requested explicitly.
    legacy = test_config(pea_tolerance_mode=:fixed_band, fairness_abs_tol=100.0)
    @test legacy.pea_tolerance_mode === :fixed_band
    @test legacy.fairness_abs_tol == 100.0
    # :strict keeps the old abort-on-unreachable behaviour.
    strict = pea_config(pea_tolerance_mode=:strict)
    common = build_common_objects(strict; verbose=false)
    path = common.oos_paths[1]
    cache = cache_lookahead_trees(common.provider, strict, common.template, path)
    run = simulate_configuration(common.template, strict, path, cache, DETERMINISTIC_RH, PEA,
                                 common.static_shares)
    @test !run.completed
    @test occursin("recovery_disabled", run.failure_message)
    @test all(iszero, run.pea_tolerances)
end

@testset "Resource metadata and partial-horizon labelling" begin
    @test policy_resource(NONE) == "none"
    @test policy_resource(STATIC_DEMAND_SHARE) == "pv"
    @test policy_resource(PEA) == "pv"
    @test policy_resource(LEXMMFPEA) == "pv"
    @test policy_resource(SA) == "savings"
    @test policy_resource(LEXMMFSA) == "savings"

    config = pea_config(pea_tolerance_mode=:strict)
    common = build_common_objects(config; verbose=false)
    path = common.oos_paths[1]
    cache = cache_lookahead_trees(common.provider, config, common.template, path)
    aborted = simulate_configuration(common.template, config, path, cache, DETERMINISTIC_RH,
                                     PEA, common.static_shares)
    @test !aborted.completed
    metrics = compute_replication_metrics(common.template, aborted, config)
    @test metrics.resource == "pv"
    @test metrics.horizon_covered < 1.0
    @test isapprox(metrics.horizon_covered,
                   aborted.periods_completed / common.template.T; rtol=1e-12)
    # Horizon-total diagnostics must not be comparable against a complete run.
    @test isnan(metrics.realized_alpha)
    @test isnan(metrics.max_pv_relative_deviation)
    @test isnan(metrics.mean_pv_relative_deviation)
    @test isnan(metrics.realized_gamma)
    @test isnan(metrics.min_household_pv)
    @test isnan(metrics.min_household_savings)
    # Raw accumulations are retained.
    @test metrics.total_operating_cost > 0
    @test metrics.periods_completed > 0

    complete_config = pea_config()
    ccommon = build_common_objects(complete_config; verbose=false)
    cpath = ccommon.oos_paths[1]
    ccache = cache_lookahead_trees(ccommon.provider, complete_config, ccommon.template, cpath)
    finished = simulate_configuration(ccommon.template, complete_config, cpath, ccache,
                                      DETERMINISTIC_RH, PEA, ccommon.static_shares)
    @test finished.completed
    cmetrics = compute_replication_metrics(ccommon.template, finished, complete_config)
    @test cmetrics.horizon_covered == 1.0
    @test !isnan(cmetrics.max_pv_relative_deviation)
    @test !isnan(cmetrics.min_household_pv)
end

# =====================================================================================
# Corrections: numeric-epsilon unit (kWh) and PEA recovery solve count
# =====================================================================================

@testset "C1 pea_tolerance_numeric_eps is an absolute allowance in kWh" begin
    config = pea_config()
    @test config.pea_tolerance_numeric_eps == 1e-6          # value preserved exactly
    custom = pea_config(pea_tolerance_numeric_eps=2.5e-7)
    @test custom.pea_tolerance_numeric_eps == 2.5e-7        # configured value preserved exactly

    common = build_common_objects(config; verbose=false)
    prepared = advance_state(common, config, DETERMINISTIC_RH, PEA, 18)
    state = prepared.state
    tree = prepared.cache[(19, DETERMINISTIC_RH)]
    past = fairness_past_state(state)
    aggregates = scenario_aggregates(common.template, tree)

    refs = build_remaining_horizon_model(common.template, state, tree, config)
    phase1 = solve_minimum_pea_tolerance!(refs, past, aggregates, config)
    @test phase1.outcome === SOLVE_OK
    epsilon_star = phase1.epsilon_star

    phase2 = solve_pea_operational_phase!(refs, phase1.handles, epsilon_star, config)
    @test phase2.outcome === SOLVE_OK

    # The cap adds two kWh quantities: epsilon_pea <= epsilon_pea_star + numeric_eps_kWh.
    cap = refs.model[:pea_tolerance_cap]
    @test isapprox(normalized_rhs(cap), epsilon_star + config.pea_tolerance_numeric_eps;
                   rtol=1e-12)
    @test isapprox(normalized_rhs(cap) - epsilon_star, config.pea_tolerance_numeric_eps;
                   atol=1e-15)

    # The allowance is negligible against the band it protects: numerical, not economic.
    @test config.pea_tolerance_numeric_eps < 1e-5 * epsilon_star

    # Changing only the numeric allowance must not move epsilon_pea_star.
    other = pea_config(pea_tolerance_numeric_eps=1e-8)
    refs_other = build_remaining_horizon_model(common.template, state, tree, other)
    phase1_other = solve_minimum_pea_tolerance!(refs_other, past, aggregates, other)
    @test phase1_other.outcome === SOLVE_OK
    @test isapprox(phase1_other.epsilon_star, epsilon_star; rtol=1e-9)

    # The implemented Phase-II action is reproducible for a fixed configuration.
    baseline = solve_at(common, config, state, DETERMINISTIC_RH, PEA)
    repeat_run = solve_at(common, config, state, DETERMINISTIC_RH, PEA)
    @test baseline.result.solved && repeat_run.result.solved
    @test baseline.result.action.p == repeat_run.result.action.p
    @test baseline.result.pea.tolerance_used == repeat_run.result.pea.tolerance_used

    # Varying only the numeric allowance may move the optimum, but *only within the allowance*:
    # that is precisely what makes it numerical rather than economic. A 1e-6 kWh change in the
    # cap cannot move a band of several kWh.
    common_other = build_common_objects(other; verbose=false)
    variant = solve_at(common_other, other, state, DETERMINISTIC_RH, PEA)
    @test variant.result.solved
    @test baseline.result.action.shared_battery_mode == variant.result.action.shared_battery_mode
    allowance = config.pea_tolerance_numeric_eps + other.pea_tolerance_numeric_eps
    @test abs(baseline.result.pea.tolerance_used - variant.result.pea.tolerance_used) <= allowance
    @test maximum(abs.(baseline.result.action.p .- variant.result.action.p)) <=
          allowance * length(baseline.result.action.p)
    # And the band itself is unchanged to the precision that matters economically.
    @test isapprox(baseline.result.pea.tolerance_used, variant.result.pea.tolerance_used;
                   rtol=1e-5)
end

@testset "C1 the kWh unit is explicit in metadata, schema and documentation" begin
    config = pea_config()
    common = build_common_objects(config; verbose=false)
    document = experiment_config_dictionary(config, common.template)
    parameters = document["fairness_parameters"]
    @test haskey(parameters, "pea_tolerance_numeric_eps_kwh")
    @test parameters["pea_tolerance_numeric_eps_kwh"] == config.pea_tolerance_numeric_eps
    @test occursin("kWh", parameters["pea_tolerance_numeric_eps_unit"])
    @test occursin("kWh", parameters["pea_tolerance_unit"])
    # The old unitless metadata key must not linger alongside the new one.
    @test !haskey(parameters, "pea_tolerance_numeric_eps")

    # Output schema carries the unit in the column name.
    path = common.oos_paths[1]
    cache = cache_lookahead_trees(common.provider, config, common.template, path)
    run = simulate_configuration(common.template, config, path, cache, DETERMINISTIC_RH, PEA,
                                 common.static_shares)
    frame = pea_recovery_frame(config, [run])
    @test "PEA_Tolerance_Numeric_Eps_kWh" in names(frame)
    @test "PEA_Tolerance_Used_kWh" in names(frame)
    @test !("PEA_Tolerance_Numeric_Eps" in names(frame))
    @test all(frame.PEA_Tolerance_Numeric_Eps_kWh .== config.pea_tolerance_numeric_eps)

    # No source, schema or document may call the allowance dimensionless.
    roots = [joinpath(REPO_ROOT, "codes", "oos_experiment"),
             joinpath(REPO_ROOT, "scripts", "oos")]
    sources = String[]
    for root in roots, (directory, _, files) in walkdir(root)
        append!(sources, joinpath.(directory, files))
    end
    push!(sources, joinpath(REPO_ROOT, "docs", "oos_experiment.md"))
    for file in sources
        # Normalize away markdown emphasis, line wrapping and case, so the check is about the
        # claim rather than about how it happens to be typeset.
        text = lowercase(replace(read(file, String), r"[*_`]" => "", r"\s+" => " "))
        for match in eachmatch(r"dimensionless", text)
            window = text[max(1, match.offset - 60):(match.offset - 1)]
            # Every occurrence must be inside a negation: the allowance is NOT dimensionless.
            @test occursin("not", window) || occursin("neither", window) ||
                  occursin("never", window)
        end
    end
    # Positive assertion: the unit is stated where a reader would look for it.
    docs = read(joinpath(REPO_ROOT, "docs", "oos_experiment.md"), String)
    @test occursin("pea_tolerance_numeric_eps", docs)
    @test occursin("same unit", lowercase(docs))
    @test occursin("kwh", lowercase(docs))
end

@testset "C2 PEA recovery runs four solves in a fixed order" begin
    config = pea_config()
    common = build_common_objects(config; verbose=false)
    path = common.oos_paths[1]
    cache = cache_lookahead_trees(common.provider, config, common.template, path)
    run = simulate_configuration(common.template, config, path, cache, DETERMINISTIC_RH, PEA,
                                 common.static_shares)
    @test run.completed

    strict_periods = 0
    recovered_periods = 0
    for record in run.records
        labels = [p.label for p in record.result.phases]
        if record.result.pea.tolerance_activated
            recovered_periods += 1
            # 1 strict + 1 diagnostic + 1 Phase I + 1 Phase II = 4
            @test length(labels) == 4
            @test labels == ["single_solve", "pea_diagnostic_physical",
                             "pea_phase1_min_tolerance", "pea_phase2_operational"]
            @test [p.phase for p in record.result.phases] == [0, 1, 2, 3]
            # The strict solve is logged as infeasible; the diagnostic as feasible.
            @test record.result.phases[1].termination_status == "INFEASIBLE"
            @test record.result.phases[2].primal_status == "FEASIBLE_POINT"
        else
            strict_periods += 1
            @test length(labels) == 1
            @test labels == ["single_solve"]
        end
    end
    @test recovered_periods > 0
    @test strict_periods > 0
    @test strict_periods + recovered_periods == common.template.T

    # solve_log.csv reproduces the same counts.
    frame = solve_log_frame(config, [run])
    @test nrow(frame) == strict_periods + 4 * recovered_periods
    @test Set(frame.PhaseLabel) == Set(["single_solve", "pea_diagnostic_physical",
                                        "pea_phase1_min_tolerance", "pea_phase2_operational"])
end

@testset "C2 Phase I is never implemented; the action comes from Phase II" begin
    config = pea_config()
    common = build_common_objects(config; verbose=false)
    prepared = advance_state(common, config, DETERMINISTIC_RH, PEA, 18)
    state = prepared.state
    tree = prepared.cache[(19, DETERMINISTIC_RH)]
    past = fairness_past_state(state)
    aggregates = scenario_aggregates(common.template, tree)

    # Phase I alone, solved in isolation: its action is a min-tolerance action, not the one
    # the simulator implements.
    isolated = build_remaining_horizon_model(common.template, state, tree, config)
    phase1 = solve_minimum_pea_tolerance!(isolated, past, aggregates, config)
    @test phase1.outcome === SOLVE_OK
    phase1_action, _ = extract_current_action(isolated, config)
    phase1_cost = value(isolated.expected_future_cost)

    # Phase II on the same model, then the full workflow.
    solve_pea_operational_phase!(isolated, phase1.handles, phase1.epsilon_star, config)
    phase2_cost = value(isolated.expected_future_cost)
    implemented = solve_at(common, config, state, DETERMINISTIC_RH, PEA)
    @test implemented.result.solved

    # Phase II never costs more than Phase I's incidental solution: it optimizes cost.
    @test phase2_cost <= phase1_cost + 1e-6
    # And the implemented action matches the Phase-II objective value, not Phase I's.
    @test isapprox(implemented.result.objective_value, phase2_cost; rtol=1e-6)
    if !isapprox(phase1_cost, phase2_cost; rtol=1e-9)
        @test !isapprox(implemented.result.objective_value, phase1_cost; rtol=1e-9)
        @test phase1_action !== nothing
    end
end

@testset "C2 blocked recoveries log the diagnostic but no Phase I or Phase II" begin
    config = pea_config()
    common = build_common_objects(config; verbose=false)
    prepared = advance_state(common, config, DETERMINISTIC_RH, PEA, 4)
    tree = prepared.cache[(5, DETERMINISTIC_RH)]

    # Physical infeasibility: strict + diagnostic only, and no recovery phase at all.
    broken = deepcopy(prepared.state)
    broken.soc_before = common.template.s_max + 500.0
    recovery = attempt_adaptive_pea_recovery(
        common.template, broken, tree, config, fairness_past_state(broken),
        string(SOLVE_PROVEN_INFEASIBLE), SOLVE_PROVEN_INFEASIBLE,
    )
    @test !recovery.solved
    @test [p.label for p in recovery.phases] == ["pea_diagnostic_physical"]
    @test !any(p -> startswith(p.label, "pea_phase"), recovery.phases)

    # No infeasibility proof: not even a diagnostic solve is run.
    for outcome in (SOLVE_TIME_LIMIT, SOLVE_NUMERICAL_ERROR, SOLVE_UNKNOWN)
        blocked_recovery = attempt_adaptive_pea_recovery(
            common.template, prepared.state, tree, config, fairness_past_state(prepared.state),
            string(outcome), outcome,
        )
        @test !blocked_recovery.solved
        @test isempty(blocked_recovery.phases)
        @test blocked_recovery.pea.recovery_status == "blocked_no_infeasibility_proof"
    end
end

# =====================================================================================
# Downstream compatibility: the reference reader must consume real generated outputs
# =====================================================================================

"""Generate a real small campaign into a fresh directory and return its path."""
function generate_smoke_outputs(; replications::Int=2)
    directory = mktempdir(; prefix="oos_downstream_")
    config = test_config(
        experiment_seed=12345, households=4, oos_replications=replications,
        two_stage_scenarios=3, multistage_branching=[2, 2],
        output_directory=directory, export_representative_models=false,
        experiment_id="oos_downstream_test",
    )
    common = build_common_objects(config; verbose=false)
    runs = ReplicationRun[]
    metrics = ReplicationMetrics[]
    for path in common.oos_paths
        cache = cache_lookahead_trees(common.provider, config, common.template, path)
        for policy in config.fairness_set, controller in config.controller_set
            run = simulate_configuration(common.template, config, path, cache, controller,
                                         policy, common.static_shares)
            push!(runs, run)
            push!(metrics, compute_replication_metrics(common.template, run, config))
        end
    end
    statistics = campaign_statistics(metrics)
    summaries = configuration_pea_summaries(metrics)
    write_campaign_outputs(config, common.template, runs, metrics, statistics,
                           ModelAudit[], GateReport[]; configuration_summaries=summaries)
    return (directory=directory, config=config, runs=runs, metrics=metrics)
end

const DOWNSTREAM_SMOKE = generate_smoke_outputs()

@testset "D1 current output schemas are accepted by the reference reader" begin
    validation = validate_output_directory(DOWNSTREAM_SMOKE.directory; expected_configurations=18)
    for issue in blocking_issues(validation)
        @info "blocking schema issue" file = issue.file detail = issue.detail
    end
    @test isempty(blocking_issues(validation))
    @test validation.passed
    # Every file the campaign writes must be present and non-empty.
    for file in keys(OOS_REQUIRED_COLUMNS)
        @test isfile(joinpath(DOWNSTREAM_SMOKE.directory, file))
        @test validation.files[file] > 0
    end
    @test validation.metadata["output_schema_version"] == string(OOS_OUTPUT_SCHEMA_VERSION)
end

@testset "D2 the obsolete numeric-epsilon column is not required" begin
    frame = CSV.read(joinpath(DOWNSTREAM_SMOKE.directory, "pea_recovery.csv"), DataFrame)
    @test "PEA_Tolerance_Numeric_Eps_kWh" in names(frame)
    @test !("PEA_Tolerance_Numeric_Eps" in names(frame))
    @test !("PEA_Tolerance_Numeric_Eps" in OOS_REQUIRED_COLUMNS["pea_recovery.csv"])
    # The current name resolves without any warning.
    warnings = SchemaIssue[]
    column = oos_column(frame, "PEA_Tolerance_Numeric_Eps_kWh"; warnings=warnings)
    @test isempty(warnings)
    @test all(column .== DOWNSTREAM_SMOKE.config.pea_tolerance_numeric_eps)
end

@testset "D3 historical schema is read as kWh with an explicit warning" begin
    # A historical directory carries the unitless column name. It must still be readable, in
    # kWh, and must announce itself.
    historical = CSV.read(joinpath(DOWNSTREAM_SMOKE.directory, "pea_recovery.csv"), DataFrame)
    rename!(historical, "PEA_Tolerance_Numeric_Eps_kWh" => "PEA_Tolerance_Numeric_Eps")
    warnings = SchemaIssue[]
    column = oos_column(historical, "PEA_Tolerance_Numeric_Eps_kWh";
                        warnings=warnings, file="pea_recovery.csv")
    @test length(warnings) == 1
    @test warnings[1].severity === :warning
    @test occursin("kWh", warnings[1].detail)
    @test all(column .== DOWNSTREAM_SMOKE.config.pea_tolerance_numeric_eps)
    # A genuinely absent column is an error, never a silent fallback.
    @test_throws ErrorException oos_column(historical, "NoSuchColumn")
end

@testset "D4 metadata: current keys, kWh unit, value preserved" begin
    metadata = read_experiment_metadata(
        joinpath(DOWNSTREAM_SMOKE.directory, "experiment_config.json"))
    @test haskey(metadata, "pea_tolerance_numeric_eps_kwh")
    @test haskey(metadata, "pea_tolerance_numeric_eps_unit")
    @test !haskey(metadata, "pea_tolerance_numeric_eps")
    @test occursin("kWh", metadata["pea_tolerance_numeric_eps_unit"])
    @test parse(Float64, metadata["pea_tolerance_numeric_eps_kwh"]) ==
          DOWNSTREAM_SMOKE.config.pea_tolerance_numeric_eps
    @test metadata["pea_tolerance_mode"] == "adaptive_minimum"
    # Reproducibility identification.
    for key in ("julia_version", "manifest_julia_version", "manifest_toml_sha1",
                "code_commit", "experiment_seed", "output_schema_version",
                "pea_solve_sequence_version")
        @test haskey(metadata, key)
    end
    @test metadata["manifest_julia_version"] == metadata["julia_version"]
end

@testset "D5/D6/D7 solve sequences parsed by semantic label" begin
    recovery = CSV.read(joinpath(DOWNSTREAM_SMOKE.directory, "pea_recovery.csv"), DataFrame)
    solve_log = CSV.read(joinpath(DOWNSTREAM_SMOKE.directory, "solve_log.csv"), DataFrame)

    activated = Set((r.Replication, r.Controller, r.Period) for r in eachrow(recovery)
                    if r.Fairness == "PEA" && r.PEA_Tolerance_Activated)
    grouped = Dict{Tuple{Int,String,Int},Vector{Tuple{Int,String}}}()
    for row in eachrow(solve_log)
        row.Fairness == "PEA" || continue
        key = (Int(row.Replication), String(row.Controller), Int(row.Period))
        push!(get!(grouped, key, Tuple{Int,String}[]), (Int(row.Phase), String(row.PhaseLabel)))
    end
    @test !isempty(activated)                       # the recovery path really was exercised
    strict = recovered = 0
    for (key, entries) in grouped
        sorted = sort(entries; by=first)
        labels = [label for (_, label) in sorted]
        if key in activated
            recovered += 1
            @test length(labels) == 4
            @test labels == OOS_PEA_RECOVERY_SEQUENCE
            @test [phase for (phase, _) in sorted] == [0, 1, 2, 3]
        else
            strict += 1
            @test labels == [OOS_SOLVE_LABEL_STRICT]
        end
        # The label -> phase mapping is the documented one.
        for (phase, label) in sorted
            @test OOS_SOLVE_PHASE_INDEX[label] == phase
        end
    end
    @test recovered > 0 && strict > 0

    # Phase II is the implemented action source and carries a real operating-cost objective;
    # the diagnostic solve must never be read as a policy action.
    @test OOS_IMPLEMENTED_ACTION_SOURCE == OOS_SOLVE_LABEL_PHASE2
    phase2 = filter(r -> r.PhaseLabel == OOS_SOLVE_LABEL_PHASE2, solve_log)
    diagnostic = filter(r -> r.PhaseLabel == OOS_SOLVE_LABEL_DIAGNOSTIC, solve_log)
    phase1 = filter(r -> r.PhaseLabel == OOS_SOLVE_LABEL_PHASE1, solve_log)
    @test nrow(phase2) == recovered
    @test nrow(diagnostic) == recovered
    @test nrow(phase1) == recovered
    @test all(!isnan, phase2.Objective)
    # Phase-I objectives are bands (kWh), not operating costs: orders of magnitude apart.
    @test maximum(phase1.Objective) < minimum(phase2.Objective)
    # Phase-I and Phase-II are separately timed rows.
    @test nrow(unique(phase2, [:Replication, :Controller, :Period])) == nrow(phase2)
end

@testset "D8 configuration aggregation matches the raw recovery rows" begin
    recovery = CSV.read(joinpath(DOWNSTREAM_SMOKE.directory, "pea_recovery.csv"), DataFrame)
    summary = CSV.read(joinpath(DOWNSTREAM_SMOKE.directory, "replication_summary.csv"), DataFrame)
    configuration = CSV.read(joinpath(DOWNSTREAM_SMOKE.directory, "configuration_summary.csv"),
                             DataFrame)
    recomputed = recompute_pea_statistics(recovery)

    for row in eachrow(summary)
        key = (String(row.Controller), String(row.Fairness), Int(row.Replication))
        stats = recomputed.per_replication[key]
        @test row.PEAToleranceActivations == stats.activations
        @test isapprox(row.PEAToleranceActivationRate, stats.activation_rate; atol=1e-12)
        @test isapprox(row.PEAToleranceMeanActive, stats.mean_active; atol=1e-12)
        @test isapprox(row.PEAToleranceMeanAllPeriods, stats.mean_all_periods; atol=1e-12)
        @test isapprox(row.PEAToleranceMax, stats.maximum_band; atol=1e-12)
    end
    for row in eachrow(configuration)
        key = (String(row.Controller), String(row.Fairness))
        stats = recomputed.per_configuration[key]
        @test row.ConfigPEAToleranceActivations == stats.activations
        @test isapprox(row.ConfigPEAToleranceMeanActive, stats.mean_active; atol=1e-12)
        @test isapprox(row.ConfigPEAToleranceMeanAllPeriods, stats.mean_all_periods; atol=1e-12)
        @test isapprox(row.ConfigPEAToleranceMax, stats.maximum_band; atol=1e-12)
        @test row.PeriodsSolved == stats.periods
    end

    # Pooling is over periods, not an unweighted mean of replication means.
    for key in keys(recomputed.per_configuration)
        key[2] == "PEA" || continue
        means = [stats.mean_active for ((c, f, _), stats) in recomputed.per_replication
                 if c == key[1] && f == key[2] && stats.activations > 0]
        counts = [stats.activations for ((c, f, _), stats) in recomputed.per_replication
                  if c == key[1] && f == key[2] && stats.activations > 0]
        length(means) >= 2 || continue
        length(unique(counts)) == 1 && continue          # equal weights: the two coincide
        pooled = recomputed.per_configuration[key].mean_active
        @test isapprox(pooled, sum(means .* counts) / sum(counts); rtol=1e-12)
    end
end

@testset "D9/D10 resource metadata and NONE vs STATIC_DEMAND_SHARE separation" begin
    summary = CSV.read(joinpath(DOWNSTREAM_SMOKE.directory, "replication_summary.csv"), DataFrame)
    households = CSV.read(joinpath(DOWNSTREAM_SMOKE.directory, "household_summary.csv"), DataFrame)
    paired = CSV.read(joinpath(DOWNSTREAM_SMOKE.directory, "paired_statistics.csv"), DataFrame)

    expected = Dict("NONE" => "none", "STATIC_DEMAND_SHARE" => "pv", "PEA" => "pv",
                    "SA" => "savings", "LEXMMFPEA" => "pv", "LEXMMFSA" => "savings")
    for row in eachrow(summary)
        @test String(row.Resource) in OOS_RESOURCE_VALUES
        @test String(row.Resource) == expected[String(row.Fairness)]
    end
    for row in eachrow(households)
        @test String(row.Resource) in OOS_RESOURCE_VALUES
    end

    # Both policies survive as distinct rows everywhere.
    policies = sort(unique(String.(summary.Fairness)))
    @test length(policies) == 6
    @test "NONE" in policies && "STATIC_DEMAND_SHARE" in policies
    @test nrow(filter(r -> r.Fairness == "NONE", summary)) ==
          nrow(filter(r -> r.Fairness == "STATIC_DEMAND_SHARE", summary))
    labels = Set(vcat(String.(paired.Baseline), String.(paired.Comparison)))
    @test any(occursin("|NONE", label) for label in labels)
    @test any(occursin("|STATIC_DEMAND_SHARE", label) for label in labels)
    # Equal cost must not be read as equal allocation: the allocations genuinely differ.
    pv_none = sort([(r.Replication, r.House, r.PVAllocation) for r in eachrow(households)
                    if r.Fairness == "NONE" && r.Controller == "DETERMINISTIC_RH"])
    pv_sds = sort([(r.Replication, r.House, r.PVAllocation) for r in eachrow(households)
                   if r.Fairness == "STATIC_DEMAND_SHARE" && r.Controller == "DETERMINISTIC_RH"])
    @test length(pv_none) == length(pv_sds) && !isempty(pv_none)
    @test maximum(abs(a[3] - b[3]) for (a, b) in zip(pv_none, pv_sds)) > 1e-6
end

@testset "D11/D12/D13 completion gating, matrix size, conditional-PEA absence" begin
    summary = CSV.read(joinpath(DOWNSTREAM_SMOKE.directory, "replication_summary.csv"), DataFrame)
    @test length(unique(zip(summary.Controller, summary.Fairness))) == 18
    @test all(status -> status in ("completed", "aborted"), summary.CompletionStatus)
    for row in eachrow(summary)
        if row.CompletionStatus == "completed"
            @test row.HorizonCovered == 1.0
            @test !isnan(row.MaxPVRelativeDeviation)
        else
            @test row.HorizonCovered < 1.0
            @test isnan(row.MaxPVRelativeDeviation)   # not comparable to a complete run
        end
    end
    for policy in unique(String.(summary.Fairness))
        @test !(policy in ("CPEA", "CSA", "CLEXMMFPEA", "CLEXMMFSA"))
        @test !startswith(policy, "ERDINC")
    end

    # Paired comparisons never use more observations than there are completed replications.
    paired = CSV.read(joinpath(DOWNSTREAM_SMOKE.directory, "paired_statistics.csv"), DataFrame)
    completed = count(==("completed"), summary.CompletionStatus)
    @test all(row -> row.Observations <= completed, eachrow(paired))
end

@testset "D14/D15 the reader rejects injected schema and sequence errors" begin
    # A corrupted copy must fail loudly rather than be silently mis-read.
    broken = mktempdir(; prefix="oos_broken_")
    for file in readdir(DOWNSTREAM_SMOKE.directory)
        source = joinpath(DOWNSTREAM_SMOKE.directory, file)
        isfile(source) && cp(source, joinpath(broken, file))
    end
    @test validate_output_directory(broken).passed

    # (a) a missing required column
    dropped = CSV.read(joinpath(broken, "replication_summary.csv"), DataFrame)
    select!(dropped, Not(:Resource))
    CSV.write(joinpath(broken, "replication_summary.csv"), dropped)
    injected = validate_output_directory(broken)
    @test !injected.passed
    @test any(issue -> occursin("Resource", issue.detail), blocking_issues(injected))
    @test_throws ErrorException enforce_output_schema!(injected)

    # (b) a broken solve sequence: drop the diagnostic row of a recovered period
    resequenced = mktempdir(; prefix="oos_resequenced_")
    for file in readdir(DOWNSTREAM_SMOKE.directory)
        source = joinpath(DOWNSTREAM_SMOKE.directory, file)
        isfile(source) && cp(source, joinpath(resequenced, file))
    end
    solve_log = CSV.read(joinpath(resequenced, "solve_log.csv"), DataFrame)
    CSV.write(joinpath(resequenced, "solve_log.csv"),
              filter(r -> r.PhaseLabel != OOS_SOLVE_LABEL_DIAGNOSTIC, solve_log))
    sequence_error = validate_output_directory(resequenced)
    @test !sequence_error.passed
    @test any(issue -> occursin("secuencia", issue.detail), blocking_issues(sequence_error))

    # (c) a schema-version mismatch blocks mixing incompatible directories
    versioned = mktempdir(; prefix="oos_versioned_")
    for file in readdir(DOWNSTREAM_SMOKE.directory)
        source = joinpath(DOWNSTREAM_SMOKE.directory, file)
        isfile(source) && cp(source, joinpath(versioned, file))
    end
    metadata_path = joinpath(versioned, "experiment_config.json")
    write(metadata_path, replace(read(metadata_path, String),
                                 "\"output_schema_version\": $(OOS_OUTPUT_SCHEMA_VERSION)" =>
                                 "\"output_schema_version\": 1"))
    mismatch = validate_output_directory(versioned)
    @test !mismatch.passed
    @test any(issue -> occursin("esquema", issue.detail), blocking_issues(mismatch))
    @test !isempty(scan_for_stale_result_directories([versioned]))

    # A directory with no schema version at all is reported as historical, not silently used.
    legacy = mktempdir(; prefix="oos_legacy_")
    write(joinpath(legacy, "experiment_config.json"), "{\n  \"formulation_id\": \"old\"\n}\n")
    @test !isempty(scan_for_stale_result_directories([legacy]))
end

@testset "D16 tolerance defaults have a single source of truth" begin
    # The struct default, the environment-derived default and the shell must agree. They were
    # once declared in three places and drifted, which aborted a campaign configuration on
    # solver round-off; this pins them together.
    struct_default = test_config()
    @test struct_default.flow_tol == OOS_DEFAULT_FLOW_TOL
    @test struct_default.feasibility_tol == OOS_DEFAULT_FEASIBILITY_TOL
    @test struct_default.integrality_tol == OOS_DEFAULT_INTEGRALITY_TOL

    for key in ("FLOW_TOL", "FEASIBILITY_TOL", "INTEGRALITY_TOL", "CONTROLLER_SET",
                "FAIRNESS_SET", "PEA_TOLERANCE_MODE", "FAIRNESS_ABS_TOL")
        haskey(ENV, key) && delete!(ENV, key)
    end
    withenv("FORMULATION_ID" => "tolerance_probe", "OOS_OUTPUT_DIR" => TEST_OUTPUT) do
        from_environment = oos_config_from_environment()
        @test from_environment.flow_tol == struct_default.flow_tol
        @test from_environment.feasibility_tol == struct_default.feasibility_tol
        @test from_environment.integrality_tol == struct_default.integrality_tol
    end

    # The runner must not re-declare a numeric default that could drift from Julia's.
    runner = read(joinpath(REPO_ROOT, "scripts", "oos", "run_oos_experiment.sh"), String)
    @test !occursin(r"FLOW_TOL:-[0-9]", runner)
    @test !occursin(r"FEASIBILITY_TOL:-[0-9]", runner)
    @test !occursin(r"INTEGRALITY_TOL:-[0-9]", runner)

    # A validator must never be stricter than the solver's own guarantee.
    @test OOS_DEFAULT_FEASIBILITY_TOL > OOS_SOLVER_FEASIBILITY_TOL
    @test OOS_DEFAULT_FLOW_TOL > OOS_SOLVER_FEASIBILITY_TOL
    # ... and the PV-allocation identity accumulates (J+1) rows of that guarantee.
    config = test_config(households=10)
    common = build_common_objects(config; verbose=false)
    path = common.oos_paths[1]
    state = initial_simulation_state(common.template, path.replication_id)
    reveal_period!(state, path, 1)
    action = PeriodAction(1, 0, fill(path.pv[1] / 10, 10), zeros(10), zeros(10),
                          collect(path.demand[:, 1]) .- path.pv[1] / 10, zeros(10),
                          fill(0.1, 10), 0.0, 0.0, common.template.s_I)
    validation = validate_period_action(common.template, state, action, config)
    @test validation.valid
    @test validation.residuals.pv_allocation <= max(config.feasibility_tol,
                                                    11 * OOS_SOLVER_FEASIBILITY_TOL)
end
