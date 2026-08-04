if !isdefined(@__MODULE__, :solveMulti)
    include("multi.jl")
end

using CSV
using DataFrames
using Dates
using Statistics
import MathOptInterface as MOI

const FAIRNESS_COMPARISON_NONCONDITIONAL = [
    "PEA", "SA", "LEXMMFPEA", "LEXMMFSA",
    "ERDINC_PSR", "ERDINC_ESR", "ERDINC_PESR",
    "ERDINC_PC", "ERDINC_EC", "ERDINC_PEC",
    "STATIC_DEMAND_SHARE",
]

const FAIRNESS_COMPARISON_CONDITIONAL = [
    "CPEA", "CSA", "CLEXMMFPEA", "CLEXMMFSA",
]

const FAIRNESS_COMPARISON_POLICIES = vcat(
    FAIRNESS_COMPARISON_NONCONDITIONAL,
    FAIRNESS_COMPARISON_CONDITIONAL,
)

comparison_is_conditional(policy::String) = policy in FAIRNESS_COMPARISON_CONDITIONAL

function comparison_parse_int_list(value::AbstractString)
    return parse.(Int, [strip(x) for x in split(value, ',') if !isempty(strip(x))])
end

function comparison_atomic_write(path::String, df::DataFrame)
    mkpath(dirname(abspath(path)))
    temporary = joinpath(dirname(abspath(path)), ".$(basename(path)).tmp.$(getpid())")
    CSV.write(temporary, df)
    mv(temporary, abspath(path); force=true)
    return path
end

function comparison_load_csv(path::String)
    if isfile(path) && filesize(path) > 0
        string_columns = Set([
            "ConfigID", "RandomInstanceID", "InstanceFile", "InstFolder", "TreeSpec",
            "DemandProfile", "Fairness", "ErrorType", "ErrorMessage", "Timestamp",
            "FailureReason", "Worker", "LogFile",
        ])
        return CSV.read(
            path, DataFrame;
            types=(index, name) -> String(name) in string_columns ? String : nothing,
        )
    end
    return DataFrame()
end

comparison_read_manifest(path::String) = comparison_load_csv(path)

function comparison_empty_failures()
    return DataFrame(
        ConfigID=String[], Fairness=String[], ConditionalStage=Union{Missing,Int}[],
        ErrorType=String[], ErrorMessage=String[], Timestamp=String[],
    )
end

function comparison_load_failures(path::String)
    loaded = comparison_load_csv(path)
    return ncol(loaded) == 0 ? comparison_empty_failures() : loaded
end

function _comparison_stage_matches(value, stage)
    return ismissing(stage) ? ismissing(value) : (!ismissing(value) && Int(value) == Int(stage))
end

function comparison_combo_mask(df::DataFrame, config_id::String, policy::String, stage)
    nrow(df) == 0 && return falses(0)
    required = ["ConfigID", "Fairness", "ConditionalStage"]
    all(column -> column in names(df), required) || return falses(nrow(df))
    return BitVector([
        String(df.ConfigID[i]) == config_id &&
        String(df.Fairness[i]) == policy &&
        _comparison_stage_matches(df.ConditionalStage[i], stage)
        for i in 1:nrow(df)
    ])
end

function comparison_without_combo(df::DataFrame, config_id::String, policy::String, stage)
    nrow(df) == 0 && return df
    return df[.!comparison_combo_mask(df, config_id, policy, stage), :]
end

function comparison_run_complete(
    summary::DataFrame,
    by_house::DataFrame,
    conditional::DataFrame,
    inst::InstanceM,
    config_id::String,
    policy::String,
    stage,
)
    summary_mask = comparison_combo_mask(summary, config_id, policy, stage)
    count(summary_mask) == 1 || return false
    summary_row = summary[findfirst(summary_mask), :]
    summary_row.Status === true || return false

    house_mask = comparison_combo_mask(by_house, config_id, policy, stage)
    count(house_mask) == inst.J || return false
    houses = by_house[house_mask, :House]
    length(unique(houses)) == inst.J || return false

    if comparison_is_conditional(policy)
        conditional_mask = comparison_combo_mask(conditional, config_id, policy, stage)
        expected = length(stage_entry_nodes(inst.tree, Int(stage))) * inst.J
        count(conditional_mask) == expected || return false
        keys = Set(
            (Int(conditional.Node[i]), Int(conditional.House[i]))
            for i in findall(conditional_mask)
        )
        length(keys) == expected || return false
    end
    return true
