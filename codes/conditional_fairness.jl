const ERDINC_LABEL_TO_METRIC = Dict(
    "ERDINC_PSR" => :PSR,
    "ERDINC_ESR" => :ESR,
    "ERDINC_PESR" => :PESR,
    "ERDINC_PC" => :PC,
    "ERDINC_EC" => :EC,
    "ERDINC_PEC" => :PEC,
)

const CONDITIONAL_FAIRNESS_LABELS = Set([
    "CPEA",
    "CSA",
    "CLEXMMFPEA",
    "CLEXMMFSA",
])

const NEW_FAIRNESS_LABELS = union(Set(keys(ERDINC_LABEL_TO_METRIC)), CONDITIONAL_FAIRNESS_LABELS)

is_new_fairness_label(fairness::String) = fairness in NEW_FAIRNESS_LABELS

"""Validate and return the information-state nodes at entry to `stage`."""
function validate_conditional_stage(tree::Tree, stage::Int)
    1 <= stage <= tree.S || error(
        "conditional_stage=$stage fuera de rango; debe pertenecer a 1:$(tree.S)."
    )
    return nothing
end

function stage_entry_nodes(tree::Tree, stage::Int)::Vector{Int}
    validate_conditional_stage(tree, stage)
    if stage == 1
        return [1]
    end
    return Int[
        n for n in 1:tree.V
        if tree.stages[n] == stage &&
           tree.parents[n] > 0 &&
           tree.stages[tree.parents[n]] == stage - 1
    ]
end

scenario_probabilities(tree::Tree)::Vector{Float64} =
    Float64[tree.rho[scenario[1]] for scenario in tree.scenarios]

function scenarios_through_node(tree::Tree, n::Int)::Vector{Int}
    1 <= n <= tree.V || error("Nodo de condicionamiento inválido: $n.")
    return Int[s for s in eachindex(tree.scenarios) if n in tree.scenarios[s]]
end

function conditional_scenario_probabilities(tree::Tree, n::Int)::Vector{Pair{Int,Float64}}
    rho_n = tree.rho[n]
    rho_n > 0 || error("El nodo $n tiene probabilidad no positiva: $rho_n.")
    probs = scenario_probabilities(tree)
    return Pair{Int,Float64}[s => probs[s] / rho_n for s in scenarios_through_node(tree, n)]
end

function _conditional_context(tree::Tree, stage::Int; probability_tol::Float64=1e-8)
    nodes = stage_entry_nodes(tree, stage)
    isempty(nodes) && error("No hay nodos de entrada para conditional_stage=$stage.")
    probs = scenario_probabilities(tree)
    scenario_lists = [scenarios_through_node(tree, n) for n in nodes]
    conditional = [
        Pair{Int,Float64}[s => probs[s] / tree.rho[n] for s in scenario_lists[b]]
        for (b, n) in enumerate(nodes)
    ]
    for (b, n) in enumerate(nodes)
        total = sum(last(pair) for pair in conditional[b])
        abs(total - 1.0) <= probability_tol || error(
            "Las probabilidades condicionales del nodo $n suman $total, no 1."
        )
    end
    return (stage=stage, nodes=nodes, conditional=conditional)
end

function _scenario_demand_matrix(inst::InstanceM)
    return [
        inst.delta * sum(inst.d[j,n] for n in scenario)
        for j in 1:inst.J, scenario in inst.tree.scenarios
    ]
end

function _scenario_pv_totals(inst::InstanceM)
    return Float64[
        inst.delta * sum(inst.c_pv[n] for n in scenario)
        for scenario in inst.tree.scenarios
    ]
end

function _scenario_all_grid_costs(inst::InstanceM)
    time_periods = createTime(inst.tree)
    return [
        inst.delta * sum(inst.nu[j,time_periods[n]] * inst.d[j,n] for n in scenario)
        for j in 1:inst.J, scenario in inst.tree.scenarios
    ]
end

"""Validate all positive denominators used by scenario-ratio fairness rules."""
function validate_positive_scenario_denominators(inst::InstanceM)
    demand = _scenario_demand_matrix(inst)
    for s in axes(demand, 2), j in axes(demand, 1)
        demand[j,s] > 0 || error(
            "Demanda acumulada no positiva para hogar $j, escenario $s: $(demand[j,s])."
        )
    end
    return nothing
