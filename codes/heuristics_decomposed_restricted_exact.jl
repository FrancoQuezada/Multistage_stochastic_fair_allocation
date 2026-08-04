if !isdefined(@__MODULE__, :solveMulti)
    include("multi.jl")
end
if !isdefined(@__MODULE__, :_pea_expected_target)
    include("heuristics_sa_restricted_exact.jl")
end
if !isdefined(@__MODULE__, :lexico_mmf_pea_targets_persistent)
    include("heuristics_lex_restricted_exact.jl")
end

function _project_simplex_total(v::Vector{Float64}, total::Float64)
    n=length(v)
    total <= 0 && return zeros(n)
    u=sort(v; rev=true)
    cssv=cumsum(u)
    rho=0
    theta=0.0
    for i in 1:n
        theta_i=(cssv[i]-total)/i
        if u[i] - theta_i > 0
            rho=i
            theta=theta_i
        end
    end
    if rho == 0
        return fill(total / n, n)
    end
    return max.(v .- theta, 0.0)
end

function _expected_pv_received(inst::InstanceM, p::Matrix{Float64})
    return [sum(inst.tree.rho[n] * p[j, n] for n in 1:inst.tree.V) for j in 1:inst.J]
end

function _marginal_pv_value_matrix(
    inst::InstanceM,
    p::Matrix{Float64},
    yfix::Matrix{Float64},
    zfix::Matrix{Float64}
)
    scenarioTree=inst.tree
    timePeriods=createTime(scenarioTree)
    values=zeros(inst.J, scenarioTree.V)
    for j in 1:inst.J, n in 1:scenarioTree.V
        net=inst.d[j, n] - p[j, n] - yfix[j, n] + zfix[j, n]
        if net > TOL
            values[j, n]=inst.delta * scenarioTree.rho[n] * inst.nu[j, timePeriods[n]]
        else
            values[j, n]=inst.delta * scenarioTree.rho[n] * inst.beta
        end
    end
    return values
end

function _repair_expected_pv_targets!(
    inst::InstanceM,
    p::Matrix{Float64},
    target::Vector{Float64};
    yfix::Union{Nothing,Matrix{Float64}}=nothing,
    zfix::Union{Nothing,Matrix{Float64}}=nothing,
    tol::Float64=1e-9
)
    scenarioTree=inst.tree
    q=[scenarioTree.rho[n] * p[j, n] for j in 1:inst.J, n in 1:scenarioTree.V]
    residual=target .- vec(sum(q, dims=2))
    values = (yfix === nothing || zfix === nothing) ? ones(inst.J, scenarioTree.V) : _marginal_pv_value_matrix(inst, p, yfix, zfix)
    max_moves=max(1000, 10 * inst.J * scenarioTree.V)
    moves=0

    while maximum(abs.(residual)) > 1e-6 && moves < max_moves
        receivers=sortperm(residual; rev=true)
        donors=sortperm(residual)
        progressed=false

        for j in receivers
            residual[j] <= tol && continue
            for i in donors
                residual[i] >= -tol && continue
                i == j && continue

                best_n=0
                best_score=-Inf
                for n in 1:scenarioTree.V
                    if q[i, n] > tol
                        score=values[j, n] - values[i, n]
                        if score > best_score
                            best_score=score
                            best_n=n
                        end
                    end
                end

                best_n == 0 && continue
                give=min(residual[j], -residual[i], q[i, best_n])
                if give > tol
                    q[i, best_n] -= give
                    q[j, best_n] += give
                    residual[i] += give
                    residual[j] -= give
                    progressed=true
                    moves += 1
                end
                residual[j] <= tol && break
            end
        end

        progressed || break
    end

    max_residual=maximum(abs.(residual))
    max_residual <= 1e-6 || error("No se pudo cerrar exactamente el repair de PEA. Residual max = $max_residual")

    for n in 1:scenarioTree.V
        if scenarioTree.rho[n] > 0
            p[:, n] .= q[:, n] ./ scenarioTree.rho[n]
        else
            p[:, n] .= 0.0
        end
    end

    final_gap=target .- _expected_pv_received(inst, p)
    maximum(abs.(final_gap)) <= 1e-6 || error("Repair de PEA no cerro el gap final. Residual max = $(maximum(abs.(final_gap)))")
    return p
end

