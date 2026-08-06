include("multi.jl")

using Serialization
using SHA
using Test

const STATIC_VALIDATION_TOL = 1e-8
const STATIC_REGRESSION_RTOL = 1e-6
const STATIC_EXISTING_LABELS = [
    "NONE", "PEA", "SA", "LEXMMFPEA", "LEXMMFSA",
    "ERDINC_PSR", "ERDINC_ESR", "ERDINC_PESR",
    "ERDINC_PC", "ERDINC_EC", "ERDINC_PEC",
    "CPEA", "CSA", "CLEXMMFPEA", "CLEXMMFSA",
]

function _solve_static_validation_existing(inst::InstanceM, label::String)
    result = if label in ("CPEA", "CSA")
        solveMulti(inst, label; conditional_stage=2, fairness_abs_tol=0.0)
    elseif label in ("CLEXMMFPEA", "CLEXMMFSA")
        solveMulti(inst, label; conditional_stage=2, lex_eps_abs=TOL)
    elseif startswith(label, "ERDINC_")
        solveMulti(inst, label; fairness_mmr=1.2)
    else
        solveMulti(inst, label)
    end
    return result isa Tuple ? result[1] : result
end

function _static_validation_snapshot(inst::InstanceM, label::String)
    sol = _solve_static_validation_existing(inst, label)
    return (
        status=sol.status,
        expected_cost=sum(sol.costs),
        costs=copy(sol.costs), s=copy(sol.s), I=copy(sol.I), G=copy(sol.G),
        battery_mode=copy(sol.battery_mode),
        z=copy(sol.z), y=copy(sol.y), p=copy(sol.p),
        sizes=(
            s=size(sol.s), I=size(sol.I), G=size(sol.G), battery_mode=size(sol.battery_mode), z=size(sol.z),
            y=size(sol.y), p=size(sol.p), costs=size(sol.costs),
        ),
    )
end

function _static_componentwise_regression_ok(after, before)
    size(after) == size(before) || return false
    return all(
        abs(a - b) <= STATIC_REGRESSION_RTOL * max(1.0, abs(b))
        for (a, b) in zip(after, before)
    )
end

function _static_solution_reproducible(first::SolutionM, second::SolutionM)
    first.status == second.status || return false
    for field in (:costs, :s, :I, :G, :battery_mode, :z, :y, :p)
        a = getproperty(first, field)
        b = getproperty(second, field)
        size(a) == size(b) || return false
        all(abs(x - y) <= STATIC_VALIDATION_TOL for (x, y) in zip(a, b)) || return false
    end
    return true
end

function _max_operational_residual(inst::InstanceM, sol::SolutionM)
    tree = inst.tree
    time_periods = createTime(tree)
    residual = 0.0
    for n in 1:tree.V
        residual = max(residual, abs(sum(sol.p[j,n] for j in 1:inst.J) - inst.c_pv[n]))
        residual = max(residual, max(0.0, sum(sol.y[j,n] for j in 1:inst.J) - inst.f_bar))
        residual = max(residual, max(0.0, sum(sol.z[j,n] for j in 1:inst.J) - inst.f_under))
        residual = max(residual, abs(sol.battery_mode[n] - round(sol.battery_mode[n])))
        residual = max(residual, sol.battery_mode[n] >= 0.5 ?
            sum(sol.y[j,n] for j in 1:inst.J) : sum(sol.z[j,n] for j in 1:inst.J))
        residual = max(residual, max(0.0, sol.s[n] - inst.s_max))
        residual = max(residual, max(0.0, inst.s_min - sol.s[n]))
        for j in 1:inst.J
            balance = sol.p[j,n] + sol.y[j,n] + sol.I[j,n] - sol.z[j,n] - sol.G[j,n]
            residual = max(residual, abs(inst.d[j,n] - balance))
        end
        if time_periods[n] == inst.T
            residual = max(residual, abs(sol.s[n] - inst.s_I))
        end
    end
    initial_soc = inst.s_I +
        inst.delta * inst.e_c * sum(sol.z[j,1] for j in 1:inst.J) -
        inst.delta * sum(sol.y[j,1] for j in 1:inst.J) / inst.e_d
    residual = max(residual, abs(sol.s[1] - initial_soc))
    for n in 2:tree.V
        expected_soc = sol.s[tree.parents[n]] +
            inst.delta * inst.e_c * sum(sol.z[j,n] for j in 1:inst.J) -
            inst.delta * sum(sol.y[j,n] for j in 1:inst.J) / inst.e_d
        residual = max(residual, abs(sol.s[n] - expected_soc))
    end
    recomputed_cost = inst.delta * sum(
        tree.rho[n] *
        (inst.mu * sol.y[j,n] + inst.nu[j,time_periods[n]] * sol.I[j,n] - inst.beta * sol.G[j,n])
        for j in 1:inst.J, n in 1:tree.V
    )
    residual = max(residual, abs(sum(sol.costs) - recomputed_cost))
    return residual
