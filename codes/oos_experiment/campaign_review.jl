# =====================================================================================
# Campaign operational review (redesign stage 14).
#
# Turns a merged campaign dataset into the go / no-go evidence plan section 7 (Stage 14) demands
# before a confirmatory run: completeness, infeasibility, recovery incidence, numerical
# diagnostics, runtime and memory — plus the paired effects, read at the unit section 8 requires.
#
# This is NOT the schema validator. `validate_output_directory` asks whether the dataset is
# well-formed; this asks whether the EXPERIMENT it records is fit to scale up. A dataset can be
# perfectly well-formed and still be unfit — a policy that aborted in half the cells, a solver
# that hit its time limit, a band that had to open in every period.
#
# The design cell of each row comes from the MANIFEST, not from parsing an identifier: the
# manifest is the campaign's authority and already records `battery_level`, `uncertainty_level`
# and `demand_regime` per structural instance.
# =====================================================================================

"""One design cell of the structural catalog, with the run outcomes that landed in it."""
struct CampaignCell
    structural_instance_id::String
    battery_level::String
    uncertainty_level::String
    demand_regime::String
    structural_draw::Int
    expected_runs::Int
    completed_runs::Int
    aborted_runs::Int
    aborted_policies::Vector{String}
    optimization_failures::Int
    physical_violations::Int
    max_physical_residual::Float64
    max_fairness_residual::Float64
end

"""Outcome of reviewing a merged campaign dataset for fitness to scale up."""
struct CampaignReview
    directory::String
    manifest_id::String
    freeze::NamedTuple
    cells::Vector{CampaignCell}
    replications::Int
    recovery::Vector{NamedTuple}
    numerics::NamedTuple
    runtime::NamedTuple
    paired::Vector{NamedTuple}
    blocking::Vector{String}
    warnings::Vector{String}
end

campaign_review_ready(review::CampaignReview) = isempty(review.blocking)

