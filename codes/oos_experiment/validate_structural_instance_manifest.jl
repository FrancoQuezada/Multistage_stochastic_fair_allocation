# =====================================================================================
# Standalone structural-manifest validator (redesign stage 3, schema v2).
#
# Reads a SAVED manifest from disk — exactly as a downstream consumer would, by key name and with
# no access to the generator's in-memory objects — and verifies its internal cardinality,
# identifiers, digest, seed contracts, extended-period data, pairings, assignments and resolved
# physical parameters.
#
# It never runs an out-of-sample campaign. With rematerialization enabled it re-invokes the
# repository instance pipeline to confirm that stored physical parameters and all deterministic
# data digests are exactly what the approved pipeline produces.
#
#     julia +<manifest channel> --project=. \
#         codes/oos_experiment/validate_structural_instance_manifest.jl <manifest.json>
#
# Environment:
#     STRUCTURAL_MANIFEST_PATH            manifest to read, if no argument is given
#     STRUCTURAL_MANIFEST_REMATERIALIZE   1 (default) to re-check resolved physical parameters
#     STRUCTURAL_MANIFEST_REMATERIALIZE_LIMIT
#                                         bound the number of rematerialized rows; 0 = all
#
# Exits nonzero and names every blocking problem when the manifest is not consumable.
# =====================================================================================

const REPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
include(joinpath(REPO_ROOT, "codes", "oos_experiment", "oos_experiment.jl"))

function main()
    path = length(ARGS) >= 1 ? ARGS[1] : get(ENV, "STRUCTURAL_MANIFEST_PATH", "")
    isempty(path) && error(
        "Indica el manifiesto como argumento o vía STRUCTURAL_MANIFEST_PATH."
    )
    isfile(path) || error("No existe el manifiesto estructural: $path")

    rematerialize = _env_bool("STRUCTURAL_MANIFEST_REMATERIALIZE", true)
    limit = _env_int("STRUCTURAL_MANIFEST_REMATERIALIZE_LIMIT", 0)

    println("=== Validación del manifiesto de instancias estructurales ===")
    println("manifiesto      : ", path)
    println("rematerializar  : ", rematerialize, limit > 0 ? " (límite $limit filas)" : " (todas)")
    println()

    base_config = nothing
    if rematerialize
        document = canonical_json_parse(read(path, String))
        rows = document["structural_instances"]
        isempty(rows) && error("El manifiesto no contiene instancias estructurales.")
        reference = rows[1]
        # A base configuration only has to be constructible: every instance-level field is
        # overridden per structural row during rematerialization.
        base_config = OOSExperimentConfig(
            experiment_seed=_as_int(document["design"]["experiment_seed"]),
            oos_replications=_as_int(document["design"]["oos_replication_count"]),
            evaluation_horizon=_as_int(document["design"]["evaluation_horizon"]),
            lookahead_horizon=_as_int(document["design"]["lookahead_horizon"]),
            implementation_step=_as_int(document["design"]["implementation_step"]),
            formulation_id="structural_manifest_validation",
            export_representative_models=false,
            require_shared_battery_validation=false,
            output_directory=dirname(abspath(path)),
            instance_file=absolute_base_instance_file(String(reference["base_instance_file"])),
            households=_as_int(reference["households"]),
            theta=_as_float(reference["theta"]),
            avg_demand=_as_float(reference["avg_demand"]),
            dev_demand=_as_float(reference["dev_demand"]),
            pv_scale=_as_float(reference["pv_scale"]),
            demand_profile=String(reference["repository_demand_profile"]),
            in_sample_stages=_as_int(reference["in_sample_stages"]),
            in_sample_children=_as_int(reference["in_sample_children"]),
            in_sample_periods_per_stage=_as_int(reference["in_sample_periods_per_stage"]),
        )
    end

    report = validate_structural_manifest(
        path; base_config=base_config, rematerialize=rematerialize, rematerialize_limit=limit,
    )

    for issue in report.issues
        println("  ", structural_issue_is_blocking(issue) ? "[FALLA] " : "[AVISO] ",
                issue.section, " :: ", issue.detail)
    end
    println()
    println("STRUCTURAL_MANIFEST_ID=", report.manifest_id)
    for key in sort(collect(keys(report.counts)))
        println("STRUCTURAL_MANIFEST_COUNT_", uppercase(key), "=", report.counts[key])
    end
    blocking = length(structural_blocking_issues(report))
    println("STRUCTURAL_MANIFEST_BLOCKING_ISSUES=", blocking)

    if report.passed
        println("STRUCTURAL_MANIFEST_VALIDATION=OK")
        return 0
    end
    println("STRUCTURAL_MANIFEST_VALIDATION=FAIL")
    return 1
end

exit(main())
