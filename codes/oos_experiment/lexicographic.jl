# =====================================================================================
# Lexicographic max-min fairness on the corrected shared-battery physical model.
#
# The linear characterization is the repository's own (see `codes/mmf_sa.jl`):
#
#     max_{zeta, d >= 0}  k * zeta_k - sum_j d_{k,j}   s.t.  zeta_k - d_{k,j} <= X_j
#
# whose optimum equals the sum of the k smallest outcomes `X_j`. Maximizing that value for
# k = 1, ..., J in order yields the lexicographic max-min outcome vector.
#
# The essential difference from the legacy PV master in `codes/mmf_pea.jl` is that *every*
# phase here runs on the full corrected physical model, including the node-level shared
# battery mode. No fairness target is ever imported from the old formulation.
# =====================================================================================

"""Outcome expressions maximized lexicographically, per policy."""
function lexicographic_outcome_expressions(
    refs::PhysicalModelRefs,
    policy::FairnessPolicy,
    past::FairnessPastState,
    aggregates,
)
    if policy === LEXMMFPEA
        # X_j = P_j^past + E_t[ sum_tau p_{j,tau} ]
        return expected_pv_allocation_expressions(refs, past)
    elseif policy === LEXMMFSA
        # X_j = S_j^past + E_t[ S_{j,t} ]
        return expected_savings_expressions(refs, past, aggregates)
    end
    error("La política $policy no es lexicográfica.")
end

"""Result of the lexicographic sweep and of the economic tie-break."""
struct LexicographicResult
    solved::Bool
    phase_levels::Vector{Float64}        # omega_k : sum of the k smallest outcomes
    achieved_outcomes::Vector{Float64}   # per-household outcome after the tie-break
    phase_objectives::Vector{Float64}    # every phase objective, tie-break included
    phase_statuses::Vector{String}
    phase_records::Vector{SolvePhaseRecord}
    solve_time_sec::Float64
    solver_time_sec::Float64
    failed_phase::Int
    failure_message::String
end

"""Snapshot one solve of a persistent lexicographic model as a `SolvePhaseRecord`."""
function _phase_record(
    model::JuMP.Model,
    phase::Int,
    label::String,
    wall_time::Float64,
    solver_time::Float64,
)
    binaries = generated_binary_count(model)
    variables = num_variables(model)
    return SolvePhaseRecord(
        phase, label,
        string(termination_status(model)), string(primal_status(model)),
        has_values(model) ? objective_value(model) : NaN,
        Float64(safe_solver_attribute(model, MOI.ObjectiveBound(), NaN)),
        wall_time, solver_time,
        variables, binaries, variables - binaries,
        model_constraint_count(model), model_nonzero_count(model),
        Int(safe_solver_attribute(model, MOI.NodeCount(), 0)),
        Float64(safe_solver_attribute(model, MOI.RelativeGap(), NaN)),
        NaN,
    )
end

"""
Run the J lexicographic phases and then the economic tie-break on one persistent model.

Convention (single, explicit): the lexicographic fairness levels are computed under the
corrected physical model, and the expected remaining operating cost is then minimized while
preserving those levels within `lex_eps_abs`.
"""
function solve_lexicographic!(
    refs::PhysicalModelRefs,
    policy::FairnessPolicy,
    past::FairnessPastState,
    aggregates,
    config::OOSExperimentConfig,
)
    model = refs.model
    J = refs.template.J
    outcome = lexicographic_outcome_expressions(refs, policy, past, aggregates)

    @variable(model, lex_zeta[1:J])
    @variable(model, lex_slack[1:J, 1:J] >= 0)
    @constraint(model, lex_envelope[k in 1:J, j in 1:J],
        lex_zeta[k] - lex_slack[k, j] <= outcome[j])

    phase_levels = fill(NaN, J)
    phase_objectives = Float64[]
    phase_statuses = String[]
    phase_records = SolvePhaseRecord[]
    total_wall = 0.0
    total_solver = 0.0

    for k in 1:J
        @objective(model, Max, k * lex_zeta[k] - sum(lex_slack[k, j] for j in 1:J))
        t_phase = time()
        optimize!(model)
        phase_wall = time() - t_phase
        phase_solver = _safe_solve_time(model)
        total_wall += phase_wall
        total_solver += phase_solver
        push!(phase_statuses, string(termination_status(model)))
        push!(phase_records, _phase_record(model, k, "lex_phase_$k", phase_wall, phase_solver))
        if !has_values(model)
            return LexicographicResult(
                false, phase_levels, fill(NaN, J), phase_objectives, phase_statuses,
                phase_records, total_wall, total_solver, k,
                "La fase lexicográfica $k no produjo valores (estado $(termination_status(model))).",
            )
        end
        level = objective_value(model)
        phase_levels[k] = level
        push!(phase_objectives, level)
        # Preserve the level attained so far, within the configured absolute tolerance.
        @constraint(model, k * lex_zeta[k] - sum(lex_slack[k, j] for j in 1:J) >= level - config.lex_eps_abs)
    end

    # Economic tie-break: minimize expected remaining operating cost at the preserved levels.
    set_expected_cost_objective!(refs)
    t_phase = time()
    optimize!(model)
    phase_wall = time() - t_phase
    phase_solver = _safe_solve_time(model)
    total_wall += phase_wall
    total_solver += phase_solver
    push!(phase_statuses, string(termination_status(model)))
    push!(phase_records, _phase_record(model, J + 1, "economic_tie_break", phase_wall, phase_solver))
    if !has_values(model)
        return LexicographicResult(
            false, phase_levels, fill(NaN, J), phase_objectives, phase_statuses,
            phase_records, total_wall, total_solver, J + 1,
            "El desempate económico lexicográfico no produjo valores " *
            "(estado $(termination_status(model))).",
        )
    end
    push!(phase_objectives, objective_value(model))
    achieved = lexicographic_achieved_outcomes(refs, policy, past, aggregates)

    return LexicographicResult(
        true, phase_levels, achieved, phase_objectives, phase_statuses,
        phase_records, total_wall, total_solver, 0, "",
    )
end

"""
Residual of the lexicographic guarantee: largest shortfall of the achieved cumulative
order statistics with respect to the computed levels.

Comparing cumulative sums of the sorted achieved outcomes against `omega_k` is the correct
check, because the lexicographic levels are defined on sums of the k smallest outcomes and
are invariant to household relabelling.
"""
function lexicographic_level_residual(levels::Vector{Float64}, achieved::Vector{Float64})
    length(levels) == length(achieved) || error("Dimensiones lexicográficas inconsistentes.")
    any(isnan, levels) && return NaN
    any(isnan, achieved) && return NaN
    sorted = sort(achieved)
    residual = 0.0
    running = 0.0
    for k in eachindex(sorted)
        running += sorted[k]
        residual = max(residual, levels[k] - running)
    end
    return max(residual, 0.0)
end

_safe_solve_time(model::JuMP.Model) = try
    solve_time(model)
catch
    0.0
end