"""
Review a merged campaign dataset against the manifest it was produced from.

Reads only the merged CSVs and the manifest; recomputes nothing the campaign already computed
except where the review's question differs from the producer's.
"""
function review_campaign(directory::AbstractString, manifest_path::AbstractString)
    document = canonical_json_parse(read(String(manifest_path), String))
    instances = document["structural_instances"]
    manifest_id = String(document["manifest_id"])

    replications = CSV.read(joinpath(directory, "replication_summary.csv"), DataFrame)
    solves = CSV.read(joinpath(directory, "solve_log.csv"), DataFrame)
    recovery_frame = CSV.read(joinpath(directory, "pea_recovery.csv"), DataFrame)
    provenance_path = joinpath(directory, "solve_provenance.csv")
    provenance = isfile(provenance_path) ? CSV.read(provenance_path, DataFrame) : nothing
    statistics = CSV.read(joinpath(directory, "paired_statistics.csv"), DataFrame)

    blocking = String[]
    warnings = String[]

    # --- the freeze, verified rather than asserted in prose ------------------------------------
    #
    # Plan section 7 (Stage 14) requires the code version, manifest, calibrated levels, solver
    # configuration, schema versions, task granularity and merge procedure to be FROZEN before a
    # confirmatory run. Every one of those is already recorded by the producer, so the freeze is
    # a check, not a document: `code_dirty` self-declares a tree that cannot be reproduced, and
    # an unpinned solver thread count makes the result machine-dependent through CPLEX's
    # tie-breaking among equally optimal solutions.
    metadata = read_experiment_metadata(joinpath(directory, "experiment_config.json"))
    dirty = lowercase(String(get(metadata, "code_dirty", "true"))) in ("true", "1", "yes")
    # `read_experiment_metadata` flattens the document line by line, so the solver's thread
    # setting arrives under its own key rather than under `solver_settings`.
    threads = something(tryparse(Int, String(get(metadata, "threads", ""))), -1)
    freeze = (
        code_commit=String(get(metadata, "code_commit", "")),
        code_dirty=dirty,
        julia_version=String(get(metadata, "julia_version", "")),
        solver=String(get(metadata, "solver", "")),
        solver_threads=threads,
        mip_gap=something(tryparse(Float64, String(get(metadata, "mip_gap", ""))), NaN),
        output_schema_version=String(get(metadata, "output_schema_version", "")),
        pea_solve_sequence_version=String(get(metadata, "pea_solve_sequence_version", "")),
    )
    dirty && push!(blocking,
        "el árbol de código estaba sucio al producir el dataset (code_dirty=true): la campaña " *
        "confirmatoria no puede referirse a una versión que no existe en el historial")
    threads == 1 || push!(blocking,
        "hilos de solver = $(threads == -1 ? "sin registrar" : string(threads)); la campaña " *
        "exige exactamente 1 por trabajador, porque el número de hilos cambia el desempate de " *
        "CPLEX entre óptimos equivalentes y el resultado dejaría de reproducirse entre máquinas")

    replication_ids = sort(unique(Int.(replications.Replication)))
    controllers = sort(unique(String.(replications.Controller)))
    policies = sort(unique(String.(replications.Fairness)))
    expected_runs = length(replication_ids) * length(controllers) * length(policies)

    # --- per design cell ------------------------------------------------------------------
    cells = CampaignCell[]
    for entry in instances
        identifier = String(entry["structural_instance_id"])
        rows = filter(r -> String(r.StructuralInstanceID) == identifier, replications)
        completed = filter(r -> r.CompletionStatus == "completed", rows)
        aborted = filter(r -> r.CompletionStatus != "completed", rows)
        push!(cells, CampaignCell(
            identifier,
            String(entry["battery_level"]), String(entry["uncertainty_level"]),
            String(entry["demand_regime"]), Int(entry["structural_draw"]),
            expected_runs, nrow(completed), nrow(aborted),
            sort(unique(String.(aborted.Fairness))),
            sum(Int.(rows.OptimizationFailures); init=0),
            sum(Int.(rows.PhysicalViolations); init=0),
            isempty(completed) ? NaN : maximum(Float64.(completed.MaxPhysicalResidual)),
            isempty(completed) ? NaN : maximum(Float64.(completed.MaxFairnessResidual)),
        ))
    end

    # Completeness is the first gate: a cell missing runs cannot enter a paired analysis, and a
    # POLICY missing from some cells and not others silently unbalances the design.
    for cell in cells
        if cell.completed_runs + cell.aborted_runs < cell.expected_runs
            push!(blocking, "celda $(cell.structural_instance_id): " *
                  "$(cell.completed_runs + cell.aborted_runs)/$(cell.expected_runs) corridas presentes")
        end
        isempty(cell.aborted_policies) || push!(blocking,
            "celda $(cell.structural_instance_id): abortaron $(cell.aborted_runs) corridas " *
            "de $(join(cell.aborted_policies, ", "))")
        cell.physical_violations == 0 || push!(blocking,
            "celda $(cell.structural_instance_id): $(cell.physical_violations) violaciones físicas")
    end
    # A policy that aborts in SOME cells and completes in others is worse than one that fails
    # everywhere: the design silently loses a factor level in part of the catalog, and any
    # comparison involving that policy is then taken over a different set of cells than the
    # others. That asymmetry is what makes it blocking rather than a warning.
    unbalanced = [
        policy for policy in policies
        if any(cell -> policy in cell.aborted_policies, cells) &&
           any(cell -> !(policy in cell.aborted_policies), cells)
    ]
    isempty(unbalanced) || push!(blocking,
        "diseño desbalanceado: $(join(unbalanced, ", ")) completa en unas celdas y no en otras")

    # --- recovery incidence, per policy ------------------------------------------------------
    recovery = NamedTuple[]
    for policy in sort(unique(String.(recovery_frame.Fairness)))
        rows = filter(r -> String(r.Fairness) == policy, recovery_frame)
        bands = Float64.(rows.PEA_Tolerance_Used_kWh)
        active = filter(>(OOS_PEA_ACTIVATION_THRESHOLD), bands)
        strict = count(r -> r.PEA_Strict_Feasible === true, eachrow(rows))
        push!(recovery, (
            policy=policy, periods=length(bands), activations=length(active),
            rate=isempty(bands) ? 0.0 : length(active) / length(bands),
            mean_active=isempty(active) ? 0.0 : sum(active) / length(active),
            maximum_band=isempty(bands) ? 0.0 : maximum(bands),
            strict_feasible=strict,
        ))
    end
    for entry in recovery
        # A band that opens in essentially every period is not a recovery mechanism any more;
        # it has become the model, and the policy no longer means what its name says.
        entry.rate > 0.95 && entry.periods > 0 && push!(warnings,
            "$(entry.policy): la banda se activa en el $(round(100 * entry.rate, digits=1)) % " *
            "de los períodos (máx $(round(entry.maximum_band, digits=2)) kWh); la política " *
            "prácticamente nunca es estrictamente factible")
    end

    # --- numerical diagnostics ----------------------------------------------------------------
    statuses = Dict{String,Int}()
    for row in eachrow(solves)
        status = String(row.TerminationStatus)
        statuses[status] = get(statuses, status, 0) + 1
    end
    gaps = [Float64(g) for g in solves.FinalGap if !ismissing(g) && isfinite(Float64(g))]

    # The fairness residual must be read against the tolerance the POLICY declares, not against
    # zero. A lexicographic policy legitimately consumes its own `lex_eps_abs` — the raw maximum
    # is then ~1.0 and looks alarming next to a physical residual of 1e-14, while meaning nothing
    # of the sort. A non-lexicographic policy has no such allowance, so for those the same number
    # would be a real violation, and only that case is worth blocking on.
    lexicographic = ["LEXMMFPEA", "LEXMMFSA"]
    lex_rows = filter(r -> String(r.Fairness) in lexicographic, solves)
    other_rows = filter(r -> !(String(r.Fairness) in lexicographic), solves)
    lexicographic_residual = maximum(Float64.(lex_rows.FairnessResidual); init=0.0)
    non_lexicographic_residual = maximum(Float64.(other_rows.FairnessResidual); init=0.0)
    lex_tolerance = something(
        tryparse(Float64, String(get(metadata, "lex_eps_abs", ""))), 1.0)
    feasibility = something(
        tryparse(Float64, String(get(metadata, "feasibility_tol", ""))), 1e-5)
    non_lexicographic_residual <= feasibility || push!(blocking,
        "residuo de fairness $(non_lexicographic_residual) en una política NO lexicográfica, " *
        "por encima de la tolerancia de factibilidad $(feasibility): esas políticas no tienen " *
        "banda propia, así que el residuo es una violación de la regla")
    lexicographic_residual <= lex_tolerance * (1 + 1e-6) || push!(blocking,
        "residuo de fairness $(lexicographic_residual) por encima de lex_eps_abs " *
        "$(lex_tolerance): la política lexicográfica excedió su propia tolerancia declarada")
    time_limited = count(s -> occursin("TIME_LIMIT", uppercase(String(s))),
                         String.(solves.TerminationStatus))
    numerics = (
        solves=nrow(solves), statuses=statuses, time_limited=time_limited,
        max_gap=isempty(gaps) ? 0.0 : maximum(gaps),
        mean_gap=isempty(gaps) ? 0.0 : sum(gaps) / length(gaps),
        max_physical_residual=maximum(Float64.(solves.MaxPhysicalResidual); init=0.0),
        max_fairness_residual=maximum(Float64.(solves.FairnessResidual); init=0.0),
        lexicographic_residual=lexicographic_residual,
        non_lexicographic_residual=non_lexicographic_residual,
    )
    # A solve that stopped on its time limit reports a feasible incumbent, not an optimum. The
    # comparison between controllers then partly measures how far each got, not what each is.
    time_limited == 0 || push!(blocking,
        "$(time_limited) solves terminaron por límite de tiempo: el óptimo no está garantizado " *
        "y la comparación entre controladores mediría cuán lejos llegó cada uno")

    # --- runtime and memory, the sizing input --------------------------------------------------
    if provenance === nothing
        runtime = (solves=0, total_solver_sec=NaN, max_solve_sec=NaN, mean_solve_sec=NaN,
                   peak_memory_mb=NaN, tasks=0, max_task_sec=NaN)
        push!(warnings, "sin solve_provenance.csv: no hay evidencia de runtime ni de memoria")
    else
        seconds = Float64.(provenance.SolverTimeSec)
        by_task = Dict{String,Float64}()
        for row in eachrow(provenance)
            key = String(row.ParallelTaskID)
            by_task[key] = get(by_task, key, 0.0) + Float64(row.SolverTimeSec)
        end
        runtime = (
            solves=nrow(provenance),
            total_solver_sec=sum(seconds; init=0.0),
            max_solve_sec=maximum(seconds; init=0.0),
            mean_solve_sec=isempty(seconds) ? 0.0 : sum(seconds) / length(seconds),
            peak_memory_mb=maximum(Float64.(provenance.PeakMemoryMB); init=0.0),
            tasks=length(by_task),
            max_task_sec=isempty(by_task) ? 0.0 : maximum(values(by_task)),
        )
    end

    # --- paired effects on operating cost -------------------------------------------------------
    paired = NamedTuple[]
    for row in eachrow(statistics)
        String(row.Metric) == "total_operating_cost__controller_difference" || continue
        push!(paired, (
            baseline=String(row.Baseline), comparison=String(row.Comparison),
            observations=Int(row.Observations), mean=Float64(row.Mean),
            relative_percent=Float64(row.MeanRelativePercent),
            confidence_low=Float64(row.ConfidenceLow),
            confidence_high=Float64(row.ConfidenceHigh),
        ))
    end

    return CampaignReview(
        String(directory), manifest_id, freeze, cells, length(replication_ids),
        recovery, numerics, runtime, paired, blocking, warnings,
    )
