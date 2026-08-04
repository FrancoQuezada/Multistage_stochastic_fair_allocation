if !isdefined(@__MODULE__, :comparison_summary_row)
    include("fairness_comparison_metrics.jl")
end

function _baseline_costs_by_config(path::String)
    baseline = comparison_load_csv(path)
    nrow(baseline) > 0 || error("El baseline NONE está vacío: $path")
    costs = Dict{String,Float64}()
    for row in eachrow(baseline)
        String(row.Fairness) == "NONE" || continue
        row.Status === true || continue
        config_id = String(row.ConfigID)
        haskey(costs, config_id) && error("Baseline duplicado para $config_id.")
        costs[config_id] = Float64(row.ExpectedCost)
    end
    return costs
end

function run_fairness_policy_worker(
    policy::String;
    manifest_path::String,
    comparison_dir::String,
    conditional_stages::Vector{Int}=[2,3,4,5,6],
    fairness_mmr::Float64=1.2,
    lex_eps_abs::Float64=TOL,
    cplex_threads::Int=1,
)
    policy in FAIRNESS_COMPARISON_POLICIES || error("Política inválida: $policy")
    verify_cplex_thread_limit(cplex_threads)
    manifest = comparison_read_manifest(manifest_path)
    baseline_costs = _baseline_costs_by_config(joinpath(comparison_dir, "baseline", "summary.csv"))
    policy_dir = joinpath(comparison_dir, "by_policy", policy)
    mkpath(policy_dir)
    summary_path = joinpath(policy_dir, "summary.csv")
    house_path = joinpath(policy_dir, "by_house.csv")
    conditional_path = joinpath(policy_dir, "conditional_by_node.csv")
    failures_path = joinpath(policy_dir, "failures.csv")
    summary = comparison_load_csv(summary_path)
    houses = comparison_load_csv(house_path)
    conditional = comparison_is_conditional(policy) ? comparison_load_csv(conditional_path) : DataFrame()
    failures = comparison_load_failures(failures_path)
    failures_this_run = 0

    for config in eachrow(manifest)
        config_id = String(config.ConfigID)
        haskey(baseline_costs, config_id) || error("Falta NONE para ConfigID=$config_id.")
        inst = comparison_instance(config)
        stages = if comparison_is_conditional(policy)
            valid = sort(unique(stage for stage in conditional_stages if 1 <= stage <= Int(config.NBstage)))
            isempty(valid) && error("No hay etapas condicionales válidas para $config_id y $policy.")
            valid
        else
            Union{Missing,Int}[missing]
        end

        for stage in stages
            if comparison_run_complete(summary, houses, conditional, inst, config_id, policy, stage)
                println("SKIP $policy $config_id stage=$stage: resultado completo.")
                failures = comparison_without_combo(failures, config_id, policy, stage)
                continue
            end

            summary = comparison_without_combo(summary, config_id, policy, stage)
            houses = comparison_without_combo(houses, config_id, policy, stage)
            if comparison_is_conditional(policy)
                conditional = comparison_without_combo(conditional, config_id, policy, stage)
            end
            failures = comparison_without_combo(failures, config_id, policy, stage)
            println("RUN $policy $config_id stage=$stage ($(config.TreeSpec), $(config.InstanceFile))")
            try
                solution, diagnostics = solve_comparison_policy(
                    inst, policy;
                    conditional_stage=stage,
                    fairness_mmr=fairness_mmr,
                    lex_eps_abs=lex_eps_abs,
                )
                solution.status || error("$policy terminó sin solución primal.")
                summary_row = comparison_summary_row(
                    inst, config, policy, stage, solution, diagnostics,
                    baseline_costs[config_id];
                    fairness_mmr=fairness_mmr, lex_eps_abs=lex_eps_abs,
                )
                house_rows = comparison_house_rows(inst, config, policy, stage, solution)
                append!(summary, DataFrame([summary_row]); cols=:union)
                append!(houses, DataFrame(house_rows); cols=:union)
                if comparison_is_conditional(policy)
                    node_rows = comparison_conditional_rows(
                        inst, config, policy, Int(stage), solution, diagnostics,
                    )
                    append!(conditional, DataFrame(node_rows); cols=:union)
                end
                comparison_atomic_write(summary_path, summary)
                comparison_atomic_write(house_path, houses)
                comparison_is_conditional(policy) && comparison_atomic_write(conditional_path, conditional)
                comparison_atomic_write(failures_path, failures)
            catch err
                failures_this_run += 1
                push!(failures, (
                    ConfigID=config_id, Fairness=policy, ConditionalStage=stage,
                    ErrorType=string(typeof(err)), ErrorMessage=sprint(showerror, err),
                    Timestamp=string(now()),
                ))
                comparison_atomic_write(failures_path, failures)
                println(stderr, "FAIL $policy $config_id stage=$stage: ", sprint(showerror, err))
            end
        end
    end

    comparison_atomic_write(failures_path, failures)
    failures_this_run == 0 || error("$policy registró $failures_this_run fallos.")
    println("$policy completado: $(nrow(summary)) filas de resumen.")
    return summary, houses, conditional
end

if abspath(PROGRAM_FILE) == @__FILE__
    policy = get(ENV, "POLICY", "")
    isempty(policy) && error("Define POLICY.")
    run_fairness_policy_worker(
        policy;
        manifest_path=get(ENV, "MANIFEST_PATH", "../results_models/fairness_comparison/config_manifest.csv"),
        comparison_dir=get(ENV, "FAIRNESS_COMPARISON_DIR", "../results_models/fairness_comparison"),
        conditional_stages=comparison_parse_int_list(get(ENV, "CONDITIONAL_STAGE_SET", "2,3,4,5,6")),
        fairness_mmr=parse(Float64, get(ENV, "FAIRNESS_MMR", "1.2")),
        lex_eps_abs=parse(Float64, get(ENV, "LEX_EPS_ABS", string(TOL))),
        cplex_threads=parse(Int, get(ENV, "CPLEX_THREADS", "1")),
    )
end