end

function write_cplex_thread_parameter_file(path::String, threads::Int)
    threads >= 1 || error("CPLEX_THREADS debe ser positivo.")
    mkpath(dirname(abspath(path)))
    env = CPLEX.Env()
    try
        ret = CPLEX.CPXsetintparam(env, CPLEX.CPXPARAM_Threads, threads)
        ret == 0 || error("CPXsetintparam devolvió $ret.")
        ret = CPLEX.CPXwriteparam(env, abspath(path))
        ret == 0 || error("CPXwriteparam devolvió $ret.")
    finally
        finalize(env)
    end
    return abspath(path)
end

function verify_cplex_thread_limit(expected_threads::Int)
    optimizer = CPLEX.Optimizer()
    actual = try
        MOI.get(optimizer, MOI.NumberOfThreads())
    finally
        finalize(optimizer)
    end
    actual == expected_threads || error(
        "CPLEX usa $actual hilos; se esperaban $expected_threads. " *
        "Configura ILOG_CPLEX_PARAMETER_FILE antes de iniciar el worker."
    )
    return actual
end

function comparison_instance(row)
    instance_file = joinpath(String(row.InstFolder), String(row.InstanceFile))
    inst = generateInstance(
        Int(row.NBstage), Int(row.Childs), Int(row.Periods), Int(row.J),
        instance_file, Float64(row.Theta), Float64(row.Avg_d), Float64(row.Dev_d);
        pv_scale=Float64(row.PVScale), demand_profile=String(row.DemandProfile),
    )
    scaleInstance!(inst; battery_scale=Float64(row.BatteryScale))
    return inst
end

function solve_comparison_policy(
    inst::InstanceM,
    policy::String;
    conditional_stage::Union{Missing,Int}=missing,
    fairness_mmr::Float64=1.2,
    lex_eps_abs::Float64=TOL,
)
    policy in FAIRNESS_COMPARISON_POLICIES || error("Política comparativa no soportada: $policy")
    if policy == "STATIC_DEMAND_SHARE"
        solution = solveMulti(inst, policy)
        return solution, static_demand_share_diagnostics(inst, solution)
    elseif policy in ("CPEA", "CSA")
        ismissing(conditional_stage) && error("$policy requiere ConditionalStage.")
        return solveMulti(
            inst, policy;
            conditional_stage=conditional_stage,
            fairness_abs_tol=0.0,
        )
    elseif policy in ("CLEXMMFPEA", "CLEXMMFSA")
        ismissing(conditional_stage) && error("$policy requiere ConditionalStage.")
        return solveMulti(
            inst, policy;
            conditional_stage=conditional_stage,
            lex_eps_abs=lex_eps_abs,
        )
    elseif startswith(policy, "ERDINC_")
        return solveMulti(inst, policy; fairness_mmr=fairness_mmr)
    end
    result = solveMulti(inst, policy)
    return result isa Tuple ? (result[1], nothing) : (result, nothing)
end

function _comparison_gini(values::Vector{Float64})
    any(x -> x < 0, values) && return missing
    total = sum(values)
    total > 0 || return missing
    n = length(values)
    return sum(abs(values[i] - values[j]) for i in 1:n, j in 1:n) / (2 * n * total)
end

function _comparison_jain(values::Vector{Float64})
    any(x -> x < 0, values) && return missing
    total = sum(values)
    total > 0 || return missing
    denominator = length(values) * sum(abs2, values)
    denominator > 0 || return missing
    return total^2 / denominator
end


