include("multi.jl")

using CSV
using DataFrames

function natural_instance_sort(files::Vector{String})
    function file_key(file::String)
        m = match(r"(\d+)", file)
        return m === nothing ? (typemax(Int), file) : (parse(Int, m.captures[1]), file)
    end
    return sort(files; by=file_key)
end

function env_int(name::String, default::Int)
    value = strip(get(ENV, name, string(default)))
    token = strip(first(split(value, ",")))
    return parse(Int, token)
end

function env_float(name::String, default::Float64)
    value = strip(get(ENV, name, string(default)))
    token = strip(first(split(value, ",")))
    return parse(Float64, token)
end

function split_nonempty(value::String, sep::String=",")
    return [strip(x) for x in split(value, sep) if !isempty(strip(x))]
end

function env_int_list(name::String, default::String)
    value = get(ENV, name, default)
    return [parse(Int, x) for x in split_nonempty(value)]
end

function env_float_list(name::String, default::String)
    value = get(ENV, name, default)
    return [parse(Float64, x) for x in split_nonempty(value)]
end

function run_all_grid_expected_costs_report(;
    inst_folder::String="inst/inst2020",
    instance_from::Int=1,
    instance_to::Int=10,
    NBstage::Int=6,
    childs::Int=4,
    periods::Int=4,
    J::Int=5,
    theta::Float64=0.2,
    avg_d::Float64=100.0,
    dev_d::Float64=10.0,
    out_csv::String="all_grid_expected_costs_S6_C4_P4.csv"
)
    isdir(inst_folder) || error("No existe el directorio de instancias: $inst_folder")

    files = natural_instance_sort(readdir(inst_folder))
    isempty(files) && error("No se encontraron archivos en: $inst_folder")

    from = max(1, instance_from)
    to = min(length(files), instance_to)
    from > to && error("Rango de instancias invalido: [$instance_from,$instance_to]")

    df = DataFrame()
    df[!, "InstanceNo"] = Int64[]
    df[!, "InstanceFile"] = String[]
    df[!, "NBstage"] = Int64[]
    df[!, "Childs"] = Int64[]
    df[!, "Periods"] = Int64[]
    df[!, "Theta"] = Float64[]
    df[!, "Avg_d"] = Float64[]
    df[!, "Dev_d"] = Float64[]
    df[!, "J"] = Int64[]
    df[!, "House"] = Int64[]
    df[!, "AllGridExpectedCost"] = Float64[]

    for (offset, file) in enumerate(files[from:to])
        instance_no = from + offset - 1
        inFile = joinpath(inst_folder, file)
        println("All-grid -> file=", file, ", S=", NBstage, ", C=", childs, ", P=", periods)
        inst = generateInstance(NBstage, childs, periods, J, inFile, theta, avg_d, dev_d)
        expected_costs = all_grid_expected_costs(inst)
        for j in 1:J
            push!(df, (
                instance_no,
                file,
                NBstage,
                childs,
                periods,
                theta,
                avg_d,
                dev_d,
                J,
                j,
                expected_costs[j]
            ))
        end
    end

    CSV.write(out_csv, df)
    return df
end

function run_all_grid_expected_costs_config_set(;
    inst_folder::String="inst/inst2020",
    instance_from::Int=1,
    instance_to::Int=100,
    NBstage::Int=6,
    childs::Int=4,
    periods::Int=4,
    J_set::Vector{Int}=[5, 10],
    theta_set::Vector{Float64}=[0.2, 0.6],
    avg_d_set::Vector{Float64}=[100.0],
    dev_d_set::Vector{Float64}=[10.0, 20.0],
    out_csv::String="all_grid_expected_costs_S6_C4_P4.csv"
)
    all_rows = DataFrame()
    for J in J_set
        for theta in theta_set
            for avg_d in avg_d_set
                for dev_d in dev_d_set
                    println(
                        "All-grid config -> S=", NBstage,
                        ", C=", childs,
                        ", P=", periods,
                        ", J=", J,
                        ", theta=", theta,
                        ", avg_d=", avg_d,
                        ", dev_d=", dev_d
                    )
                    df_cfg = run_all_grid_expected_costs_report(
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
    childs = env_int("CHILDS", 4)
    periods = env_int("PERIODS", 4)
    J_set = env_int_list("J_SET", get(ENV, "J", "5,10"))
    theta_set = env_float_list("THETA_SET", get(ENV, "THETA", "0.2,0.6"))
    avg_d_set = env_float_list("AVG_D_SET", get(ENV, "AVG_D", "100.0"))
    dev_d_set = env_float_list("DEV_D_SET", get(ENV, "DEV_D", "10.0,20.0"))
    out_csv = get(ENV, "OUT_CSV", "all_grid_expected_costs_S6_C4_P4.csv")

    df = run_all_grid_expected_costs_config_set(
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
    println("Reporte all-grid: ", out_csv)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
