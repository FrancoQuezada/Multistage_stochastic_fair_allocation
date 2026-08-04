include("vss.jl")

using CSV
using DataFrames

function split_nonempty(value::String, sep::String=",")
    return [strip(x) for x in split(value, sep) if !isempty(strip(x))]
end

function env_int(name::String, default::Int)
    value = strip(get(ENV, name, string(default)))
    token = strip(first(split(value, ",")))
    return parse(Int, token)
end

function env_int_list(name::String, default::String)
    value = get(ENV, name, default)
    return [parse(Int, x) for x in split_nonempty(value)]
end

function env_float_list(name::String, default::String)
    value = get(ENV, name, default)
    return [parse(Float64, x) for x in split_nonempty(value)]
end

function run_vss_none_config_set(;
    inst_folder::String="inst/inst2020",
    instance_from::Int=1,
    instance_to::Int=100,
    NBstage::Int=6,
    childs::Int=2,
    periods::Int=4,
    J_set::Vector{Int}=[5, 10],
    theta_set::Vector{Float64}=[0.2, 0.6],
    avg_d_set::Vector{Float64}=[100.0],
    dev_d_set::Vector{Float64}=[10.0, 20.0],
    out_csv::String="vss_none_report.csv"
)
    all_rows = DataFrame()
    for J in J_set
        for theta in theta_set
            for avg_d in avg_d_set
                for dev_d in dev_d_set
                    df_cfg = run_vss_none_report(
                        inst_folder=inst_folder,
                        instance_from=instance_from,
                        instance_to=instance_to,
                        NBstage=NBstage,
                        childs=childs,
                        periods=periods,
                        J=J,
                        theta=theta,
                        avg_d=avg_d,
                        dev_d=dev_d,
                        out_csv=out_csv
                    )
                    all_rows = isempty(all_rows) ? copy(df_cfg) : vcat(all_rows, df_cfg)
                    CSV.write(out_csv, all_rows)
                end
            end
        end
    end
    return all_rows
end

function main()
    inst_folder = get(ENV, "INST_FOLDER", "inst/inst2020")
    instance_from = env_int("INSTANCE_FROM", 1)
    instance_to = env_int("INSTANCE_TO", 100)
    NBstage = env_int("NBSTAGE", 6)
    childs = env_int("CHILDS", 2)
    periods = env_int("PERIODS", 4)
    J_set = env_int_list("J_SET", "5,10")
    theta_set = env_float_list("THETA_SET", "0.2,0.6")
    avg_d_set = env_float_list("AVG_D_SET", "100.0")
    dev_d_set = env_float_list("DEV_D_SET", "10.0,20.0")
    out_csv = get(ENV, "OUT_CSV", "vss_none_report.csv")

    df = run_vss_none_config_set(
        inst_folder=inst_folder,
        instance_from=instance_from,
        instance_to=instance_to,
        NBstage=NBstage,
        childs=childs,
        periods=periods,
        J_set=J_set,
        theta_set=theta_set,
        avg_d_set=avg_d_set,
        dev_d_set=dev_d_set,
        out_csv=out_csv
    )

    println("Filas generadas: ", nrow(df))
    println("Reporte VSS/EVPI NONE: ", out_csv)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
