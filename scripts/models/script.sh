#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"
cd "$CODES_DIR"

SCRIPT_NAME="${SCRIPT_NAME:-$(basename "$0")}"
INST_FOLDER="${INST_FOLDER:-$DEFAULT_INST_FOLDER}"
INSTANCE_FROM="${INSTANCE_FROM:-1}"
INSTANCE_TO="${INSTANCE_TO:-1}"
FAIRNESS_SET="${FAIRNESS_SET:-}"
if [[ -z "$FAIRNESS_SET" ]]; then
  echo "ERROR: define FAIRNESS_SET (ejemplo: FAIRNESS_SET=PEA)" >&2
  exit 1
fi
TREE_SET="${TREE_SET:-6:2:4}"
J_SET="${J_SET:-5}"
THETA_SET="${THETA_SET:-0.2}"
AVG_D_SET="${AVG_D_SET:-100.0}"
DEV_D_SET="${DEV_D_SET:-10.0}"
DEMAND_PROFILE_SET="${DEMAND_PROFILE_SET:-mixed}"
BATTERY_SCALE_SET="${BATTERY_SCALE_SET:-1.0}"
PV_SCALE_SET="${PV_SCALE_SET:-1.0}"
SA_FAIRNESS_ABS_TOL="${SA_FAIRNESS_ABS_TOL:-0.0}"
OUT_CSV="${OUT_CSV:-$RESULTS_MODELS_DIR/fairness_config_set_report.csv}"
OUT_CSV_HOUSE="${OUT_CSV_HOUSE:-$RESULTS_MODELS_DIR/fairness_config_set_report_by_house.csv}"
LOCK_OUTPUT="${LOCK_OUTPUT:-1}"

if [[ "$LOCK_OUTPUT" == "1" ]]; then
  if ! command -v flock >/dev/null 2>&1; then
    echo "ERROR: 'flock' no está disponible y LOCK_OUTPUT=1. Instala flock o usa LOCK_OUTPUT=0." >&2
    exit 1
  fi
  mkdir -p "$(dirname "$OUT_CSV")"
  LOCK_FILE="${OUT_CSV}.lock"
  exec 9>"$LOCK_FILE"
  flock 9
fi

export SCRIPT_NAME INST_FOLDER INSTANCE_FROM INSTANCE_TO FAIRNESS_SET TREE_SET
export J_SET THETA_SET AVG_D_SET DEV_D_SET DEMAND_PROFILE_SET BATTERY_SCALE_SET PV_SCALE_SET SA_FAIRNESS_ABS_TOL OUT_CSV OUT_CSV_HOUSE LOCK_OUTPUT

julia --quiet --startup-file=no --history-file=no - <<'JULIA'
include("multi.jl");
using Dates;
using CSV, DataFrames;

split_nonempty(s, sep) = [x for x in split(s, sep) if !isempty(strip(x))];
parse_int_list(s) = [parse(Int, strip(x)) for x in split_nonempty(s, ",")];
parse_float_list(s) = [parse(Float64, strip(x)) for x in split_nonempty(s, ",")];
parse_string_list(s) = [String(strip(x)) for x in split_nonempty(s, ",")];

script_name = ENV["SCRIPT_NAME"];
inst_folder = ENV["INST_FOLDER"];
instance_from = parse(Int, ENV["INSTANCE_FROM"]);
instance_to = parse(Int, ENV["INSTANCE_TO"]);
fairness_set = [String(strip(x)) for x in split_nonempty(ENV["FAIRNESS_SET"], ",")];
tree_specs = split_nonempty(ENV["TREE_SET"], ";");
J_set = parse_int_list(ENV["J_SET"]);
theta_set = parse_float_list(ENV["THETA_SET"]);
avg_d_set = parse_float_list(ENV["AVG_D_SET"]);
dev_d_set = parse_float_list(ENV["DEV_D_SET"]);
demand_profile_set = parse_string_list(ENV["DEMAND_PROFILE_SET"]);
battery_scale_set = parse_float_list(ENV["BATTERY_SCALE_SET"]);
pv_scale_set = parse_float_list(ENV["PV_SCALE_SET"]);
sa_fairness_abs_tol = parse(Float64, ENV["SA_FAIRNESS_ABS_TOL"]);
out_csv = ENV["OUT_CSV"];
out_csv_house = ENV["OUT_CSV_HOUSE"];
run_id = Dates.format(now(), "yyyymmdd_HHMMSS");

isdir(inst_folder) || error("No existe carpeta de instancias: $inst_folder");

tree_set = NamedTuple[];
for spec in tree_specs
    parts = split(spec, ":");
    length(parts) == 3 || error("TREE_SET inválido en '$spec'. Usa NBstage:childs:periods");
    push!(tree_set, (
        NBstage = parse(Int, strip(parts[1])),
        childs = parse(Int, strip(parts[2])),
        periods = parse(Int, strip(parts[3]))
    ));
end

function file_index(name::String)
    m = match(r"(\d+)", name)
    return m === nothing ? typemax(Int) : parse(Int, m.captures[1])
