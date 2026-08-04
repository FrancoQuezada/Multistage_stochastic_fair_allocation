include("structuresMulti.jl")

function build_lex_pea_model(inst::InstanceM)
    scenarioTree=inst.tree
    model = Model(CPLEX.Optimizer)

    @variable(model, p[1:inst.J,1:scenarioTree.V] >= 0)
    @variable(model, zeta[1:inst.J])
    @variable(model, daux[1:inst.J,1:inst.J] >= 0)

    @constraint(model, [n in 1:scenarioTree.V], sum(p[j,n] for j in 1:inst.J) == inst.c_pv[n])
    @constraint(model, [j in 1:inst.J, s in eachindex(scenarioTree.scenarios)],
        sum(p[j,n] for n in scenarioTree.scenarios[s]) <= sum(inst.d[j,n] for n in scenarioTree.scenarios[s]))

    scenario_prob=[scenarioTree.rho[scenario[1]] for scenario in scenarioTree.scenarios]
    @expression(model, alloc[j in 1:inst.J],
        sum(scenario_prob[s]*sum(p[j,n] for n in scenarioTree.scenarios[s]) for s in eachindex(scenarioTree.scenarios)))

    set_silent(model)
    for n in 1:inst.J, j in 1:inst.J
        @constraint(model, zeta[n] - daux[n,j] <= alloc[j])
    end
    return (model=model, p=p, zeta=zeta, daux=daux)
end

function lexico_mmf_pea_targets(inst::InstanceM)
    ω=zeros(inst.J)
    p_last=zeros(inst.J, inst.tree.V)
    total_solve_time=0.0
    total_run_time=0.0
    persistent=build_lex_pea_model(inst)
    model=persistent.model
    lex_eps_abs=TOL
    for k in 1:inst.J
        @objective(model, Max, k * persistent.zeta[k] - sum(persistent.daux[k,j] for j in 1:inst.J))
        t_start=time()
        optimize!(model)
        step_time = round(solve_time(model), digits=2)
        step_run_time = time() - t_start
        total_solve_time+=step_time
        total_run_time+=step_run_time
        if !has_values(model)
            return zeros(inst.J), zeros(inst.J, length(inst.tree.scenarios)), round(total_solve_time, digits=2), total_run_time
        end
        ω[k]=objective_value(model)
        p_last.=value.(persistent.p)
        @constraint(model, k * persistent.zeta[k] - sum(persistent.daux[k,j] for j in 1:inst.J) >= ω[k] - lex_eps_abs)
    end

    scenarioTree=inst.tree
    scenario_prob=[scenarioTree.rho[scenario[1]] for scenario in scenarioTree.scenarios]
    scenario_target=[sum(p_last[j,n] for n in scenario) for j in 1:inst.J, scenario in scenarioTree.scenarios]
    expected_target=[sum(scenario_prob[s]*scenario_target[j,s] for s in eachindex(scenarioTree.scenarios)) for j in 1:inst.J]
    return expected_target, scenario_target, round(total_solve_time, digits=2), total_run_time
end
