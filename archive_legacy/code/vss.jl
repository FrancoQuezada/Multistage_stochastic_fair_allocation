include("multi.jl")
include("stochastic.jl")

using CSV
using DataFrames

function normalize_fairness_name(fairness::String)
    fair = uppercase(strip(fairness))
    fair == "" && return "NONE"
    fair == "PAE" && return "PEA"
    fair == "PSA" && return "SA"
    return fair
end

function deterministic_solver_name(fairness::String)
    fair = normalize_fairness_name(fairness)
    if fair == "NONE"
        return ""
    elseif fair == "PEA"
        return "Proportional PEA"
    elseif fair == "SA"
        return "Proportional SA"
    elseif fair in ("LEXMMFPEA", "MMFPEA", "EMMFPEA")
        return "MMF PEA"
    end
    return nothing
end

function twostage_solver_name(fairness::String)
    fair = normalize_fairness_name(fairness)
    if fair == "NONE"
        return ""
    elseif fair == "PEA"
        return "aggregated PEA"
    elseif fair == "SA"
        return "aggregated SA"
    end
    return nothing
end

function natural_instance_sort(files::Vector{String})
    function file_key(file::String)
        m = match(r"(\d+)", file)
        return m === nothing ? (typemax(Int), file) : (parse(Int, m.captures[1]), file)
    end
    return sort(files; by=file_key)
end

function multistage_to_twostage(inst::InstanceM)
    inst2 = Instance()
    inst2.J = inst.J
    inst2.T = inst.T
    inst2.Omega = length(inst.tree.scenarios)
    inst2.s_max = inst.s_max
    inst2.s_min = inst.s_min
    inst2.delta = inst.delta
    inst2.e_c = inst.e_c
    inst2.e_d = inst.e_d
    inst2.s_I = inst.s_I
    inst2.f_under = inst.f_under
    inst2.f_bar = inst.f_bar
    inst2.mu = inst.mu
    inst2.beta = inst.beta
    inst2.nu = copy(inst.nu)
    inst2.pv_det = copy(inst.pv_det)
    inst2.d_det = copy(inst.d_det)
    inst2.id = inst.id * "_2S"
    inst2.timeStamp = [string(t) for t in 1:inst.T]

    scen_count = inst2.Omega
    inst2.c_pv = zeros(inst.T, scen_count)
    inst2.d = zeros(inst.J, inst.T, scen_count)
    inst2.rho = zeros(scen_count)

    timePeriods = createTime(inst.tree)
    for (s_idx, scenario) in enumerate(inst.tree.scenarios)
        for n in scenario
            t = timePeriods[n]
            inst2.c_pv[t, s_idx] = inst.c_pv[n]
            for j in 1:inst.J
                inst2.d[j, t, s_idx] = inst.d[j, n]
            end
        end
        inst2.rho[s_idx] = inst.tree.rho[scenario[1]]
    end

    return inst2
end

function scenario_to_deterministic_instance(inst::InstanceM, scenario::Vector{Int})
    timePeriods = createTime(inst.tree)
    det = Instance()
    det.J = inst.J
    det.T = inst.T
    det.Omega = 1
    det.s_max = inst.s_max
    det.s_min = inst.s_min
    det.delta = inst.delta
    det.e_c = inst.e_c
    det.e_d = inst.e_d
    det.s_I = inst.s_I
    det.f_under = inst.f_under
    det.f_bar = inst.f_bar
    det.mu = inst.mu
    det.beta = inst.beta
    det.nu = copy(inst.nu)
    det.rho = [1.0]
    det.id = inst.id * "_WS"
    det.timeStamp = [string(t) for t in 1:inst.T]

    det.pv_det = zeros(inst.T)
    det.d_det = zeros(inst.J, inst.T)
    det.c_pv = zeros(inst.T, 1)
    det.d = zeros(inst.J, inst.T, 1)

    for n in scenario
        t = timePeriods[n]
        det.pv_det[t] = inst.c_pv[n]
        det.c_pv[t, 1] = inst.c_pv[n]
        for j in 1:inst.J
            det.d_det[j, t] = inst.d[j, n]
            det.d[j, t, 1] = inst.d[j, n]
        end
    end

    return det
end