end
files = sort(readdir(inst_folder), by = f -> (replace(f, r"\d+" => ""), file_index(f), f));
from = max(1, instance_from);
to = min(length(files), instance_to);
from <= to || error("Rango inválido: [$instance_from,$instance_to] para $(length(files)) archivos");

configs = NamedTuple[];
for (local_file_idx, file) in enumerate(files[from:to])
    file_idx = from + local_file_idx - 1
    inFile = joinpath(inst_folder, file);
    for fair in fairness_set
        for tree in tree_set
            for J in J_set
                for theta in theta_set
                    for avg_d in avg_d_set
                        for dev_d in dev_d_set
                            for demand_profile in demand_profile_set
                                for battery_scale in battery_scale_set
                                    for pv_scale in pv_scale_set
                                        push!(configs, (
                                            run_id = run_id,
                                            script_name = script_name,
                                            inst_folder = inst_folder,
                                            instance_no = file_idx,
                                            instance_file = file,
                                            fairness = fair,
                                            inFile = inFile,
                                            NBstage = tree.NBstage,
                                            childs = tree.childs,
                                            periods = tree.periods,
                                            J = J,
                                            theta = theta,
                                            avg_d = avg_d,
                                            dev_d = dev_d,
                                            demand_profile = demand_profile,
                                            battery_scale = battery_scale,
                                            pv_scale = pv_scale,
                                            sa_fairness_abs_tol = sa_fairness_abs_tol
                                        ));
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

println("Total configuraciones a ejecutar: ", length(configs));

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

function reorder_columns!(df::DataFrame, front_cols::Vector{String})
    if nrow(df) == 0 && ncol(df) == 0
        return df
    end
    present_front = [c for c in front_cols if c in names(df)]
    tail = [c for c in names(df) if !(c in present_front)]
    select!(df, vcat(present_front, tail))
    return df
end

all_df = load_existing_df(out_csv);
all_df_house = load_existing_df(out_csv_house);
summary_front = ["InstanceNo","InstanceFile","NBstage","Childs","Periods","Theta","Avg_d","Dev_d","DemandProfile","J","BatteryScale","PVScale","Fairness","InstFolder"]
house_front = ["InstanceNo","InstanceFile","NBstage","Childs","Periods","Theta","Avg_d","Dev_d","DemandProfile","J","BatteryScale","PVScale","Fairness","House","InstFolder"]

for (cfg_idx, cfg) in enumerate(configs)
    println("Running config ", cfg_idx, "/", length(configs), " -> ",
        "(fairness=", cfg.fairness,
        ", file=", basename(cfg.inFile),
        ", S=", cfg.NBstage,
        ", C=", cfg.childs,
        ", P=", cfg.periods,
        ", J=", cfg.J,
        ", theta=", cfg.theta,
        ", demand_profile=", cfg.demand_profile,
        ", battery_scale=", cfg.battery_scale,
        ", pv_scale=", cfg.pv_scale, ")");

    df, df_house = run_single_fairness_instance(
        fairness=cfg.fairness,
        inFile=cfg.inFile,
        NBstage=cfg.NBstage,
        childs=cfg.childs,
        periods=cfg.periods,
        J=cfg.J,
        theta=cfg.theta,
        avg_d=cfg.avg_d,
        dev_d=cfg.dev_d,
        demand_profile=cfg.demand_profile,
        battery_scale=cfg.battery_scale,
        pv_scale=cfg.pv_scale,
        sa_fairness_abs_tol=cfg.sa_fairness_abs_tol,
        write_csv=false
    );

    for target_df in (df, df_house)
        target_df[!,"InstFolder"] = fill(cfg.inst_folder, nrow(target_df));
        target_df[!,"InstanceNo"] = fill(cfg.instance_no, nrow(target_df));
        target_df[!,"InstanceFile"] = fill(cfg.instance_file, nrow(target_df));
        target_df[!,"Fairness"] = fill(cfg.fairness, nrow(target_df));
        target_df[!,"NBstage"] = fill(cfg.NBstage, nrow(target_df));
        target_df[!,"Childs"] = fill(cfg.childs, nrow(target_df));
        target_df[!,"Periods"] = fill(cfg.periods, nrow(target_df));
        target_df[!,"J"] = fill(cfg.J, nrow(target_df));
        target_df[!,"Theta"] = fill(cfg.theta, nrow(target_df));
        target_df[!,"Avg_d"] = fill(cfg.avg_d, nrow(target_df));
        target_df[!,"Dev_d"] = fill(cfg.dev_d, nrow(target_df));
        target_df[!,"DemandProfile"] = fill(cfg.demand_profile, nrow(target_df));
        target_df[!,"BatteryScale"] = fill(cfg.battery_scale, nrow(target_df));
        target_df[!,"PVScale"] = fill(cfg.pv_scale, nrow(target_df));
    end

    append!(all_df, df; cols=:union)
    append!(all_df_house, df_house; cols=:union)
    reorder_columns!(all_df, summary_front)
    reorder_columns!(all_df_house, house_front)
    CSV.write(out_csv, all_df)
    CSV.write(out_csv_house, all_df_house)
end
JULIA
