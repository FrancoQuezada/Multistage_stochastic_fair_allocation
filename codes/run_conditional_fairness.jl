include("multi.jl")

using CSV
using DataFrames

const DEFAULT_NEW_FAIRNESS_POLICIES = [
    "ERDINC_PSR", "ERDINC_ESR", "ERDINC_PESR",
    "ERDINC_PC", "ERDINC_EC", "ERDINC_PEC",
    "CPEA", "CSA", "CLEXMMFPEA", "CLEXMMFSA",
]

function _new_policy_violation(diagnostics)
    if diagnostics.kind == :ERDINC
        return diagnostics.mmr_abs_violation
    elseif diagnostics.kind in (:CPEA, :CSA)
        return diagnostics.max_abs_gap
    end
    return diagnostics.max_lex_violation
end

function _append_diagnostics!(df::DataFrame, fairness::String, diagnostics)
    if diagnostics.kind == :ERDINC
        for j in eachindex(diagnostics.metric_values)
            push!(df, (
                Fairness=fairness, RecordType="household_metric", House=j,
                ConditioningNode=missing, Level=missing,
                Actual=diagnostics.metric_values[j], Target=missing,
                Gap=missing, NodeProbability=missing,
            ); cols=:union)
        end
        push!(df, (
            Fairness=fairness, RecordType="mmr_summary", House=missing,
            ConditioningNode=missing, Level=missing,
            Actual=diagnostics.achieved_mmr, Target=diagnostics.fairness_mmr,
            Gap=diagnostics.mmr_abs_violation, NodeProbability=missing,
        ); cols=:union)
    elseif diagnostics.kind in (:CPEA, :CSA)
        for (b, node) in enumerate(diagnostics.nodes), j in axes(diagnostics.actual, 1)
            push!(df, (
                Fairness=fairness, RecordType="conditional_equation", House=j,
                ConditioningNode=node, Level=missing,
                Actual=diagnostics.actual[j,b], Target=diagnostics.target[j,b],
                Gap=diagnostics.gap[j,b], NodeProbability=diagnostics.node_probabilities[b],
            ); cols=:union)
        end
    else
        for (b, node) in enumerate(diagnostics.nodes), j in axes(diagnostics.outcomes, 1)
            push!(df, (
                Fairness=fairness, RecordType="conditional_outcome", House=j,
                ConditioningNode=node, Level=missing,
                Actual=diagnostics.outcomes[j,b], Target=missing,
                Gap=missing, NodeProbability=diagnostics.node_probabilities[b],
            ); cols=:union)
        end
        for k in eachindex(diagnostics.omega)
            push!(df, (
                Fairness=fairness, RecordType="lexicographic_level", House=missing,
                ConditioningNode=missing, Level=k,
                Actual=diagnostics.achieved_levels[k], Target=diagnostics.omega[k],
                Gap=diagnostics.achieved_levels[k] - diagnostics.omega[k],
                NodeProbability=missing,
            ); cols=:union)
        end
    end
    return df
end