end

function _validate_positive_total_demand(inst::InstanceM)
    demand = _scenario_demand_matrix(inst)
    for (s, total) in enumerate(vec(sum(demand, dims=1)))
        total > 0 || error("Demanda comunitaria no positiva en el escenario $s: $total.")
    end
    return nothing
end

function _validate_positive_all_grid_total(inst::InstanceM)
    all_grid = _scenario_all_grid_costs(inst)
    for (s, total) in enumerate(vec(sum(all_grid, dims=1)))
        total > 0 || error("Benchmark all-grid no positivo en el escenario $s: $total.")
    end
    return nothing
end

function _validate_nonnegative_tolerance(name::String, value::Float64)
    value >= 0 || error("$name debe ser no negativo; se recibió $value.")
    return nothing
end

function _build_conditional_full_model(
    inst::InstanceM;
    require_nonnegative_costs::Bool=false,
    lambdaS=nothing,
    EEV::Bool=false,
)
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
    battery_mode=add_shared_battery_mode_constraints!(
        model, y, z, 1:inst.J, 1:tree.V;
        discharge_limit=inst.f_bar,
        charge_limit=inst.f_under,
    )

    if EEV
        lambdaS === nothing && error("EEV=true requiere lambdaS.")
        lambda_nodes = [lambdaS[j,time_periods[n]] for j in 1:inst.J, n in 1:tree.V]
        fix.(lambda, lambda_nodes; force=true)
    end

    @constraint(model, [j in 1:inst.J, n in 1:tree.V], p[j,n] == lambda[j,n] * inst.c_pv[n])
    @constraint(model, [n in 1:tree.V], sum(lambda[:,n]) == 1)
    @constraint(model, [n in 1:tree.V], s[n] <= inst.s_max)
    @constraint(model, [n in 2:tree.V],
        s[n] == s[tree.parents[n]] + inst.delta * inst.e_c * sum(z[j,n] for j in 1:inst.J) -
                inst.delta * sum(y[j,n] for j in 1:inst.J) / inst.e_d)
    @constraint(model,
        s[1] == inst.s_I + inst.delta * inst.e_c * sum(z[j,1] for j in 1:inst.J) -
                inst.delta * sum(y[j,1] for j in 1:inst.J) / inst.e_d)
    @constraint(model, [j in 1:inst.J, n in 1:tree.V],
        inst.d[j,n] == p[j,n] + y[j,n] + I[j,n] - z[j,n] - G[j,n])
    @constraint(model, [n in 1:tree.V; time_periods[n] == inst.T], s[n] == inst.s_I)
    @constraint(model, [n in 1:tree.V], s[n] >= inst.s_min)

    @expression(model, cost_node[j in 1:inst.J, n in 1:tree.V],
        inst.delta * (inst.mu * y[j,n] + inst.nu[j,time_periods[n]] * I[j,n] - inst.beta * G[j,n]))
    @expression(model, costs[j in 1:inst.J],
        sum(tree.rho[n] * cost_node[j,n] for n in 1:tree.V))
    if require_nonnegative_costs
        @constraint(model, [j in 1:inst.J], costs[j] >= 0)
    end

    return (
        model=model, s=s, I=I, G=G, battery_mode=battery_mode, z=z, y=y, p=p, lambda=lambda,
        costs=costs, cost_node=cost_node, time_periods=time_periods,
    )
end

function _configure_conditional_model!(model::Model)
    set_attribute(model, "CPXPARAM_TimeLimit", 60 * 60)
    set_silent(model)
    return model
end

function _failed_conditional_solution(inst::InstanceM, solve_seconds::Float64, run_seconds::Float64)
    tree = inst.tree
    return SolutionM(
        zeros(tree.V), zeros(inst.J, tree.V), zeros(inst.J, tree.V),
        zeros(tree.V), zeros(inst.J, inst.T),
        zeros(inst.J, tree.V), zeros(inst.J, tree.V), zeros(inst.J, tree.V),
        fill(Inf, inst.J), false, round(solve_seconds, digits=2), run_seconds, inst.id,
    )
end