function solve_multistage_policy(inst::InstanceM, fairness::String; lambdaS=zeros(inst.J, inst.T), EEV::Bool=false, sa_fairness_abs_tol::Float64=TOL)
    result =
        if EEV
            solveMulti(inst, fairness, lambdaS, true; sa_fairness_abs_tol=sa_fairness_abs_tol)
        else
            solveMulti(inst, fairness; sa_fairness_abs_tol=sa_fairness_abs_tol)
        end
    return result isa Tuple ? result[1] : result
end

function safe_rel_gap(benchmark_cost, rp_cost)
    if !isfinite(benchmark_cost) || !isfinite(rp_cost)
        return missing
    end
    denom = abs(rp_cost) > TOL ? rp_cost : TOL
    return (benchmark_cost - rp_cost) / denom
end

function solve_wait_and_see_none(inst::InstanceM)
    probs = _scenario_probabilities(inst)
    ws_cost = 0.0
    ws_wall_time = 0.0
    for (s_idx, scenario) in enumerate(inst.tree.scenarios)
        det_inst = scenario_to_deterministic_instance(inst, scenario)
        t0 = time()
        det_cost, _ = solve!(det_inst, "")
        ws_wall_time += time() - t0
        ws_cost += probs[s_idx] * det_cost
    end
    return ws_cost, round(ws_wall_time, digits=2)
end

function solve_vss_instance(inst::InstanceM, fairness::String; sa_fairness_abs_tol::Float64=TOL)
    fair = normalize_fairness_name(fairness)
    rp_sol = solve_multistage_policy(inst, fair; sa_fairness_abs_tol=sa_fairness_abs_tol)
    rp_cost = sum(rp_sol.costs)

    det_solver = deterministic_solver_name(fair)
    det_policy_cost = missing
    det_eval_cost = missing
    det_vss_abs = missing
    det_vss_pct = missing
    det_supported = det_solver !== nothing

    if det_supported
        det_policy_cost, lambda_det = solve!(inst, det_solver)
        det_eval_sol = solve_multistage_policy(inst, fair; lambdaS=lambda_det, EEV=true, sa_fairness_abs_tol=sa_fairness_abs_tol)
        det_eval_cost = sum(det_eval_sol.costs)
        det_vss_abs = isfinite(det_eval_cost) && isfinite(rp_cost) ? det_eval_cost - rp_cost : missing
        det_vss_pct = safe_rel_gap(det_eval_cost, rp_cost)
    end

    ts_solver = twostage_solver_name(fair)
    ts_policy_cost = missing
    ts_eval_cost = missing
    ts_vss_abs = missing
    ts_vss_pct = missing
    ts_supported = ts_solver !== nothing

    if ts_supported
        inst2 = multistage_to_twostage(inst)
        ts_sol = twoS(inst2, ts_solver)
        ts_policy_cost = sum(ts_sol.costs)
        ts_eval_sol = solve_multistage_policy(inst, fair; lambdaS=ts_sol.lambda, EEV=true, sa_fairness_abs_tol=sa_fairness_abs_tol)
        ts_eval_cost = sum(ts_eval_sol.costs)
        ts_vss_abs = isfinite(ts_eval_cost) && isfinite(rp_cost) ? ts_eval_cost - rp_cost : missing
        ts_vss_pct = safe_rel_gap(ts_eval_cost, rp_cost)
    end

    return (
        Fairness=fair,
        RPStatus=rp_sol.status,
        RPCost=rp_cost,
        RPModelSolveTimeSec=rp_sol.time,
        DeterministicSupported=det_supported,
        DeterministicPolicyCost=det_policy_cost,
        DeterministicEEVCost=det_eval_cost,
        VSSvsDetAbs=det_vss_abs,
        VSSvsDetPct=det_vss_pct,
        TwoStageSupported=ts_supported,
        TwoStagePolicyCost=ts_policy_cost,
        TwoStageEEVCost=ts_eval_cost,
        VSSvsTwoStageAbs=ts_vss_abs,
        VSSvsTwoStagePct=ts_vss_pct
    )
end

