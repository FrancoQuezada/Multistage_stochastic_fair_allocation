include("heuristics_constructive.jl")
using DataFrames
using CSV
using Dates

split_nonempty(s, sep) = [x for x in split(s, sep) if !isempty(strip(x))]
parse_int_list(s) = [parse(Int, strip(x)) for x in split_nonempty(s, ",")]
parse_float_list(s) = [parse(Float64, strip(x)) for x in split_nonempty(s, ",")]
parse_string_list(s) = [String(strip(x)) for x in split_nonempty(s, ",")]

function file_index(name::String)
    m = match(r"(\d+)", name)
    return m === nothing ? typemax(Int) : parse(Int, m.captures[1])
end

function _scenario_metrics(inst::InstanceM, sol::SolutionM, fairness::String)
    probs = _scenario_probabilities(inst)
    total_prob = max(sum(probs), TOL)

    if sol.status
        scenario_costs_house = _scenario_cost_matrix(inst, sol)
        scenario_pv_house = [sum(sol.p[j, n] for n in scenario) for j in 1:inst.J, scenario in inst.tree.scenarios]
        scenario_total = [sum(scenario_costs_house[:, s]) for s in 1:size(scenario_costs_house, 2)]
        scenario_expected = sum(probs[s] * scenario_total[s] for s in eachindex(scenario_total)) / total_prob
        reg = _regret_matrix(inst, sol, fairness)
        regret_expected = sum(probs[s] * sum(reg[:, s]) / inst.J for s in 1:size(reg, 2)) / total_prob
    else
        scenario_costs_house = fill(Inf, inst.J, length(inst.tree.scenarios))
        scenario_pv_house = fill(Inf, inst.J, length(inst.tree.scenarios))
        reg = fill(Inf, inst.J, length(inst.tree.scenarios))
        scenario_total = fill(Inf, length(inst.tree.scenarios))
        scenario_expected = Inf
        regret_expected = Inf
    end

    return (
        probs = probs,
        total_prob = total_prob,
        scenario_costs_house = scenario_costs_house,
        scenario_pv_house = scenario_pv_house,
        scenario_total = scenario_total,
        scenario_expected = scenario_expected,
        reg = reg,
        regret_expected = regret_expected
    )
end

function _expected_house_savings(inst::InstanceM, sol::SolutionM)
    return all_grid_expected_costs(inst) .- sol.costs
end

