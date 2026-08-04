include("multi.jl")

using CSV
using DataFrames
using Statistics

split_nonempty(s, sep) = [x for x in split(s, sep) if !isempty(strip(x))]
parse_int_list(s) = [parse(Int, strip(x)) for x in split_nonempty(s, ",")]
parse_float_list(s) = [parse(Float64, strip(x)) for x in split_nonempty(s, ",")]

function fairness_label(f::String)
    if f == "NONE"
        return "NF"
    elseif f == "LEXMMFPEA"
        return "MMPEA"
    elseif f == "LEXMMFSA"
        return "MMSA"
    end
    return f
end

function representative_house_metrics(;
    inFile::String,
    NBstage::Int64,
    childs::Int64,
    periods::Int64,
    J_set::Vector{Int64},
    theta_set::Vector{Float64},
    avg_d::Float64,
    dev_d::Float64,
    fairness_list::Vector{String},
    battery_scale::Float64=1.0,
    pv_scale::Float64=1.0
)
    detail = DataFrame(
        InstanceFile=String[],
        NBstage=Int64[],
        Childs=Int64[],
        Periods=Int64[],
        Theta=Float64[],
        Avg_d=Float64[],
        Dev_d=Float64[],
        J=Int64[],
        Fairness=String[],
        House=Int64[],
        PVAutonomyExpectedPct=Float64[],
        SavingsPct=Float64[],
        PVReceivedExpected=Float64[],
        ExpectedDemand=Float64[],
        AllGridExpectedCost=Float64[],
        CostExpected=Float64[]
    )

    for J in J_set
        for theta in theta_set
            inst = generateInstance(NBstage, childs, periods, J, inFile, theta, avg_d, dev_d; pv_scale=pv_scale)
            scaleInstance!(inst; battery_scale=battery_scale)
            probs = _scenario_probabilities(inst)
            total_prob = max(sum(probs), TOL)
            scenario_demand_house = [sum(inst.d[j, n] for n in scenario) for j in 1:inst.J, scenario in inst.tree.scenarios]
            all_grid = all_grid_expected_costs(inst)

            for fair in fairness_list
                reg_from_solve = nothing
                if fair in ("LEXMMFSA", "MMFSA", "", "NONE")
                    sol = solveMulti(inst, fair)
                else
                    sol, reg_from_solve = solveMulti(inst, fair)
                end

                if sol.status
                    scenario_pv_house = [sum(sol.p[j, n] for n in scenario) for j in 1:inst.J, scenario in inst.tree.scenarios]
                    scenario_costs_house = _scenario_cost_matrix(inst, sol)
                else
                    scenario_pv_house = fill(NaN, inst.J, length(inst.tree.scenarios))
                    scenario_costs_house = fill(NaN, inst.J, length(inst.tree.scenarios))
                end

                for j in 1:inst.J
                    pv_autonomy = sum(
                        probs[s] * (scenario_pv_house[j, s] / max(scenario_demand_house[j, s], TOL))
                        for s in 1:length(probs)
                    ) / total_prob
                    cost_expected = sum(probs[s] * scenario_costs_house[j, s] for s in 1:length(probs)) / total_prob
                    pv_expected = sum(probs[s] * scenario_pv_house[j, s] for s in 1:length(probs)) / total_prob
                    expected_demand = sum(probs[s] * scenario_demand_house[j, s] for s in 1:length(probs)) / total_prob
                    savings = all_grid[j] - cost_expected
                    savings_pct = 100 * savings / max(all_grid[j], TOL)

                    push!(detail, (
                        basename(inFile),
                        NBstage,
                        childs,
                        periods,
                        theta,
                        avg_d,
                        dev_d,
                        J,
                        fair,
                        j,
                        100 * pv_autonomy,
                        savings_pct,
                        pv_expected,
                        expected_demand,
                        all_grid[j],
                        cost_expected
                    ))
                end
            end
        end
    end

    return detail
end

function summarize_metric(detail::DataFrame, metric_col::Symbol)
    summary = DataFrame(
        J=Int64[],
        Theta=Float64[],
        Fairness=String[],
        Mean=Float64[],
        Min=Float64[],
        Max=Float64[],
        Std=Float64[]
    )

    for J in sort(unique(detail.J))
        for theta in sort(unique(detail.Theta))
            for fair in sort(unique(detail.Fairness))
                sub = detail[(detail.J .== J) .& (detail.Theta .== theta) .& (detail.Fairness .== fair), :]
                vals = collect(skipmissing(sub[!, metric_col]))
                vals = [v for v in vals if isfinite(v)]
                isempty(vals) && continue
                push!(summary, (J, theta, fair, mean(vals), minimum(vals), maximum(vals), std(vals; corrected=false)))
            end
        end
    end

    return summary
end