function solve_vss_none_instance(inst::InstanceM)
    fair = "NONE"
    rp_sol = solve_multistage_policy(inst, fair)
    rp_cost = sum(rp_sol.costs)

    det_policy_cost, lambda_det = solve!(inst, "")
    det_eval_sol = solve_multistage_policy(inst, fair; lambdaS=lambda_det, EEV=true)
    det_eval_cost = sum(det_eval_sol.costs)

    inst2 = multistage_to_twostage(inst)
    ts_sol = twoS(inst2, "")
    ts_policy_cost = sum(ts_sol.costs)
    ts_eval_sol = solve_multistage_policy(inst, fair; lambdaS=ts_sol.lambda, EEV=true)
    ts_eval_cost = sum(ts_eval_sol.costs)

    ws_cost, ws_wall_time = solve_wait_and_see_none(inst)
    evpi_abs = isfinite(ws_cost) && isfinite(rp_cost) ? rp_cost - ws_cost : missing
    evpi_pct =
        if !isfinite(ws_cost) || !isfinite(rp_cost)
            missing
        else
            denom = abs(rp_cost) > TOL ? rp_cost : TOL
            (rp_cost - ws_cost) / denom
        end

    return (
        Fairness=fair,
        RPStatus=rp_sol.status,
        RPCost=rp_cost,
        RPModelSolveTimeSec=rp_sol.time,
        DeterministicPolicyCost=det_policy_cost,
        DeterministicEEVCost=det_eval_cost,
        VSSvsDetAbs=isfinite(det_eval_cost) && isfinite(rp_cost) ? det_eval_cost - rp_cost : missing,
        VSSvsDetPct=safe_rel_gap(det_eval_cost, rp_cost),
        TwoStagePolicyCost=ts_policy_cost,
        TwoStageEEVCost=ts_eval_cost,
        VSSvsTwoStageAbs=isfinite(ts_eval_cost) && isfinite(rp_cost) ? ts_eval_cost - rp_cost : missing,
        VSSvsTwoStagePct=safe_rel_gap(ts_eval_cost, rp_cost),
        WaitAndSeeExpectedCost=ws_cost,
        WaitAndSeeWallTimeSec=ws_wall_time,
        EVPIAbs=evpi_abs,
        EVPIPct=evpi_pct
    )
end

function run_vss_report(;
    inst_folder::String="inst/inst2020",
    instance_from::Int64=1,
    instance_to::Int64=10,
    NBstage::Int64=6,
    childs::Int64=2,
    periods::Int64=4,
    J::Int64=5,
    theta::Float64=0.2,
    avg_d::Float64=100.0,
    dev_d::Float64=10.0,
    sa_fairness_abs_tol::Float64=TOL,
    fairness_list::Vector{String}=["NONE", "PEA", "SA", "LEXMMFPEA", "LEXMMFSA"],
    out_csv::String="vss_report.csv"
)
    if !isdir(inst_folder)
        error("No existe el directorio de instancias: $inst_folder")
    end

    files = natural_instance_sort(readdir(inst_folder))
    isempty(files) && error("No se encontraron archivos en: $inst_folder")

    from = max(1, instance_from)
    to = min(length(files), instance_to)
    from > to && error("Rango de instancias invalido: [$instance_from,$instance_to]")

    df = DataFrame()
    df[!, "InstanceNo"] = Int64[]
    df[!, "InstanceFile"] = String[]
    df[!, "NBstage"] = Int64[]
    df[!, "Childs"] = Int64[]
    df[!, "Periods"] = Int64[]
    df[!, "Theta"] = Float64[]
    df[!, "Avg_d"] = Float64[]
    df[!, "Dev_d"] = Float64[]
    df[!, "J"] = Int64[]
    df[!, "Fairness"] = String[]
    df[!, "RPStatus"] = Bool[]
    df[!, "RPCost"] = Float64[]
    df[!, "RPModelSolveTimeSec"] = Float64[]
    df[!, "DeterministicSupported"] = Bool[]
    df[!, "DeterministicPolicyCost"] = Union{Missing, Float64}[]
    df[!, "DeterministicEEVCost"] = Union{Missing, Float64}[]
    df[!, "VSSvsDetAbs"] = Union{Missing, Float64}[]
    df[!, "VSSvsDetPct"] = Union{Missing, Float64}[]
    df[!, "TwoStageSupported"] = Bool[]
    df[!, "TwoStagePolicyCost"] = Union{Missing, Float64}[]
    df[!, "TwoStageEEVCost"] = Union{Missing, Float64}[]
    df[!, "VSSvsTwoStageAbs"] = Union{Missing, Float64}[]
    df[!, "VSSvsTwoStagePct"] = Union{Missing, Float64}[]

    for (offset, file) in enumerate(files[from:to])
        instance_no = from + offset - 1
        inFile = joinpath(inst_folder, file)
        inst = generateInstance(NBstage, childs, periods, J, inFile, theta, avg_d, dev_d)
        for fairness in fairness_list
            println("VSS -> file=", file, ", fairness=", fairness, ", S=", NBstage, ", C=", childs, ", P=", periods)
            row = solve_vss_instance(inst, fairness; sa_fairness_abs_tol=sa_fairness_abs_tol)
            push!(df, (
                instance_no,
                file,
                NBstage,
                childs,
                periods,
                theta,
                avg_d,
                dev_d,
                J,
                row.Fairness,
                row.RPStatus,
                row.RPCost,
                row.RPModelSolveTimeSec,
                row.DeterministicSupported,
                row.DeterministicPolicyCost,
                row.DeterministicEEVCost,
                row.VSSvsDetAbs,
                row.VSSvsDetPct,
                row.TwoStageSupported,
                row.TwoStagePolicyCost,
                row.TwoStageEEVCost,
                row.VSSvsTwoStageAbs,
                row.VSSvsTwoStagePct
            ))
            CSV.write(out_csv, df)
        end
    end

    return df
