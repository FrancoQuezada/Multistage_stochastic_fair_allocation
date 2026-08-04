if !isdefined(@__MODULE__, :solve_pea_restricted_exact)
    include("heuristics_sa_restricted_exact.jl")
elseif !isdefined(@__MODULE__, :solveMulti)
    include("multi.jl")
end

function _expected_pv_received_from_sol(inst::InstanceM, sol::SolutionM)
    [sum(inst.tree.rho[n] * sol.p[j, n] for n in 1:inst.tree.V) for j in 1:inst.J]
end

function solve_lex_pea_restricted_final(
    inst::InstanceM,
    expected_target::Vector{Float64};
    baseline_sol::Union{Nothing,SolutionM}=nothing,
    refs_in=nothing
)
    scenarioTree=inst.tree

    if refs_in !== nothing
        refs=refs_in
        baseline_sol !== nothing || error("Se requiere baseline_sol cuando se reusa refs_in.")
    elseif baseline_sol === nothing
        refs, baseline_sol=_solve_baseline_then_restrict(inst)
    else
        baseline_sol.status || error("La solucion baseline NONE no es factible.")
        refs=_build_full_multistage_model(inst)
    end

    _fix_battery_to_baseline!(refs, baseline_sol)
    _set_start_values_from_solution!(inst, refs, baseline_sol)

    @constraint(refs.model, [j in 1:inst.J, s in eachindex(scenarioTree.scenarios)],
        sum(refs.p[j, n] for n in scenarioTree.scenarios[s]) <= sum(inst.d[j, n] for n in scenarioTree.scenarios[s]))
    @constraint(refs.model, [j in 1:inst.J],
        sum(scenarioTree.rho[scenario[1]] * sum(refs.p[j, n] for n in scenario) for scenario in scenarioTree.scenarios) == expected_target[j])

    t_start=time()
    optimize!(refs.model)
    run_time=time() - t_start
    return _solution_from_full_model(inst, refs; run_time_sec=run_time)
end

function build_lex_pea_target_model(inst::InstanceM)
    scenarioTree=inst.tree
    model=Model(CPLEX.Optimizer)

    @variable(model, p[1:inst.J,1:scenarioTree.V] >= 0)
    @variable(model, zeta[1:inst.J])
    @variable(model, daux[1:inst.J,1:inst.J] >= 0)

    @constraint(model, [n in 1:scenarioTree.V], sum(p[j,n] for j in 1:inst.J) == inst.c_pv[n])
    @constraint(model, [j in 1:inst.J, s in eachindex(scenarioTree.scenarios)],
        sum(p[j,n] for n in scenarioTree.scenarios[s]) <= sum(inst.d[j,n] for n in scenarioTree.scenarios[s]))

    scenario_prob=[scenarioTree.rho[scenario[1]] for scenario in scenarioTree.scenarios]
    @expression(model, alloc[j in 1:inst.J],
        sum(scenario_prob[s] * sum(p[j,n] for n in scenarioTree.scenarios[s]) for s in eachindex(scenarioTree.scenarios)))
    for n in 1:inst.J, j in 1:inst.J
        @constraint(model, zeta[n] - daux[n,j] <= alloc[j])
    end

    set_silent(model)
    return (
        model=model,
        p=p,
        zeta=zeta,
        daux=daux
    )
end

function lexico_mmf_pea_targets_persistent(inst::InstanceM)
    persistent=build_lex_pea_target_model(inst)
    model=persistent.model
    ω=zeros(inst.J)
    p_last=zeros(inst.J, inst.tree.V)
    total_solve_time=0.0
    total_run_time=0.0
    lex_eps_abs=TOL

    for k in 1:inst.J
        @objective(model, Max, k * persistent.zeta[k] - sum(persistent.daux[k,j] for j in 1:inst.J))
        t_start=time()
        optimize!(model)
        step_run_time=time() - t_start
        step_time=round(solve_time(model), digits=2)
        total_solve_time += step_time
        total_run_time += step_run_time

        if !has_values(model)
            return zeros(inst.J), zeros(inst.J, length(inst.tree.scenarios)), round(total_solve_time, digits=2), total_run_time
        end

        ω[k]=objective_value(model)
        p_last .= value.(persistent.p)
        @constraint(model, k * persistent.zeta[k] - sum(persistent.daux[k,j] for j in 1:inst.J) >= ω[k] - lex_eps_abs)
    end

    scenarioTree=inst.tree
    scenario_prob=[scenarioTree.rho[scenario[1]] for scenario in scenarioTree.scenarios]
    scenario_target=[sum(p_last[j,n] for n in scenario) for j in 1:inst.J, scenario in scenarioTree.scenarios]
    expected_target=[sum(scenario_prob[s] * scenario_target[j,s] for s in eachindex(scenarioTree.scenarios)) for j in 1:inst.J]
    return expected_target, scenario_target, round(total_solve_time, digits=2), total_run_time
end

