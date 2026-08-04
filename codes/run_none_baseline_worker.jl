if !isdefined(@__MODULE__, :comparison_summary_row)
    include("fairness_comparison_metrics.jl")
end

function run_none_baseline_worker(;
    manifest_path::String,
    comparison_dir::String,
    cplex_threads::Int=1,
)
    verify_cplex_thread_limit(cplex_threads)
    manifest = comparison_read_manifest(manifest_path)
    baseline_dir = joinpath(comparison_dir, "baseline")
    mkpath(baseline_dir)
    summary_path = joinpath(baseline_dir, "summary.csv")
    house_path = joinpath(baseline_dir, "by_house.csv")
    failures_path = joinpath(baseline_dir, "failures.csv")
    summary = comparison_load_csv(summary_path)
    houses = comparison_load_csv(house_path)
    failures = comparison_load_failures(failures_path)
    failures_this_run = 0

    for config in eachrow(manifest)
        config_id = String(config.ConfigID)
        inst = comparison_instance(config)
        if comparison_run_complete(summary, houses, DataFrame(), inst, config_id, "NONE", missing)
            println("SKIP NONE $config_id: resultado completo.")
            failures = comparison_without_combo(failures, config_id, "NONE", missing)
            continue
        end

        summary = comparison_without_combo(summary, config_id, "NONE", missing)
        houses = comparison_without_combo(houses, config_id, "NONE", missing)
        failures = comparison_without_combo(failures, config_id, "NONE", missing)
        println("RUN NONE $config_id ($(config.TreeSpec), $(config.InstanceFile))")
        try
            solution = solveMulti(inst, "NONE")
            solution.status || error("NONE terminó sin solución primal.")
            expected_cost = sum(solution.costs)
            summary_row = comparison_summary_row(
                inst, config, "NONE", missing, solution, nothing, expected_cost,
            )
            house_rows = comparison_house_rows(inst, config, "NONE", missing, solution)
            append!(summary, DataFrame([summary_row]); cols=:union)
            append!(houses, DataFrame(house_rows); cols=:union)
            comparison_atomic_write(summary_path, summary)
            comparison_atomic_write(house_path, houses)
            comparison_atomic_write(failures_path, failures)
        catch err
            failures_this_run += 1
            push!(failures, (
                ConfigID=config_id, Fairness="NONE", ConditionalStage=missing,
                ErrorType=string(typeof(err)), ErrorMessage=sprint(showerror, err),
                Timestamp=string(now()),
            ))
            comparison_atomic_write(failures_path, failures)
            println(stderr, "FAIL NONE $config_id: ", sprint(showerror, err))
        end
    end
    comparison_atomic_write(failures_path, failures)
    failures_this_run == 0 || error("NONE registró $failures_this_run fallos.")
    println("NONE completado: $(nrow(summary)) filas de resumen.")
    return summary, houses
end

if abspath(PROGRAM_FILE) == @__FILE__
    run_none_baseline_worker(
        manifest_path=get(ENV, "MANIFEST_PATH", "../results_models/fairness_comparison/config_manifest.csv"),
        comparison_dir=get(ENV, "FAIRNESS_COMPARISON_DIR", "../results_models/fairness_comparison"),
        cplex_threads=parse(Int, get(ENV, "CPLEX_THREADS", "1")),
    )
end