function run_constructive_heuristics_config_set(;
    inst_folder::String = "inst/inst2020",
    instance_from::Int64 = 1,
    instance_to::Int64 = 1,
    heuristic_set::Vector{String} = ["PEA"],
    tree_set::Vector{NamedTuple} = [(NBstage = 6, childs = 4, periods = 4)],
    J_set::Vector{Int64} = [5],
    theta_set::Vector{Float64} = [0.2],
    avg_d_set::Vector{Float64} = [100.0],
    dev_d_set::Vector{Float64} = [10.0],
    demand_profile_set::Vector{String} = ["mixed"],
    battery_scale_set::Vector{Float64} = [1.0],
    pv_scale_set::Vector{Float64} = [1.0],
    eta_set::Vector{Float64} = [1.0],
    out_csv::String = "constructive_heuristics_report.csv",
    out_csv_house::String = "constructive_heuristics_report_by_house.csv",
    out_csv_diag::String = "constructive_heuristics_report_diagnostics.csv",
    out_csv_diag_house::String = "constructive_heuristics_report_diagnostics_by_house.csv",
    append_each_config::Bool = true
)
    isdir(inst_folder) || error("No existe carpeta de instancias: $inst_folder")
    files = sort(readdir(inst_folder), by = f -> (replace(f, r"\d+" => ""), file_index(f), f))
    isempty(files) && error("No se encontraron archivos en: $inst_folder")

    from = max(1, instance_from)
    to = min(length(files), instance_to)
    from <= to || error("Rango inválido: [$instance_from,$instance_to] para $(length(files)) archivos")
    selected_files = files[from:to]

    df = DataFrame(
        :InstanceNo => Int64[],
        :InstanceFile => String[],
        :NBstage => Int64[],
        :Childs => Int64[],
        :Periods => Int64[],
        Symbol("#scen") => Int64[],
        :Theta => Float64[],
        :Avg_d => Float64[],
        :Dev_d => Float64[],
        :J => Int64[],
        :Fairness => String[],
        :InstFolder => String[],
        :Status => Bool[],
        :ExpectedCost => Float64[],
        :ScenarioCostExpected => Float64[],
        :ScenarioCostMin => Float64[],
        :ScenarioCostMax => Float64[],
        :RegretExpected => Float64[],
        :RegretMin => Float64[],
        :RegretMax => Float64[],
        :RunTimeSec => Float64[],
        :ModelSolveTimeSec => Float64[]
    )

    df_house = DataFrame(
        :InstanceNo => Int64[],
        :InstanceFile => String[],
        :NBstage => Int64[],
        :Childs => Int64[],
        :Periods => Int64[],
        Symbol("#scen") => Int64[],
        :Theta => Float64[],
        :Avg_d => Float64[],
        :Dev_d => Float64[],
        :J => Int64[],
        :Fairness => String[],
        :House => Int64[],
        :InstFolder => String[],
        :Status => Bool[],
        :PVReceivedExpected => Float64[],
        :PVReceivedMin => Float64[],
        :PVReceivedMax => Float64[],
        :CostExpected => Float64[],
        :CostMin => Float64[],
        :CostMax => Float64[],
        :RegretExpected => Float64[],
        :RegretMin => Float64[],
        :RegretMax => Float64[],
        :RunTimeSec => Float64[],
        :ModelSolveTimeSec => Float64[]
    )

    df_diag = DataFrame(
        :InstanceNo => Int64[],
        :InstanceFile => String[],
        :NBstage => Int64[],
        :Childs => Int64[],
        :Periods => Int64[],
        Symbol("#scen") => Int64[],
        :Theta => Float64[],
        :Avg_d => Float64[],
        :Dev_d => Float64[],
        :J => Int64[],
        :Fairness => String[],
        :InstFolder => String[],
        :Status => Bool[],
        :MeanAbsFairnessGap => Float64[],
        :MaxAbsFairnessGap => Float64[],
        :RunTimeSec => Float64[],
        :ModelSolveTimeSec => Float64[]
    )

    df_diag_house = DataFrame(
        :InstanceNo => Int64[],
        :InstanceFile => String[],
        :NBstage => Int64[],
        :Childs => Int64[],
        :Periods => Int64[],
        Symbol("#scen") => Int64[],
        :Theta => Float64[],
        :Avg_d => Float64[],
        :Dev_d => Float64[],
        :J => Int64[],
        :Fairness => String[],
        :House => Int64[],
        :InstFolder => String[],
        :Status => Bool[],
        :FairnessGap => Float64[],
        :AbsFairnessGap => Float64[],
        :RunTimeSec => Float64[],
        :ModelSolveTimeSec => Float64[]
    )

    run_id = Dates.format(now(), "yyyymmdd_HHMMSS")
    configs = NamedTuple[]
    for (local_idx, file) in enumerate(selected_files)
        global_idx = from + local_idx - 1
        inFile = joinpath(inst_folder, file)
        for heuristic in heuristic_set
            for tree in tree_set
                for J in J_set
                    for theta in theta_set
                        for avg_d in avg_d_set
                            for dev_d in dev_d_set
                                for demand_profile in demand_profile_set
                                    for battery_scale in battery_scale_set
                                        for pv_scale in pv_scale_set
                                            for eta in eta_set
                                                push!(configs, (
                                                    run_id = run_id,
                                                    instance_no = global_idx,
                                                    instance_file = file,
                                                    inFile = inFile,
                                                    heuristic = heuristic,
                                                    NBstage = tree.NBstage,
                                                    childs = tree.childs,
                                                    periods = tree.periods,
                                                    J = J,
                                                    theta = theta,
                                                    avg_d = avg_d,
                                                    dev_d = dev_d,
                                                    demand_profile = demand_profile,
                                                    battery_scale = battery_scale,
                                                    pv_scale = pv_scale,
                                                    eta = eta
                                                ))
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    println("Total configuraciones heuristicas a ejecutar: ", length(configs))

    for (cfg_idx, cfg) in enumerate(configs)
        println(
            "Running heuristic config ", cfg_idx, "/", length(configs),
            " -> (heuristic=", cfg.heuristic,
            ", file=", basename(cfg.inFile),
            ", S=", cfg.NBstage,
            ", C=", cfg.childs,
            ", P=", cfg.periods,
            ", J=", cfg.J,
            ", theta=", cfg.theta,
            ", demand_profile=", cfg.demand_profile,
            ", battery_scale=", cfg.battery_scale,
            ", pv_scale=", cfg.pv_scale,
            ", eta=", cfg.eta, ")"
        )

        inst = generateInstance(
            cfg.NBstage, cfg.childs, cfg.periods, cfg.J, cfg.inFile, cfg.theta, cfg.avg_d, cfg.dev_d;
            pv_scale = cfg.pv_scale,
            demand_profile = cfg.demand_profile
        )
        scaleInstance!(inst; battery_scale = cfg.battery_scale)

        result = solve_constructive_heuristic(inst, cfg.heuristic; eta = cfg.eta)

        heuristic_sol = result.heuristic_sol
        metrics = _scenario_metrics(inst, heuristic_sol, cfg.heuristic)
        probs = metrics.probs
        total_prob = metrics.total_prob
        fairness_gap = if cfg.heuristic in ("SA", "PSA", "ESA")
            result.diagnostics.heuristic_sa_gap
        elseif cfg.heuristic in ("PEA", "PAE", "PPEA", "EPPEA")
            result.diagnostics.actual_gap
        else
            fill(NaN, inst.J)
        end

        push!(df, (
            cfg.instance_no,
            cfg.instance_file,
            cfg.NBstage,
            cfg.childs,
            cfg.periods,
            length(inst.tree.scenarios),
            cfg.theta,
            cfg.avg_d,
            cfg.dev_d,
            cfg.J,
            cfg.heuristic,
            inst_folder,
            heuristic_sol.status,
            sum(heuristic_sol.costs),
            metrics.scenario_expected,
            minimum(metrics.scenario_total),
            maximum(metrics.scenario_total),
            metrics.regret_expected,
            minimum(metrics.reg),
            maximum(metrics.reg),
            result.total_run_time,
            result.total_model_solve_time
        ))

        push!(df_diag, (
            cfg.instance_no,
            cfg.instance_file,
            cfg.NBstage,
            cfg.childs,
            cfg.periods,
            length(inst.tree.scenarios),
            cfg.theta,
            cfg.avg_d,
            cfg.dev_d,
            cfg.J,
            cfg.heuristic,
            inst_folder,
            heuristic_sol.status,
            mean(abs.(fairness_gap)),
            maximum(abs.(fairness_gap)),
            result.total_run_time,
            result.total_model_solve_time
        ))

        for j in 1:inst.J
            pv_j = [metrics.scenario_pv_house[j, s] for s in 1:size(metrics.scenario_pv_house, 2)]
            cost_j = [metrics.scenario_costs_house[j, s] for s in 1:size(metrics.scenario_costs_house, 2)]
            reg_j = [metrics.reg[j, s] for s in 1:size(metrics.reg, 2)]
            pv_expected = sum(probs[s] * pv_j[s] for s in eachindex(pv_j)) / total_prob
            cost_expected = sum(probs[s] * cost_j[s] for s in eachindex(cost_j)) / total_prob
            reg_expected = sum(probs[s] * reg_j[s] for s in eachindex(reg_j)) / total_prob

            push!(df_house, (
                cfg.instance_no,
                cfg.instance_file,
                cfg.NBstage,
                cfg.childs,
                cfg.periods,
                length(inst.tree.scenarios),
                cfg.theta,
                cfg.avg_d,
                cfg.dev_d,
                cfg.J,
                cfg.heuristic,
                j,
                inst_folder,
                heuristic_sol.status,
                pv_expected,
                minimum(pv_j),
                maximum(pv_j),
                cost_expected,
                minimum(cost_j),
                maximum(cost_j),
                reg_expected,
                minimum(reg_j),
                maximum(reg_j),
                result.total_run_time,
                result.total_model_solve_time
            ))

            push!(df_diag_house, (
                cfg.instance_no,
                cfg.instance_file,
                cfg.NBstage,
                cfg.childs,
                cfg.periods,
                length(inst.tree.scenarios),
                cfg.theta,
                cfg.avg_d,
                cfg.dev_d,
                cfg.J,
                cfg.heuristic,
                j,
                inst_folder,
                heuristic_sol.status,
                fairness_gap[j],
                abs(fairness_gap[j]),
                result.total_run_time,
                result.total_model_solve_time
            ))
        end

        if append_each_config
            CSV.write(out_csv, df)
            CSV.write(out_csv_house, df_house)
            CSV.write(out_csv_diag, df_diag)
            CSV.write(out_csv_diag_house, df_diag_house)
        end
    end

    if !append_each_config
        CSV.write(out_csv, df)
        CSV.write(out_csv_house, df_house)
        CSV.write(out_csv_diag, df_diag)
        CSV.write(out_csv_diag_house, df_diag_house)
    end

    return df, df_house, df_diag, df_diag_house
