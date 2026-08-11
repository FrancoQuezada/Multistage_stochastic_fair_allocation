# =====================================================================================
# Structural-instance manifest generator (redesign stage 3, schema v2).
#
# Validates an explicit structural design, materializes the complete factorial catalog through
# the repository's verified instance pipeline, checks every internal invariant, and writes the
# canonical manifest atomically. It runs NO out-of-sample campaign and generates no scenario
# support.
#
#     julia +<manifest channel> --project=. \
#         codes/oos_experiment/generate_structural_instance_manifest.jl
#
# Normally driven by `scripts/oos/generate_structural_instance_manifest.sh`, which resolves the
# Julia channel from `Manifest.toml`.
#
# REQUIRED inputs, with NO defaults on purpose: the four numeric factor levels and the number of
# structural draws per cell. Nothing in this repository proposes a calibrated battery scale or
# uncertainty intensity — stage 12 does that — so a missing input is an error rather than a
# silently plausible number.
#
#     INSTANCE_DRAWS_PER_CELL    K, structural draws per factor cell
#     LOW_BATTERY_SCALE          battery_scale of LOW_BATTERY
#     HIGH_BATTERY_SCALE         battery_scale of HIGH_BATTERY
#     LOW_UNCERTAINTY_THETA      theta of LOW_UNCERTAINTY
#     HIGH_UNCERTAINTY_THETA     theta of HIGH_UNCERTAINTY
#     STRUCTURAL_MANIFEST_PATH   destination of the canonical manifest
#
# Optional, all following the repository's existing parsing conventions:
#
#     STRUCTURAL_BASE_INSTANCES        comma-separated base instance files (repo-relative or
#                                      absolute inside the repository)
#     INST_FOLDER / INSTANCE_FROM / INSTANCE_TO
#                                      base instances selected by index, as elsewhere in the repo
#     EXPERIMENT_SEED, J_SET, AVG_D_SET, DEV_D_SET, PV_SCALE_SET, TREE_SET
#     OOS_REPLICATIONS
#     EVALUATION_HORIZON, LOOKAHEAD_HORIZON, IMPLEMENTATION_STEP
#     REPOSITORY_DEMAND_PROFILE        the legacy generateInstance profile argument, FIXED across
#                                      the catalog (it is not the structural demand regime)
#     STRUCTURAL_MANIFEST_OVERWRITE    1 to replace a conflicting existing manifest
#     STRUCTURAL_MANIFEST_COMPANIONS   0 to skip the CSV and provenance companions
# =====================================================================================

const REPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
include(joinpath(REPO_ROOT, "codes", "oos_experiment", "oos_experiment.jl"))

"""Required environment input, with no fallback value."""
function _required_env(name::AbstractString, description::AbstractString)
    raw = strip(get(ENV, String(name), ""))
    isempty(raw) && error(
        "Falta la entrada obligatoria $name ($description). El catálogo estructural no ofrece " *
        "valores por defecto para los niveles numéricos de los factores ni para el número de " *
        "sorteos: la etapa 12 los calibra, y un valor inventado aquí se leería como una " *
        "recomendación."
    )
    return String(raw)
end

function _required_env_int(name::AbstractString, description::AbstractString)
    raw = _required_env(name, description)
    parsed = tryparse(Int, raw)
    parsed === nothing &&
        error("La variable de entorno $name debe ser un entero; se recibió \"$raw\".")
    return parsed
end

function _required_env_float(name::AbstractString, description::AbstractString)
    raw = _required_env(name, description)
    parsed = tryparse(Float64, raw)
    parsed === nothing &&
        error("La variable de entorno $name debe ser un número; se recibió \"$raw\".")
    isfinite(parsed) || error("La variable de entorno $name debe ser finita; se recibió \"$raw\".")
    return parsed
end