end

function run_vss_none_report(;
    inst_folder::String="inst/inst2020",
    instance_from::Int64=1,
    instance_to::Int64=10,
    NBstage::Int64=6,
    childs::Int64=2,
    periods::Int64=4,
    J::Int64=5,
    theta::Float64=0.2,
    avg_d::Float64=100.0,
    dev_d::Float64=10.0,
    out_csv::String="vss_none_report.csv"
)
    if !isdir(inst_folder)
        error("No existe el directorio de instancias: $inst_folder")
    end

    files = natural_instance_sort(readdir(inst_folder))
    isempty(files) && error("No se encontraron archivos en: $inst_folder")

    from = max(1, instance_from)
    to = min(length(files), instance_to)
    from > to && error("Rango de instancias invalido: [$instance_from,$instance_to]")

    df = DataFrame()
    df[!, "InstanceNo"] = Int64[]
    df[!, "InstanceFile"] = String[]
    df[!, "NBstage"] = Int64[]
    df[!, "Childs"] = Int64[]
    df[!, "Periods"] = Int64[]
    df[!, "Theta"] = Float64[]
    df[!, "Avg_d"] = Float64[]
    df[!, "Dev_d"] = Float64[]
    df[!, "J"] = Int64[]
    df[!, "Fairness"] = String[]
    df[!, "RPStatus"] = Bool[]
    df[!, "RPCost"] = Float64[]
    df[!, "RPModelSolveTimeSec"] = Float64[]
    df[!, "DeterministicPolicyCost"] = Float64[]
    df[!, "DeterministicEEVCost"] = Float64[]
    df[!, "VSSvsDetAbs"] = Float64[]
    df[!, "VSSvsDetPct"] = Float64[]
    df[!, "TwoStagePolicyCost"] = Float64[]
    df[!, "TwoStageEEVCost"] = Float64[]
    df[!, "VSSvsTwoStageAbs"] = Float64[]
    df[!, "VSSvsTwoStagePct"] = Float64[]
    df[!, "WaitAndSeeExpectedCost"] = Float64[]
    df[!, "WaitAndSeeWallTimeSec"] = Float64[]
    df[!, "EVPIAbs"] = Float64[]
    df[!, "EVPIPct"] = Float64[]

    for (offset, file) in enumerate(files[from:to])
        instance_no = from + offset - 1
        inFile = joinpath(inst_folder, file)
        inst = generateInstance(NBstage, childs, periods, J, inFile, theta, avg_d, dev_d)
        println("VSS/EVPI NONE -> file=", file, ", S=", NBstage, ", C=", childs, ", P=", periods, ", J=", J, ", theta=", theta)
        row = solve_vss_none_instance(inst)
        push!(df, (
            instance_no,
            file,
            NBstage,
            childs,
            periods,
            theta,
            avg_d,
            dev_d,
            J,
            row.Fairness,
            row.RPStatus,
            row.RPCost,
            row.RPModelSolveTimeSec,
            row.DeterministicPolicyCost,
            row.DeterministicEEVCost,
            row.VSSvsDetAbs,
            row.VSSvsDetPct,
            row.TwoStagePolicyCost,
            row.TwoStageEEVCost,
            row.VSSvsTwoStageAbs,
            row.VSSvsTwoStagePct,
            row.WaitAndSeeExpectedCost,
            row.WaitAndSeeWallTimeSec,
            row.EVPIAbs,
            row.EVPIPct
        ))
        CSV.write(out_csv, df)
    end

    return df
end
