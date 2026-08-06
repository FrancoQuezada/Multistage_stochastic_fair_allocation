if !isdefined(@__MODULE__, :solveMulti)
    include("multi.jl")
end

function _pea_expected_target(inst::InstanceM)
    scenarioTree=inst.tree
    [sum(
        scenarioTree.rho[scenario[1]] *
        (sum(inst.c_pv[n] for n in scenario) / sum(inst.d[k, n] for k in 1:inst.J, n in scenario)) *
        sum(inst.d[j, n] for n in scenario)
        for scenario in scenarioTree.scenarios
    ) for j in 1:inst.J]
end

function _pea_expected_gap(inst::InstanceM, sol::SolutionM)
    target=_pea_expected_target(inst)
    obtained=[sum(inst.tree.rho[n] * sol.p[j, n] for n in 1:inst.tree.V) for j in 1:inst.J]
    return obtained .- target
end

function _sa_expected_gap(inst::InstanceM, sol::SolutionM)
    scenarioTree=inst.tree
    timePeriods=createTime(scenarioTree)
    scen=scenarioTree.scenarios
    scenario_prob=[scenarioTree.rho[scenario[1]] for scenario in scen]
    grid_house=[[sum(inst.delta * inst.nu[j, timePeriods[n]] * inst.d[j, n] for n in scenario) for j in 1:inst.J] for scenario in scen]
    costNode=[inst.delta * (inst.mu * sol.y[j, n] + inst.nu[j, timePeriods[n]] * sol.I[j, n] - inst.beta * sol.G[j, n]) for j in 1:inst.J, n in 1:scenarioTree.V]
    grid_total=[max(TOL, sum(grid_house[s][j] for j in 1:inst.J)) for s in eachindex(scen)]
    gap=zeros(inst.J)
    for j in 1:inst.J
        lhs = sum(scenario_prob[s] * (grid_house[s][j] - sum(costNode[j, n] for n in scen[s])) for s in eachindex(scen))
        rhs = sum(scenario_prob[s] * ((grid_total[s] - sum(sum(costNode[k, n] for k in 1:inst.J) for n in scen[s])) / grid_total[s]) * grid_house[s][j] for s in eachindex(scen))
        gap[j] = lhs - rhs
    end
    return gap
end

function _build_full_multistage_model(inst::InstanceM)
    scenarioTree=inst.tree
    timePeriods=createTime(scenarioTree)
    model=Model(CPLEX.Optimizer)

    @variable(model, s[1:scenarioTree.V] >= 0)
    @variable(model, I[1:inst.J,1:scenarioTree.V] >= 0)
    @variable(model, G[1:inst.J,1:scenarioTree.V] >= 0)
    @variable(model, z[1:inst.J,1:scenarioTree.V] >= 0)
    @variable(model, y[1:inst.J,1:scenarioTree.V] >= 0)
    @variable(model, p[1:inst.J,1:scenarioTree.V] >= 0)
    @variable(model, lambda[1:inst.J,1:scenarioTree.V] >= 0)
    battery_mode=add_shared_battery_mode_constraints!(
        model, y, z, 1:inst.J, 1:scenarioTree.V;
        discharge_limit=inst.f_bar,
        charge_limit=inst.f_under,
    )

    @constraint(model, [j in 1:inst.J, n in 1:scenarioTree.V], p[j,n] == lambda[j,n] * inst.c_pv[n])
    @constraint(model, [n in 1:scenarioTree.V], sum(lambda[:,n]) == 1)
    @constraint(model, [n in 1:scenarioTree.V], s[n] <= inst.s_max)
    @constraint(model, [n in 2:scenarioTree.V],
        s[n] == s[scenarioTree.parents[n]] +
                inst.delta * inst.e_c * sum(z[j,n] for j in 1:inst.J) -
                inst.delta * sum(y[j,n] for j in 1:inst.J) / inst.e_d
    )
    @constraint(model, s[1] == inst.s_I +
        inst.delta * inst.e_c * sum(z[j,1] for j in 1:inst.J) -
        inst.delta * sum(y[j,1] for j in 1:inst.J) / inst.e_d
    )
    @constraint(model, [j in 1:inst.J, n in 1:scenarioTree.V], inst.d[j,n] == p[j,n] + y[j,n] + I[j,n] - z[j,n] - G[j,n])
    @constraint(model, [n in 1:scenarioTree.V; timePeriods[n] == inst.T], s[n] == inst.s_I)
    @constraint(model, [n in 1:scenarioTree.V], s[n] >= inst.s_min)

    @expression(model, costs[j in 1:inst.J], inst.delta * sum(
        scenarioTree.rho[n] * (inst.mu * y[j,n] + inst.nu[j,timePeriods[n]] * I[j,n] - inst.beta * G[j,n])
        for n in 1:scenarioTree.V
    ))
    @objective(model, Min, sum(costs[j] for j in 1:inst.J))

    set_attribute(model, "CPXPARAM_TimeLimit", 60 * 60)
    set_silent(model)

    return (
        model=model,
        scenarioTree=scenarioTree,
        timePeriods=timePeriods,
        s=s,
        I=I,
        G=G,
        battery_mode=battery_mode,
        z=z,
        y=y,
        p=p,
        lambda=lambda,
        costs=costs
    )