function _solution_from_conditional_refs(
    inst::InstanceM,
    refs;
    solve_seconds::Float64=solve_time(refs.model),
    run_seconds::Float64=solve_seconds,
)
    if !has_values(refs.model)
        return _failed_conditional_solution(inst, solve_seconds, run_seconds)
    end
    return SolutionM(
        value.(refs.s), value.(refs.I), value.(refs.G),
        collect(value.(refs.battery_mode)), zeros(inst.J, inst.T),
        value.(refs.z), value.(refs.y), value.(refs.p), value.(refs.costs),
        true, round(solve_seconds, digits=2), run_seconds, inst.id,
    )
end

function _conditional_pea_outcomes(model::Model, inst::InstanceM, p, context)
    outcomes = Matrix{JuMP.AffExpr}(undef, inst.J, length(context.nodes))
    for b in eachindex(context.nodes), j in 1:inst.J
        outcomes[j,b] = @expression(model,
            sum(
                q_cond * inst.delta * sum(p[j,m] for m in inst.tree.scenarios[s_idx])
                for (s_idx, q_cond) in context.conditional[b]
            ))
    end
    return outcomes
end

function _scenario_savings_expressions(model::Model, inst::InstanceM, cost_node)
    benchmark = _scenario_all_grid_costs(inst)
    savings = Matrix{JuMP.AffExpr}(undef, inst.J, length(inst.tree.scenarios))
    for s_idx in eachindex(inst.tree.scenarios), j in 1:inst.J
        scenario = inst.tree.scenarios[s_idx]
        savings[j,s_idx] = @expression(model,
            benchmark[j,s_idx] - sum(cost_node[j,m] for m in scenario))
    end
    return benchmark, savings
end

function _conditional_sa_outcomes(model::Model, inst::InstanceM, cost_node, context)
    benchmark, savings = _scenario_savings_expressions(model, inst, cost_node)
    outcomes = Matrix{JuMP.AffExpr}(undef, inst.J, length(context.nodes))
    for b in eachindex(context.nodes), j in 1:inst.J
        outcomes[j,b] = @expression(model,
            sum(q_cond * savings[j,s_idx] for (s_idx, q_cond) in context.conditional[b]))
    end
    return (outcomes=outcomes, benchmark=benchmark, savings=savings)
end

function add_erdinc_fairness!(
    model::Model,
    inst::InstanceM,
    refs,
    metric;
    fairness_mmr::Float64=1.2,
)
    fairness_mmr >= 1.0 || error("fairness_mmr debe ser al menos 1; se recibió $fairness_mmr.")
    metric_symbol = metric isa Symbol ? metric : Symbol(metric)
    metric_symbol in (:PSR, :ESR, :PESR, :PC, :EC, :PEC) ||
        error("Métrica Erdinç no soportada: $metric.")
    if metric_symbol in (:PSR, :ESR, :PESR)
        validate_positive_scenario_denominators(inst)
    end

    probs = scenario_probabilities(inst.tree)
    demand = _scenario_demand_matrix(inst)
    metric_expr = Vector{JuMP.AffExpr}(undef, inst.J)
    for j in 1:inst.J
        expr = JuMP.AffExpr(0.0)
        for s_idx in eachindex(inst.tree.scenarios)
            scenario = inst.tree.scenarios[s_idx]
            scale = probs[s_idx]
            if metric_symbol in (:PSR, :ESR, :PESR)
                scale /= demand[j,s_idx]
            end
            if metric_symbol in (:PSR, :PC, :PESR, :PEC)
                for n in scenario
                    JuMP.add_to_expression!(expr, scale * inst.delta, refs.p[j,n])
                end
            end
            if metric_symbol in (:ESR, :EC, :PESR, :PEC)
                for n in scenario
                    JuMP.add_to_expression!(expr, scale * inst.delta, refs.y[j,n])
                end
            end
        end
        metric_expr[j] = expr
    end

    @variable(model, erdinc_n_min >= 0)
    @variable(model, erdinc_n_max >= 0)
    @constraint(model, [j in 1:inst.J], erdinc_n_min <= metric_expr[j])
    @constraint(model, [j in 1:inst.J], metric_expr[j] <= erdinc_n_max)
    @constraint(model, erdinc_n_max <= fairness_mmr * erdinc_n_min)

    return (
        kind=:ERDINC, metric=metric_symbol, fairness_mmr=fairness_mmr,
        metric_expr=metric_expr, n_min=erdinc_n_min, n_max=erdinc_n_max,
    )
