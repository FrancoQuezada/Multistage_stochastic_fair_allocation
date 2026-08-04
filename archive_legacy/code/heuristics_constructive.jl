if !isdefined(@__MODULE__, :solveMulti)
    include("multi.jl")
end

using Statistics

const HEUR_TOL = 1e-9

function _expected_pv_received(inst::InstanceM, sol::SolutionM)
    return [sum(inst.tree.rho[n] * sol.p[j, n] for n in 1:inst.tree.V) for j in 1:inst.J]
end

function _expected_pv_received(inst::InstanceM, lambda_policy::Array{Float64,2})
    return [sum(inst.tree.rho[n] * lambda_policy[j, n] * inst.c_pv[n] for n in 1:inst.tree.V) for j in 1:inst.J]
end

function _baseline_lambda(inst::InstanceM, sol::SolutionM; weight_floor::Float64=1e-8)
    lambda0=zeros(inst.J, inst.tree.V)
    for n in 1:inst.tree.V
        if inst.c_pv[n] > HEUR_TOL
            for j in 1:inst.J
                lambda0[j, n]=max(sol.p[j, n] / inst.c_pv[n], 0.0)
            end
        else
            lambda0[:, n] .= 1.0 / inst.J
        end
        total=sum(lambda0[:, n])
        if total <= HEUR_TOL
            lambda0[:, n] .= 1.0 / inst.J
        else
            lambda0[:, n] ./= total
        end
        lambda0[:, n] .= max.(lambda0[:, n], weight_floor)
        lambda0[:, n] ./= sum(lambda0[:, n])
    end
    return lambda0
end

function _pea_expected_target(inst::InstanceM)
    target=zeros(inst.J)
    for scenario in inst.tree.scenarios
        scen_prob=inst.tree.rho[scenario[1]]
        total_pv=sum(inst.c_pv[n] for n in scenario)
        total_demand=sum(inst.d[j, n] for j in 1:inst.J, n in scenario)
        total_demand <= TOL && continue
        for j in 1:inst.J
            target[j] += scen_prob * (total_pv / total_demand) * sum(inst.d[j, n] for n in scenario)
        end
    end
    return target
end

function _scenario_savings_matrix(inst::InstanceM, sol::SolutionM)
    grid_costs=all_grid_scenario_cost_matrix(inst)
    scenario_costs=_scenario_cost_matrix(inst, sol)
    return grid_costs .- scenario_costs
end

function _expected_savings(inst::InstanceM, sol::SolutionM)
    return all_grid_expected_costs(inst) .- sol.costs
end

function _sa_expected_gap(inst::InstanceM, sol::SolutionM)
    scenarioTree=inst.tree
    timePeriods=createTime(scenarioTree)
    scen=scenarioTree.scenarios
    scenario_prob=[scenarioTree.rho[scenario[1]] for scenario in scen]
    grid_house=[[sum(inst.delta * inst.nu[j, timePeriods[n]] * inst.d[j, n] for n in scenario) for j in 1:inst.J] for scenario in scen]
    costNode=[inst.delta * (inst.mu * sol.y[j, n] + inst.nu[j, timePeriods[n]] * sol.I[j, n] - inst.beta * sol.G[j, n]) for j in 1:inst.J, n in 1:scenarioTree.V]
    grid_total=[max(HEUR_TOL, sum(grid_house[s][j] for j in 1:inst.J)) for s in eachindex(scen)]
    gap=zeros(inst.J)
    for j in 1:inst.J
        lhs = sum(scenario_prob[s] * (grid_house[s][j] - sum(costNode[j, n] for n in scen[s])) for s in eachindex(scen))
        rhs = sum(scenario_prob[s] * ((grid_total[s] - sum(sum(costNode[k, n] for k in 1:inst.J) for n in scen[s])) / grid_total[s]) * grid_house[s][j] for s in eachindex(scen))
        gap[j] = lhs - rhs
    end
    return gap
end

function _sa_expected_target_from_baseline(inst::InstanceM, baseline_sol::SolutionM)
    grid_costs=all_grid_scenario_cost_matrix(inst)
    scenario_costs=_scenario_cost_matrix(inst, baseline_sol)
    target=zeros(inst.J)
    for (s_idx, scenario) in enumerate(inst.tree.scenarios)
        scen_prob=inst.tree.rho[scenario[1]]
        grid_house=grid_costs[:, s_idx]
        grid_total=max(sum(grid_house), TOL)
        total_savings=sum(grid_house) - sum(scenario_costs[:, s_idx])
        ratio=total_savings / grid_total
        for j in 1:inst.J
            target[j] += scen_prob * ratio * grid_house[j]
        end
    end
    return target