"""Resolve the base-instance set, either listed explicitly or selected by index as elsewhere."""
function _resolve_base_instances()
    explicit = strip(get(ENV, "STRUCTURAL_BASE_INSTANCES", ""))
    if !isempty(explicit)
        return [String(strip(entry)) for entry in split(explicit, ',') if !isempty(strip(entry))]
    end
    folder = get(ENV, "INST_FOLDER", joinpath(OOS_CODES_DIRECTORY, "inst", "inst2020"))
    isdir(folder) || error("No se encontró la carpeta de instancias: $folder")
    files = sort(readdir(folder))
    isempty(files) && error("No hay archivos de instancia en: $folder")
    from = _env_int("INSTANCE_FROM", 1)
    to = _env_int("INSTANCE_TO", from)
    1 <= from <= to <= length(files) || error(
        "Rango de instancias inválido: INSTANCE_FROM=$from, INSTANCE_TO=$to con " *
        "$(length(files)) archivos disponibles."
    )
    return [joinpath(folder, files[index]) for index in from:to]
end

function main()
    tree_spec = first(_env_list("TREE_SET", ["3:2:8"]))
    parts = split(tree_spec, ':')
    length(parts) == 3 || error("TREE_SET debe tener el formato S:C:P, por ejemplo 3:2:8.")
    stages, children, periods = parse.(Int, parts)

    design = OOSStructuralDesignConfig(
        base_instance_files=_resolve_base_instances(),
        experiment_seed=_env_int("EXPERIMENT_SEED", 12345),
        structural_draws_per_cell=_required_env_int(
            "INSTANCE_DRAWS_PER_CELL", "sorteos estructurales por celda (K)",
        ),
        battery_scales=battery_scale_map(
            _required_env_float("LOW_BATTERY_SCALE", "escala de batería de LOW_BATTERY"),
            _required_env_float("HIGH_BATTERY_SCALE", "escala de batería de HIGH_BATTERY"),
        ),
        uncertainty_thetas=uncertainty_theta_map(
            _required_env_float("LOW_UNCERTAINTY_THETA", "theta de LOW_UNCERTAINTY"),
            _required_env_float("HIGH_UNCERTAINTY_THETA", "theta de HIGH_UNCERTAINTY"),
        ),
        households=first(_env_int_list("J_SET", [5])),
        avg_demand=first([parse(Float64, x) for x in _env_list("AVG_D_SET", ["100.0"])]),
        dev_demand=first([parse(Float64, x) for x in _env_list("DEV_D_SET", ["10.0"])]),
        pv_scale=first([parse(Float64, x) for x in _env_list("PV_SCALE_SET", ["1.0"])]),
        oos_replications=_env_int("OOS_REPLICATIONS", 20),
        evaluation_horizon=_env_int("EVALUATION_HORIZON", OOS_DEFAULT_EVALUATION_HORIZON),
        lookahead_horizon=_env_int("LOOKAHEAD_HORIZON", OOS_DEFAULT_LOOKAHEAD_HORIZON),
        implementation_step=_env_int("IMPLEMENTATION_STEP", OOS_DEFAULT_IMPLEMENTATION_STEP),
        in_sample_stages=stages,
        in_sample_children=children,
        in_sample_periods_per_stage=periods,
        repository_demand_profile=_env("REPOSITORY_DEMAND_PROFILE", "mixed"),
    )

    manifest_path = _required_env(
        "STRUCTURAL_MANIFEST_PATH", "destino del manifiesto canónico",
    )

    # The base configuration supplies the solver, fairness and formulation settings that are NOT
    # part of the structural design. Its instance-level fields are overridden per structural
    # instance, so its own instance_file only has to exist.
    base_config = OOSExperimentConfig(
        experiment_seed=design.experiment_seed,
        oos_replications=design.oos_replications,
        evaluation_horizon=design.evaluation_horizon,
        lookahead_horizon=design.lookahead_horizon,
        implementation_step=design.implementation_step,
        formulation_id=_env("FORMULATION_ID", "structural_catalog_stage3"),
        export_representative_models=false,
        require_shared_battery_validation=false,
        output_directory=dirname(abspath(manifest_path)),
        instance_file=absolute_base_instance_file(first(design.base_instance_files)),
        households=design.households,
        theta=uncertainty_theta(design, LOW_UNCERTAINTY),
        avg_demand=design.avg_demand,
        dev_demand=design.dev_demand,
        pv_scale=design.pv_scale,
        demand_profile=design.repository_demand_profile,
        in_sample_stages=design.in_sample_stages,
        in_sample_children=design.in_sample_children,
        in_sample_periods_per_stage=design.in_sample_periods_per_stage,
    )

    println("=== Generación del manifiesto de instancias estructurales ===")
    println("instancias base       : ", join(design.base_instance_files, ", "))
    println("sorteos por celda (K) : ", design.structural_draws_per_cell)
    println("diseño                : ",
            length(design.base_instance_files), " x 2 x 2 x 2 x ",
            design.structural_draws_per_cell, " = ",
            expected_structural_instance_count(design), " instancias estructurales")
    println("escalas de batería    : LOW=", battery_scale(design, LOW_BATTERY),
            "  HIGH=", battery_scale(design, HIGH_BATTERY), "  [PROVISIONAL, sin calibrar]")
    println("thetas                : LOW=", uncertainty_theta(design, LOW_UNCERTAINTY),
            "  HIGH=", uncertainty_theta(design, HIGH_UNCERTAINTY), "  [PROVISIONAL, sin calibrar]")
    println("réplicas OOS previstas: ", design.oos_replications)
    println("estructura temporal   : H=", design.evaluation_horizon,
            " L=", design.lookahead_horizon, " h=", design.implementation_step,
            " inicios=", rolling_iteration_starts(design),
            " (períodos abstractos del modelo)")
    println("soporte requerido     : ", required_period_support_end(design),
            " (T0 se resolverá desde la instancia; Tdata=max(T0, soporte))")
    println("bloques deterministas : ", expected_deterministic_data_count(design),
            " (uno por instancia base y sorteo estructural)")
    println("destino               : ", manifest_path)
    println()

    result = generate_structural_manifest(
        base_config, design, manifest_path;
        overwrite=_env_bool("STRUCTURAL_MANIFEST_OVERWRITE", false),
        write_companions=_env_bool("STRUCTURAL_MANIFEST_COMPANIONS", true),
        verbose=true,
    )

    println()
    println("STRUCTURAL_MANIFEST_PATH=", result.path)
    println("STRUCTURAL_MANIFEST_ID=", result.manifest_id)
    println("STRUCTURAL_MANIFEST_STATUS=", result.status)
    println("STRUCTURAL_MANIFEST_EXPECTED_INSTANCES=",
            expected_structural_instance_count(design))
    println("STRUCTURAL_MANIFEST_ACTUAL_INSTANCES=", result.structural_instances)
    println("STRUCTURAL_MANIFEST_PAIRED_BASES=", result.paired_bases)
    println("STRUCTURAL_MANIFEST_DEMAND_ASSIGNMENTS=", result.demand_assignments)
    println("STRUCTURAL_MANIFEST_DETERMINISTIC_DATA_BLOCKS=",
            result.deterministic_data_blocks)
    println("STRUCTURAL_MANIFEST_PLANNED_OOS_KEYS=", result.planned_oos_keys)
    println("STRUCTURAL_MANIFEST_PLANNED_SUPPORT_KEYS=", result.planned_support_keys)
    println("STRUCTURAL_MANIFEST_FACTOR_LEVEL_STATUS=", design.factor_level_status)
    for companion in result.companion_files
        println("STRUCTURAL_MANIFEST_COMPANION=", companion)
    end

    result.structural_instances == expected_structural_instance_count(design) || error(
        "El manifiesto registró $(result.structural_instances) instancias y se esperaban " *
        "$(expected_structural_instance_count(design))."
    )
    println("STRUCTURAL_MANIFEST_RESULT=OK")
    return 0
end

exit(main())