end

function _read_expected_hashes(path::String)
    hashes = Dict{String,String}()
    for line in eachline(path)
        parts = split(strip(line))
        length(parts) == 2 || error("Línea de hash inválida: $line")
        hashes[parts[2]] = parts[1]
    end
    return hashes
end

_file_sha256(path::String) = bytes2hex(sha256(read(path)))

function validate_static_demand_share(;
    baseline_path::String,
    unrelated_hashes_path::String,
    after_path::String,
)
    isfile(baseline_path) || error("No existe la referencia previa: $baseline_path")
    isfile(unrelated_hashes_path) || error("No existe el archivo de hashes: $unrelated_hashes_path")

    baseline = open(deserialize, baseline_path)
    inst = generateInstance(3, 2, 8, 5, "inst/inst2020/Drahi_1.csv", 0.2, 100.0, 10.0)
    time_periods = createTime(inst.tree)
    expected = static_expected_demands(inst)
    shares = static_demand_shares(inst)

    @testset "Static expected demands and shares" begin
        @test size(expected) == (inst.J, inst.T)
        @test size(shares) == (inst.J, inst.T)
        for t in 1:inst.T
            nodes = Int[n for n in 1:inst.tree.V if time_periods[n] == t]
            probability_mass = sum(inst.tree.rho[n] for n in nodes)
            @test isapprox(sum(shares[:,t]), 1.0; atol=STATIC_VALIDATION_TOL, rtol=0.0)
            for j in 1:inst.J
                manual_expected =
                    sum(inst.tree.rho[n] * inst.d[j,n] for n in nodes) / probability_mass
                @test isapprox(expected[j,t], manual_expected; atol=STATIC_VALIDATION_TOL, rtol=0.0)
                @test all(shares[j,time_periods[n]] == shares[j,t] for n in nodes)
            end
        end
    end

    first = solveMulti(inst, "STATIC_DEMAND_SHARE")
    first_diagnostics = static_demand_share_diagnostics(inst, first)
    second = solveMulti(inst, "STATIC_DEMAND_SHARE")

    @testset "Static policy feasibility and diagnostics" begin
        @test first isa SolutionM
        @test first.status
        @test first_diagnostics.ExpectedDemandByHousePeriod == expected
        @test first_diagnostics.StaticShareByHousePeriod == shares
        @test first_diagnostics.MaxShareSumResidual <= STATIC_VALIDATION_TOL
        @test first_diagnostics.MaxAcrossNodeShareResidual <= STATIC_VALIDATION_TOL
        @test first_diagnostics.MaxPVAllocationResidual <= STATIC_VALIDATION_TOL
        @test _max_operational_residual(inst, first) <= STATIC_VALIDATION_TOL
        for n in 1:inst.tree.V, j in 1:inst.J
            if inst.c_pv[n] > 0
                @test isapprox(
                    first.p[j,n] / inst.c_pv[n], shares[j,time_periods[n]];
                    atol=STATIC_VALIDATION_TOL, rtol=0.0,
                )
            else
                @test abs(first.p[j,n]) <= STATIC_VALIDATION_TOL
            end
        end
    end

    @testset "Same operational formulation as NONE" begin
        none = solveMulti(inst, "NONE")
        @test none.status
        @test size(first.s) == size(none.s)
        @test size(first.I) == size(none.I)
        @test size(first.G) == size(none.G)
        @test size(first.battery_mode) == size(none.battery_mode) == (inst.tree.V,)
        @test size(first.z) == size(none.z)
        @test size(first.y) == size(none.y)
        @test size(first.p) == size(none.p)
        @test _max_operational_residual(inst, none) <= STATIC_VALIDATION_TOL
        @test _max_operational_residual(inst, first) <= STATIC_VALIDATION_TOL
    end

    @testset "Instance seed stability" begin
        repeated = generateInstance(3, 2, 8, 5, "inst/inst2020/Drahi_1.csv", 0.2, 100.0, 10.0)
        @test repeated.c_pv == inst.c_pv
        @test repeated.d == inst.d
        @test repeated.nu == inst.nu
        @test repeated.pv_det == inst.pv_det
        @test repeated.d_det == inst.d_det
    end

    @testset "Static policy reproducibility" begin
        @test _static_solution_reproducible(first, second)
        second_diagnostics = static_demand_share_diagnostics(inst, second)
        for field in (
            :ExpectedDemandByHousePeriod, :StaticShareByHousePeriod,
            :MaxShareSumResidual, :MaxAcrossNodeShareResidual,
            :MaxPVAllocationResidual, :ExpectedCost,
        )
            @test getproperty(first_diagnostics, field) == getproperty(second_diagnostics, field)
        end
    end

    after = Dict(label => _static_validation_snapshot(inst, label) for label in STATIC_EXISTING_LABELS)
    mkpath(dirname(abspath(after_path)))
    open(after_path, "w") do io
        serialize(io, after)
    end
    @testset "All existing policies use the corrected shared battery" begin
        for label in STATIC_EXISTING_LABELS
            current = after[label]
            @test current.status
            @test isfinite(current.expected_cost)
            @test current.sizes.battery_mode == (inst.tree.V,)
            violations = shared_battery_violations(
                current.battery_mode, current.y, current.z;
                discharge_limit=inst.f_bar,
                charge_limit=inst.f_under,
            )
            @test violations.simultaneous_flow == 0.0
            @test violations.mode_violation == 0.0
            @test violations.rate_violation == 0.0
        end
    end

    expected_hashes = _read_expected_hashes(unrelated_hashes_path)
    repo_root = normpath(joinpath(@__DIR__, ".."))
    intentionally_modified = Set([
        "codes/structuresMulti.jl",
        "codes/mmf_sa.jl",
        "codes/conditional_fairness.jl",
        "codes/validate_conditional_fairness.jl",
    ])
    @testset "Unrelated file hashes" begin
        for (relative_path, expected_hash) in expected_hashes
            relative_path in intentionally_modified && continue
            absolute_path = joinpath(repo_root, relative_path)
            @test isfile(absolute_path)
            @test _file_sha256(absolute_path) == expected_hash
        end
    end
    return true
end

if abspath(PROGRAM_FILE) == @__FILE__
    validate_static_demand_share(
        baseline_path=get(
            ENV, "BASELINE_PATH",
            "../results_models/static_demand_share_validation/existing_policies_before.bin",
        ),
        unrelated_hashes_path=get(
            ENV, "UNRELATED_HASHES_PATH",
            "../results_models/static_demand_share_validation/unrelated_hashes_before.txt",
        ),
        after_path=get(
            ENV, "AFTER_PATH",
            "../results_models/static_demand_share_validation/existing_policies_after.bin",
        ),
    )
end
