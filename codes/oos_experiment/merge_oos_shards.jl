# =====================================================================================
# Deterministic shard merge (redesign stage 13).
#
# Fuses a shard root into one campaign dataset in canonical manifest order — never in completion
# order — and refuses to produce anything at all while the set is incomplete, duplicated or in
# conflict. The campaign aggregates are recomputed here, once, from the merged replication-level
# rows: a shard holds one replication of one paired base, so an aggregate over replications
# cannot be concatenated out of the shards.
#
#     bash scripts/oos/merge_oos_shards.sh
#
# REQUIRED:
#     STRUCTURAL_MANIFEST_PATH   the same manifest the shards were run from
#     OOS_SHARD_ROOT             directory the shards were committed under
#     OOS_MERGED_DIR             destination of the merged campaign dataset
#
# Optional:
#     OOS_REPLICATIONS           R override; must match the value the shards were run with
#     FORMULATION_ID             recorded for traceability only
#     OOS_CAMPAIGN_REVIEW        0 to skip the stage-14 operational review (default on)
# =====================================================================================

const REPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
include(joinpath(REPO_ROOT, "codes", "oos_experiment", "oos_experiment.jl"))

function _need(name::AbstractString, description::AbstractString)
    raw = strip(get(ENV, String(name), ""))
    isempty(raw) && error("Falta la entrada obligatoria $name ($description).")
    return String(raw)
end

function main()
    manifest_path = _need("STRUCTURAL_MANIFEST_PATH", "manifiesto estructural de la campaña")
    shard_root = _need("OOS_SHARD_ROOT", "raíz de shards de la campaña")
    output_directory = _need("OOS_MERGED_DIR", "destino del dataset fusionado")

    raw = strip(get(ENV, "OOS_REPLICATIONS", ""))
    replications = isempty(raw) ? nothing : parse(Int, raw)
    enumeration = oos_tasks_from_manifest(manifest_path; replications=replications)
    expected = [task.task_id for task in enumeration.tasks]

    println("=== Merge determinista de shards ===")
    println("manifiesto   : ", manifest_path)
    println("manifest_id  : ", enumeration.manifest_id)
    println("shard root   : ", shard_root)
    println("destino      : ", output_directory)
    println("tareas espera: ", length(expected))
    println()

    report = merge_oos_shards(shard_root, output_directory, expected)
    println(report.detail)
    if !report.merged
        println()
        println("OOS_MERGE_STATUS=refused")
        exit(1)
    end

    for file in sort(collect(keys(report.files)))
        println("  ", rpad(file, 34), report.files[file], " filas")
    end

    # The merged dataset is validated the way a downstream reader would, and its summaries are
    # recomputed from the raw period rows. A merge that passes structurally but reports summaries
    # the period rows do not support is not a usable campaign.
    println()
    validation = validate_output_directory(output_directory)
    blocking = blocking_issues(validation)
    println("validación de esquema : ", isempty(blocking) ? "OK" :
            "$(length(blocking)) problemas bloqueantes")
    for issue in blocking
        println("  ", issue.file, " :: ", issue.detail)
    end

    recompute = recompute_from_period_rows(output_directory)
    println("recómputo independiente: ", recomputation_summary(recompute))
    for mismatch in recompute.mismatches[1:min(8, end)]
        println("  ", mismatch.key, ": reportado ", mismatch.reported,
                ", recomputado ", mismatch.recomputed)
    end

    # Schema validity is not fitness. The review asks the separate question stage 14 needs
    # answered before scaling up: is the EXPERIMENT this dataset records fit to run larger?
    review = nothing
    if lowercase(get(ENV, "OOS_CAMPAIGN_REVIEW", "1")) in ("1", "true", "yes")
        println()
        analysis = write_campaign_analysis(output_directory, manifest_path)
        println("análisis por celda: ", analysis.cost_rows, " filas de costo, ",
                analysis.paired_rows, " filas pareadas")
        for path in analysis.paths
            println("  ", basename(path))
        end
        println()
        review = review_campaign(output_directory, manifest_path)
        print_campaign_review(review)
    end

    println()
    passed = isempty(blocking) && recompute.passed
    println("OOS_MERGE_STATUS=", passed ? "ok" : "failed")
    review === nothing || println("OOS_CAMPAIGN_REVIEW_STATUS=",
                                  campaign_review_ready(review) ? "ok" : "blocked")
    println("OOS_MERGED_DIR=", output_directory)
    passed || exit(1)
end

main()