end

function add_conditional_proportional_pea!(
    model::Model,
    inst::InstanceM,
    refs;
    conditional_stage::Int,
    fairness_abs_tol::Float64=0.0,
)
    _validate_nonnegative_tolerance("fairness_abs_tol", fairness_abs_tol)
    _validate_positive_total_demand(inst)
    context = _conditional_context(inst.tree, conditional_stage)
    actual = _conditional_pea_outcomes(model, inst, refs.p, context)
    demand = _scenario_demand_matrix(inst)
    total_demand = vec(sum(demand, dims=1))
    pv_total = _scenario_pv_totals(inst)
    target = zeros(inst.J, length(context.nodes))

    for b in eachindex(context.nodes), j in 1:inst.J
        target[j,b] = sum(
            q_cond * (pv_total[s_idx] / total_demand[s_idx]) * demand[j,s_idx]
            for (s_idx, q_cond) in context.conditional[b]
        )
        if fairness_abs_tol > 0
            @constraint(model, actual[j,b] - target[j,b] <= fairness_abs_tol)
            @constraint(model, target[j,b] - actual[j,b] <= fairness_abs_tol)
        else
            @constraint(model, actual[j,b] == target[j,b])
        end
    end
    return (kind=:CPEA, context=context, actual=actual, target=target)
end

function add_conditional_proportional_sa!(
    model::Model,
    inst::InstanceM,
    refs;
    conditional_stage::Int,
    fairness_abs_tol::Float64=0.0,
)
    _validate_nonnegative_tolerance("fairness_abs_tol", fairness_abs_tol)
    _validate_positive_all_grid_total(inst)
    context = _conditional_context(inst.tree, conditional_stage)
    sa = _conditional_sa_outcomes(model, inst, refs.cost_node, context)
    benchmark_total = vec(sum(sa.benchmark, dims=1))
    target = Matrix{JuMP.AffExpr}(undef, inst.J, length(context.nodes))

    for b in eachindex(context.nodes), j in 1:inst.J
        target[j,b] = @expression(model,
            sum(
                q_cond * (sa.benchmark[j,s_idx] / benchmark_total[s_idx]) *
                sum(sa.savings[k,s_idx] for k in 1:inst.J)
                for (s_idx, q_cond) in context.conditional[b]
            ))
        if fairness_abs_tol > 0
            @constraint(model, sa.outcomes[j,b] - target[j,b] <= fairness_abs_tol)
            @constraint(model, target[j,b] - sa.outcomes[j,b] <= fairness_abs_tol)
        else
            @constraint(model, sa.outcomes[j,b] == target[j,b])
        end
    end
    return (kind=:CSA, context=context, actual=sa.outcomes, target=target)
end

function _add_conditional_order_statistics!(model::Model, inst::InstanceM, outcomes, context)
    nb = length(context.nodes)
    @variable(model, conditional_zeta[1:inst.J,1:nb])
    @variable(model, conditional_daux[1:inst.J,1:inst.J,1:nb] >= 0)
    @constraint(model, [k in 1:inst.J, j in 1:inst.J, b in 1:nb],
        conditional_zeta[k,b] - conditional_daux[k,j,b] <= outcomes[j,b])
    @expression(model, phi[k in 1:inst.J],
        sum(
            inst.tree.rho[context.nodes[b]] *
            (k * conditional_zeta[k,b] - sum(conditional_daux[k,j,b] for j in 1:inst.J))
            for b in 1:nb
        ))
    return (zeta=conditional_zeta, daux=conditional_daux, phi=phi)
end

function _achieved_conditional_levels(inst::InstanceM, context, outcome_values::Matrix{Float64})
    levels = zeros(inst.J)
    for b in eachindex(context.nodes)
        ordered = sort(outcome_values[:,b])
        prefix = cumsum(ordered)
        levels .+= inst.tree.rho[context.nodes[b]] .* prefix
    end
    return levels
end