function _comparison_vector_stats(values::Vector{Float64})
    return (
        minimum=minimum(values),
        maximum=maximum(values),
        range=maximum(values) - minimum(values),
        gini=_comparison_gini(values),
        jain=_comparison_jain(values),
    )
end

function _comparison_share(value::Float64, total::Float64)
    return abs(total) > eps(Float64) ? value / total : missing
end

function comparison_common_metrics(inst::InstanceM, sol::SolutionM)
    tree = inst.tree
    probabilities = scenario_probabilities(tree)
    time_periods = createTime(tree)
    expected_pv = Float64[
        sum(tree.rho[n] * sol.p[j,n] for n in 1:tree.V) for j in 1:inst.J
    ]
    expected_ess = Float64[
        sum(tree.rho[n] * sol.y[j,n] for n in 1:tree.V) for j in 1:inst.J
    ]
    expected_pv_ess = expected_pv .+ expected_ess

    demand = _scenario_demand_matrix(inst)
    expected_psr = zeros(inst.J)
    expected_esr = zeros(inst.J)
    expected_pesr = zeros(inst.J)
    for j in 1:inst.J, s_idx in eachindex(tree.scenarios)
        denominator = demand[j,s_idx]
        denominator > 0 || error("Demanda no positiva para hogar $j, escenario $s_idx.")
        scenario = tree.scenarios[s_idx]
        pv = inst.delta * sum(sol.p[j,n] for n in scenario)
        ess = inst.delta * sum(sol.y[j,n] for n in scenario)
        expected_psr[j] += probabilities[s_idx] * pv / denominator
        expected_esr[j] += probabilities[s_idx] * ess / denominator
        expected_pesr[j] += probabilities[s_idx] * (pv + ess) / denominator
    end

    benchmark = Float64[
        inst.delta * sum(
            tree.rho[n] * inst.nu[j,time_periods[n]] * inst.d[j,n]
            for n in 1:tree.V
        )
        for j in 1:inst.J
    ]
    savings = benchmark .- sol.costs
    all(x -> x > 0, benchmark) || error("El benchmark all-grid esperado debe ser positivo.")
    savings_rate = savings ./ benchmark

    return (
        expected_pv=expected_pv,
        expected_ess=expected_ess,
        expected_pv_ess=expected_pv_ess,
        expected_psr=expected_psr,
        expected_esr=expected_esr,
        expected_pesr=expected_pesr,
        benchmark=benchmark,
        savings=savings,
        savings_rate=savings_rate,
        pv_stats=_comparison_vector_stats(expected_pv),
        ess_stats=_comparison_vector_stats(expected_ess),
        pv_ess_stats=_comparison_vector_stats(expected_pv_ess),
        psr_stats=_comparison_vector_stats(expected_psr),
        esr_stats=_comparison_vector_stats(expected_esr),
        pesr_stats=_comparison_vector_stats(expected_pesr),
        savings_stats=_comparison_vector_stats(savings),
        savings_rate_stats=_comparison_vector_stats(savings_rate),
        savings_negative_count=count(x -> x < 0, savings),
    )
end

function _comparison_ratio(minimum_value::Float64, maximum_value::Float64)
    return minimum_value > 0 ? maximum_value / minimum_value : missing
end

function _comparison_pea_residuals(inst::InstanceM, sol::SolutionM)
    probs = scenario_probabilities(inst.tree)
    residuals = zeros(inst.J)
    for j in 1:inst.J
        actual = sum(
            probs[s_idx] * sum(sol.p[j,n] for n in scenario)
            for (s_idx, scenario) in enumerate(inst.tree.scenarios)
        )
        target = sum(
            probs[s_idx] *
            (sum(inst.c_pv[n] for n in scenario) /
             sum(inst.d[k,n] for k in 1:inst.J, n in scenario)) *
            sum(inst.d[j,n] for n in scenario)
            for (s_idx, scenario) in enumerate(inst.tree.scenarios)
        )
        residuals[j] = abs(actual - target)
    end
    return residuals
end

