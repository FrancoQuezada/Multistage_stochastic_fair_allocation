using CSV
using DataFrames
using Random

const FAIRNESS_MANIFEST_COLUMNS = [
    "ConfigID", "RandomInstanceID", "InstanceFile", "InstFolder", "TreeSpec",
    "NBstage", "Childs", "Periods", "Scenarios", "J", "Theta", "Avg_d",
    "Dev_d", "DemandProfile", "BatteryScale", "PVScale", "InstanceSampleSeed",
]

_manifest_split(value, separator) = [strip(x) for x in split(value, separator) if !isempty(strip(x))]
_manifest_ints(value) = parse.(Int, _manifest_split(value, ','))
_manifest_floats(value) = parse.(Float64, _manifest_split(value, ','))

function _manifest_bool(value::AbstractString)
    normalized = lowercase(strip(value))
    normalized in ("true", "1", "yes") && return true
    normalized in ("false", "0", "no") && return false
    error("Booleano inválido: $value")
end

function _parse_tree_specs(value::AbstractString)
    trees = NamedTuple[]
    for spec in _manifest_split(value, ';')
        parts = split(spec, ':')
        length(parts) == 3 || error("TreeSpec inválido '$spec'; usa NBstage:Childs:Periods.")
        stages, childs, periods = parse.(Int, strip.(parts))
        stages >= 1 || error("NBstage debe ser positivo en '$spec'.")
        childs >= 1 || error("Childs debe ser positivo en '$spec'.")
        periods >= 1 || error("Periods debe ser positivo en '$spec'.")
        push!(trees, (
            TreeSpec=spec,
            NBstage=stages,
            Childs=childs,
            Periods=periods,
            Scenarios=childs^(stages - 1),
        ))
    end
    isempty(trees) && error("TREE_SET no puede estar vacío.")
    return trees
end

function _atomic_manifest_write(path::String, df::DataFrame)
    mkpath(dirname(abspath(path)))
    temporary = joinpath(dirname(abspath(path)), ".$(basename(path)).tmp.$(getpid())")
    CSV.write(temporary, df)
    mv(temporary, abspath(path); force=true)
    return path
end

function _read_fairness_manifest(path::String)
    string_columns = Set([
        "ConfigID", "RandomInstanceID", "InstanceFile", "InstFolder", "TreeSpec",
        "DemandProfile",
    ])
    return CSV.read(
        path, DataFrame;
        types=(index, name) -> String(name) in string_columns ? String : nothing,
    )
end

function validate_fairness_comparison_manifest(df::DataFrame)
    missing_columns = setdiff(FAIRNESS_MANIFEST_COLUMNS, names(df))
    isempty(missing_columns) || error("Faltan columnas del manifiesto: $(join(missing_columns, ", ")).")
    nrow(df) > 0 || error("El manifiesto está vacío.")
    length(unique(df.ConfigID)) == nrow(df) || error("Hay ConfigID duplicados en el manifiesto.")
    for row in eachrow(df)
        isdir(row.InstFolder) || error("No existe InstFolder: $(row.InstFolder)")
        isfile(joinpath(row.InstFolder, row.InstanceFile)) || error(
            "No existe la instancia $(row.InstanceFile) en $(row.InstFolder)."
        )
        row.Scenarios == row.Childs^(row.NBstage - 1) || error(
            "Scenarios inconsistente para ConfigID=$(row.ConfigID)."
        )
    end
    return df
end

