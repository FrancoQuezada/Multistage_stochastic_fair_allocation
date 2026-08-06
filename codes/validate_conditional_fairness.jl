include("multi.jl")

using Serialization
using Test

const VALIDATION_LEGACY_LABELS = ["NONE", "PEA", "SA", "LEXMMFPEA", "LEXMMFSA"]
const REGRESSION_RTOL = 1e-6
const NUMERICAL_ATOL = 1e-6

function _validation_solution(inst::InstanceM, label::String; kwargs...)
    result = solveMulti(inst, label; kwargs...)
    return result isa Tuple ? result[1] : result
end

function _validation_expected_pv(inst::InstanceM, solution::SolutionM)
    probabilities = scenario_probabilities(inst.tree)
    return [
        sum(
            probabilities[s_idx] * inst.delta * sum(solution.p[j,n] for n in scenario)
            for (s_idx, scenario) in enumerate(inst.tree.scenarios)
        )
        for j in 1:inst.J
    ]
end

function _validation_expected_grid(inst::InstanceM)
    probabilities = scenario_probabilities(inst.tree)
    time_periods = createTime(inst.tree)
    return [
        sum(
            probabilities[s_idx] *
            sum(inst.delta * inst.nu[j,time_periods[n]] * inst.d[j,n] for n in scenario)
            for (s_idx, scenario) in enumerate(inst.tree.scenarios)
        )
        for j in 1:inst.J
    ]
end

function _validation_snapshot(inst::InstanceM, label::String)
    solution = _validation_solution(inst, label)
    expected_pv = _validation_expected_pv(inst, solution)
    outcomes = label == "LEXMMFPEA" ? expected_pv :
        (label == "LEXMMFSA" ? _validation_expected_grid(inst) .- solution.costs : Float64[])
    return (
        status=solution.status,
        expected_cost=sum(solution.costs),
        costs=copy(solution.costs),
        s=copy(solution.s), I=copy(solution.I), G=copy(solution.G),
        battery_mode=copy(solution.battery_mode),
        z=copy(solution.z), y=copy(solution.y), p=copy(solution.p),
        sizes=(
            s=size(solution.s), I=size(solution.I), G=size(solution.G),
            battery_mode=size(solution.battery_mode),
            z=size(solution.z), y=size(solution.y), p=size(solution.p),
            costs=size(solution.costs),
        ),
        lex_levels=isempty(outcomes) ? Float64[] : cumsum(sort(outcomes)),
    )
end

function _componentwise_regression_ok(after, before)
    size(after) == size(before) || return false
    return all(
        abs(a - b) <= REGRESSION_RTOL * max(1.0, abs(b))
        for (a, b) in zip(after, before)
    )
end

