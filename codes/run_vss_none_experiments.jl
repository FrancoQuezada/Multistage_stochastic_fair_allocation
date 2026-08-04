include("vss_none.jl")

using CSV
using DataFrames

split_nonempty(value::String, sep::String=",") = [strip(x) for x in split(value, sep) if !isempty(strip(x))]
env_int(name::String, default::Int) = parse(Int, strip(first(split(strip(get(ENV, name, string(default))), ","))))
env_int_list(name::String, default::String) = [parse(Int, x) for x in split_nonempty(get(ENV, name, default))]
env_float_list(name::String, default::String) = [parse(Float64, x) for x in split_nonempty(get(ENV, name, default))]
env_string_list(name::String, default::String) = [String(x) for x in split_nonempty(get(ENV, name, default))]

function load_existing_df(path::String)
    if isfile(path) && filesize(path) > 0
        try
            return CSV.read(path, DataFrame)
        catch
            return DataFrame()
        end
    end
    return DataFrame()
end

function run_vss_none_config_set(; inst_folder::String="inst/inst2020", instance_from::Int=1, instance_to::Int=10, NBstage::Int=6, childs::Int=6, periods::Int=4, J_set::Vector{Int}=[5,10], theta_set::Vector{Float64}=[0.2,0.6], avg_d_set::Vector{Float64}=[100.0], dev_d_set::Vector{Float64}=[10.0,20.0], demand_profile_set::Vector{String}=["mixed"], battery_scale_set::Vector{Float64}=[1.0], pv_scale_set::Vector{Float64}=[1.0], out_csv::String="vss_none_report.csv")
    existing_df = load_existing_df(out_csv)
    all_rows = DataFrame()

    for J in J_set
        for theta in theta_set
            for avg_d in avg_d_set
                for dev_d in dev_d_set
                    for demand_profile in demand_profile_set
                        for battery_scale in battery_scale_set
                            for pv_scale in pv_scale_set
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
                                    demand_profile=demand_profile,
                                    battery_scale=battery_scale,
                                    pv_scale=pv_scale,
                                )
                                all_rows = isempty(all_rows) ? copy(df_cfg) : vcat(all_rows, df_cfg; cols=:union)
                                combined = isempty(existing_df) ? copy(all_rows) : vcat(existing_df, all_rows; cols=:union)
                                CSV.write(out_csv, combined)
                            end
                        end
                    end
                end
            end
        end
    end

    return isempty(existing_df) ? all_rows : vcat(existing_df, all_rows; cols=:union)
end

function main()
    inst_folder = get(ENV, "INST_FOLDER", "inst/inst2020")
    instance_from = env_int("INSTANCE_FROM", 1)
    instance_to = env_int("INSTANCE_TO", 10)
    NBstage = env_int("NBSTAGE", 6)
    childs = env_int("CHILDS", 6)
    periods = env_int("PERIODS", 4)
    J_set = env_int_list("J_SET", "5,10")
    theta_set = env_float_list("THETA_SET", "0.2,0.6")
    avg_d_set = env_float_list("AVG_D_SET", "100.0")
    dev_d_set = env_float_list("DEV_D_SET", "10.0,20.0")
    demand_profile_set = env_string_list("DEMAND_PROFILE_SET", "mixed")
    battery_scale_set = env_float_list("BATTERY_SCALE_SET", "1.0")
    pv_scale_set = env_float_list("PV_SCALE_SET", "1.0")
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
        demand_profile_set=demand_profile_set,
        battery_scale_set=battery_scale_set,
        pv_scale_set=pv_scale_set,
        out_csv=out_csv,
    )

    println("Filas totales en reporte VSS/EVPI NONE: ", nrow(df))
    println("Reporte: ", out_csv)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