end

function _normalize_scores!(scores::AbstractVector{<:Real}; weight_floor::Float64=1e-8)
    scores .= max.(scores, 0.0)
    total=sum(scores)
    if total <= HEUR_TOL
        scores .= 1.0
    end
    scores .= max.(scores, weight_floor)
    scores ./= sum(scores)
    return scores
end

function _pea_lambda_objective_weights(
    inst::InstanceM,
    baseline_sol::SolutionM,
    lambda0::Array{Float64,2};
    eta::Float64=1.0,
    weight_floor::Float64=1e-8
)
    timePeriods=createTime(inst.tree)
    weights=zeros(inst.J, inst.tree.V)
    eta_eff=max(eta, weight_floor)
    for n in 1:inst.tree.V
        t=timePeriods[n]
        expected_budget=inst.tree.rho[n] * inst.c_pv[n]
        for j in 1:inst.J
            demand=max(inst.d[j, n], TOL)
            import_ratio=clamp(baseline_sol.I[j, n] / demand, 0.0, 1.0)
            marginal_value=inst.beta + (inst.nu[j, t] - inst.beta) * import_ratio
            alignment=max(lambda0[j, n], weight_floor)^eta_eff
            weights[j, n]=max(expected_budget * marginal_value * alignment, weight_floor)
        end
    end
    return weights
end

function _allocate_capped_proportional!(
    alloc::AbstractVector{Float64},
    residual::AbstractVector{Float64},
    weights::AbstractVector{Float64},
    budget::Float64;
    weight_floor::Float64=1e-8
)
    alloc .= 0.0
    budget_rem = min(budget, sum(residual))
    active = [j for j in eachindex(residual) if residual[j] > HEUR_TOL]

    while budget_rem > HEUR_TOL && !isempty(active)
        w = [max(weights[j], weight_floor) for j in active]
        wsum = sum(w)
        wsum <= HEUR_TOL && (w .= 1.0; wsum = sum(w))
        proposal = budget_rem .* (w ./ wsum)

        saturated_any = false
        for (idx, j) in enumerate(active)
            if proposal[idx] >= residual[j] - HEUR_TOL
                alloc[j] += residual[j]
                budget_rem -= residual[j]
                residual[j] = 0.0
                saturated_any = true
            end
        end

        if !saturated_any
            for (idx, j) in enumerate(active)
                alloc[j] += proposal[idx]
                residual[j] -= proposal[idx]
            end
            budget_rem = 0.0
        end

        active = [j for j in active if residual[j] > HEUR_TOL]
    end

    return alloc
end

function _constructive_exact_budget_split!(
    alloc::AbstractVector{Float64},
    residual::AbstractVector{Float64},
    weights::AbstractVector{Float64},
    budget::Float64,
    future_budget::Float64;
    weight_floor::Float64=1e-8
)
    alloc .= 0.0
    budget <= HEUR_TOL && return alloc

    total_residual=sum(residual)
    expected_total=budget + future_budget
    abs(total_residual - expected_total) <= 1e-8 * max(expected_total, 1.0) ||
        error("Asignacion constructiva PEA inconsistente: residual total != budget + future_budget.")
    capacity=copy(residual)
    _allocate_capped_proportional!(alloc, capacity, weights, budget; weight_floor=weight_floor)

    total_alloc=sum(alloc)
    diff=budget-total_alloc
    if abs(diff) > 1e-10 * max(budget, 1.0)
        if diff > 0
            room=max.(capacity, 0.0)
            j=argmax(room)
            room[j] + 1e-8 >= diff || error("No hay capacidad suficiente para cerrar el presupuesto constructivo.")
            alloc[j] += diff
            capacity[j] -= diff
        else
            j=argmax(alloc)
            alloc[j] + 1e-8 >= -diff || error("No hay asignacion suficiente para ajustar el presupuesto constructivo.")
            alloc[j] += diff
            capacity[j] -= diff
        end
    end

    residual .= max.(capacity, 0.0)
    total_residual_new=sum(residual)
    abs(total_residual_new - future_budget) <= 1e-8 * max(future_budget, 1.0) ||
        error("Asignacion constructiva PEA inconsistente: residual final != future_budget.")
    return alloc
end