function validate_conditional_fairness(; baseline_path::String)
    isfile(baseline_path) || error(
        "No existe la referencia pre-implementación: $baseline_path. " *
        "Ejecuta primero capture_legacy_baseline.jl sobre la revisión de referencia."
    )
    baseline = open(deserialize, baseline_path)
    inst = generateInstance(3, 2, 8, 5, "inst/inst2020/Drahi_1.csv", 0.2, 100.0, 10.0)
    expected_grid = _validation_expected_grid(inst)

    @testset "Conditional probabilities" begin
        for stage in 1:inst.tree.S
            for node in stage_entry_nodes(inst.tree, stage)
                conditional = conditional_scenario_probabilities(inst.tree, node)
                @test !isempty(conditional)
                @test isapprox(sum(last(pair) for pair in conditional), 1.0; atol=1e-8, rtol=0.0)
            end
        end
    end

    @testset "Root proportional equivalence" begin
        pea, _ = solveMulti(inst, "PEA")
        cpea, cpea_diag = solveMulti(
            inst, "CPEA"; conditional_stage=1, fairness_abs_tol=0.0,
        )
        @test pea.status == cpea.status == true
        @test isapprox(sum(cpea.costs), sum(pea.costs); atol=NUMERICAL_ATOL, rtol=REGRESSION_RTOL)
        @test _componentwise_regression_ok(cpea_diag.actual[:,1], _validation_expected_pv(inst, pea))
        @test cpea_diag.max_abs_gap <= NUMERICAL_ATOL

        sa, _ = solveMulti(inst, "SA"; sa_fairness_abs_tol=0.0)
        csa, csa_diag = solveMulti(
            inst, "CSA"; conditional_stage=1, fairness_abs_tol=0.0,
        )
        @test sa.status == csa.status == true
        @test isapprox(sum(csa.costs), sum(sa.costs); atol=NUMERICAL_ATOL, rtol=REGRESSION_RTOL)
        @test _componentwise_regression_ok(csa_diag.actual[:,1], expected_grid .- sa.costs)
        @test csa_diag.max_abs_gap <= NUMERICAL_ATOL
    end

    @testset "Root lexicographic-level equivalence" begin
        legacy_pea, _ = solveMulti(inst, "LEXMMFPEA")
        legacy_pea_levels = cumsum(sort(_validation_expected_pv(inst, legacy_pea)))
        conditional_pea, conditional_pea_diag = solveMulti(
            inst, "CLEXMMFPEA"; conditional_stage=1, lex_eps_abs=TOL,
        )
        @test conditional_pea.status
        @test _componentwise_regression_ok(conditional_pea_diag.omega, legacy_pea_levels)
        @test conditional_pea_diag.max_lex_violation <= TOL + NUMERICAL_ATOL

        legacy_sa = solveMulti(inst, "LEXMMFSA")
        legacy_sa_levels = cumsum(sort(expected_grid .- legacy_sa.costs))
        conditional_sa, conditional_sa_diag = solveMulti(
            inst, "CLEXMMFSA"; conditional_stage=1, lex_eps_abs=TOL,
        )
        @test conditional_sa.status
        @test all(
            abs(conditional_sa_diag.omega[k] - legacy_sa_levels[k]) <= TOL + NUMERICAL_ATOL
            for k in eachindex(legacy_sa_levels)
        )
        @test conditional_sa_diag.max_lex_violation <= TOL + NUMERICAL_ATOL
    end

    @testset "Erdinc MMR rules" begin
        for label in sort(collect(keys(ERDINC_LABEL_TO_METRIC)))
            solution, diagnostics = solveMulti(inst, label; fairness_mmr=1.2)
            @test solution.status
            @test diagnostics.achieved_max <=
                diagnostics.fairness_mmr * diagnostics.achieved_min + NUMERICAL_ATOL
            @test diagnostics.mmr_abs_violation <= NUMERICAL_ATOL

            equal_solution, equal_diagnostics = solveMulti(inst, label; fairness_mmr=1.0)
            @test equal_solution.status
            @test equal_diagnostics.achieved_max - equal_diagnostics.achieved_min <=
                NUMERICAL_ATOL
        end
    end

    @testset "Conditional proportional equations" begin
        for stage in 2:inst.tree.S
            for label in ("CPEA", "CSA")
                solution, diagnostics = solveMulti(
                    inst, label; conditional_stage=stage, fairness_abs_tol=0.0,
                )
                @test solution.status
                @test diagnostics.nodes == stage_entry_nodes(inst.tree, stage)
                @test diagnostics.max_abs_gap <= NUMERICAL_ATOL
                @test maximum(abs.(diagnostics.gap)) <= NUMERICAL_ATOL
            end
        end
    end

    @testset "Weighted conditional lexicographic levels" begin
        for stage in 2:inst.tree.S
            for label in ("CLEXMMFPEA", "CLEXMMFSA")
                solution, diagnostics = solveMulti(
                    inst, label; conditional_stage=stage, lex_eps_abs=TOL,
                )
                @test solution.status
                @test diagnostics.nodes == stage_entry_nodes(inst.tree, stage)
                @test isapprox(sum(diagnostics.node_probabilities), 1.0; atol=1e-8, rtol=0.0)
                @test diagnostics.max_lex_violation <= TOL + NUMERICAL_ATOL
                @test all(
                    diagnostics.achieved_levels[k] >= diagnostics.omega[k] - TOL - NUMERICAL_ATOL
                    for k in 1:inst.J
                )
            end
        end
    end

    @testset "Corrected shared-battery operational structure" begin
        for label in VALIDATION_LEGACY_LABELS
            after = _validation_snapshot(inst, label)
            @test after.status
            @test isfinite(after.expected_cost)
            @test after.sizes.battery_mode == (inst.tree.V,)
            violations = shared_battery_violations(
                after.battery_mode, after.y, after.z;
                discharge_limit=inst.f_bar,
                charge_limit=inst.f_under,
            )
            @test violations.simultaneous_flow == 0.0
            @test violations.mode_violation == 0.0
            @test violations.rate_violation == 0.0
        end
    end
    return true
end

if abspath(PROGRAM_FILE) == @__FILE__
    baseline_path = get(
        ENV, "BASELINE_PATH",
        "../results_models/conditional_fairness_validation/baseline_before.bin",
    )
    validate_conditional_fairness(; baseline_path=baseline_path)
end