end

function _solution_from_full_model(inst::InstanceM, refs; run_time_sec::Float64)
    sol_time_sec=round(solve_time(refs.model), digits=2)
    if has_values(refs.model)
        return SolutionM(
            value.(refs.s),
            value.(refs.I),
            value.(refs.G),
            collect(value.(refs.battery_mode)),
            zeros(inst.J, inst.T),
            value.(refs.z),
            value.(refs.y),
            value.(refs.p),
            value.(refs.costs),
            true,
            sol_time_sec,
            run_time_sec,
            inst.id
        )
    end

    return SolutionM(
        zeros(refs.scenarioTree.V),
        zeros(inst.J, refs.scenarioTree.V),
        zeros(inst.J, refs.scenarioTree.V),
        zeros(refs.scenarioTree.V),
        zeros(inst.J, inst.T),
        zeros(inst.J, refs.scenarioTree.V),
        zeros(inst.J, refs.scenarioTree.V),
        zeros(inst.J, refs.scenarioTree.V),
        fill(Inf, inst.J),
        false,
        sol_time_sec,
        run_time_sec,
        inst.id
    )
end

function _set_start_values_from_solution!(inst::InstanceM, refs, sol::SolutionM)
    set_start_value.(refs.s, sol.s)
    set_start_value.(refs.I, sol.I)
    set_start_value.(refs.G, sol.G)
    set_start_value.(refs.z, sol.z)
    set_start_value.(refs.y, sol.y)
    set_start_value.(refs.battery_mode, sol.battery_mode)
    set_start_value.(refs.p, sol.p)
    for n in 1:refs.scenarioTree.V
        if abs(inst.c_pv[n]) > 1e-9
            for j in 1:inst.J
                set_start_value(refs.lambda[j,n], sol.p[j,n] / inst.c_pv[n])
            end
        else
            for j in 1:inst.J
                set_start_value(refs.lambda[j,n], 1.0 / inst.J)
            end
        end
    end
end

function _fix_battery_to_baseline!(refs, baseline_sol::SolutionM)
    fix.(refs.y, baseline_sol.y; force=true)
    fix.(refs.z, baseline_sol.z; force=true)
    fix.(refs.battery_mode, baseline_sol.battery_mode; force=true)
end

function _solve_baseline_then_restrict(inst::InstanceM)
    t_baseline=time()
    refs=_build_full_multistage_model(inst)
    optimize!(refs.model)
    baseline_run_time=time() - t_baseline
    baseline_sol=_solution_from_full_model(inst, refs; run_time_sec=baseline_run_time)
    baseline_sol.status || error("La solucion baseline NONE no es factible.")
    return refs, baseline_sol
end

function solve_pea_restricted_exact(
    inst::InstanceM;
    baseline_sol::Union{Nothing,SolutionM}=nothing
)
    target=_pea_expected_target(inst)

    if baseline_sol === nothing
        refs, baseline_sol=_solve_baseline_then_restrict(inst)
        _fix_battery_to_baseline!(refs, baseline_sol)
        _set_start_values_from_solution!(inst, refs, baseline_sol)

        @constraint(refs.model, [j in 1:inst.J],
            sum(refs.scenarioTree.rho[scenario[1]] * sum(refs.p[j, n] for n in scenario) for scenario in refs.scenarioTree.scenarios) == target[j]
        )

        t_restricted=time()
        optimize!(refs.model)
        restricted_run_time=time() - t_restricted
        sol=_solution_from_full_model(inst, refs; run_time_sec=restricted_run_time)
    else
        baseline_sol.status || error("La solucion baseline NONE no es factible.")
        t_restricted=time()
        refs=_build_full_multistage_model(inst)
        _fix_battery_to_baseline!(refs, baseline_sol)
        _set_start_values_from_solution!(inst, refs, baseline_sol)

        @constraint(refs.model, [j in 1:inst.J],
            sum(refs.scenarioTree.rho[scenario[1]] * sum(refs.p[j, n] for n in scenario) for scenario in refs.scenarioTree.scenarios) == target[j]
        )

        optimize!(refs.model)
        restricted_run_time=time() - t_restricted
        sol=_solution_from_full_model(inst, refs; run_time_sec=restricted_run_time)
    end

    return (
        baseline_sol=baseline_sol,
        restricted_sol=sol,
        total_run_time=baseline_sol.run_time + sol.run_time,
        total_model_solve_time=baseline_sol.time + sol.time,
        diagnostics=(
            baseline_expected_cost=sum(baseline_sol.costs),
            restricted_expected_cost=sum(sol.costs),
            pea_target=target,
            pea_gap=_pea_expected_gap(inst, sol)
        )
    )