function tex_table_from_summary(summary::DataFrame, metric_name::String, caption::String, label::String)
    fairness_order = ["NONE", "PEA", "SA", "LEXMMFPEA", "LEXMMFSA"]
    J_values = sort(unique(summary.J))
    theta_values = sort(unique(summary.Theta))

    lines = String[]
    push!(lines, "\\begin{table}[h]")
    push!(lines, "\\centering")
    push!(lines, "\\caption{$caption}")
    push!(lines, "\\label{$label}")
    push!(lines, "\\begin{tabular}{llcccc|cccc}")
    push!(lines, "\\hline")
    push!(lines, " &  & \\multicolumn{4}{c|}{\$\\\\sigma = $(theta_values[1])\$} & \\multicolumn{4}{c}{\$\\\\sigma = $(theta_values[2])\$} \\\\")
    push!(lines, "\\hline")
    push!(lines, "\$|J|\$ & Policy & Mean & Min & Max & Std & Mean & Min & Max & Std \\\\")
    push!(lines, "\\hline")

    for J in J_values
        for fair in fairness_order
            row1 = summary[(summary.J .== J) .& (summary.Theta .== theta_values[1]) .& (summary.Fairness .== fair), :]
            row2 = summary[(summary.J .== J) .& (summary.Theta .== theta_values[2]) .& (summary.Fairness .== fair), :]
            nrow(row1) == 1 || continue
            nrow(row2) == 1 || continue
            push!(lines,
                string(
                    J, " & ", fairness_label(fair), " & ",
                    round(row1.Mean[1], digits=2), " & ",
                    round(row1.Min[1], digits=2), " & ",
                    round(row1.Max[1], digits=2), " & ",
                    round(row1.Std[1], digits=2), " & ",
                    round(row2.Mean[1], digits=2), " & ",
                    round(row2.Min[1], digits=2), " & ",
                    round(row2.Max[1], digits=2), " & ",
                    round(row2.Std[1], digits=2), " \\\\"
                )
            )
        end
        push!(lines, "\\hline")
    end

    push!(lines, "\\end{tabular}")
    push!(lines, "\\end{table}")
    return join(lines, "\n")
end

function main()
    inFile = get(ENV, "INST_FILE", "inst/inst2020/Drahi_1.csv")
    NBstage = parse(Int, get(ENV, "NBSTAGE", "6"))
    childs = parse(Int, get(ENV, "CHILDS", "4"))
    periods = parse(Int, get(ENV, "PERIODS", "4"))
    J_set = parse_int_list(get(ENV, "J_SET", "5,10"))
    theta_set = parse_float_list(get(ENV, "THETA_SET", "0.2,0.6"))
    avg_d = parse(Float64, get(ENV, "AVG_D", "100.0"))
    dev_d = parse(Float64, get(ENV, "DEV_D", "10.0"))
    fairness_list = [String(strip(x)) for x in split_nonempty(get(ENV, "FAIRNESS_SET", "NONE,PEA,SA,LEXMMFPEA,LEXMMFSA"), ",")]
    battery_scale = parse(Float64, get(ENV, "BATTERY_SCALE", "1.0"))
    pv_scale = parse(Float64, get(ENV, "PV_SCALE", "1.0"))

    out_detail_csv = get(ENV, "OUT_DETAIL_CSV", "representative_instance_house_metrics.csv")
    out_autonomy_csv = get(ENV, "OUT_AUTONOMY_CSV", "representative_instance_pv_autonomy_summary.csv")
    out_savings_csv = get(ENV, "OUT_SAVINGS_CSV", "representative_instance_savings_summary.csv")
    out_tex = get(ENV, "OUT_TEX", "representative_instance_tables.tex")

    detail = representative_house_metrics(
        inFile=inFile,
        NBstage=NBstage,
        childs=childs,
        periods=periods,
        J_set=J_set,
        theta_set=theta_set,
        avg_d=avg_d,
        dev_d=dev_d,
        fairness_list=fairness_list,
        battery_scale=battery_scale,
        pv_scale=pv_scale
    )

    autonomy_summary = summarize_metric(detail, :PVAutonomyExpectedPct)
    savings_summary = summarize_metric(detail, :SavingsPct)

    CSV.write(out_detail_csv, detail)
    CSV.write(out_autonomy_csv, autonomy_summary)
    CSV.write(out_savings_csv, savings_summary)

    tex_parts = String[]
    push!(tex_parts, tex_table_from_summary(
        autonomy_summary,
        "PV autonomy",
        "Distribution of expected house-level PV autonomy (\\%) for the representative instance",
        "tab:coverage_PV_repr"
    ))
    push!(tex_parts, "")
    push!(tex_parts, tex_table_from_summary(
        savings_summary,
        "Savings",
        "Distribution of savings across households (\\%) for the representative instance",
        "tab:coverage_SA_repr"
    ))

    open(out_tex, "w") do io
        write(io, join(tex_parts, "\n"))
    end

    println("Detalle por casa: ", out_detail_csv)
    println("Resumen PV autonomy: ", out_autonomy_csv)
    println("Resumen savings: ", out_savings_csv)
    println("Tablas LaTeX: ", out_tex)
end

main()