function _constructive_sa_energy_split!(
    alloc::AbstractVector{Float64},
    residual::AbstractVector{Float64},
    unit_value::AbstractVector{Float64},
    scores::AbstractVector{Float64},
    energy_budget::Float64,
    future_potential::AbstractVector{Float64};
    weight_floor::Float64=1e-8
)
    alloc .= 0.0
    energy_budget <= HEUR_TOL && return alloc

    mandatory=zeros(length(residual))
    for j in eachindex(residual)
        if residual[j] > future_potential[j] + HEUR_TOL && unit_value[j] > HEUR_TOL
            mandatory[j]=(residual[j] - future_potential[j]) / unit_value[j]
        end
    end

    mandatory_total=sum(mandatory)
    if mandatory_total > energy_budget + 1e-8 * max(energy_budget, 1.0)
        mandatory .*= energy_budget / mandatory_total
        mandatory_total=energy_budget
    end
    alloc .+= mandatory

    residual_after=max.(residual .- unit_value .* alloc, 0.0)
    energy_rem=energy_budget - mandatory_total

    if energy_rem > HEUR_TOL
        caps=zeros(length(residual))
        for j in eachindex(residual)
            if unit_value[j] > HEUR_TOL
                caps[j]=residual_after[j] / unit_value[j]
            end
        end
        if sum(caps) > HEUR_TOL
            extra=similar(alloc)
            _allocate_capped_proportional!(extra, caps, scores, energy_rem; weight_floor=weight_floor)
            alloc .+= extra
            residual_after .-= unit_value .* extra
            residual_after .= max.(residual_after, 0.0)
        end
    end

    residual .= residual_after
    return alloc
end

function constructive_lambda_pea(
    inst::InstanceM;
    baseline_sol::Union{Nothing,SolutionM}=nothing,
    eta::Float64=1.0,
    weight_floor::Float64=1e-8
)
    baseline_sol === nothing && (baseline_sol = solveMulti(inst, "NONE"))
    baseline_sol.status || error("La solucion baseline NONE no es factible.")

    lambda0=_baseline_lambda(inst, baseline_sol; weight_floor=weight_floor)
    target=_pea_expected_target(inst)
    total_budget = sum(inst.tree.rho[n] * inst.c_pv[n] for n in 1:inst.tree.V)
    total_target = sum(target)
    if abs(total_target - total_budget) > 1e-6 * max(total_budget, 1.0)
        error("Target PEA inconsistente: total_target=$(total_target) vs total_budget=$(total_budget)")
    end
    if total_target > HEUR_TOL
        target .*= total_budget / total_target
    end

    t_start=time()
    weights=_pea_lambda_objective_weights(
        inst,
        baseline_sol,
        lambda0;
        eta=eta,
        weight_floor=weight_floor
    )
    lambdaH=zeros(inst.J, inst.tree.V)
    residual=copy(target)
    node_order=sortperm(createTime(inst.tree))
    node_budget=[inst.tree.rho[n] * inst.c_pv[n] for n in node_order]
    suffix_future=zeros(length(node_order))
    rem=0.0
    for idx in reverse(eachindex(node_order))
        suffix_future[idx]=rem
        rem += node_budget[idx]
    end
    node_alloc=zeros(inst.J)
    for (idx, n) in enumerate(node_order)
        budget=node_budget[idx]
        if budget <= HEUR_TOL
            lambdaH[:, n] .= 1.0 / inst.J
            continue
        end
        _constructive_exact_budget_split!(
            node_alloc,
            residual,
            view(weights, :, n),
            budget,
            suffix_future[idx];
            weight_floor=weight_floor
        )
        lambdaH[:, n] .= node_alloc ./ budget
    end
    alloc_run_time=time() - t_start
    alloc_solve_time=0.0

    final_expected=_expected_pv_received(inst, lambdaH)
    actual_gap=target .- final_expected
    final_residual=copy(residual)
    maximum(abs.(final_residual)) <= 1e-8 * max(total_budget, 1.0) || error("La heuristica PEA no cerro el residual constructivo.")
    maximum(abs.(actual_gap)) <= 1e-8 * max(total_budget, 1.0) || error("La heuristica PEA no cerro el target esperado inducido por lambda.")

    diagnostics=(
        target=target,
        baseline_expected=_expected_pv_received(inst, baseline_sol),
        final_expected=final_expected,
        initial_residual=copy(target),
        final_residual=copy(final_residual),
        actual_gap=copy(actual_gap),
        baseline_lambda=lambda0,
        allocation_run_time=alloc_run_time,
        allocation_solve_time=alloc_solve_time
    )
    return lambdaH, diagnostics
end