function solve_erdinc_fairness(
    inst::InstanceM,
    metric;
    fairness_mmr::Float64=1.2,
    lambdaS=nothing,
    EEV::Bool=false,
)
    run_start = time()
    refs = _build_conditional_full_model(inst; lambdaS=lambdaS, EEV=EEV)
    fairness_refs = add_erdinc_fairness!(refs.model, inst, refs, metric; fairness_mmr=fairness_mmr)
    @objective(refs.model, Min, sum(refs.costs[j] for j in 1:inst.J))
    _configure_conditional_model!(refs.model)
    optimize!(refs.model)
    run_seconds = time() - run_start
    solution = _solution_from_conditional_refs(inst, refs; run_seconds=run_seconds)

    if solution.status
        values = value.(fairness_refs.metric_expr)
        achieved_min = minimum(values)
        achieved_max = maximum(values)
        denominator = max(achieved_min, eps(Float64))
        achieved_mmr = achieved_max / denominator
        violation = max(0.0, achieved_max - fairness_mmr * achieved_min)
    else
        values = fill(Inf, inst.J)
        achieved_min = Inf
        achieved_max = Inf
        achieved_mmr = Inf
        violation = Inf
    end
    diagnostics = (
        kind=:ERDINC, metric=fairness_refs.metric, fairness_mmr=fairness_mmr,
        metric_values=values, achieved_min=achieved_min, achieved_max=achieved_max,
        achieved_mmr=achieved_mmr, mmr_abs_violation=violation,
        termination_status=termination_status(refs.model),
    )
    return solution, diagnostics
end

function solve_conditional_proportional_pea(
    inst::InstanceM;
    conditional_stage::Int,
    fairness_abs_tol::Float64=0.0,
    lambdaS=nothing,
    EEV::Bool=false,
)
    run_start = time()
    refs = _build_conditional_full_model(inst; lambdaS=lambdaS, EEV=EEV)
    fairness_refs = add_conditional_proportional_pea!(
        refs.model, inst, refs;
        conditional_stage=conditional_stage, fairness_abs_tol=fairness_abs_tol,
    )
    @objective(refs.model, Min, sum(refs.costs[j] for j in 1:inst.J))
    _configure_conditional_model!(refs.model)
    optimize!(refs.model)
    solution = _solution_from_conditional_refs(inst, refs; run_seconds=time() - run_start)
    actual = solution.status ? value.(fairness_refs.actual) : fill(Inf, size(fairness_refs.actual))
    target = fairness_refs.target
    gap = actual .- target
    diagnostics = (
        kind=:CPEA, conditional_stage=conditional_stage,
        nodes=fairness_refs.context.nodes,
        node_probabilities=inst.tree.rho[fairness_refs.context.nodes],
        actual=actual, target=target, gap=gap,
        max_abs_gap=solution.status ? maximum(abs.(gap)) : Inf,
        termination_status=termination_status(refs.model),
    )
    return solution, diagnostics
end

function solve_conditional_proportional_sa(
    inst::InstanceM;
    conditional_stage::Int,
    fairness_abs_tol::Float64=0.0,
    lambdaS=nothing,
    EEV::Bool=false,
)
    run_start = time()
    refs = _build_conditional_full_model(inst; lambdaS=lambdaS, EEV=EEV)
    fairness_refs = add_conditional_proportional_sa!(
        refs.model, inst, refs;
        conditional_stage=conditional_stage, fairness_abs_tol=fairness_abs_tol,
    )
    @objective(refs.model, Min, sum(refs.costs[j] for j in 1:inst.J))
    _configure_conditional_model!(refs.model)
    optimize!(refs.model)
    solution = _solution_from_conditional_refs(inst, refs; run_seconds=time() - run_start)
    actual = solution.status ? value.(fairness_refs.actual) : fill(Inf, size(fairness_refs.actual))
    target = solution.status ? value.(fairness_refs.target) : fill(Inf, size(fairness_refs.target))
    gap = actual .- target
    diagnostics = (
        kind=:CSA, conditional_stage=conditional_stage,
        nodes=fairness_refs.context.nodes,
        node_probabilities=inst.tree.rho[fairness_refs.context.nodes],
        actual=actual, target=target, gap=gap,
        max_abs_gap=solution.status ? maximum(abs.(gap)) : Inf,
        termination_status=termination_status(refs.model),
    )
    return solution, diagnostics
