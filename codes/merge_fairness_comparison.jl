if !isdefined(@__MODULE__, :comparison_summary_row)
    include("fairness_comparison_metrics.jl")
end

function _comparison_key(row)
    stage = ismissing(row.ConditionalStage) ? 0 : Int(row.ConditionalStage)
    return (String(row.ConfigID), String(row.Fairness), stage)
end

function _assert_unique_rows(df::DataFrame, key_function, label::String)
    keys = [key_function(row) for row in eachrow(df)]
    length(keys) == length(unique(keys)) || error("Hay duplicados en $label.")
    return nothing
end

function _append_csv_union!(destination::DataFrame, path::String)
    source = comparison_load_csv(path)
    nrow(source) > 0 && append!(destination, source; cols=:union)
    return destination
end

function _worker_exit_codes(comparison_dir::String)
    path = joinpath(comparison_dir, "worker_exit_status.csv")
    status = comparison_load_csv(path)
    codes = Dict{String,Int}()
    if nrow(status) > 0
        for row in eachrow(status)
            codes[String(row.Worker)] = Int(row.ExitCode)
        end
    end
    return codes
end

function merge_fairness_comparison(;
    manifest_path::String,
    comparison_dir::String,
    conditional_stages::Vector{Int}=[2,3,4,5,6],
)
    manifest = comparison_read_manifest(manifest_path)
    summary = DataFrame()
    houses = DataFrame()
    conditional = DataFrame()
    _append_csv_union!(summary, joinpath(comparison_dir, "baseline", "summary.csv"))
    _append_csv_union!(houses, joinpath(comparison_dir, "baseline", "by_house.csv"))
    for policy in FAIRNESS_COMPARISON_POLICIES
        policy_dir = joinpath(comparison_dir, "by_policy", policy)
        _append_csv_union!(summary, joinpath(policy_dir, "summary.csv"))
        _append_csv_union!(houses, joinpath(policy_dir, "by_house.csv"))
        if comparison_is_conditional(policy)
            _append_csv_union!(conditional, joinpath(policy_dir, "conditional_by_node.csv"))
        end
    end

    _assert_unique_rows(summary, _comparison_key, "all_fairness_summary")
    _assert_unique_rows(
        houses,
        row -> (_comparison_key(row)..., Int(row.House)),
        "all_fairness_by_house",
    )
    _assert_unique_rows(
        conditional,
        row -> (_comparison_key(row)..., Int(row.Node), Int(row.House)),
        "all_conditional_by_node",
    )

    exit_codes = _worker_exit_codes(comparison_dir)
    execution = DataFrame()
    failed = DataFrame(
        ConfigID=String[], Fairness=String[], ConditionalStage=Union{Missing,Int}[],
        FailureReason=String[], WorkerExitCode=Union{Missing,Int}[],
    )
    for config in eachrow(manifest)
        expected_runs = Tuple{String,Union{Missing,Int}}[("NONE", missing)]
        append!(expected_runs, [(policy, missing) for policy in FAIRNESS_COMPARISON_NONCONDITIONAL])
        for policy in FAIRNESS_COMPARISON_CONDITIONAL
            append!(expected_runs, [
                (policy, stage) for stage in sort(unique(conditional_stages))
                if 1 <= stage <= Int(config.NBstage)
            ])
        end
        for (policy, stage) in expected_runs
            mask = comparison_combo_mask(summary, String(config.ConfigID), policy, stage)
            present = count(mask) == 1
            status = present ? summary[findfirst(mask), :Status] : false
            house_count = count(comparison_combo_mask(
                houses, String(config.ConfigID), policy, stage,
            ))
            expected_house_count = Int(config.J)
            conditional_count = comparison_is_conditional(policy) ? count(comparison_combo_mask(
                conditional, String(config.ConfigID), policy, stage,
            )) : 0
            expected_conditional_count = if comparison_is_conditional(policy)
                tree = buildTree(Int(config.NBstage), Int(config.Childs), Int(config.Periods))
                length(stage_entry_nodes(tree, Int(stage))) * Int(config.J)
            else
                0
            end
            complete = present && status === true &&
                house_count == expected_house_count &&
                conditional_count == expected_conditional_count
            worker = policy == "NONE" ? "NONE" : policy
            exit_code = get(exit_codes, worker, missing)
            push!(execution, (
                ConfigID=String(config.ConfigID), Fairness=policy,
                ConditionalStage=stage, Present=present, Status=status,
                HouseRows=house_count, ExpectedHouseRows=expected_house_count,
                ConditionalRows=conditional_count,
                ExpectedConditionalRows=expected_conditional_count,
                Complete=complete, WorkerExitCode=exit_code,
            ); cols=:union)
            if !complete
                reason = !present ? "missing_summary" :
                    (status !== true ? "solver_status_false" : "incomplete_detail_rows")
                push!(failed, (
                    ConfigID=String(config.ConfigID), Fairness=policy,
                    ConditionalStage=stage, FailureReason=reason,
                    WorkerExitCode=exit_code,
                ))
            end
        end
    end

    for (worker, directory) in vcat(
        [("NONE", joinpath(comparison_dir, "baseline"))],
        [(policy, joinpath(comparison_dir, "by_policy", policy)) for policy in FAIRNESS_COMPARISON_POLICIES],
    )
        worker_failures = comparison_load_failures(joinpath(directory, "failures.csv"))
        for row in eachrow(worker_failures)
            push!(failed, (
                ConfigID=String(row.ConfigID), Fairness=String(row.Fairness),
                ConditionalStage=row.ConditionalStage,
                FailureReason=String(row.ErrorType) * ": " * String(row.ErrorMessage),
                WorkerExitCode=get(exit_codes, worker, missing),
            ))
        end
    end

    consolidated_dir = joinpath(comparison_dir, "consolidated")
    mkpath(consolidated_dir)
    comparison_atomic_write(joinpath(consolidated_dir, "all_fairness_summary.csv"), summary)
    comparison_atomic_write(joinpath(consolidated_dir, "all_fairness_by_house.csv"), houses)
    comparison_atomic_write(joinpath(consolidated_dir, "all_conditional_by_node.csv"), conditional)
    comparison_atomic_write(joinpath(consolidated_dir, "execution_status.csv"), execution)
    comparison_atomic_write(joinpath(comparison_dir, "failed_runs.csv"), failed)
    nrow(failed) == 0 || error("La consolidación detectó $(nrow(failed)) ejecuciones fallidas o incompletas.")
    println("Consolidación completa: $(nrow(summary)) resúmenes, $(nrow(houses)) filas por hogar.")
    return summary, houses, conditional, execution, failed
end

if abspath(PROGRAM_FILE) == @__FILE__
    merge_fairness_comparison(
        manifest_path=get(ENV, "MANIFEST_PATH", "../results_models/fairness_comparison/config_manifest.csv"),
        comparison_dir=get(ENV, "FAIRNESS_COMPARISON_DIR", "../results_models/fairness_comparison"),
        conditional_stages=comparison_parse_int_list(get(ENV, "CONDITIONAL_STAGE_SET", "2,3,4,5,6")),
    )
end