end

if abspath(PROGRAM_FILE) == @__FILE__
    inst_folder = get(ENV, "INST_FOLDER", "inst/inst2020")
    instance_from = parse(Int, get(ENV, "INSTANCE_FROM", "1"))
    instance_to = parse(Int, get(ENV, "INSTANCE_TO", "1"))
    heuristic_set = parse_string_list(get(ENV, "HEURISTIC_SET", "PEA"))
    tree_specs = split_nonempty(get(ENV, "TREE_SET", "6:4:4"), ";")
    J_set = parse_int_list(get(ENV, "J_SET", "5"))
    theta_set = parse_float_list(get(ENV, "THETA_SET", "0.2"))
    avg_d_set = parse_float_list(get(ENV, "AVG_D_SET", "100.0"))
    dev_d_set = parse_float_list(get(ENV, "DEV_D_SET", "10.0"))
    demand_profile_set = parse_string_list(get(ENV, "DEMAND_PROFILE_SET", "mixed"))
    battery_scale_set = parse_float_list(get(ENV, "BATTERY_SCALE_SET", "1.0"))
    pv_scale_set = parse_float_list(get(ENV, "PV_SCALE_SET", "1.0"))
    eta_set = parse_float_list(get(ENV, "ETA_SET", "1.0"))
    out_csv = get(ENV, "OUT_CSV", "constructive_heuristics_report.csv")
    out_csv_house = get(ENV, "OUT_CSV_HOUSE", "constructive_heuristics_report_by_house.csv")
    out_csv_diag = get(ENV, "OUT_CSV_DIAG", "constructive_heuristics_report_diagnostics.csv")
    out_csv_diag_house = get(ENV, "OUT_CSV_DIAG_HOUSE", "constructive_heuristics_report_diagnostics_by_house.csv")

    tree_set = NamedTuple[]
    for spec in tree_specs
        parts = split(spec, ":")
        length(parts) == 3 || error("TREE_SET invalido en '$spec'. Usa NBstage:childs:periods")
        push!(tree_set, (
            NBstage = parse(Int, strip(parts[1])),
            childs = parse(Int, strip(parts[2])),
            periods = parse(Int, strip(parts[3]))
        ))
    end

    run_constructive_heuristics_config_set(
        inst_folder = inst_folder,
        instance_from = instance_from,
        instance_to = instance_to,
        heuristic_set = heuristic_set,
        tree_set = tree_set,
        J_set = J_set,
        theta_set = theta_set,
        avg_d_set = avg_d_set,
        dev_d_set = dev_d_set,
        demand_profile_set = demand_profile_set,
        battery_scale_set = battery_scale_set,
        pv_scale_set = pv_scale_set,
        eta_set = eta_set,
        out_csv = out_csv,
        out_csv_house = out_csv_house,
        out_csv_diag = out_csv_diag,
        out_csv_diag_house = out_csv_diag_house
    )
end