end

function conditional_lex_pea_levels(
    inst::InstanceM;
    conditional_stage::Int,
    lex_eps_abs::Float64,
)
    _validate_nonnegative_tolerance("lex_eps_abs", lex_eps_abs)
    context = _conditional_context(inst.tree, conditional_stage)
    run_start = time()
    model = Model(CPLEX.Optimizer)
    @variable(model, p[1:inst.J,1:inst.tree.V] >= 0)
    @constraint(model, [n in 1:inst.tree.V], sum(p[j,n] for j in 1:inst.J) == inst.c_pv[n])
    demand = _scenario_demand_matrix(inst)
    @constraint(model, [j in 1:inst.J, s_idx in eachindex(inst.tree.scenarios)],
        inst.delta * sum(p[j,n] for n in inst.tree.scenarios[s_idx]) <= demand[j,s_idx])
    outcomes = _conditional_pea_outcomes(model, inst, p, context)
    order_refs = _add_conditional_order_statistics!(model, inst, outcomes, context)
    _configure_conditional_model!(model)

    omega = zeros(inst.J)
    outcome_values = zeros(inst.J, length(context.nodes))
    total_solve_time = 0.0
    statuses = Any[]
    for k in 1:inst.J
        @objective(model, Max, order_refs.phi[k])
        optimize!(model)
        push!(statuses, termination_status(model))
        total_solve_time += solve_time(model)
        has_values(model) || error(
            "CLEXMMFPEA falló en el nivel $k: $(termination_status(model))."
        )
        omega[k] = objective_value(model)
        outcome_values .= value.(outcomes)
        @constraint(model, order_refs.phi[k] >= omega[k] - lex_eps_abs)
    end
    return (
        omega=omega, target_outcomes=outcome_values, context=context,
        solve_time=total_solve_time, run_time=time() - run_start,
        termination_statuses=statuses,
    )
end

function solve_conditional_lex_pea(
    inst::InstanceM;
    conditional_stage::Int,
    lex_eps_abs::Float64,
)
    _validate_nonnegative_tolerance("lex_eps_abs", lex_eps_abs)
    total_start = time()
    levels = conditional_lex_pea_levels(
        inst; conditional_stage=conditional_stage, lex_eps_abs=lex_eps_abs,
    )
    refs = _build_conditional_full_model(inst)
    demand = _scenario_demand_matrix(inst)
    @constraint(refs.model, [j in 1:inst.J, s_idx in eachindex(inst.tree.scenarios)],
        inst.delta * sum(refs.p[j,n] for n in inst.tree.scenarios[s_idx]) <= demand[j,s_idx])
    outcomes = _conditional_pea_outcomes(refs.model, inst, refs.p, levels.context)
    order_refs = _add_conditional_order_statistics!(refs.model, inst, outcomes, levels.context)
    @constraint(refs.model, [k in 1:inst.J], order_refs.phi[k] >= levels.omega[k] - lex_eps_abs)
    @objective(refs.model, Min, sum(refs.costs[j] for j in 1:inst.J))
    _configure_conditional_model!(refs.model)
    optimize!(refs.model)
    total_solve_time = levels.solve_time + solve_time(refs.model)
    solution = _solution_from_conditional_refs(
        inst, refs; solve_seconds=total_solve_time, run_seconds=time() - total_start,
    )
    outcome_values = solution.status ? value.(outcomes) : fill(Inf, size(outcomes))
    achieved = solution.status ?
        _achieved_conditional_levels(inst, levels.context, outcome_values) : fill(-Inf, inst.J)
    violation = solution.status ? maximum(max.(levels.omega .- achieved, 0.0)) : Inf
    diagnostics = (
        kind=:CLEXMMFPEA, conditional_stage=conditional_stage,
        nodes=levels.context.nodes,
        node_probabilities=inst.tree.rho[levels.context.nodes],
        outcomes=outcome_values, omega=levels.omega, achieved_levels=achieved,
        max_lex_violation=violation, lex_eps_abs=lex_eps_abs,
        level_termination_statuses=levels.termination_statuses,
        final_termination_status=termination_status(refs.model),
    )
    return solution, diagnostics
