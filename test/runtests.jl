using Test
using JuMP
using CPLEX

const REPO_ROOT = normpath(joinpath(@__DIR__, ".."))
include(joinpath(REPO_ROOT, "codes", "multi.jl"))
include(joinpath(REPO_ROOT, "codes", "heuristics_sa_restricted_exact.jl"))
include(joinpath(REPO_ROOT, "codes", "heuristics_lex_restricted_exact.jl"))
include(joinpath(REPO_ROOT, "codes", "heuristics_decomposed_restricted_exact.jl"))
include(joinpath(REPO_ROOT, "codes", "structures_deterministic.jl"))
include(joinpath(REPO_ROOT, "codes", "two_stage_none.jl"))

function _silent_model()
    model = Model(CPLEX.Optimizer)
    set_silent(model)
    return model
end

function _shared_flow_model(; households=2, nodes=1, discharge_limit=4.0, charge_limit=3.0)
    model = _silent_model()
    @variable(model, y[1:households,1:nodes] >= 0)
    @variable(model, z[1:households,1:nodes] >= 0)
    battery_mode = add_shared_battery_mode_constraints!(
        model, y, z, 1:households, 1:nodes;
        discharge_limit=discharge_limit,
        charge_limit=charge_limit,
    )
    @objective(model, Min, 0)
    return (model=model, y=y, z=z, battery_mode=battery_mode)
end

function _is_feasible(y_values, z_values; mode_value=nothing, discharge_limit=4.0, charge_limit=3.0)
    refs = _shared_flow_model(
        households=size(y_values, 1),
        nodes=size(y_values, 2),
        discharge_limit=discharge_limit,
        charge_limit=charge_limit,
    )
    fix.(refs.y, y_values; force=true)
    fix.(refs.z, z_values; force=true)
    if mode_value !== nothing
        fix.(refs.battery_mode, mode_value; force=true)
    end
    optimize!(refs.model)
    return is_solved_and_feasible(refs.model; allow_local=false, dual=false)
end

function _old_household_mode_accepts_cross_flow()
    model = _silent_model()
    @variable(model, y[1:2,1:1] >= 0)
    @variable(model, z[1:2,1:1] >= 0)
    @variable(model, legacy_mode[1:2,1:1], Bin)
    @constraint(model, [j in 1:2], z[j,1] <= 3.0 * legacy_mode[j,1])
    @constraint(model, [j in 1:2], y[j,1] <= 4.0 * (1 - legacy_mode[j,1]))
    fix(y[1,1], 0.0; force=true)
    fix(z[1,1], 1.0; force=true)
    fix(y[2,1], 1.0; force=true)
    fix(z[2,1], 0.0; force=true)
    @objective(model, Min, 0)
    optimize!(model)
    return is_solved_and_feasible(model; allow_local=false, dual=false)
end

function _direction_throughput_objective(; shared_mode::Bool)
    model = _silent_model()
    @variable(model, y[1:2,1:1] >= 0)
    @variable(model, z[1:2,1:1] >= 0)
    if shared_mode
        add_shared_battery_mode_constraints!(
            model, y, z, 1:2, 1:1;
            discharge_limit=4.0,
            charge_limit=3.0,
        )
    else
        @variable(model, legacy_mode[1:2,1:1], Bin)
        @constraint(model, [j in 1:2], z[j,1] <= 3.0 * legacy_mode[j,1])
        @constraint(model, [j in 1:2], y[j,1] <= 4.0 * (1 - legacy_mode[j,1]))
        @constraint(model, sum(y[:,1]) <= 4.0)
        @constraint(model, sum(z[:,1]) <= 3.0)
    end
    @objective(model, Max, sum(y) + sum(z))
    optimize!(model)
    return objective_value(model)
end