function constructive_lambda_sa(
    inst::InstanceM;
    baseline_sol::Union{Nothing,SolutionM}=nothing,
    eta::Float64=1.0,
    weight_floor::Float64=1e-8
)
    baseline_sol === nothing && (baseline_sol = solveMulti(inst, "NONE"))
    baseline_sol.status || error("La solucion baseline NONE no es factible.")

    lambda0=_baseline_lambda(inst, baseline_sol; weight_floor=weight_floor)
    target=_sa_expected_target_from_baseline(inst, baseline_sol)
    residual=copy(target)
    lambdaH=zeros(inst.J, inst.tree.V)
    timePeriods=createTime(inst.tree)
    node_order=sortperm(timePeriods)
    unit_value=zeros(inst.J)
    unit_values=zeros(inst.J, inst.tree.V)
    energy_alloc=zeros(inst.J)
    future_potential=zeros(inst.J, length(node_order))

    for n in node_order
        t=timePeriods[n]
        for j in 1:inst.J
            demand=max(inst.d[j, n], HEUR_TOL)
            import_ratio=clamp(baseline_sol.I[j, n] / demand, 0.0, 1.0)
            demand_ratio=clamp(inst.d[j, n] / max(inst.c_pv[n], HEUR_TOL), 0.0, 1.0)
            local_use_ratio=max(import_ratio, demand_ratio)
            unit_values[j, n]=inst.tree.rho[n] * inst.delta * (inst.beta + (inst.nu[j, t] - inst.beta) * local_use_ratio)
        end
    end

    running_future=zeros(inst.J)
    for idx in reverse(eachindex(node_order))
        future_potential[:, idx] .= running_future
        n=node_order[idx]
        running_future .+= unit_values[:, n] .* inst.c_pv[n]
    end

    for (idx, n) in enumerate(node_order)
        if inst.c_pv[n] <= HEUR_TOL
            lambdaH[:, n] .= lambda0[:, n]
            continue
        end
        demand_n=inst.d[:, n]
        need=max.(residual, 0.0)
        scores=Vector{Float64}(undef, inst.J)
        unit_value .= view(unit_values, :, n)
        attainable = future_potential[:, idx] .+ unit_value .* inst.c_pv[n]
        for j in 1:inst.J
            base=max(lambda0[j, n], weight_floor)
            if need[j] <= HEUR_TOL || unit_value[j] <= HEUR_TOL
                scores[j]=0.0
            else
                scarcity=need[j] / max(attainable[j], weight_floor)
                local_value=max(unit_value[j], weight_floor)
                local_demand=max(demand_n[j], weight_floor)
                scores[j]=base * local_value * local_demand * (1.0 + eta * scarcity)
            end
        end
        if maximum(scores) <= HEUR_TOL
            lambdaH[:, n] .= lambda0[:, n]
            continue
        end
        _constructive_sa_energy_split!(
            energy_alloc,
            residual,
            unit_value,
            scores,
            inst.c_pv[n],
            view(future_potential, :, idx);
            weight_floor=weight_floor
        )
        if sum(energy_alloc) <= HEUR_TOL
            lambdaH[:, n] .= lambda0[:, n]
            continue
        end
        lambdaH[:, n] .= energy_alloc ./ inst.c_pv[n]
    end

    diagnostics=(
        target=target,
        baseline_expected=_expected_savings(inst, baseline_sol),
        initial_residual=copy(target),
        final_residual=copy(residual),
        baseline_lambda=lambda0
    )
    return lambdaH, diagnostics
end