function run_new_fairness_policies(;
    fairness_list::Vector{String}=copy(DEFAULT_NEW_FAIRNESS_POLICIES),
    inFile::String="inst/inst2020/Drahi_1.csv",
    NBstage::Int=3,
    childs::Int=2,
    periods::Int=8,
    J::Int=5,
    theta::Float64=0.2,
    avg_d::Float64=100.0,
    dev_d::Float64=10.0,
    demand_profile::String="mixed",
    battery_scale::Float64=1.0,
    pv_scale::Float64=1.0,
    conditional_stage::Int=2,
    fairness_mmr::Float64=1.2,
    fairness_abs_tol::Float64=0.0,
    lex_eps_abs::Float64=TOL,
    out_csv::String="conditional_fairness_report.csv",
    out_csv_house::String="conditional_fairness_report_by_house.csv",
    out_csv_diagnostics::String="conditional_fairness_diagnostics.csv",
)
    isfile(inFile) || error("No existe el archivo de instancia: $inFile")
    all(is_new_fairness_label, fairness_list) || error(
        "Este runner solo admite las políticas nuevas: $(join(fairness_list, ", "))."
    )
    inst = generateInstance(
        NBstage, childs, periods, J, inFile, theta, avg_d, dev_d;
        pv_scale=pv_scale, demand_profile=demand_profile,
    )
    scaleInstance!(inst; battery_scale=battery_scale)
    validate_conditional_stage(inst.tree, conditional_stage)
    probabilities = scenario_probabilities(inst.tree)
    total_probability = sum(probabilities)

    summary = DataFrame()
    houses = DataFrame()
    diagnostics_df = DataFrame()
    for fairness in fairness_list
        if fairness in CONDITIONAL_FAIRNESS_LABELS
            solution, diagnostics = solveMulti(
                inst, fairness;
                conditional_stage=conditional_stage,
                fairness_abs_tol=fairness_abs_tol,
                lex_eps_abs=lex_eps_abs,
            )
        else
            solution, diagnostics = solveMulti(inst, fairness; fairness_mmr=fairness_mmr)
        end

        if solution.status
            scenario_costs_house = _scenario_cost_matrix(inst, solution)
            scenario_pv_house = [
                inst.delta * sum(solution.p[j,n] for n in scenario)
                for j in 1:inst.J, scenario in inst.tree.scenarios
            ]
            scenario_costs = vec(sum(scenario_costs_house, dims=1))
        else
            scenario_costs_house = fill(Inf, inst.J, length(inst.tree.scenarios))
            scenario_pv_house = fill(Inf, inst.J, length(inst.tree.scenarios))
            scenario_costs = fill(Inf, length(inst.tree.scenarios))
        end
        scenario_expected = sum(probabilities .* scenario_costs) / total_probability

        push!(summary, (
            InstanceNo=1, InstanceFile=basename(inFile), InstanceID=inst.id,
            Fairness=fairness, Status=solution.status,
            ExpectedCost=sum(solution.costs), ScenarioCostExpected=scenario_expected,
            ScenarioCostMin=minimum(scenario_costs), ScenarioCostMax=maximum(scenario_costs),
            RegretExpected=NaN, RegretMin=NaN, RegretMax=NaN,
            DemandProfile=demand_profile, BatteryScale=battery_scale, PVScale=pv_scale,
            RunTimeSec=solution.run_time, ModelSolveTimeSec=solution.time,
            ConditionalStage=fairness in CONDITIONAL_FAIRNESS_LABELS ? conditional_stage : missing,
            FairnessMMR=haskey(ERDINC_LABEL_TO_METRIC, fairness) ? fairness_mmr : missing,
            FairnessAbsTol=fairness in ("CPEA", "CSA") ? fairness_abs_tol : missing,
            LexEpsAbs=fairness in ("CLEXMMFPEA", "CLEXMMFSA") ? lex_eps_abs : missing,
            MaxFairnessViolation=_new_policy_violation(diagnostics),
        ); cols=:union)

        for j in 1:inst.J
            pv_values = scenario_pv_house[j,:]
            cost_values = scenario_costs_house[j,:]
            push!(houses, (
                InstanceNo=1, InstanceFile=basename(inFile), InstanceID=inst.id,
                Fairness=fairness, House=j, Status=solution.status,
                PVReceivedExpected=sum(probabilities .* pv_values) / total_probability,
                PVReceivedMin=minimum(pv_values), PVReceivedMax=maximum(pv_values),
                CostExpected=sum(probabilities .* cost_values) / total_probability,
                CostMin=minimum(cost_values), CostMax=maximum(cost_values),
                RegretExpected=NaN, RegretMin=NaN, RegretMax=NaN,
                DemandProfile=demand_profile, BatteryScale=battery_scale, PVScale=pv_scale,
                RunTimeSec=solution.run_time, ModelSolveTimeSec=solution.time,
            ); cols=:union)
        end
        _append_diagnostics!(diagnostics_df, fairness, diagnostics)
    end

    for path in (out_csv, out_csv_house, out_csv_diagnostics)
        mkpath(dirname(abspath(path)))
    end
    CSV.write(out_csv, summary)
    CSV.write(out_csv_house, houses)
    CSV.write(out_csv_diagnostics, diagnostics_df)
    return summary, houses, diagnostics_df
end

if abspath(PROGRAM_FILE) == @__FILE__
    split_list(value) = String[String(strip(x)) for x in split(value, ",") if !isempty(strip(x))]
    run_new_fairness_policies(
        fairness_list=split_list(get(ENV, "FAIRNESS_SET", join(DEFAULT_NEW_FAIRNESS_POLICIES, ","))),
        inFile=get(ENV, "IN_FILE", "inst/inst2020/Drahi_1.csv"),
        NBstage=parse(Int, get(ENV, "NB_STAGE", "3")),
        childs=parse(Int, get(ENV, "CHILDS", "2")),
        periods=parse(Int, get(ENV, "PERIODS", "8")),
        J=parse(Int, get(ENV, "J", "5")),
        theta=parse(Float64, get(ENV, "THETA", "0.2")),
        avg_d=parse(Float64, get(ENV, "AVG_D", "100.0")),
        dev_d=parse(Float64, get(ENV, "DEV_D", "10.0")),
        demand_profile=get(ENV, "DEMAND_PROFILE", "mixed"),
        battery_scale=parse(Float64, get(ENV, "BATTERY_SCALE", "1.0")),
        pv_scale=parse(Float64, get(ENV, "PV_SCALE", "1.0")),
        conditional_stage=parse(Int, get(ENV, "CONDITIONAL_STAGE", "2")),
        fairness_mmr=parse(Float64, get(ENV, "FAIRNESS_MMR", "1.2")),
        fairness_abs_tol=parse(Float64, get(ENV, "FAIRNESS_ABS_TOL", "0.0")),
        lex_eps_abs=parse(Float64, get(ENV, "LEX_EPS_ABS", string(TOL))),
        out_csv=get(ENV, "OUT_CSV", "../results_models/conditional_fairness_report.csv"),
        out_csv_house=get(ENV, "OUT_CSV_HOUSE", "../results_models/conditional_fairness_report_by_house.csv"),
        out_csv_diagnostics=get(ENV, "OUT_CSV_DIAGNOSTICS", "../results_models/conditional_fairness_diagnostics.csv"),
    )
end