end

"""Print the review as the go / no-go evidence sheet it is."""
function print_campaign_review(review::CampaignReview)
    println("=== Revisión operativa de campaña ===")
    println("dataset     : ", review.directory)
    println("manifest_id : ", review.manifest_id)
    println("réplicas    : ", review.replications)
    println("\n--- congelamiento ---")
    println("  commit=", review.freeze.code_commit[1:min(12, end)],
            review.freeze.code_dirty ? "  [ÁRBOL SUCIO]" : "  [limpio]",
            "  julia=", review.freeze.julia_version,
            "  ", review.freeze.solver,
            "  hilos=", review.freeze.solver_threads,
            "  gap MIP=", review.freeze.mip_gap)
    println("  esquema de salida v", review.freeze.output_schema_version,
            "  secuencia PEA v", review.freeze.pea_solve_sequence_version)

    println("\n--- completitud por celda del diseño ---")
    println("  ", rpad("batería", 14), rpad("incert.", 16), rpad("régimen", 15),
            rpad("sorteo", 8), rpad("completas", 12), "abortadas")
    for cell in review.cells
        println("  ", rpad(cell.battery_level, 14), rpad(cell.uncertainty_level, 16),
                rpad(cell.demand_regime, 15), rpad(string(cell.structural_draw), 8),
                rpad("$(cell.completed_runs)/$(cell.expected_runs)", 12),
                cell.aborted_runs == 0 ? "-" :
                    "$(cell.aborted_runs) ($(join(cell.aborted_policies, ",")))")
    end

    println("\n--- incidencia de recuperación por política ---")
    for entry in review.recovery
        println("  ", rpad(entry.policy, 20),
                "períodos=", lpad(entry.periods, 5),
                "  activaciones=", lpad(entry.activations, 5),
                " (", lpad(round(100 * entry.rate, digits=1), 5), " %)",
                "  banda media activa=", round(entry.mean_active, digits=3),
                "  máx=", round(entry.maximum_band, digits=3))
    end

    println("\n--- diagnósticos numéricos ---")
    println("  solves=", review.numerics.solves,
            "  por límite de tiempo=", review.numerics.time_limited)
    println("  estados: ", join(["$k=$v" for (k, v) in sort(collect(review.numerics.statuses))], "  "))
    println("  gap final máx=", review.numerics.max_gap,
            "  medio=", review.numerics.mean_gap)
    println("  residuo físico máx=", review.numerics.max_physical_residual)
    println("  residuo de fairness: lexicográficas=", review.numerics.lexicographic_residual,
            " (contra su lex_eps_abs)  resto=", review.numerics.non_lexicographic_residual,
            " (contra la tolerancia de factibilidad)")

    println("\n--- runtime y memoria (base para dimensionar la campaña) ---")
    println("  solves cronometrados=", review.runtime.solves,
            "  tiempo total de solver=", round(review.runtime.total_solver_sec, digits=1), " s")
    println("  por solve: medio=", round(review.runtime.mean_solve_sec, digits=3),
            " s  máx=", round(review.runtime.max_solve_sec, digits=3), " s")
    println("  por tarea: máx=", round(review.runtime.max_task_sec, digits=1), " s",
            "  sobre ", review.runtime.tasks, " tareas")
    println("  memoria pico=", round(review.runtime.peak_memory_mb, digits=1), " MB")

    println("\n--- efecto pareado sobre el costo de operación ---")
    println("  (unidad: par (instancia estructural, réplica); positivo = la comparación es más cara)")
    for entry in review.paired
        println("  ", rpad(entry.baseline, 26), " -> ", rpad(entry.comparison, 26),
                " n=", lpad(entry.observations, 4),
                "  media=", lpad(round(entry.mean, digits=2), 12),
                " (", round(entry.relative_percent, digits=4), " %)",
                "  IC95=[", round(entry.confidence_low, digits=2), ", ",
                round(entry.confidence_high, digits=2), "]")
    end

    println()
    if isempty(review.blocking)
        println("SIN BLOQUEANTES: el piloto habilita la campaña confirmatoria.")
    else
        println("BLOQUEANTES (", length(review.blocking), "):")
        for issue in review.blocking
            println("  - ", issue)
        end
    end
    for warning in review.warnings
        println("  aviso: ", warning)
    end
    return nothing