function solve_fixed_lambda_policy(inst::InstanceM, lambda_policy::Array{Float64,2})
    size(lambda_policy, 1) == inst.J || error("lambda_policy debe tener J filas.")
    size(lambda_policy, 2) == inst.tree.V || error("lambda_policy debe tener V columnas.")

    t_start = time()
    lambda_use=copy(lambda_policy)
    for n in 1:inst.tree.V
        _normalize_scores!(view(lambda_use, :, n))
    end

    scenarioTree=inst.tree
    timePeriods=createTime(scenarioTree)
    model=Model(CPLEX.Optimizer)

    @variable(model, s[1:scenarioTree.V] >= 0)
    @variable(model, I[1:inst.J,1:scenarioTree.V] >= 0)
    @variable(model, G[1:inst.J,1:scenarioTree.V] >= 0)
    @variable(model, z[1:inst.J,1:scenarioTree.V] >= 0)
    @variable(model, y[1:inst.J,1:scenarioTree.V] >= 0)
    @expression(model, p[j in 1:inst.J, n in 1:scenarioTree.V], lambda_use[j, n] * inst.c_pv[n])

    @constraint(model, [n in 1:scenarioTree.V], s[n] <= inst.s_max)
    @constraint(model, [n in 2:scenarioTree.V], s[n] == s[scenarioTree.parents[n]] + inst.delta * inst.e_c * sum(z[j, n] for j in 1:inst.J) - inst.delta * sum(y[j, n] for j in 1:inst.J) / inst.e_d)
    @constraint(model, s[1] == inst.s_I + inst.delta * inst.e_c * sum(z[j, 1] for j in 1:inst.J) - inst.delta * sum(y[j, 1] for j in 1:inst.J) / inst.e_d)
    @constraint(model, [n in 1:scenarioTree.V], sum(y[j, n] for j in 1:inst.J) <= inst.f_bar)
    @constraint(model, [n in 1:scenarioTree.V], sum(z[j, n] for j in 1:inst.J) <= inst.f_under)
    @constraint(model, [j in 1:inst.J, n in 1:scenarioTree.V], inst.d[j, n] == p[j, n] + y[j, n] + I[j, n] - z[j, n] - G[j, n])
    @constraint(model, [n in 1:scenarioTree.V ; timePeriods[n] == inst.T], s[n] == inst.s_I)
    @constraint(model, [n in 1:scenarioTree.V], s[n] >= inst.s_min)

    @expression(model, costs[j in 1:inst.J], inst.delta * sum(scenarioTree.rho[n] * (inst.mu * y[j, n] + inst.nu[j, timePeriods[n]] * I[j, n] - inst.beta * G[j, n]) for n in 1:scenarioTree.V))
    @objective(model, Min, sum(costs[j] for j in 1:inst.J))

    set_attribute(model, "CPXPARAM_TimeLimit", 60 * 60)
    set_silent(model)
    optimize!(model)
    run_time = time() - t_start

    if has_values(model)
        costsAux=value.(costs)
        yAux=value.(y)
        zAux=value.(z)
        iAux=value.(I)
        pAux=value.(p)
        sTotAux=value.(s)
        GAux=value.(G)
        wAux=zeros(inst.J, inst.T)
        xAux=zeros(inst.J, inst.T)
        solTime=round(solve_time(model), digits=2)
        return SolutionM(sTotAux, iAux, GAux, xAux, wAux, zAux, yAux, pAux, costsAux, true, solTime, run_time, inst.id)
    end

    costsAux=fill(Inf, inst.J)
    yAux=zeros(inst.J, inst.tree.V)
    zAux=zeros(inst.J, inst.tree.V)
    iAux=zeros(inst.J, inst.tree.V)
    pAux=zeros(inst.J, inst.tree.V)
    sTotAux=zeros(inst.tree.V)
    GAux=zeros(inst.J, inst.tree.V)
    wAux=zeros(inst.J, inst.T)
    xAux=zeros(inst.J, inst.T)
    solTime=round(solve_time(model), digits=2)
    return SolutionM(sTotAux, iAux, GAux, xAux, wAux, zAux, yAux, pAux, costsAux, false, solTime, run_time, inst.id)
end

function solve_constructive_heuristic(
    inst::InstanceM,
    fairness::String;
    eta::Float64=1.0,
    weight_floor::Float64=1e-8
)
    baseline_sol=solveMulti(inst, "NONE")
    baseline_sol.status || error("La solucion baseline NONE no es factible.")

    t_constructive_start = time()
    if fairness in ("PEA", "PAE", "PPEA", "EPPEA")
        lambdaH, diag=constructive_lambda_pea(
            inst;
            baseline_sol=baseline_sol,
            eta=eta,
            weight_floor=weight_floor
        )
    elseif fairness in ("SA", "PSA", "ESA")
        lambdaH, diag=constructive_lambda_sa(
            inst;
            baseline_sol=baseline_sol,
            eta=eta,
            weight_floor=weight_floor
        )
    else
        error("Heuristica constructiva soportada solo para PEA y SA.")
    end
    constructive_time=time() - t_constructive_start

    solH=solve_fixed_lambda_policy(inst, lambdaH)
    expected_pv=_expected_pv_received(inst, solH)
    expected_sav=_expected_savings(inst, solH)
    sa_gap = fairness in ("SA", "PSA", "ESA") ? _sa_expected_gap(inst, solH) : fill(NaN, inst.J)
    total_run_time=baseline_sol.run_time + constructive_time + solH.run_time
    total_model_solve_time=baseline_sol.time + solH.time
    return (
        fairness=fairness,
        baseline_sol=baseline_sol,
        heuristic_sol=solH,
        lambda=lambdaH,
        total_run_time=total_run_time,
        total_model_solve_time=total_model_solve_time,
        diagnostics=merge(diag, (
            heuristic_expected_pv=expected_pv,
            heuristic_expected_savings=expected_sav,
            heuristic_sa_gap=sa_gap
        ))
    )
end