end

function solve_sa_restricted_exact(
    inst::InstanceM;
    baseline_sol::Union{Nothing,SolutionM}=nothing,
    sa_fairness_abs_tol::Float64=0.0
)
    if baseline_sol === nothing
        refs, baseline_sol=_solve_baseline_then_restrict(inst)
    else
        baseline_sol.status || error("La solucion baseline NONE no es factible.")
        t_build=time()
        refs=_build_full_multistage_model(inst)
        build_run_time=time() - t_build
        _set_start_values_from_solution!(inst, refs, baseline_sol)
        # build_run_time is implicitly included in the restricted solve wall-clock below.
    end

    ybar=[sum(baseline_sol.y[j, n] for j in 1:inst.J) for n in 1:refs.scenarioTree.V]
    zbar=[sum(baseline_sol.z[j, n] for j in 1:inst.J) for n in 1:refs.scenarioTree.V]

    _fix_battery_to_baseline!(refs, baseline_sol)
    _set_start_values_from_solution!(inst, refs, baseline_sol)

    @expression(refs.model, costNode[j in 1:inst.J, n in 1:refs.scenarioTree.V], inst.delta * (
        inst.mu * refs.y[j,n] + inst.nu[j, refs.timePeriods[n]] * refs.I[j,n] - inst.beta * refs.G[j,n]
    ))

    scenario_prob=[refs.scenarioTree.rho[scenario[1]] for scenario in refs.scenarioTree.scenarios]
    grid_house=[[sum(inst.delta * inst.nu[j, refs.timePeriods[n]] * inst.d[j, n] for n in scenario) for j in 1:inst.J] for scenario in refs.scenarioTree.scenarios]
    grid_total=[max(TOL, sum(grid_house[s][j] for j in 1:inst.J)) for s in eachindex(refs.scenarioTree.scenarios)]
    for j in 1:inst.J
        lhs = sum(scenario_prob[s] * (grid_house[s][j] - sum(costNode[j, n] for n in refs.scenarioTree.scenarios[s])) for s in eachindex(refs.scenarioTree.scenarios))
        rhs = sum(scenario_prob[s] * ((grid_total[s] - sum(sum(costNode[k, n] for k in 1:inst.J) for n in refs.scenarioTree.scenarios[s])) / grid_total[s]) * grid_house[s][j] for s in eachindex(refs.scenarioTree.scenarios))
        if sa_fairness_abs_tol > 0
            @constraint(refs.model, lhs - rhs <= sa_fairness_abs_tol)
            @constraint(refs.model, rhs - lhs <= sa_fairness_abs_tol)
        else
            @constraint(refs.model, lhs == rhs)
        end
    end

    t_restricted=time()
    optimize!(refs.model)
    restricted_run_time=time() - t_restricted
    sol=_solution_from_full_model(inst, refs; run_time_sec=restricted_run_time)

    return (
        baseline_sol=baseline_sol,
        restricted_sol=sol,
        total_run_time=baseline_sol.run_time + sol.run_time,
        total_model_solve_time=baseline_sol.time + sol.time,
        diagnostics=(
            baseline_expected_cost=sum(baseline_sol.costs),
            restricted_expected_cost=sum(sol.costs),
            aggregate_y=ybar,
            aggregate_z=zbar,
            sa_gap=_sa_expected_gap(inst, sol)
        )
    )
end

function solve_restricted_exact(
    inst::InstanceM,
    fairness::String;
    baseline_sol::Union{Nothing,SolutionM}=nothing,
    sa_fairness_abs_tol::Float64=0.0
)
    if fairness == "PEA"
        return solve_pea_restricted_exact(inst; baseline_sol=baseline_sol)
    elseif fairness == "SA"
        return solve_sa_restricted_exact(inst; baseline_sol=baseline_sol, sa_fairness_abs_tol=sa_fairness_abs_tol)
    else
        error("Fairness restringida no soportada: $fairness")
    end
end
