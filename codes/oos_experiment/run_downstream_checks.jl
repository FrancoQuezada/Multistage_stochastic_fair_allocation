# =====================================================================================
# Downstream reader entry point.
#
# Consumes a generated result directory exactly as an analysis, table or plotting script
# would: from disk, by column name, with no access to the producer's in-memory objects.
# Run by `scripts/oos/preflight_oos_campaign.sh` against the smoke campaign, and usable
# directly against any result directory:
#
#     julia +<manifest channel> --project=. codes/oos_experiment/run_downstream_checks.jl <dir>
#
# Exits nonzero and names the failing check when the directory is not consumable.
# =====================================================================================

const REPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
include(joinpath(REPO_ROOT, "codes", "oos_experiment", "oos_experiment.jl"))

using Printf

function main()
    directory = length(ARGS) >= 1 ? ARGS[1] : get(ENV, "OOS_SMOKE_DIR", "")
    isempty(directory) && error(
        "Indica el directorio de resultados como argumento o vía OOS_SMOKE_DIR."
    )
    expected_replications = tryparse(Int, get(ENV, "OOS_EXPECTED_REPLICATIONS", ""))

    println("Lector downstream sobre: ", directory)
    validation = validate_output_directory(directory; expected_configurations=18)
    enforce_output_schema!(validation; label="campaña smoke")

    recovery = CSV.read(joinpath(directory, "pea_recovery.csv"), DataFrame)
    summary = CSV.read(joinpath(directory, "replication_summary.csv"), DataFrame)
    configuration = CSV.read(joinpath(directory, "configuration_summary.csv"), DataFrame)
    solve_log = CSV.read(joinpath(directory, "solve_log.csv"), DataFrame)
    households = CSV.read(joinpath(directory, "household_summary.csv"), DataFrame)
    paired = CSV.read(joinpath(directory, "paired_statistics.csv"), DataFrame)

    failures = String[]
    check(condition, message) = condition || push!(failures, message)

    # --- completion ---------------------------------------------------------------------
    configurations = length(unique(zip(summary.Controller, summary.Fairness)))
    check(configurations == 18, "se hallaron $configurations configuraciones, no 18")
    if expected_replications !== nothing
        expected_rows = 18 * expected_replications
        check(nrow(summary) == expected_rows,
              "replication_summary tiene $(nrow(summary)) filas, se esperaban $expected_rows")
    end
    incomplete = filter(row -> row.CompletionStatus != "completed", summary)
    check(nrow(incomplete) == 0,
          "configuraciones incompletas: " *
          join(["$(r.Controller)/$(r.Fairness)#$(r.Replication)" for r in eachrow(incomplete)], ", "))

    # --- PEA statistics, recomputed independently from the raw per-period rows ------------
    recomputed = recompute_pea_statistics(recovery)
    println("\nRecomputación independiente desde pea_recovery.csv (banda en kWh):")
    @printf("  %-18s %-22s %8s %8s %12s %12s %10s\n",
            "controlador", "regla", "períodos", "activ.", "media activa", "media todos", "máximo")
    for key in sort(collect(keys(recomputed.per_configuration)))
        stats = recomputed.per_configuration[key]
        @printf("  %-18s %-22s %8d %8d %12.6f %12.6f %10.6f\n",
                key[1], key[2], stats.periods, stats.activations,
                stats.mean_active, stats.mean_all_periods, stats.maximum_band)
        row = filter(r -> r.Controller == key[1] && r.Fairness == key[2], configuration)
        check(nrow(row) == 1, "configuration_summary sin fila única para $key")
        nrow(row) == 1 || continue
        reported = first(row)
        for (column, expected) in (
            ("ConfigPEAToleranceActivations", Float64(stats.activations)),
            ("ConfigPEAToleranceActivationRate", stats.activation_rate),
            ("ConfigPEAToleranceMeanActive", stats.mean_active),
            ("ConfigPEAToleranceMeanAllPeriods", stats.mean_all_periods),
            ("ConfigPEAToleranceMax", stats.maximum_band),
        )
            check(isapprox(Float64(reported[column]), expected; atol=1e-9, rtol=1e-9),
                  "$key $column: CSV $(reported[column]) vs recomputado $expected")
        end
    end

    # An unweighted mean of replication means must NOT be what the configuration reports.
    for key in sort(collect(keys(recomputed.per_configuration)))
        key[2] == "PEA" || continue
        per_replication_means = Float64[]
        for ((controller, policy, _), stats) in recomputed.per_replication
            controller == key[1] && policy == key[2] && stats.activations > 0 &&
                push!(per_replication_means, stats.mean_active)
        end
        length(per_replication_means) >= 2 || continue
        unweighted = sum(per_replication_means) / length(per_replication_means)
        pooled = recomputed.per_configuration[key].mean_active
        if !isapprox(unweighted, pooled; rtol=1e-9)
            println("  $(key[1])/PEA: agrupado $(round(pooled, digits=6)) kWh " *
                    "!= media no ponderada de réplicas $(round(unweighted, digits=6)) kWh " *
                    "(agrupado es el correcto)")
        end
    end

    # --- solve sequences, by semantic label ------------------------------------------------
    activated = Set(
        (row.Replication, row.Controller, row.Period)
        for row in eachrow(recovery) if row.Fairness == "PEA" && row.PEA_Tolerance_Activated
    )
    grouped = Dict{Tuple{Int,String,Int},Vector{String}}()
    for row in eachrow(solve_log)
        row.Fairness == "PEA" || continue
        key = (Int(row.Replication), String(row.Controller), Int(row.Period))
        push!(get!(grouped, key, String[]), String(row.PhaseLabel))
    end
    strict_periods = recovered_periods = 0
    for (key, labels) in grouped
        if key in activated
            recovered_periods += 1
            check(labels == OOS_PEA_RECOVERY_SEQUENCE,
                  "período recuperado $key: secuencia $labels")
        else
            strict_periods += 1
            check(labels == [OOS_SOLVE_LABEL_STRICT], "período estricto $key: secuencia $labels")
        end
    end
    check(recovered_periods > 0,
          "el smoke no produjo ningún período recuperado; la ruta de recuperación no se ejercitó")
    println("\nSecuencias de resolución PEA: $strict_periods período(s) estricto(s) con 1 " *
            "resolución, $recovered_periods recuperado(s) con 4.")

    # The diagnostic solve must never be mistaken for a policy action or an operating cost.
    diagnostic_rows = filter(r -> r.PhaseLabel == OOS_SOLVE_LABEL_DIAGNOSTIC, solve_log)
    check(nrow(diagnostic_rows) == recovered_periods,
          "filas de diagnóstico $(nrow(diagnostic_rows)) != períodos recuperados $recovered_periods")
    phase2_rows = filter(r -> r.PhaseLabel == OOS_IMPLEMENTED_ACTION_SOURCE, solve_log)
    check(nrow(phase2_rows) == recovered_periods,
          "filas de Fase II $(nrow(phase2_rows)) != períodos recuperados $recovered_periods")
    check(all(!isnan, phase2_rows.Objective),
          "alguna Fase II no reporta objetivo operativo")

    # --- units and the absence of an implicit fixed band --------------------------------------
    warnings = SchemaIssue[]
    numeric_eps = oos_column(recovery, "PEA_Tolerance_Numeric_Eps_kWh";
                             warnings=warnings, file="pea_recovery.csv")
    for issue in warnings
        println("  [AVISO] ", issue.detail)
    end
    check(all(value -> value > 0 && value < 1e-3, numeric_eps),
          "epsilon numérico fuera del rango puramente numérico: $(unique(numeric_eps))")
    check(!any(value -> isapprox(Float64(value), 100.0; atol=1e-9), recovery.PEA_Tolerance_Used_kWh),
          "se halló una banda PEA de 100.0 kWh")

    metadata = read_experiment_metadata(joinpath(directory, "experiment_config.json"))
    check(haskey(metadata, "pea_tolerance_numeric_eps_kwh"),
          "falta pea_tolerance_numeric_eps_kwh en los metadatos")
    check(occursin("kWh", get(metadata, "pea_tolerance_numeric_eps_unit", "")),
          "la unidad del epsilon numérico no declara kWh")
    check(get(metadata, "pea_tolerance_mode", "") == "adaptive_minimum",
          "modo PEA en metadatos: $(get(metadata, "pea_tolerance_mode", "ausente"))")
    check(get(metadata, "output_schema_version", "") == string(OOS_OUTPUT_SCHEMA_VERSION),
          "versión de esquema en metadatos: $(get(metadata, "output_schema_version", "ausente"))")

    # --- non-PEA policies ----------------------------------------------------------------------
    for row in eachrow(recovery)
        row.Fairness == "PEA" && continue
        check(row.PEA_Tolerance_Activated == false,
              "$(row.Fairness) declara activación de tolerancia")
        check(Float64(row.PEA_Tolerance_Used_kWh) == 0.0,
              "$(row.Fairness) reporta banda $(row.PEA_Tolerance_Used_kWh)")
    end

    # --- NONE vs STATIC_DEMAND_SHARE remain distinct categories -------------------------------
    policies = sort(unique(String.(summary.Fairness)))
    check("NONE" in policies && "STATIC_DEMAND_SHARE" in policies,
          "faltan NONE y/o STATIC_DEMAND_SHARE: $policies")
    check(length(policies) == 6, "se hallaron $(length(policies)) reglas: $policies")
    for policy in policies
        check(!(policy in ("CPEA", "CSA", "CLEXMMFPEA", "CLEXMMFSA")) &&
              !startswith(policy, "ERDINC"), "política condicional/legada presente: $policy")
    end
    none_pv = sort([(r.Replication, r.House, r.PVAllocation)
                    for r in eachrow(households) if r.Fairness == "NONE" &&
                        r.Controller == "DETERMINISTIC_RH"])
    sds_pv = sort([(r.Replication, r.House, r.PVAllocation)
                   for r in eachrow(households) if r.Fairness == "STATIC_DEMAND_SHARE" &&
                       r.Controller == "DETERMINISTIC_RH"])
    check(length(none_pv) == length(sds_pv) && !isempty(none_pv),
          "NONE y STATIC_DEMAND_SHARE no tienen filas comparables")
    if length(none_pv) == length(sds_pv) && !isempty(none_pv)
        differences = maximum(abs(a[3] - b[3]) for (a, b) in zip(none_pv, sds_pv))
        println("\nNONE vs STATIC_DEMAND_SHARE: max |dPV| = $(round(differences, digits=6)) kWh " *
                "sobre $(length(none_pv)) pares hogar-réplica (categorías separadas).")
    end
    # Paired comparisons must keep them apart as well.
    labels = Set(vcat(String.(paired.Baseline), String.(paired.Comparison)))
    check(any(occursin("NONE", label) for label in labels),
          "paired_statistics no menciona NONE")
    check(any(occursin("STATIC_DEMAND_SHARE", label) for label in labels),
          "paired_statistics no menciona STATIC_DEMAND_SHARE")

    # --- resource metadata ------------------------------------------------------------------------
    expected_resource = Dict("NONE" => "none", "STATIC_DEMAND_SHARE" => "pv", "PEA" => "pv",
                             "SA" => "savings", "LEXMMFPEA" => "pv", "LEXMMFSA" => "savings")
    for row in eachrow(summary)
        check(String(row.Resource) == expected_resource[String(row.Fairness)],
              "Resource $(row.Resource) para $(row.Fairness)")
    end

    # --- incomplete trajectories must be excluded from paired comparisons ----------------------
    completed_pairs = Set(
        (row.Replication, row.Controller, row.Fairness)
        for row in eachrow(summary) if row.CompletionStatus == "completed"
    )
    for row in eachrow(paired)
        occursin("difference", String(row.Metric)) || continue
        Int(row.Observations) <= length(completed_pairs) ||
            push!(failures, "una comparación pareada usa más observaciones que réplicas completas")
    end

    println()
    if isempty(failures)
        println("DOWNSTREAM_READER=OK")
        println("Todas las verificaciones downstream pasaron.")
        return 0
    end
    println("DOWNSTREAM_READER=FAIL")
    for failure in failures
        println("  [FALLA] ", failure)
    end
    return 1
end

exit(main())
