if !isdefined(@__MODULE__, :comparison_summary_row)
    include("fairness_comparison_metrics.jl")
end

using SHA
using Test

const COMPARISON_VALIDATION_ATOL = 1e-6

function _validation_key(row)
    stage = ismissing(row.ConditionalStage) ? 0 : Int(row.ConditionalStage)
    return (String(row.ConfigID), String(row.Fairness), stage)
end

function _validation_keys(df::DataFrame)
    return Set(_validation_key(row) for row in eachrow(df))
end

function _validation_append_csv_union!(destination::DataFrame, path::String)
    source = comparison_load_csv(path)
    nrow(source) > 0 && append!(destination, source; cols=:union)
    return destination
end

function _validation_hashes(path::String)
    result = Dict{String,String}()
    for line in eachline(path)
        parts = split(strip(line))
        length(parts) == 2 || error("Hash inválido: $line")
        result[parts[2]] = parts[1]
    end
    return result
end

_validation_sha(path::String) = bytes2hex(sha256(read(path)))

function _validation_expected_pv(inst::InstanceM, sol::SolutionM)
    probs = scenario_probabilities(inst.tree)
    return Float64[
        sum(
            probs[s_idx] * inst.delta * sum(sol.p[j,n] for n in scenario)
            for (s_idx, scenario) in enumerate(inst.tree.scenarios)
        )
        for j in 1:inst.J
    ]
end

function _validation_expected_grid(inst::InstanceM)
    probs = scenario_probabilities(inst.tree)
    time_periods = createTime(inst.tree)
    return Float64[
        sum(
            probs[s_idx] * inst.delta *
            sum(inst.nu[j,time_periods[n]] * inst.d[j,n] for n in scenario)
            for (s_idx, scenario) in enumerate(inst.tree.scenarios)
        )
        for j in 1:inst.J
    ]
end

function _validation_legacy_pea_levels(inst::InstanceM)
    persistent = build_lex_pea_model(inst)
    levels = zeros(inst.J)
    for k in 1:inst.J
        @objective(
            persistent.model,
            Max,
            k * persistent.zeta[k] - sum(persistent.daux[k,j] for j in 1:inst.J),
        )
        optimize!(persistent.model)
        has_values(persistent.model) || error("LEXMMFPEA legado falló en el nivel $k.")
        levels[k] = objective_value(persistent.model)
        @constraint(
            persistent.model,
            k * persistent.zeta[k] - sum(persistent.daux[k,j] for j in 1:inst.J) >=
                levels[k] - TOL,
        )
    end
    return levels
end

function _validation_legacy_sa_levels(inst::InstanceM)
    persistent = build_lex_sa_model(inst)
    levels = zeros(inst.J)
    for k in 1:inst.J
        @objective(
            persistent.model,
            Max,
            k * persistent.zeta[k] - sum(persistent.d[k,j] for j in 1:inst.J),
        )
        optimize!(persistent.model)
        has_values(persistent.model) || error("LEXMMFSA legado falló en el nivel $k.")
        levels[k] = objective_value(persistent.model)
        @constraint(
            persistent.model,
            k * persistent.zeta[k] - sum(persistent.d[k,j] for j in 1:inst.J) >=
                levels[k] - TOL,
        )
    end
    return levels
end