function solve_lex_pea_restricted_exact(
    inst::InstanceM;
    baseline_sol::Union{Nothing,SolutionM}=nothing
)
    refs=nothing
    if baseline_sol === nothing
        refs, baseline_sol=_solve_baseline_then_restrict(inst)
    else
        baseline_sol.status || error("La solucion baseline NONE no es factible.")
    end

    expected_target, scenario_target, lex_solve_time, lex_run_time = lexico_mmf_pea_targets_persistent(inst)
    final_sol = solve_lex_pea_restricted_final(inst, expected_target; baseline_sol=baseline_sol, refs_in=refs)

    actual_gap = expected_target .- _expected_pv_received_from_sol(inst, final_sol)
    return (
        baseline_sol=baseline_sol,
        restricted_sol=final_sol,
        total_run_time=baseline_sol.run_time + lex_run_time + final_sol.run_time,
        total_model_solve_time=baseline_sol.time + lex_solve_time + final_sol.time,
        diagnostics=(
            expected_target=expected_target,
            scenario_target=scenario_target,
            actual_gap=actual_gap
        )
    )
end

function _add_lex_sa_restricted_structure!(inst::InstanceM, refs)
    @variable(refs.model, zeta[1:inst.J])
    @variable(refs.model, d[1:inst.J,1:inst.J] >= 0)
    @constraint(refs.model, [j in 1:inst.J], refs.costs[j] >= 0)

    savings_rhs=[(inst.delta) * sum(refs.scenarioTree.rho[t] * inst.nu[j, refs.timePeriods[t]] * inst.d[j,t] for t in 1:refs.scenarioTree.V) for j in 1:inst.J]
    row_cons=Matrix{ConstraintRef}(undef, inst.J, inst.J)
    for n in 1:inst.J, j in 1:inst.J
        row_cons[n, j] = @constraint(refs.model, zeta[n] - d[n, j] <= savings_rhs[j] - refs.costs[j])
    end
    return (zeta=zeta, d=d, row_cons=row_cons)
end

function solve_lex_sa_restricted_exact(
    inst::InstanceM;
    baseline_sol::Union{Nothing,SolutionM}=nothing
)
    if baseline_sol === nothing
        refs, baseline_sol=_solve_baseline_then_restrict(inst)
    else
        baseline_sol.status || error("La solucion baseline NONE no es factible.")
        refs=_build_full_multistage_model(inst)
    end

    _fix_battery_to_baseline!(refs, baseline_sol)
    _set_start_values_from_solution!(inst, refs, baseline_sol)
    lexrefs=_add_lex_sa_restricted_structure!(inst, refs)

    ω=zeros(inst.J)
    sol=SolutionM(
        copy(baseline_sol.s),
        zeros(inst.J, inst.tree.V),
        zeros(inst.J, inst.tree.V),
        zeros(inst.J, inst.T),
        zeros(inst.J, inst.T),
        copy(baseline_sol.z),
        copy(baseline_sol.y),
        zeros(inst.J, inst.tree.V),
        fill(Inf, inst.J),
        false,
        0.0,
        0.0,
        inst.id
    )

    total_solve_time=0.0
    total_run_time=0.0
    lex_eps_abs = TOL
    for k in 1:inst.J
        @objective(refs.model, Max, k * lexrefs.zeta[k] - sum(lexrefs.d[k, j] for j in 1:inst.J))
        t_start=time()
        optimize!(refs.model)
        step_run_time=time() - t_start
        step_time=round(solve_time(refs.model), digits=2)
        total_solve_time += step_time
        total_run_time += step_run_time
        if has_values(refs.model)
            sol.costs=value.(refs.costs)
            sol.y=copy(baseline_sol.y)
            sol.z=copy(baseline_sol.z)
            sol.I=value.(refs.I)
            sol.p=value.(refs.p)
            sol.s=copy(baseline_sol.s)
            sol.G=value.(refs.G)
            sol.w=zeros(inst.J, inst.T)
            sol.x=zeros(inst.J, inst.T)
            sol.time=step_time
            sol.run_time=step_run_time
            sol.status=true
            sol.id=inst.id
            ω[k]=objective_value(refs.model)
            @constraint(refs.model, k * lexrefs.zeta[k] - sum(lexrefs.d[k, j] for j in 1:inst.J) >= ω[k] - lex_eps_abs)
        else
            sol.costs=fill(Inf, inst.J)
            sol.y=copy(baseline_sol.y)
            sol.z=copy(baseline_sol.z)
            sol.I=zeros(inst.J, inst.tree.V)
            sol.p=zeros(inst.J, inst.tree.V)
            sol.G=zeros(inst.J, inst.tree.V)
            sol.w=zeros(inst.J, inst.T)
            sol.x=zeros(inst.J, inst.T)
            sol.time=step_time
            sol.run_time=step_run_time
            sol.status=false
            sol.id=inst.id
            break
        end
    end
    sol.time=round(total_solve_time, digits=2)
    sol.run_time=total_run_time

    expected_savings=all_grid_expected_costs(inst) .- sol.costs
    return (
        baseline_sol=baseline_sol,
        restricted_sol=sol,
        total_run_time=baseline_sol.run_time + sol.run_time,
        total_model_solve_time=baseline_sol.time + sol.time,
        diagnostics=(
            omega=ω,
            expected_savings=expected_savings,
            sa_gap=_sa_expected_gap(inst, sol)
        )
    )
end

function solve_lex_restricted_exact(
    inst::InstanceM,
    fairness::String;
    baseline_sol::Union{Nothing,SolutionM}=nothing
)
    if fairness in ("LEXMMFPEA", "MMFPEA", "EMMFPEA")
        return solve_lex_pea_restricted_exact(inst; baseline_sol=baseline_sol)
    elseif fairness in ("LEXMMFSA", "MMFSA")
        return solve_lex_sa_restricted_exact(inst; baseline_sol=baseline_sol)
    else
        error("Fairness lexicografica restringida no soportada: $fairness")
    end
end