function _comparison_sa_residuals(inst::InstanceM, sol::SolutionM)
    probs = scenario_probabilities(inst.tree)
    time_periods = createTime(inst.tree)
    residuals = zeros(inst.J)
    for j in 1:inst.J
        actual = 0.0
        target = 0.0
        for (s_idx, scenario) in enumerate(inst.tree.scenarios)
            benchmark = Float64[
                inst.delta * sum(inst.nu[k,time_periods[n]] * inst.d[k,n] for n in scenario)
                for k in 1:inst.J
            ]
            costs = Float64[
                inst.delta * sum(
                    inst.mu * sol.y[k,n] + inst.nu[k,time_periods[n]] * sol.I[k,n] -
                    inst.beta * sol.G[k,n]
                    for n in scenario
                )
                for k in 1:inst.J
            ]
            savings = benchmark .- costs
            actual += probs[s_idx] * savings[j]
            target += probs[s_idx] * (benchmark[j] / sum(benchmark)) * sum(savings)
        end
        residuals[j] = abs(actual - target)
    end
    return residuals
end

function comparison_compliance_metrics(
    inst::InstanceM,
    sol::SolutionM,
    policy::String,
    diagnostics;
    lex_eps_abs::Float64=TOL,
)
    residual_mean = missing
    residual_max = missing
    rule_min = missing
    rule_max = missing
    rule_ratio = missing
    conditional_mean = missing
    conditional_max = missing
    worst_node_gap = missing
    share_sum_residual = missing
    across_node_residual = missing
    pv_allocation_residual = missing

    if policy == "PEA"
        residuals = _comparison_pea_residuals(inst, sol)
        residual_mean, residual_max = mean(residuals), maximum(residuals)
    elseif policy == "SA"
        residuals = _comparison_sa_residuals(inst, sol)
        residual_mean, residual_max = mean(residuals), maximum(residuals)
    elseif startswith(policy, "ERDINC_")
        values = Float64.(diagnostics.metric_values)
        rule_min, rule_max = minimum(values), maximum(values)
        rule_ratio = _comparison_ratio(rule_min, rule_max)
        violation = max(0.0, rule_max - diagnostics.fairness_mmr * rule_min)
        residual_mean, residual_max = violation, violation
    elseif policy == "STATIC_DEMAND_SHARE"
        share_sum_residual = diagnostics.MaxShareSumResidual
        across_node_residual = diagnostics.MaxAcrossNodeShareResidual
        pv_allocation_residual = diagnostics.MaxPVAllocationResidual
        residuals = Float64[share_sum_residual, across_node_residual, pv_allocation_residual]
        residual_mean, residual_max = mean(residuals), maximum(residuals)
    elseif policy in ("CPEA", "CSA")
        gaps = abs.(Float64.(diagnostics.gap))
        residual_mean, residual_max = mean(gaps), maximum(gaps)
        conditional_mean, conditional_max = residual_mean, residual_max
        worst_node_gap = maximum(maximum(gaps[:,b]) for b in axes(gaps, 2))
    elseif policy in ("CLEXMMFPEA", "CLEXMMFSA")
        violations = max.(Float64.(diagnostics.omega) .- lex_eps_abs .-
                          Float64.(diagnostics.achieved_levels), 0.0)
        residual_mean, residual_max = mean(violations), maximum(violations)
    end

    return (
        FairnessResidualMean=residual_mean,
        FairnessResidualMax=residual_max,
        RuleMetricMin=rule_min,
        RuleMetricMax=rule_max,
        RuleMetricRatio=rule_ratio,
        ConditionalGapMean=conditional_mean,
        ConditionalGapMax=conditional_max,
        WorstNodeGap=worst_node_gap,
        MaxShareSumResidual=share_sum_residual,
        MaxAcrossNodeShareResidual=across_node_residual,
        MaxPVAllocationResidual=pv_allocation_residual,
    )
end

