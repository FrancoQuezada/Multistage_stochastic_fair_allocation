const STATIC_DEMAND_SHARE_VALIDATION_TOL = 1e-8

function static_expected_demands(inst::InstanceM)
    time_periods = createTime(inst.tree)
    expected = zeros(inst.J, inst.T)
    for t in 1:inst.T
        nodes = Int[n for n in 1:inst.tree.V if time_periods[n] == t]
        isempty(nodes) && error("No hay nodos asociados al período $t.")
        probability_mass = sum(inst.tree.rho[n] for n in nodes)
        probability_mass > 0 || error(
            "La masa de probabilidad del período $t no es positiva: $probability_mass."
        )
        for j in 1:inst.J
            expected[j,t] =
                sum(inst.tree.rho[n] * inst.d[j,n] for n in nodes) / probability_mass
        end
    end
    return expected
end

function static_demand_shares(inst::InstanceM)
    expected = static_expected_demands(inst)
    shares = zeros(inst.J, inst.T)
    for t in 1:inst.T
        total_expected_demand = sum(expected[:,t])
        if total_expected_demand > 0
            shares[:,t] .= expected[:,t] ./ total_expected_demand
        elseif total_expected_demand == 0
            shares[:,t] .= 1.0 / inst.J
        else
            error(
                "La demanda esperada comunitaria del período $t es negativa: " *
                "$total_expected_demand."
            )
        end
        residual = abs(sum(shares[:,t]) - 1.0)
        residual <= STATIC_DEMAND_SHARE_VALIDATION_TOL || error(
            "Las participaciones estáticas del período $t suman $(sum(shares[:,t]))."
        )
    end
    return shares
end


function _build_static_demand_share_model(inst::InstanceM, shares::Matrix{Float64})
    tree = inst.tree
    model = Model(CPLEX.Optimizer)
    time_periods = createTime(tree)

    @variable(model, s[1:tree.V] >= 0)
    @variable(model, I[1:inst.J,1:tree.V] >= 0)
    @variable(model, G[1:inst.J,1:tree.V] >= 0)
    @variable(model, z[1:inst.J,1:tree.V] >= 0)
    @variable(model, y[1:inst.J,1:tree.V] >= 0)
    @variable(model, p[1:inst.J,1:tree.V] >= 0)
    @variable(model, lambda[1:inst.J,1:tree.V] >= 0)

    @constraint(model, [j in 1:inst.J, n in 1:tree.V],
        lambda[j,n] == shares[j,time_periods[n]])
    @constraint(model, [j in 1:inst.J, n in 1:tree.V],
        p[j,n] == lambda[j,n] * inst.c_pv[n])
    @constraint(model, [n in 1:tree.V], sum(lambda[:,n]) == 1)
    @constraint(model, [n in 1:tree.V], s[n] <= inst.s_max)
    @constraint(model, [n in 2:tree.V],
        s[n] == s[tree.parents[n]] +
                inst.delta * inst.e_c * sum(z[j,n] for j in 1:inst.J) -
                inst.delta * sum(y[j,n] for j in 1:inst.J) / inst.e_d)
    @constraint(model,
        s[1] == inst.s_I +
                inst.delta * inst.e_c * sum(z[j,1] for j in 1:inst.J) -
                inst.delta * sum(y[j,1] for j in 1:inst.J) / inst.e_d)
    @constraint(model, [n in 1:tree.V], sum(y[j,n] for j in 1:inst.J) <= inst.f_bar)
    @constraint(model, [n in 1:tree.V], sum(z[j,n] for j in 1:inst.J) <= inst.f_under)
    @constraint(model, [j in 1:inst.J, n in 1:tree.V],
        inst.d[j,n] == p[j,n] + y[j,n] + I[j,n] - z[j,n] - G[j,n])
    @constraint(model, [n in 1:tree.V; time_periods[n] == inst.T], s[n] == inst.s_I)
    @constraint(model, [n in 1:tree.V], s[n] >= inst.s_min)

    @expression(model, costs[j in 1:inst.J],
        inst.delta * sum(
            tree.rho[n] *
            (inst.mu * y[j,n] + inst.nu[j,time_periods[n]] * I[j,n] - inst.beta * G[j,n])
            for n in 1:tree.V
        ))
    @objective(model, Min, sum(costs[j] for j in 1:inst.J))

    set_attribute(model, "CPXPARAM_TimeLimit", 60 * 60)
    set_silent(model)
    return (
        model=model, s=s, I=I, G=G, z=z, y=y, p=p, lambda=lambda,
        costs=costs, time_periods=time_periods,
    )
end


function solve_static_demand_share(inst::InstanceM)
    run_start = time()
    shares = static_demand_shares(inst)
    refs = _build_static_demand_share_model(inst, shares)
    optimize!(refs.model)
    run_time = time() - run_start
    solver_time = solve_time(refs.model)
    println(termination_status(refs.model))

    if has_values(refs.model)
        println("Objective : ", round(objective_value(refs.model), digits=3))
        return SolutionM(
            value.(refs.s), value.(refs.I), value.(refs.G),
            zeros(inst.J, inst.T), zeros(inst.J, inst.T),
            value.(refs.z), value.(refs.y), value.(refs.p), value.(refs.costs),
            true, round(solver_time, digits=2), run_time, inst.id,
        )
    end

    return SolutionM(
        zeros(inst.tree.V), zeros(inst.J, inst.tree.V), zeros(inst.J, inst.tree.V),
        zeros(inst.J, inst.T), zeros(inst.J, inst.T),
        zeros(inst.J, inst.tree.V), zeros(inst.J, inst.tree.V),
        zeros(inst.J, inst.tree.V), fill(Inf, inst.J),
        false, round(solver_time, digits=2), run_time, inst.id,
    )
end


function static_demand_share_diagnostics(inst::InstanceM, sol::SolutionM)
    expected = static_expected_demands(inst)
    shares = static_demand_shares(inst)
    time_periods = createTime(inst.tree)

    max_share_sum_residual = maximum(
        abs(sum(shares[:,t]) - 1.0) for t in 1:inst.T
    )
    max_across_node_share_residual = 0.0
    max_pv_allocation_residual = 0.0

    for t in 1:inst.T
        nodes = Int[n for n in 1:inst.tree.V if time_periods[n] == t]
        for j in 1:inst.J
            node_shares = Float64[
                inst.c_pv[n] > 0 ? sol.p[j,n] / inst.c_pv[n] : shares[j,t]
                for n in nodes
            ]
            max_across_node_share_residual = max(
                max_across_node_share_residual,
                maximum(node_shares) - minimum(node_shares),
            )
            for n in nodes
                pv_residual = if inst.c_pv[n] > 0
                    abs(sol.p[j,n] / inst.c_pv[n] - shares[j,t])
                else
                    abs(sol.p[j,n])
                end
                max_pv_allocation_residual = max(max_pv_allocation_residual, pv_residual)
            end
        end
    end

    return (
        ExpectedDemandByHousePeriod=expected,
        StaticShareByHousePeriod=shares,
        MaxShareSumResidual=max_share_sum_residual,
        MaxAcrossNodeShareResidual=max_across_node_share_residual,
        MaxPVAllocationResidual=max_pv_allocation_residual,
        ExpectedCost=sum(sol.costs),
        RunTimeSec=sol.run_time,
        ModelSolveTimeSec=sol.time,
    )
end