function _small_twostage_instance()
    inst = Instance()
    inst.J = 2
    inst.T = 2
    inst.Omega = 2
    inst.s_max = 5.0
    inst.s_min = 0.0
    inst.delta = 1.0
    inst.e_c = 0.95
    inst.e_d = 0.95
    inst.s_I = 1.0
    inst.f_under = 2.0
    inst.f_bar = 2.0
    inst.mu = 0.0
    inst.beta = 0.0
    inst.nu = ones(inst.J, inst.T)
    inst.c_pv = zeros(inst.T, inst.Omega)
    inst.pv_det = zeros(inst.T)
    inst.d = zeros(inst.J, inst.T, inst.Omega)
    inst.d_det = zeros(inst.J, inst.T)
    inst.rho = fill(0.5, inst.Omega)
    inst.id = "shared_battery_test"
    inst.timeStamp = string.(1:inst.T)
    return inst
end

@testset "Shared-battery physical invariants" begin
    @test _old_household_mode_accepts_cross_flow()
    @test _direction_throughput_objective(shared_mode=false) ≈ 7.0
    @test _direction_throughput_objective(shared_mode=true) ≈ 4.0

    # A household charging while another receives discharge is impossible.
    @test !_is_feasible([0.0; 1.0;;], [1.0; 0.0;;])
    # The same household cannot charge and discharge simultaneously.
    @test !_is_feasible([1.0; 0.0;;], [1.0; 0.0;;])
    # Multiple households may use the same aggregate direction within its rate.
    @test _is_feasible([0.0; 0.0;;], [1.0; 2.0;;])
    @test _is_feasible([1.5; 2.5;;], [0.0; 0.0;;])
    # Aggregate rate violations remain infeasible.
    @test !_is_feasible([0.0; 0.0;;], [1.5; 2.0;;])
    @test !_is_feasible([2.0; 2.1;;], [0.0; 0.0;;])
    # Idle is feasible in either mode.
    @test _is_feasible(zeros(2, 1), zeros(2, 1); mode_value=[0.0])
    @test _is_feasible(zeros(2, 1), zeros(2, 1); mode_value=[1.0])
end

@testset "Mode conversion, policy lookup, and simulation checks" begin
    y = [0.0 1.0 0.0; 0.0 2.0 0.0]
    z = [1.0 0.0 0.0; 2.0 0.0 0.0]
    @test battery_mode_from_flows(y, z) == [1.0, 0.0, 0.0]
    @test_throws ErrorException battery_mode_from_flows([1.0;;], [1.0;;])

    agreeing = [1.0 0.0 0.0; 1.0 0.0 0.0]
    converted = convert_legacy_battery_mode(agreeing, y, z)
    @test converted.battery_mode == [1.0, 0.0, 0.0]
    @test isempty(converted.repaired_indices)

    disagreeing = [1.0 1.0 0.0; 0.0 0.0 1.0]
    repaired = convert_legacy_battery_mode(disagreeing, y, z)
    @test repaired.battery_mode == [1.0, 0.0, 0.0]
    @test length(repaired.repaired_indices) == 3
    @test_throws ErrorException convert_legacy_battery_mode([1.0; 0.0;;], [1.0; 0.0;;], [0.0; 1.0;;])
    @test_throws ErrorException convert_legacy_battery_mode(fill(0.25, 2, 1), zeros(2, 1), zeros(2, 1))

    violations = shared_battery_violations([1.0], [0.0; 1.0;;], [1.0; 0.0;;])
    @test violations.simultaneous_flow > 0
    @test violations.mode_violation > 0
    @test shared_battery_violations([0.25], zeros(1, 1), zeros(1, 1)).mode_violation > 0
end