function _validate_stage_one_equivalence(config)
    inst = comparison_instance(config)
    pea, _ = solveMulti(inst, "PEA")
    cpea, cpea_diag = solveMulti(inst, "CPEA"; conditional_stage=1, fairness_abs_tol=0.0)
    @test pea.status && cpea.status
    @test isapprox(sum(pea.costs), sum(cpea.costs); atol=COMPARISON_VALIDATION_ATOL, rtol=1e-6)
    @test cpea_diag.max_abs_gap <= COMPARISON_VALIDATION_ATOL

    sa, _ = solveMulti(inst, "SA"; sa_fairness_abs_tol=0.0)
    csa, csa_diag = solveMulti(inst, "CSA"; conditional_stage=1, fairness_abs_tol=0.0)
    @test sa.status && csa.status
    @test isapprox(sum(sa.costs), sum(csa.costs); atol=COMPARISON_VALIDATION_ATOL, rtol=1e-6)
    @test csa_diag.max_abs_gap <= COMPARISON_VALIDATION_ATOL

    legacy_pea, _ = solveMulti(inst, "LEXMMFPEA")
    legacy_pea_levels = _validation_legacy_pea_levels(inst)
    clex_pea, clex_pea_diag = solveMulti(
        inst, "CLEXMMFPEA"; conditional_stage=1, lex_eps_abs=TOL,
    )
    @test legacy_pea.status && clex_pea.status
    @test all(isapprox.(clex_pea_diag.omega, legacy_pea_levels; atol=COMPARISON_VALIDATION_ATOL, rtol=1e-6))

    legacy_sa = solveMulti(inst, "LEXMMFSA")
    legacy_sa_levels = _validation_legacy_sa_levels(inst)
    clex_sa, clex_sa_diag = solveMulti(
        inst, "CLEXMMFSA"; conditional_stage=1, lex_eps_abs=TOL,
    )
    @test legacy_sa.status && clex_sa.status
    @test all(isapprox.(clex_sa_diag.omega, legacy_sa_levels; atol=COMPARISON_VALIDATION_ATOL, rtol=1e-6))
    return nothing
end