function build_fairness_comparison_manifest(;
    manifest_path::String,
    inst_folder::String,
    tree_set::String="2:2:12;6:4:4",
    instances_per_tree::Int=5,
    instance_sample_seed::Int=20260804,
    J_set::Vector{Int}=[5],
    theta_set::Vector{Float64}=[0.2],
    avg_d_set::Vector{Float64}=[100.0],
    dev_d_set::Vector{Float64}=[10.0],
    demand_profile_set::Vector{String}=["mixed"],
    battery_scale_set::Vector{Float64}=[1.0],
    pv_scale_set::Vector{Float64}=[1.0],
    rebuild_manifest::Bool=false,
)
    if isfile(manifest_path) && !rebuild_manifest
        manifest = _read_fairness_manifest(manifest_path)
        validate_fairness_comparison_manifest(manifest)
        println("Reutilizando manifiesto existente: $manifest_path ($(nrow(manifest)) configuraciones).")
        return manifest
    end

    instances_per_tree >= 1 || error("INSTANCES_PER_TREE debe ser positivo.")
    folder = abspath(inst_folder)
    isdir(folder) || error("No existe INST_FOLDER: $folder")
    files = sort(String[
        file for file in readdir(folder)
        if isfile(joinpath(folder, file))
    ])
    length(files) >= instances_per_tree || error(
        "Se requieren $instances_per_tree archivos distintos, pero solo hay $(length(files)) en $folder."
    )
    rng = MersenneTwister(instance_sample_seed)
    selected = files[randperm(rng, length(files))[1:instances_per_tree]]
    trees = _parse_tree_specs(tree_set)

    manifest = DataFrame()
    config_number = 0
    for tree in trees
        for (random_id, file) in enumerate(selected)
            for J in J_set, theta in theta_set, avg_d in avg_d_set, dev_d in dev_d_set
                for demand_profile in demand_profile_set
                    for battery_scale in battery_scale_set, pv_scale in pv_scale_set
                        config_number += 1
                        push!(manifest, (
                            ConfigID="C" * lpad(string(config_number), 4, '0'),
                            RandomInstanceID="R" * lpad(string(random_id), 3, '0'),
                            InstanceFile=file,
                            InstFolder=folder,
                            TreeSpec=tree.TreeSpec,
                            NBstage=tree.NBstage,
                            Childs=tree.Childs,
                            Periods=tree.Periods,
                            Scenarios=tree.Scenarios,
                            J=J,
                            Theta=theta,
                            Avg_d=avg_d,
                            Dev_d=dev_d,
                            DemandProfile=demand_profile,
                            BatteryScale=battery_scale,
                            PVScale=pv_scale,
                            InstanceSampleSeed=instance_sample_seed,
                        ); cols=:union)
                    end
                end
            end
        end
    end
    validate_fairness_comparison_manifest(manifest)
    _atomic_manifest_write(manifest_path, manifest)
    println("Manifiesto creado: $manifest_path ($(nrow(manifest)) configuraciones).")
    println("Instancias seleccionadas: $(join(selected, ", ")).")
    return manifest
end

if abspath(PROGRAM_FILE) == @__FILE__
    build_fairness_comparison_manifest(
        manifest_path=get(ENV, "MANIFEST_PATH", "../results_models/fairness_comparison/config_manifest.csv"),
        inst_folder=get(ENV, "INST_FOLDER", "inst/inst2020"),
        tree_set=get(ENV, "TREE_SET", "2:2:12;6:4:4"),
        instances_per_tree=parse(Int, get(ENV, "INSTANCES_PER_TREE", "5")),
        instance_sample_seed=parse(Int, get(ENV, "INSTANCE_SAMPLE_SEED", "20260804")),
        J_set=_manifest_ints(get(ENV, "J_SET", "5")),
        theta_set=_manifest_floats(get(ENV, "THETA_SET", "0.2")),
        avg_d_set=_manifest_floats(get(ENV, "AVG_D_SET", "100.0")),
        dev_d_set=_manifest_floats(get(ENV, "DEV_D_SET", "10.0")),
        demand_profile_set=String.(_manifest_split(get(ENV, "DEMAND_PROFILE_SET", "mixed"), ',')),
        battery_scale_set=_manifest_floats(get(ENV, "BATTERY_SCALE_SET", "1.0")),
        pv_scale_set=_manifest_floats(get(ENV, "PV_SCALE_SET", "1.0")),
        rebuild_manifest=_manifest_bool(get(ENV, "REBUILD_MANIFEST", "false")),
    )
end