end

function solve_conditional_lex_sa(
    inst::InstanceM;
    conditional_stage::Int,
    lex_eps_abs::Float64,
)
    _validate_nonnegative_tolerance("lex_eps_abs", lex_eps_abs)
    context = _conditional_context(inst.tree, conditional_stage)
    total_start = time()
    refs = _build_conditional_full_model(inst; require_nonnegative_costs=true)
    sa = _conditional_sa_outcomes(refs.model, inst, refs.cost_node, context)
    order_refs = _add_conditional_order_statistics!(refs.model, inst, sa.outcomes, context)
    _configure_conditional_model!(refs.model)

    omega = zeros(inst.J)
    statuses = Any[]
    total_solve_time = 0.0
    for k in 1:inst.J
        @objective(refs.model, Max, order_refs.phi[k])
        optimize!(refs.model)
        push!(statuses, termination_status(refs.model))
        total_solve_time += solve_time(refs.model)
        has_values(refs.model) || error(
            "CLEXMMFSA falló en el nivel $k: $(termination_status(refs.model))."
        )
        omega[k] = objective_value(refs.model)
        @constraint(refs.model, order_refs.phi[k] >= omega[k] - lex_eps_abs)
    end

    @objective(refs.model, Min, sum(refs.costs[j] for j in 1:inst.J))
    optimize!(refs.model)
    total_solve_time += solve_time(refs.model)
    solution = _solution_from_conditional_refs(
        inst, refs; solve_seconds=total_solve_time, run_seconds=time() - total_start,
    )
    outcome_values = solution.status ? value.(sa.outcomes) : fill(Inf, size(sa.outcomes))
    achieved = solution.status ?
        _achieved_conditional_levels(inst, context, outcome_values) : fill(-Inf, inst.J)
    violation = solution.status ? maximum(max.(omega .- achieved, 0.0)) : Inf
    diagnostics = (
        kind=:CLEXMMFSA, conditional_stage=conditional_stage,
        nodes=context.nodes, node_probabilities=inst.tree.rho[context.nodes],
        outcomes=outcome_values, omega=omega, achieved_levels=achieved,
        max_lex_violation=violation, lex_eps_abs=lex_eps_abs,
        level_termination_statuses=statuses,
        final_termination_status=termination_status(refs.model),
    )
    return solution, diagnostics
end

function solve_new_fairness(
    inst::InstanceM,
    fairness::String,
    lambdaS=zeros(10,10),
    EEV::Bool=false;
    fairness_abs_tol::Float64=0.0,
    fairness_mmr::Float64=1.2,
    conditional_stage::Union{Nothing,Int}=nothing,
    lex_eps_abs::Float64=TOL,
)
    if haskey(ERDINC_LABEL_TO_METRIC, fairness)
        return solve_erdinc_fairness(
            inst, ERDINC_LABEL_TO_METRIC[fairness];
            fairness_mmr=fairness_mmr, lambdaS=lambdaS, EEV=EEV,
        )
    end
    conditional_stage === nothing && error(
        "La política $fairness requiere el parámetro conditional_stage."
    )
    stage = conditional_stage::Int
    if fairness == "CPEA"
        return solve_conditional_proportional_pea(
            inst; conditional_stage=stage, fairness_abs_tol=fairness_abs_tol,
            lambdaS=lambdaS, EEV=EEV,
        )
    elseif fairness == "CSA"
        return solve_conditional_proportional_sa(
            inst; conditional_stage=stage, fairness_abs_tol=fairness_abs_tol,
            lambdaS=lambdaS, EEV=EEV,
        )
    elseif fairness == "CLEXMMFPEA"
        EEV && error("CLEXMMFPEA no admite EEV=true.")
        return solve_conditional_lex_pea(
            inst; conditional_stage=stage, lex_eps_abs=lex_eps_abs,
        )
    elseif fairness == "CLEXMMFSA"
        EEV && error("CLEXMMFSA no admite EEV=true.")
        return solve_conditional_lex_sa(
            inst; conditional_stage=stage, lex_eps_abs=lex_eps_abs,
        )
    end
    error("Fairness nueva no soportada: $fairness.")
end