@testset "Repository formulations and solution dimensions" begin
    inst = generateInstance(
        3, 2, 8, 2,
        joinpath(REPO_ROOT, "codes", "inst", "inst2020", "Drahi_1.csv"),
        0.2, 100.0, 10.0,
    )
    refs = _build_full_multistage_model(inst)
    @test length(refs.battery_mode) == inst.tree.V
    @test num_constraints(refs.model, VariableRef, JuMP.MOI.ZeroOne) == inst.tree.V
    @test all(startswith(name(variable), "battery_mode[") for variable in refs.battery_mode)
    @test all(!occursin(',', name(variable)) for variable in refs.battery_mode)
    @test all(has_lower_bound(variable) && lower_bound(variable) == 0.0 for variable in refs.y)
    @test all(has_lower_bound(variable) && lower_bound(variable) == 0.0 for variable in refs.z)

    # Node-based storage makes nonanticipativity implicit for shared scenario histories.
    for node in 1:inst.tree.V
        scenarios = [scenario for scenario in inst.tree.scenarios if node in scenario]
        isempty(scenarios) || @test refs.battery_mode[node] === refs.battery_mode[node]
    end

    lp_path = tempname() * ".lp"
    write_to_file(refs.model, lp_path)
    lp = read(lp_path, String)
    # JuMP's LP writer sanitizes brackets to underscores, while the in-memory names retain them.
    @test occursin("battery_mode_1_", lp)
    @test !occursin(r"battery_mode_[0-9]+,[0-9]+_", lp)
    @test !occursin(r"legacy_mode|x_[0-9]+,[0-9]+_", lp)

    optimize!(refs.model)
    sol = _solution_from_full_model(inst, refs; run_time_sec=0.0)
    @test sol.status
    @test size(sol.battery_mode) == (inst.tree.V,)
    @test shared_battery_violations(
        sol.battery_mode, sol.y, sol.z;
        discharge_limit=inst.f_bar,
        charge_limit=inst.f_under,
    ) == (simultaneous_flow=0.0, mode_violation=0.0, rate_violation=0.0)

    # Warm starts and restricted-exact fixing transfer one value per node.
    warm_refs = _build_full_multistage_model(inst)
    _set_start_values_from_solution!(inst, warm_refs, sol)
    @test [start_value(warm_refs.battery_mode[n]) for n in 1:inst.tree.V] == sol.battery_mode
    _fix_battery_to_baseline!(warm_refs, sol)
    @test [fix_value(warm_refs.battery_mode[n]) for n in 1:inst.tree.V] == sol.battery_mode

    conditional_refs = _build_conditional_full_model(inst)
    static_refs = _build_static_demand_share_model(inst, static_demand_shares(inst))
    lex_sa_refs = build_lex_sa_model(inst)
    for formulation in (conditional_refs, static_refs, lex_sa_refs)
        @test length(formulation.battery_mode) == inst.tree.V
        @test num_constraints(formulation.model, VariableRef, JuMP.MOI.ZeroOne) == inst.tree.V
    end

    # The decomposed reconstruction stores a node-level mode and validates fixed flows.
    reconstructed = _assemble_house_recourse(inst, sol.p, sol.y, sol.z, sol.s)
    @test reconstructed.battery_mode == battery_mode_from_flows(sol.y, sol.z)

    two_stage_sol = twoS_none(_small_twostage_instance())
    @test two_stage_sol.status
    @test size(two_stage_sol.battery_mode) == (2, 2)
    @test shared_battery_violations(
        two_stage_sol.battery_mode, two_stage_sol.y, two_stage_sol.z;
        discharge_limit=2.0,
        charge_limit=2.0,
    ) == (simultaneous_flow=0.0, mode_violation=0.0, rate_violation=0.0)
end

@testset "Final source audit" begin
    source_roots = [joinpath(REPO_ROOT, "codes"), joinpath(REPO_ROOT, "archive_legacy")]
    source_files = String[]
    for root in source_roots
        for (directory, _, files) in walkdir(root)
            append!(source_files, joinpath.(directory, filter(file -> endswith(file, ".jl"), files)))
        end
    end
    source = join(read.(source_files, String), "\n")
    @test !occursin(r"battery set-up charge", source)
    @test !occursin(r"\.x\b", source)
    @test !occursin(r"@variable\([^\n]*\bx\[1:inst\.J", source)
    @test !occursin(r"xAux", source)
end