function comparison_summary_row(
    inst::InstanceM,
    config,
    policy::String,
    conditional_stage,
    sol::SolutionM,
    diagnostics,
    none_expected_cost::Float64;
    fairness_mmr::Float64=1.2,
    lex_eps_abs::Float64=TOL,
)
    common = comparison_common_metrics(inst, sol)
    compliance = comparison_compliance_metrics(
        inst, sol, policy, diagnostics; lex_eps_abs=lex_eps_abs,
    )
    expected_cost = sum(sol.costs)
    pof_abs = expected_cost - none_expected_cost
    pof_pct = pof_abs / max(1.0, abs(none_expected_cost))
    return (
        ConfigID=String(config.ConfigID),
        RandomInstanceID=String(config.RandomInstanceID),
        InstanceFile=String(config.InstanceFile),
        TreeSpec=String(config.TreeSpec),
        NBstage=Int(config.NBstage), Childs=Int(config.Childs), Periods=Int(config.Periods),
        Scenarios=Int(config.Scenarios), J=Int(config.J), Theta=Float64(config.Theta),
        Fairness=policy, ConditionalStage=conditional_stage,
        FairnessMMR=startswith(policy, "ERDINC_") ? fairness_mmr : missing,
        Status=sol.status,
        ExpectedCost=expected_cost, NoneExpectedCost=none_expected_cost,
        PoFAbs=pof_abs, PoFPct=pof_pct,
        RunTimeSec=sol.run_time, ModelSolveTimeSec=sol.time,
        PVMin=common.pv_stats.minimum, PVMax=common.pv_stats.maximum,
        PVRange=common.pv_stats.range, PVGini=common.pv_stats.gini, PVJain=common.pv_stats.jain,
        ESSMin=common.ess_stats.minimum, ESSMax=common.ess_stats.maximum,
        ESSRange=common.ess_stats.range, ESSGini=common.ess_stats.gini, ESSJain=common.ess_stats.jain,
        PVESSMin=common.pv_ess_stats.minimum, PVESSMax=common.pv_ess_stats.maximum,
        PVESSRange=common.pv_ess_stats.range,
        PVESSGini=common.pv_ess_stats.gini, PVESSJain=common.pv_ess_stats.jain,
        PSRMin=common.psr_stats.minimum, PSRMax=common.psr_stats.maximum,
        PSRRange=common.psr_stats.range, PSRGini=common.psr_stats.gini, PSRJain=common.psr_stats.jain,
        ESRMin=common.esr_stats.minimum, ESRMax=common.esr_stats.maximum,
        ESRRange=common.esr_stats.range, ESRGini=common.esr_stats.gini, ESRJain=common.esr_stats.jain,
        PESRMin=common.pesr_stats.minimum, PESRMax=common.pesr_stats.maximum,
        PESRRange=common.pesr_stats.range,
        PESRGini=common.pesr_stats.gini, PESRJain=common.pesr_stats.jain,
        SavingsMin=common.savings_stats.minimum, SavingsMax=common.savings_stats.maximum,
        SavingsRange=common.savings_stats.range,
        SavingsGini=common.savings_stats.gini, SavingsJain=common.savings_stats.jain,
        SavingsNegativeCount=common.savings_negative_count,
        SavingsRateMin=common.savings_rate_stats.minimum,
        SavingsRateMax=common.savings_rate_stats.maximum,
        SavingsRateRange=common.savings_rate_stats.range,
        SavingsRateGini=common.savings_rate_stats.gini,
        SavingsRateJain=common.savings_rate_stats.jain,
        FairnessResidualMean=compliance.FairnessResidualMean,
        FairnessResidualMax=compliance.FairnessResidualMax,
        RuleMetricMin=compliance.RuleMetricMin, RuleMetricMax=compliance.RuleMetricMax,
        RuleMetricRatio=compliance.RuleMetricRatio,
        ConditionalGapMean=compliance.ConditionalGapMean,
        ConditionalGapMax=compliance.ConditionalGapMax,
        WorstNodeGap=compliance.WorstNodeGap,
        MaxShareSumResidual=compliance.MaxShareSumResidual,
        MaxAcrossNodeShareResidual=compliance.MaxAcrossNodeShareResidual,
        MaxPVAllocationResidual=compliance.MaxPVAllocationResidual,
    )