function _assemble_house_recourse(
    inst::InstanceM,
    p::Matrix{Float64},
    yfix::Matrix{Float64},
    zfix::Matrix{Float64},
    sfix::Vector{Float64}
)
    scenarioTree=inst.tree
    timePeriods=createTime(scenarioTree)
    I=zeros(inst.J, scenarioTree.V)
    G=zeros(inst.J, scenarioTree.V)
    costs=zeros(inst.J)

    for j in 1:inst.J, n in 1:scenarioTree.V
        net=inst.d[j, n] - p[j, n] - yfix[j, n] + zfix[j, n]
        if net >= 0
            I[j, n]=net
            G[j, n]=0.0
        else
            I[j, n]=0.0
            G[j, n]=-net
        end
        costs[j] += inst.delta * scenarioTree.rho[n] * (inst.mu * yfix[j, n] + inst.nu[j, timePeriods[n]] * I[j, n] - inst.beta * G[j, n])
    end

    return SolutionM(
        copy(sfix),
        I,
        G,
        zeros(inst.J, inst.T),
        zeros(inst.J, inst.T),
        copy(zfix),
        copy(yfix),
        copy(p),
        costs,
        true,
        0.0,
        0.0,
        inst.id
    )
end

function _expected_savings(inst::InstanceM, sol::SolutionM)
    return all_grid_expected_costs(inst) .- sol.costs
end

function _rank_signal(values::Vector{Float64})
    order=sortperm(values)
    signal=zeros(length(values))
    for (rank, j) in enumerate(order)
        signal[j]=length(values) - rank
    end
    signal .-= mean(signal)
    return signal
end

function _local_allocation_weights(inst::InstanceM, baseline_p::Matrix{Float64}, baseline_values::Matrix{Float64})
    weights=zeros(inst.J, inst.tree.V)
    for n in 1:inst.tree.V
        value_scale=max(maximum(view(baseline_values, :, n)), TOL)
        for j in 1:inst.J
            weights[j, n]=max(baseline_p[j, n], 0.0) + max(inst.d[j, n], TOL) * (1.0 + baseline_values[j, n] / value_scale)
        end
    end
    return weights
end

function _update_master_allocation!(
    p::Matrix{Float64},
    inst::InstanceM,
    signal::Vector{Float64},
    local_weights::Matrix{Float64},
    value_weights::Matrix{Float64};
    step_size::Float64=0.20,
    inertia::Float64=0.80
)
    centered=signal .- mean(signal)
    for n in 1:inst.tree.V
        node_total=inst.c_pv[n]
        if node_total <= 0
            p[:, n] .= 0.0
            continue
        end
        demand_col=view(local_weights, :, n)
        value_col=view(value_weights, :, n)
        demand_scale=max(maximum(demand_col), TOL)
        value_scale=max(maximum(value_col), TOL)
        raw=zeros(inst.J)
        for j in 1:inst.J
            base=max(p[j, n], TOL)
            priority=0.5 * (demand_col[j] / demand_scale) + 0.5 * (value_col[j] / value_scale)
            tilt=step_size * centered[j] * priority
            raw[j]=base * exp(tilt)
        end
        projected=_project_simplex_total(raw, node_total)
        p[:, n] .= inertia .* p[:, n] .+ (1.0 - inertia) .* projected
        p[:, n] .= _project_simplex_total(vec(p[:, n]), node_total)
    end
    return p
end

function _pea_signal(inst::InstanceM, p::Matrix{Float64}, target::Vector{Float64})
    return target .- _expected_pv_received(inst, p)
end

function _sa_signal(inst::InstanceM, sol::SolutionM)
    return .-_sa_expected_gap(inst, sol)
end

function _lex_sa_signal(inst::InstanceM, sol::SolutionM)
    return _rank_signal(_expected_savings(inst, sol))
end

