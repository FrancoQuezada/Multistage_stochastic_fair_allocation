include("multi.jl")

using Serialization

const LEGACY_LABELS = ["NONE", "PEA", "SA", "LEXMMFPEA", "LEXMMFSA"]

function _legacy_solution(inst::InstanceM, label::String)
    result = solveMulti(inst, label)
    return result isa Tuple ? result[1] : result
end

function _legacy_snapshot(inst::InstanceM, label::String)
    solution = _legacy_solution(inst, label)
    probabilities = scenario_probabilities(inst.tree)
    time_periods = createTime(inst.tree)
    expected_grid = [
        sum(
            probabilities[s_idx] *
            sum(inst.delta * inst.nu[j,time_periods[n]] * inst.d[j,n] for n in scenario)
            for (s_idx, scenario) in enumerate(inst.tree.scenarios)
        )
        for j in 1:inst.J
    ]
    expected_pv = [
        sum(
            probabilities[s_idx] * inst.delta * sum(solution.p[j,n] for n in scenario)
            for (s_idx, scenario) in enumerate(inst.tree.scenarios)
        )
        for j in 1:inst.J
    ]
    outcomes = label == "LEXMMFPEA" ? expected_pv :
        (label == "LEXMMFSA" ? expected_grid .- solution.costs : Float64[])
    return (
        status=solution.status,
        expected_cost=sum(solution.costs),
        costs=copy(solution.costs),
        s=copy(solution.s), I=copy(solution.I), G=copy(solution.G),
        z=copy(solution.z), y=copy(solution.y), p=copy(solution.p),
        sizes=(
            s=size(solution.s), I=size(solution.I), G=size(solution.G),
            z=size(solution.z), y=size(solution.y), p=size(solution.p),
            costs=size(solution.costs),
        ),
        lex_levels=isempty(outcomes) ? Float64[] : cumsum(sort(outcomes)),
    )
end

function capture_legacy_baseline(path::String)
    inst = generateInstance(3, 2, 8, 5, "inst/inst2020/Drahi_1.csv", 0.2, 100.0, 10.0)
    baseline = Dict(label => _legacy_snapshot(inst, label) for label in LEGACY_LABELS)
    mkpath(dirname(abspath(path)))
    open(path, "w") do io
        serialize(io, baseline)
    end
    return baseline
end

if abspath(PROGRAM_FILE) == @__FILE__
    path = get(
        ENV, "BASELINE_PATH",
        "../results_models/conditional_fairness_validation/legacy_baseline.bin",
    )
    baseline = capture_legacy_baseline(path)
    for label in LEGACY_LABELS
        snap = baseline[label]
        println(
            label, " status=", snap.status,
            " expected_cost=", repr(snap.expected_cost),
            " lex_levels=", repr(snap.lex_levels),
        )
    end
end