function validate_fairness_comparison(;
    manifest_path::String,
    comparison_dir::String,
    conditional_stages::Vector{Int},
    instances_per_tree::Int,
    validation_mode::String="main",
    reference_hashes_path::String,
    validate_stage_one::Bool=true,
)
    manifest = comparison_read_manifest(manifest_path)
    summary = comparison_load_csv(joinpath(comparison_dir, "consolidated", "all_fairness_summary.csv"))
    houses = comparison_load_csv(joinpath(comparison_dir, "consolidated", "all_fairness_by_house.csv"))
    conditional = comparison_load_csv(joinpath(comparison_dir, "consolidated", "all_conditional_by_node.csv"))
    execution = comparison_load_csv(joinpath(comparison_dir, "consolidated", "execution_status.csv"))
    failed = comparison_load_csv(joinpath(comparison_dir, "failed_runs.csv"))
    tree_specs = sort(unique(String.(manifest.TreeSpec)))

    @testset "Manifest" begin
        if validation_mode == "main"
            @test tree_specs == ["2:2:12", "6:4:4"]
            @test nrow(manifest) == 10
        end
        @test length(unique(manifest.ConfigID)) == nrow(manifest)
        @test all(count(==(tree), manifest.TreeSpec) == instances_per_tree for tree in tree_specs)
        file_sets = [Set(String.(manifest[manifest.TreeSpec .== tree, :InstanceFile])) for tree in tree_specs]
        @test all(files == first(file_sets) for files in file_sets)
        @test length(first(file_sets)) == instances_per_tree
        @test all(manifest.Scenarios .== manifest.Childs .^ (manifest.NBstage .- 1))
    end

    @testset "Per-policy counts and manifest use" begin
        manifest_ids = Set(String.(manifest.ConfigID))
        baseline = summary[summary.Fairness .== "NONE", :]
        @test nrow(baseline) == nrow(manifest)
        @test Set(String.(baseline.ConfigID)) == manifest_ids
        for policy in FAIRNESS_COMPARISON_NONCONDITIONAL
            rows = summary[summary.Fairness .== policy, :]
            @test nrow(rows) == nrow(manifest)
            @test Set(String.(rows.ConfigID)) == manifest_ids
            @test all(ismissing, rows.ConditionalStage)
        end
        for policy in FAIRNESS_COMPARISON_CONDITIONAL
            rows = summary[summary.Fairness .== policy, :]
            expected = sum(
                count(stage -> 1 <= stage <= Int(config.NBstage), conditional_stages)
                for config in eachrow(manifest)
            )
            @test nrow(rows) == expected
            if validation_mode == "main"
                @test nrow(rows[rows.TreeSpec .== "2:2:12", :]) == 5
                @test nrow(rows[rows.TreeSpec .== "6:4:4", :]) == 25
                @test expected == 30
            end
        end
    end

    @testset "No duplicates and completeness" begin
        @test length(_validation_keys(summary)) == nrow(summary)
        house_keys = Set(
            (_validation_key(row)..., Int(row.House)) for row in eachrow(houses)
        )
        node_keys = Set(
            (_validation_key(row)..., Int(row.Node), Int(row.House)) for row in eachrow(conditional)
        )
        @test length(house_keys) == nrow(houses)
        @test length(node_keys) == nrow(conditional)
        @test all(summary.Status .=== true)
        @test all(execution.Complete .=== true)
        @test nrow(failed) == 0
    end

    @testset "Conditional probabilities" begin
        checked = Set{Tuple{String,Int}}()
        for config in eachrow(manifest), stage in conditional_stages
            1 <= stage <= Int(config.NBstage) || continue
            key = (String(config.TreeSpec), stage)
            key in checked && continue
            tree = buildTree(Int(config.NBstage), Int(config.Childs), Int(config.Periods))
            for node in stage_entry_nodes(tree, stage)
                @test isapprox(
                    sum(last(pair) for pair in conditional_scenario_probabilities(tree, node)),
                    1.0; atol=1e-8, rtol=0.0,
                )
            end
            push!(checked, key)
        end
    end

    @testset "Fairness residuals" begin
        for row in eachrow(summary)
            policy = String(row.Fairness)
            ismissing(row.FairnessResidualMax) && continue
            tolerance = policy == "SA" ? TOL + COMPARISON_VALIDATION_ATOL : COMPARISON_VALIDATION_ATOL
            @test Float64(row.FairnessResidualMax) <= tolerance
            if policy == "STATIC_DEMAND_SHARE"
                @test Float64(row.MaxShareSumResidual) <= 1e-8
                @test Float64(row.MaxAcrossNodeShareResidual) <= 1e-8
                @test Float64(row.MaxPVAllocationResidual) <= 1e-8
            elseif policy in ("CPEA", "CSA")
                @test Float64(row.ConditionalGapMax) <= COMPARISON_VALIDATION_ATOL
                @test Float64(row.WorstNodeGap) <= COMPARISON_VALIDATION_ATOL
            end
        end
    end

    @testset "Consolidated unions" begin
        source_summary = DataFrame()
        source_houses = DataFrame()
        source_conditional = DataFrame()
        _validation_append_csv_union!(source_summary, joinpath(comparison_dir, "baseline", "summary.csv"))
        _validation_append_csv_union!(source_houses, joinpath(comparison_dir, "baseline", "by_house.csv"))
        for policy in FAIRNESS_COMPARISON_POLICIES
            directory = joinpath(comparison_dir, "by_policy", policy)
            _validation_append_csv_union!(source_summary, joinpath(directory, "summary.csv"))
            _validation_append_csv_union!(source_houses, joinpath(directory, "by_house.csv"))
            comparison_is_conditional(policy) && _validation_append_csv_union!(
                source_conditional, joinpath(directory, "conditional_by_node.csv"),
            )
        end
        @test isequal(source_summary, summary)
        @test isequal(source_houses, houses)
        @test isequal(source_conditional, conditional)
        if validation_mode == "main"
            @test nrow(summary) == 240
        end
    end

    @testset "Historical source hashes" begin
        root = normpath(joinpath(@__DIR__, ".."))
        for (path, expected) in _validation_hashes(reference_hashes_path)
            @test _validation_sha(joinpath(root, path)) == expected
        end
    end

    if validate_stage_one
        @testset "Conditional stage 1 equivalence" begin
            _validate_stage_one_equivalence(first(eachrow(manifest)))
        end
    end
    println("Validación comparativa completada: $(nrow(summary)) ejecuciones externas.")
    return true
end

if abspath(PROGRAM_FILE) == @__FILE__
    validate_fairness_comparison(
        manifest_path=get(ENV, "MANIFEST_PATH", "../results_models/fairness_comparison/config_manifest.csv"),
        comparison_dir=get(ENV, "FAIRNESS_COMPARISON_DIR", "../results_models/fairness_comparison"),
        conditional_stages=comparison_parse_int_list(get(ENV, "CONDITIONAL_STAGE_SET", "2,3,4,5,6")),
        instances_per_tree=parse(Int, get(ENV, "INSTANCES_PER_TREE", "5")),
        validation_mode=get(ENV, "VALIDATION_MODE", "main"),
        reference_hashes_path=get(
            ENV, "REFERENCE_HASHES_PATH",
            "../results_models/fairness_comparison/source_hashes_before.txt",
        ),
        validate_stage_one=lowercase(get(ENV, "VALIDATE_STAGE1_EQUIVALENCE", "true")) == "true",
    )
end
