include("multi.jl")
include("structures_deterministic.jl")
include("two_stage_none.jl")

using CSV
using DataFrames

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

function solve_vss_none_instance(inst::InstanceM)
    rp_sol = solveMulti(inst, "NONE")
    rp_cost = sum(rp_sol.costs)

    det_policy_cost, lambda_det = solve!(inst, "")
    det_eval_sol = solveMulti(inst, "NONE", lambda_det, true)
    det_eval_cost = sum(det_eval_sol.costs)

    inst2 = multistage_to_twostage(inst)
    ts_sol = twoS_none(inst2)
    ts_policy_cost = sum(ts_sol.costs)
    ts_eval_sol = solveMulti(inst, "NONE", ts_sol.lambda, true)
    ts_eval_cost = sum(ts_eval_sol.costs)

    ws_cost, ws_wall_time = solve_wait_and_see_none(inst)
    evpi_abs = isfinite(ws_cost) && isfinite(rp_cost) ? rp_cost - ws_cost : missing
    evpi_pct = (!isfinite(ws_cost) || !isfinite(rp_cost)) ? missing : (rp_cost - ws_cost) / max(abs(rp_cost), TOL)

    return (
        Fairness = "NONE",
        RPStatus = rp_sol.status,
        RPCost = rp_cost,
        RPModelSolveTimeSec = rp_sol.time,
        RPRunTimeSec = rp_sol.run_time,
        DeterministicPolicyCost = det_policy_cost,
        DeterministicEEVCost = det_eval_cost,
        VSSvsDetAbs = isfinite(det_eval_cost) && isfinite(rp_cost) ? det_eval_cost - rp_cost : missing,
        VSSvsDetPct = safe_rel_gap(det_eval_cost, rp_cost),
        TwoStagePolicyCost = ts_policy_cost,
        TwoStageEEVCost = ts_eval_cost,
        VSSvsTwoStageAbs = isfinite(ts_eval_cost) && isfinite(rp_cost) ? ts_eval_cost - rp_cost : missing,
        VSSvsTwoStagePct = safe_rel_gap(ts_eval_cost, rp_cost),
        WaitAndSeeExpectedCost = ws_cost,
        WaitAndSeeWallTimeSec = ws_wall_time,
        EVPIAbs = evpi_abs,
        EVPIPct = evpi_pct,
    )
end

function run_vss_none_report(; inst_folder::String="inst/inst2020", instance_from::Int=1, instance_to::Int=10, NBstage::Int=6, childs::Int=6, periods::Int=4, J::Int=5, theta::Float64=0.2, avg_d::Float64=100.0, dev_d::Float64=10.0, demand_profile::String="mixed", battery_scale::Float64=1.0, pv_scale::Float64=1.0)
    isdir(inst_folder) || error("No existe el directorio de instancias: $inst_folder")
    files = natural_instance_sort(readdir(inst_folder))
    isempty(files) && error("No se encontraron archivos en: $inst_folder")

    from = max(1, instance_from)
    to = min(length(files), instance_to)
    from <= to || error("Rango de instancias invalido: [$instance_from,$instance_to]")

    rows = NamedTuple[]
    scen_count = length(buildTree(NBstage, childs, periods).scenarios)
    for (offset, file) in enumerate(files[from:to])
        instance_no = from + offset - 1
        inFile = joinpath(inst_folder, file)
        inst = generateInstance(NBstage, childs, periods, J, inFile, theta, avg_d, dev_d; pv_scale=pv_scale, demand_profile=demand_profile)
        scaleInstance!(inst; battery_scale=battery_scale)
        println("VSS/EVPI NONE -> file=", file, ", S=", NBstage, ", C=", childs, ", P=", periods, ", J=", J, ", theta=", theta)
        row = solve_vss_none_instance(inst)
        push!(rows, (
            InstanceNo = instance_no,
            InstanceFile = file,
            NBstage = NBstage,
            Childs = childs,
            Periods = periods,
            Scenarios = scen_count,
            Theta = theta,
            Avg_d = avg_d,
            Dev_d = dev_d,
            J = J,
            DemandProfile = demand_profile,
            BatteryScale = battery_scale,
            PVScale = pv_scale,
            InstFolder = inst_folder,
            Fairness = row.Fairness,
            RPStatus = row.RPStatus,
            RPCost = row.RPCost,
            RPModelSolveTimeSec = row.RPModelSolveTimeSec,
            RPRunTimeSec = row.RPRunTimeSec,
            DeterministicPolicyCost = row.DeterministicPolicyCost,
            DeterministicEEVCost = row.DeterministicEEVCost,
            VSSvsDetAbs = row.VSSvsDetAbs,
            VSSvsDetPct = row.VSSvsDetPct,
            TwoStagePolicyCost = row.TwoStagePolicyCost,
            TwoStageEEVCost = row.TwoStageEEVCost,
            VSSvsTwoStageAbs = row.VSSvsTwoStageAbs,
            VSSvsTwoStagePct = row.VSSvsTwoStagePct,
            WaitAndSeeExpectedCost = row.WaitAndSeeExpectedCost,
            WaitAndSeeWallTimeSec = row.WaitAndSeeWallTimeSec,
            EVPIAbs = row.EVPIAbs,
            EVPIPct = row.EVPIPct,
        ))
    end

    df = DataFrame(rows)
    if "Scenarios" in names(df)
        rename!(df, "Scenarios" => "#scen")
    end
    return df
end