function _decomposed_iterations!(
    inst::InstanceM,
    fairness::String,
    p::Matrix{Float64},
    yfix::Matrix{Float64},
    zfix::Matrix{Float64},
    sfix::Vector{Float64},
    baseline_p::Matrix{Float64};
    max_iter::Int=50,
    step_size::Float64=0.25,
    inertia::Float64=0.80,
    gap_tol::Float64=1e-4
)
    baseline_values=_marginal_pv_value_matrix(inst, baseline_p, yfix, zfix)
    local_weights=_local_allocation_weights(inst, baseline_p, baseline_values)
    best_sol=_assemble_house_recourse(inst, p, yfix, zfix, sfix)
    best_gap=Inf
    best_cost=sum(best_sol.costs)
    target=nothing
    extra_solve_time=0.0
    extra_run_time=0.0
    history=Float64[]
    current_step=step_size
    previous_gap=Inf

    if fairness == "PEA"
        target=_pea_expected_target(inst)
    elseif fairness == "LEXMMFPEA"
        target, _, extra_solve_time, extra_run_time = lexico_mmf_pea_targets_persistent(inst)
    end

    for _ in 1:max_iter
        sol=_assemble_house_recourse(inst, p, yfix, zfix, sfix)
        value_weights=_marginal_pv_value_matrix(inst, p, yfix, zfix)
        signal=zeros(inst.J)
        gap_value=Inf

        if fairness == "PEA" || fairness == "LEXMMFPEA"
            signal=_pea_signal(inst, p, target)
            gap_value=maximum(abs.(signal))
        elseif fairness == "SA"
            signal=_sa_signal(inst, sol)
            gap_value=maximum(abs.(signal))
        elseif fairness == "LEXMMFSA"
            signal=_lex_sa_signal(inst, sol)
            gap_value=maximum(_expected_savings(inst, sol)) - minimum(_expected_savings(inst, sol))
        else
            error("Fairness no soportada en la heuristica descompuesta: $fairness")
        end

        push!(history, gap_value)
        total_cost=sum(sol.costs)
        if gap_value < best_gap - 1e-9 || (abs(gap_value - best_gap) <= 1e-9 && total_cost < best_cost)
            best_gap=gap_value
            best_cost=total_cost
            best_sol=sol
        end
        gap_value <= gap_tol && break

        if isfinite(previous_gap)
            if gap_value > previous_gap * (1.0 + 1e-3)
                current_step=max(0.05, 0.70 * current_step)
            elseif gap_value < previous_gap * (1.0 - 1e-2)
                current_step=min(step_size, 1.05 * current_step)
            end
        end
        previous_gap=gap_value

        _update_master_allocation!(p, inst, signal, local_weights, value_weights; step_size=current_step, inertia=inertia)
    end

    return best_sol, target, round(extra_solve_time, digits=2), extra_run_time, history
end

function solve_decomposed_pea_restricted(
    inst::InstanceM;
    baseline_sol::Union{Nothing,SolutionM}=nothing,
    max_iter::Int=50,
    step_size::Float64=0.25,
    inertia::Float64=0.80,
    gap_tol::Float64=1e-4
)
    baseline_sol === nothing && (baseline_sol = solveMulti(inst, "NONE"))
    baseline_sol.status || error("La solucion baseline NONE no es factible.")

    t_start=time()
    sol, target, extra_solve_time, extra_run_time, history = _decomposed_iterations!(
        inst, "PEA", copy(baseline_sol.p), baseline_sol.y, baseline_sol.z, baseline_sol.s, baseline_sol.p;
        max_iter=max_iter, step_size=step_size, inertia=inertia, gap_tol=gap_tol
    )
    repaired_p=copy(sol.p)
    _repair_expected_pv_targets!(inst, repaired_p, target; yfix=baseline_sol.y, zfix=baseline_sol.z)
    sol=_assemble_house_recourse(inst, repaired_p, baseline_sol.y, baseline_sol.z, baseline_sol.s)
    heuristic_run_time=time() - t_start

    return (
        baseline_sol=baseline_sol,
        heuristic_sol=sol,
        total_run_time=baseline_sol.run_time + heuristic_run_time + extra_run_time,
        total_model_solve_time=baseline_sol.time + extra_solve_time,
        diagnostics=(
            expected_target=target,
            pea_gap=_pea_expected_gap(inst, sol),
            history=history
        )
    )
end

function solve_decomposed_sa_restricted(
    inst::InstanceM;
    baseline_sol::Union{Nothing,SolutionM}=nothing,
    max_iter::Int=50,
    step_size::Float64=0.25,
    inertia::Float64=0.80,
    gap_tol::Float64=1e-4
)
    baseline_sol === nothing && (baseline_sol = solveMulti(inst, "NONE"))
    baseline_sol.status || error("La solucion baseline NONE no es factible.")

    t_start=time()
    sol, _, extra_solve_time, extra_run_time, history = _decomposed_iterations!(
        inst, "SA", copy(baseline_sol.p), baseline_sol.y, baseline_sol.z, baseline_sol.s, baseline_sol.p;
        max_iter=max_iter, step_size=step_size, inertia=inertia, gap_tol=gap_tol
    )
    heuristic_run_time=time() - t_start

    return (
        baseline_sol=baseline_sol,
        heuristic_sol=sol,
        total_run_time=baseline_sol.run_time + heuristic_run_time + extra_run_time,
        total_model_solve_time=baseline_sol.time + extra_solve_time,
        diagnostics=(
            sa_gap=_sa_expected_gap(inst, sol),
            expected_savings=_expected_savings(inst, sol),
            history=history
        )
    )