end

function comparison_house_rows(
    inst::InstanceM,
    config,
    policy::String,
    conditional_stage,
    sol::SolutionM,
)
    common = comparison_common_metrics(inst, sol)
    pv_total = sum(common.expected_pv)
    ess_total = sum(common.expected_ess)
    pv_ess_total = sum(common.expected_pv_ess)
    savings_total = sum(common.savings)
    rows = NamedTuple[]
    for j in 1:inst.J
        push!(rows, (
            ConfigID=String(config.ConfigID),
            RandomInstanceID=String(config.RandomInstanceID),
            TreeSpec=String(config.TreeSpec), Fairness=policy,
            ConditionalStage=conditional_stage, House=j,
            ExpectedPV=common.expected_pv[j], ExpectedESS=common.expected_ess[j],
            ExpectedPVPlusESS=common.expected_pv_ess[j],
            ExpectedPSR=common.expected_psr[j], ExpectedESR=common.expected_esr[j],
            ExpectedPESR=common.expected_pesr[j],
            ExpectedSavings=common.savings[j], ExpectedSavingsRate=common.savings_rate[j],
            ExpectedCost=sol.costs[j],
            PVShare=_comparison_share(common.expected_pv[j], pv_total),
            ESSShare=_comparison_share(common.expected_ess[j], ess_total),
            PVESSShare=_comparison_share(common.expected_pv_ess[j], pv_ess_total),
            SavingsShare=_comparison_share(common.savings[j], savings_total),
            RunTimeSec=sol.run_time, ModelSolveTimeSec=sol.time,
        ))
    end
    return rows
end

function _conditional_scenario_quantities(inst::InstanceM, sol::SolutionM, node::Int, j::Int)
    time_periods = createTime(inst.tree)
    conditional = conditional_scenario_probabilities(inst.tree, node)
    pv = 0.0
    ess = 0.0
    savings = 0.0
    for (s_idx, probability) in conditional
        scenario = inst.tree.scenarios[s_idx]
        scenario_pv = inst.delta * sum(sol.p[j,n] for n in scenario)
        scenario_ess = inst.delta * sum(sol.y[j,n] for n in scenario)
        benchmark = inst.delta * sum(
            inst.nu[j,time_periods[n]] * inst.d[j,n] for n in scenario
        )
        cost = inst.delta * sum(
            inst.mu * sol.y[j,n] + inst.nu[j,time_periods[n]] * sol.I[j,n] -
            inst.beta * sol.G[j,n]
            for n in scenario
        )
        pv += probability * scenario_pv
        ess += probability * scenario_ess
        savings += probability * (benchmark - cost)
    end
    return pv, ess, savings
end

function comparison_conditional_rows(
    inst::InstanceM,
    config,
    policy::String,
    conditional_stage::Int,
    sol::SolutionM,
    diagnostics,
)
    nodes = stage_entry_nodes(inst.tree, conditional_stage)
    rows = NamedTuple[]
    for (node_index, node) in enumerate(nodes), j in 1:inst.J
        pv, ess, savings = _conditional_scenario_quantities(inst, sol, node, j)
        if policy in ("CPEA", "CSA")
            target = diagnostics.target[j,node_index]
            gap = diagnostics.gap[j,node_index]
            absolute_gap = abs(gap)
        else
            target = missing
            gap = missing
            absolute_gap = missing
        end
        push!(rows, (
            ConfigID=String(config.ConfigID), Fairness=policy,
            ConditionalStage=conditional_stage, Node=node,
            NodeStage=inst.tree.stages[node], NodeProbability=inst.tree.rho[node],
            House=j, ConditionalPV=pv, ConditionalESS=ess,
            ConditionalPVPlusESS=pv + ess, ConditionalSavings=savings,
            ConditionalTarget=target, ConditionalGap=gap,
            AbsoluteConditionalGap=absolute_gap,
        ))
    end
    return rows
end