end

# -------------------------------------------------------------------------------------
# Campaign analysis outputs (stage 14)
# -------------------------------------------------------------------------------------

"""
Write the two analysis tables plan section 7 (Stage 14) requires from a merged dataset.

`campaign_cost_by_cell.csv` reports cost crossed with every design dimension the plan names —
controller, fairness policy, resource, objective criterion, battery level, demand regime,
uncertainty level and implementation step — instead of pooling them away.

`campaign_paired_by_cell.csv` reports the controller effect **within** each cell, differenced
across the replications of that cell. That is the unit section 8 requires: controller-policy rows
sharing one out-of-sample path are not independent observations, so the difference is taken
inside the `(structural instance, replication)` pair and only then averaged. Pooling first and
differencing after would discard the pairing that gives the estimate its precision.

Both are derived, reproducible from the row-level data, and written next to it.
"""
function write_campaign_analysis(directory::AbstractString, manifest_path::AbstractString)
    document = canonical_json_parse(read(String(manifest_path), String))
    replications = CSV.read(joinpath(directory, "replication_summary.csv"), DataFrame)
    identity_path = joinpath(directory, "run_identity.csv")
    identities = isfile(identity_path) ? CSV.read(identity_path, DataFrame) : nothing

    design = document["design"]
    step = Int(design["implementation_step"])
    factors = Dict{String,NamedTuple}()
    for entry in document["structural_instances"]
        factors[String(entry["structural_instance_id"])] = (
            battery=String(entry["battery_level"]),
            uncertainty=String(entry["uncertainty_level"]),
            regime=String(entry["demand_regime"]),
            draw=Int(entry["structural_draw"]),
            theta=Float64(entry["theta"]),
            battery_scale=Float64(entry["battery_scale"]),
        )
    end

    criterion = OOS_OBJECTIVE_CRITERION
    resource_of = Dict{Tuple{String,String},String}()
    if identities !== nothing
        for row in eachrow(identities)
            resource_of[(String(row.Controller), String(row.Fairness))] = String(row.Resource)
        end
    end

    completed = filter(r -> r.CompletionStatus == "completed", replications)
    cells = sort(unique(String.(completed.StructuralInstanceID)))
    controllers = sort(unique(String.(completed.Controller)))
    policies = sort(unique(String.(completed.Fairness)))

    # --- costs crossed with every design dimension ---------------------------------------
    costs = DataFrame(
        StructuralInstanceID=String[], BatteryLevel=String[], DemandRegime=String[],
        UncertaintyLevel=String[], StructuralDraw=Int[], Theta=Float64[], BatteryScale=Float64[],
        ImplementationStep=Int[], Controller=String[], Fairness=String[], Resource=String[],
        ObjectiveCriterion=String[], Replications=Int[],
        MeanOperatingCost=Float64[], StdOperatingCost=Float64[],
        MeanSavings=Float64[], MeanMinHouseholdPV=Float64[], MeanMinHouseholdSavings=Float64[],
        MeanMaxPVRelativeDeviation=Float64[], MeanMaxSavingsRelativeDeviation=Float64[],
    )
    mean_of(values) = isempty(values) ? NaN : sum(values) / length(values)
    for cell in cells, controller in controllers, policy in policies
        rows = filter(
            r -> String(r.StructuralInstanceID) == cell &&
                 String(r.Controller) == controller && String(r.Fairness) == policy,
            completed,
        )
        nrow(rows) > 0 || continue
        factor = factors[cell]
        operating = Float64.(rows.TotalOperatingCost)
        mean_cost = mean_of(operating)
        push!(costs, (
            cell, factor.battery, factor.regime, factor.uncertainty, factor.draw,
            factor.theta, factor.battery_scale, step, controller, policy,
            get(resource_of, (controller, policy), ""), criterion, length(operating),
            mean_cost,
            length(operating) > 1 ?
                sqrt(sum((x - mean_cost)^2 for x in operating) / (length(operating) - 1)) : 0.0,
            mean_of(Float64.(rows.TotalSavings)),
            mean_of(Float64.(rows.MinHouseholdPV)),
            mean_of(Float64.(rows.MinHouseholdSavings)),
            mean_of(Float64.(rows.MaxPVRelativeDeviation)),
            mean_of(Float64.(rows.MaxSavingsRelativeDeviation)),
        ))
    end
    cost_path = joinpath(directory, "campaign_cost_by_cell.csv")
    CSV.write(cost_path, canonical_row_sort(costs))

    # --- paired controller effect, differenced inside each cell ----------------------------
    paired = DataFrame(
        StructuralInstanceID=String[], BatteryLevel=String[], DemandRegime=String[],
        UncertaintyLevel=String[], StructuralDraw=Int[], ImplementationStep=Int[],
        Fairness=String[], Baseline=String[], Comparison=String[],
        ObjectiveCriterion=String[], PairedObservations=Int[],
        MeanDifference=Float64[], StdDifference=Float64[], StandardError=Float64[],
        ConfidenceLow=Float64[], ConfidenceHigh=Float64[], MeanRelativePercent=Float64[],
        RelativeDenominatorFloor=Float64[], ZeroDenominatorObservations=Int[],
    )
    indexed = Dict{Tuple{String,Int,String,String},Float64}()
    for row in eachrow(completed)
        indexed[(String(row.StructuralInstanceID), Int(row.Replication),
                 String(row.Controller), String(row.Fairness))] =
            Float64(row.TotalOperatingCost)
    end
    for cell in cells, policy in policies
        replication_ids = sort(unique([
            Int(r.Replication) for r in eachrow(completed)
            if String(r.StructuralInstanceID) == cell && String(r.Fairness) == policy
        ]))
        for a in eachindex(controllers), b in eachindex(controllers)
            a < b || continue
            differences = Float64[]
            baselines = Float64[]
            comparisons = Float64[]
            for replication in replication_ids
                left = get(indexed, (cell, replication, controllers[a], policy), nothing)
                right = get(indexed, (cell, replication, controllers[b], policy), nothing)
                (left === nothing || right === nothing) && continue
                push!(baselines, left)
                push!(comparisons, right)
                push!(differences, right - left)
            end
            isempty(differences) && continue
            factor = factors[cell]
            n = length(differences)
            mean_difference = sum(differences) / n
            sd = n > 1 ?
                sqrt(sum((d - mean_difference)^2 for d in differences) / (n - 1)) : 0.0
            se = n > 1 ? sd / sqrt(n) : 0.0
            relative, excluded = paired_relative_differences(baselines, comparisons)
            push!(paired, (
                cell, factor.battery, factor.regime, factor.uncertainty, factor.draw, step,
                policy, controllers[a], controllers[b], criterion, n,
                mean_difference, sd, se,
                mean_difference - 1.96 * se, mean_difference + 1.96 * se,
                isempty(relative) ? NaN : 100 * sum(relative) / length(relative),
                OOS_RELATIVE_COMPARATOR_FLOOR, excluded,
            ))
        end
    end
    paired_path = joinpath(directory, "campaign_paired_by_cell.csv")
    CSV.write(paired_path, canonical_row_sort(paired))

    return (cost_rows=nrow(costs), paired_rows=nrow(paired),
            paths=[cost_path, paired_path])
end