end

function solve_decomposed_lex_pea_restricted(
    inst::InstanceM;
    baseline_sol::Union{Nothing,SolutionM}=nothing,
    max_iter::Int=50,
    step_size::Float64=0.25,
    inertia::Float64=0.80,
    gap_tol::Float64=1e-4
)
    baseline_sol === nothing && (baseline_sol = solveMulti(inst, "NONE"))
    baseline_sol.status || error("La solucion baseline NONE no es factible.")

    t_start=time()
    sol, target, extra_solve_time, extra_run_time, history = _decomposed_iterations!(
        inst, "LEXMMFPEA", copy(baseline_sol.p), baseline_sol.y, baseline_sol.z, baseline_sol.s, baseline_sol.p;
        max_iter=max_iter, step_size=step_size, inertia=inertia, gap_tol=gap_tol
    )
    repaired_p=copy(sol.p)
    _repair_expected_pv_targets!(inst, repaired_p, target; yfix=baseline_sol.y, zfix=baseline_sol.z)
    sol=_assemble_house_recourse(inst, repaired_p, baseline_sol.y, baseline_sol.z, baseline_sol.s)
    heuristic_run_time=time() - t_start

    return (
        baseline_sol=baseline_sol,
        heuristic_sol=sol,
        total_run_time=baseline_sol.run_time + heuristic_run_time + extra_run_time,
        total_model_solve_time=baseline_sol.time + extra_solve_time,
        diagnostics=(
            expected_target=target,
            actual_gap=target .- _expected_pv_received(inst, sol.p),
            history=history
        )
    )
end

function solve_decomposed_lex_sa_restricted(
    inst::InstanceM;
    baseline_sol::Union{Nothing,SolutionM}=nothing,
    max_iter::Int=50,
    step_size::Float64=0.25,
    inertia::Float64=0.80,
    gap_tol::Float64=1e-4
)
    baseline_sol === nothing && (baseline_sol = solveMulti(inst, "NONE"))
    baseline_sol.status || error("La solucion baseline NONE no es factible.")

    t_start=time()
    sol, _, extra_solve_time, extra_run_time, history = _decomposed_iterations!(
        inst, "LEXMMFSA", copy(baseline_sol.p), baseline_sol.y, baseline_sol.z, baseline_sol.s, baseline_sol.p;
        max_iter=max_iter, step_size=step_size, inertia=inertia, gap_tol=gap_tol
    )
    heuristic_run_time=time() - t_start

    return (
        baseline_sol=baseline_sol,
        heuristic_sol=sol,
        total_run_time=baseline_sol.run_time + heuristic_run_time + extra_run_time,
        total_model_solve_time=baseline_sol.time + extra_solve_time,
        diagnostics=(
            expected_savings=_expected_savings(inst, sol),
            sa_gap=_sa_expected_gap(inst, sol),
            history=history
        )
    )
end

function solve_decomposed_restricted(
    inst::InstanceM,
    fairness::String;
    baseline_sol::Union{Nothing,SolutionM}=nothing,
    max_iter::Int=50,
    step_size::Float64=0.25,
    inertia::Float64=0.80,
    gap_tol::Float64=1e-4
)
    if fairness == "PEA"
        return solve_decomposed_pea_restricted(
            inst;
            baseline_sol=baseline_sol,
            max_iter=max_iter,
            step_size=step_size,
            inertia=inertia,
            gap_tol=gap_tol
        )
    elseif fairness == "SA"
        return solve_decomposed_sa_restricted(
            inst;
            baseline_sol=baseline_sol,
            max_iter=max_iter,
            step_size=step_size,
            inertia=inertia,
            gap_tol=gap_tol
        )
    elseif fairness in ("LEXMMFPEA", "MMFPEA", "EMMFPEA")
        return solve_decomposed_lex_pea_restricted(
            inst;
            baseline_sol=baseline_sol,
            max_iter=max_iter,
            step_size=step_size,
            inertia=inertia,
            gap_tol=gap_tol
        )
    elseif fairness in ("LEXMMFSA", "MMFSA")
        return solve_decomposed_lex_sa_restricted(
            inst;
            baseline_sol=baseline_sol,
            max_iter=max_iter,
            step_size=step_size,
            inertia=inertia,
            gap_tol=gap_tol
        )
    else
        error("Fairness descompuesta no soportada: $fairness")
    end
end
