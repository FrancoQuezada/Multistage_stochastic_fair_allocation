# =====================================================================================
# Reference downstream reader and schema validator for the out-of-sample outputs.
#
# This is the one sanctioned *consumer* of `results_oos/`. It reads the generated files
# from disk exactly as any analysis, table or plotting script would, validates their
# schema, and independently recomputes the PEA tolerance statistics so a producer-side
# regression cannot hide behind its own aggregation.
#
# Any future analysis script should follow this file's conventions:
#   * address solves by their semantic label, never by the raw `Phase` integer;
#   * take the resource from the explicit `Resource` column, never from the rule name;
#   * gate horizon-total comparisons on `CompletionStatus` / `HorizonCovered`;
#   * keep `NONE` and `STATIC_DEMAND_SHARE` as distinct categories.
# =====================================================================================

"""
Version of the generated output interface.

Bump whenever a column is renamed or removed, or the solve sequence changes. It is written
to `experiment_config.json` so a result directory can always be matched to a reader.

  * `1` — initial adaptive-PEA interface (`PEA_Tolerance_Numeric_Eps` unitless name,
          three-solve recovery logging). **Obsolete.**
  * `2` — current: `PEA_Tolerance_Numeric_Eps_kWh`, metadata keys
          `pea_tolerance_numeric_eps_kwh` / `pea_tolerance_numeric_eps_unit`, and the
          four-solve recovery sequence `0=strict, 1=diagnostic, 2=Phase I, 3=Phase II`.
"""
const OOS_OUTPUT_SCHEMA_VERSION = 2

"""Semantic solve labels. Downstream code must match on these, not on `Phase` integers."""
const OOS_SOLVE_LABEL_STRICT = "single_solve"
const OOS_SOLVE_LABEL_DIAGNOSTIC = "pea_diagnostic_physical"
const OOS_SOLVE_LABEL_PHASE1 = "pea_phase1_min_tolerance"
const OOS_SOLVE_LABEL_PHASE2 = "pea_phase2_operational"

"""The exact solve sequence of a recovered PEA period, in execution order."""
const OOS_PEA_RECOVERY_SEQUENCE = [
    OOS_SOLVE_LABEL_STRICT, OOS_SOLVE_LABEL_DIAGNOSTIC,
    OOS_SOLVE_LABEL_PHASE1, OOS_SOLVE_LABEL_PHASE2,
]

"""Label -> canonical `Phase` integer. Provided for validation, not for filtering."""
const OOS_SOLVE_PHASE_INDEX = Dict(
    OOS_SOLVE_LABEL_STRICT => 0,
    OOS_SOLVE_LABEL_DIAGNOSTIC => 1,
    OOS_SOLVE_LABEL_PHASE1 => 2,
    OOS_SOLVE_LABEL_PHASE2 => 3,
)

"""The solve whose solution is implemented when recovery ran."""
const OOS_IMPLEMENTED_ACTION_SOURCE = OOS_SOLVE_LABEL_PHASE2

"""Admissible values of the explicit `Resource` column."""
const OOS_RESOURCE_VALUES = ("none", "pv", "savings")

"""
Columns every reader may rely on, per file.

A missing required column is an error, never a silent fallback: an analysis that cannot see
`HorizonCovered` would silently compare truncated trajectories against complete ones.
"""
const OOS_REQUIRED_COLUMNS = Dict(
    "replication_summary.csv" => [
        "ExperimentID", "Replication", "Controller", "Fairness", "FormulationID",
        "FormulationVariant", "Resource", "CompletionStatus", "PeriodsCompleted",
        "HorizonCovered", "TotalOperatingCost", "AllGridBenchmark", "TotalSavings",
        "PEAToleranceActivations", "PEAToleranceActivationRate", "PEAToleranceMeanActive",
        "PEAToleranceMeanAllPeriods", "PEAToleranceMax", "PEAStrictFeasiblePeriods",
    ],
    "household_summary.csv" => [
        "ExperimentID", "Replication", "Controller", "Fairness", "FormulationID",
        "Resource", "House", "Demand", "PVAllocation", "OperatingCost", "Savings",
    ],
    "pea_recovery.csv" => [
        "FormulationID", "Replication", "Controller", "Fairness", "Resource", "Period",
        "PEA_Applicable", "PEA_Strict_Feasible", "PEA_Tolerance_Activated",
        "PEA_Tolerance_Used_kWh", "PEA_Strict_Status", "PEA_Phase1_Status",
        "PEA_Phase2_Status", "PEA_Recovery_Status", "Failure_Source",
        "PEA_Tolerance_Mode", "PEA_Tolerance_Numeric_Eps_kWh",
    ],
    "solve_log.csv" => [
        "Replication", "Period", "Controller", "Fairness", "FormulationID",
        "Phase", "PhaseLabel", "TerminationStatus", "Objective",
        "SolveWallTimeSec", "SolverTimeSec",
    ],
    "configuration_summary.csv" => [
        "ExperimentID", "FormulationID", "Controller", "Fairness", "Resource",
        "Replications", "CompletedReplications", "PeriodsSolved",
        "ConfigPEAToleranceActivations", "ConfigPEAToleranceActivationRate",
        "ConfigPEAToleranceMeanActive", "ConfigPEAToleranceMeanAllPeriods",
        "ConfigPEAToleranceMax", "ConfigPEAStrictFeasiblePeriods",
    ],
    "paired_statistics.csv" => [
        "ExperimentID", "FormulationID", "Metric", "Baseline", "Comparison",
        "Observations", "Mean", "StandardDeviation", "StandardError",
    ],
)

"""
User-facing column names retired by a schema bump.

`historical => current`. A historical directory can still be read, with an explicit warning,
via `oos_column`; the current campaign schema is always preferred.
"""
const OOS_OBSOLETE_COLUMNS = Dict(
    "PEA_Tolerance_Numeric_Eps" => "PEA_Tolerance_Numeric_Eps_kWh",
)

"""Metadata keys retired by a schema bump: `historical => current`."""
const OOS_OBSOLETE_METADATA_KEYS = Dict(
    "pea_tolerance_numeric_eps" => "pea_tolerance_numeric_eps_kwh",
)

# -------------------------------------------------------------------------------------
# Reading helpers
# -------------------------------------------------------------------------------------

"""One problem found while validating a result directory."""
struct SchemaIssue
    file::String
    severity::Symbol      # :error or :warning
    detail::String
end

is_blocking(issue::SchemaIssue) = issue.severity === :error

"""
Resolve a column, preferring the current name and accepting a documented historical alias.

The historical `PEA_Tolerance_Numeric_Eps` was always a kWh quantity — it was merely named
without its unit — so reading it as kWh is correct, not an assumption. A warning is emitted so
a historical directory can never be mistaken for a current one.
"""
function oos_column(frame::DataFrame, name::AbstractString; warnings::Vector{SchemaIssue}=SchemaIssue[],
                    file::AbstractString="")
    columns = names(frame)
    String(name) in columns && return frame[!, name]
    for (historical, current) in OOS_OBSOLETE_COLUMNS
        if current == String(name) && historical in columns
            push!(warnings, SchemaIssue(
                String(file), :warning,
                "columna histórica `$historical` en lugar de `$current`; se interpreta en kWh " *
                "(el valor histórico siempre fue kWh, solo faltaba la unidad en el nombre)",
            ))
            return frame[!, historical]
        end
    end
    error("Falta la columna requerida `$name`" * (isempty(file) ? "" : " en $file") * ".")
end

"""
Flat scalar view of `experiment_config.json`.

Deliberately minimal: the file is machine-generated with one `"key": value` pair per line, and
this validator only needs scalar lookups. It is not a general JSON parser, and nested keys are
flattened (last occurrence wins), which is safe because the keys it checks are unique.
"""
function read_experiment_metadata(path::AbstractString)
    isfile(path) || error("No existe el archivo de metadatos: $path")
    values = Dict{String,String}()
    for line in eachline(path)
        match_result = match(r"^\s*\"([^\"]+)\"\s*:\s*(.+?),?\s*$", line)
        match_result === nothing && continue
        key = match_result.captures[1]
        raw = strip(match_result.captures[2])
        (raw == "{" || raw == "[") && continue
        values[key] = strip(raw, ['"'])
    end
    return values
end

# -------------------------------------------------------------------------------------
# Independent PEA recomputation
# -------------------------------------------------------------------------------------

"""
Recompute the PEA tolerance statistics directly from `pea_recovery.csv`.

Independent of `metrics.jl`: it re-derives activations, activation rate, active-period mean,
all-period mean and maximum from the raw per-period bands, so a producer-side aggregation bug
cannot validate itself. Returns per-replication and pooled-per-configuration tables.
"""
function recompute_pea_statistics(recovery::DataFrame)
    per_replication = Dict{Tuple{String,String,Int},NamedTuple}()
    pooled = Dict{Tuple{String,String},Vector{Float64}}()

    for row in eachrow(recovery)
        key = (String(row.Controller), String(row.Fairness), Int(row.Replication))
        band = Float64(row.PEA_Tolerance_Used_kWh)
        entry = get(per_replication, key, (bands=Float64[],))
        push!(entry.bands, band)
        per_replication[key] = entry
        push!(get!(pooled, (String(row.Controller), String(row.Fairness)), Float64[]), band)
    end

    summarize(bands) = begin
        active = filter(>(OOS_PEA_ACTIVATION_THRESHOLD), bands)
        (
            periods=length(bands),
            activations=length(active),
            activation_rate=isempty(bands) ? 0.0 : length(active) / length(bands),
            mean_active=isempty(active) ? 0.0 : sum(active) / length(active),
            mean_all_periods=isempty(bands) ? 0.0 : sum(bands) / length(bands),
            maximum_band=isempty(bands) ? 0.0 : maximum(bands),
        )
    end

    return (
        per_replication=Dict(k => summarize(v.bands) for (k, v) in per_replication),
        per_configuration=Dict(k => summarize(v) for (k, v) in pooled),
    )
end

# -------------------------------------------------------------------------------------
# Directory validation
# -------------------------------------------------------------------------------------

"""Outcome of validating one result directory."""
struct SchemaValidation
    directory::String
    passed::Bool
    issues::Vector{SchemaIssue}
    files::Dict{String,Int}          # file -> row count
    metadata::Dict{String,String}
end

blocking_issues(validation::SchemaValidation) = filter(is_blocking, validation.issues)
warning_issues(validation::SchemaValidation) = filter(!is_blocking, validation.issues)

"""
Validate a generated result directory the way a downstream reader would.

Checks, in order: required files exist; required columns are present; the solve sequence is
`1` row for a strict-feasible period and `4` rows in the documented order for a recovered one;
the PEA aggregates match an independent recomputation; non-PEA rows report no activation;
`Resource` is present and valid; `NONE` and `STATIC_DEMAND_SHARE` remain distinct; no
conditional-PEA label appears; horizon-total diagnostics are `NaN` on incomplete runs; and the
metadata carries the current keys, the kWh unit and the schema version.

`tolerance` is the numerical agreement required between the reported and recomputed statistics.
"""
function validate_output_directory(
    directory::AbstractString;
    tolerance::Float64=1e-9,
    expected_configurations::Union{Nothing,Int}=nothing,
)
    issues = SchemaIssue[]
    counts = Dict{String,Int}()
    metadata = Dict{String,String}()
    fail(file, detail) = push!(issues, SchemaIssue(String(file), :error, String(detail)))
    warn(file, detail) = push!(issues, SchemaIssue(String(file), :warning, String(detail)))

    isdir(directory) || return SchemaValidation(
        String(directory), false,
        [SchemaIssue(String(directory), :error, "el directorio de resultados no existe")],
        counts, metadata,
    )

    frames = Dict{String,DataFrame}()
    complete_files = Set{String}()
    for (file, required) in OOS_REQUIRED_COLUMNS
        path = joinpath(directory, file)
        if !isfile(path)
            fail(file, "falta el archivo de salida")
            continue
        end
        frame = CSV.read(path, DataFrame)
        frames[file] = frame
        counts[file] = nrow(frame)
        present = names(frame)
        missing_required = false
        for column in required
            if !(column in present)
                historical = nothing
                for (old, new) in OOS_OBSOLETE_COLUMNS
                    new == column && (historical = old)
                end
                if historical !== nothing && historical in present
                    warn(file, "columna histórica `$historical` en lugar de `$column`")
                else
                    fail(file, "falta la columna requerida `$column`")
                    missing_required = true
                end
            end
        end
        missing_required || push!(complete_files, file)
        for obsolete in keys(OOS_OBSOLETE_COLUMNS)
            obsolete in present && warn(
                file, "presente la columna obsoleta `$obsolete` " *
                      "(esquema histórico; el actual usa `$(OOS_OBSOLETE_COLUMNS[obsolete])`)",
            )
        end
    end

    # --- metadata -----------------------------------------------------------------------
    metadata_path = joinpath(directory, "experiment_config.json")
    if !isfile(metadata_path)
        fail("experiment_config.json", "falta el archivo de metadatos")
    else
        metadata = read_experiment_metadata(metadata_path)
        for key in ("pea_tolerance_numeric_eps_kwh", "pea_tolerance_numeric_eps_unit",
                    "pea_tolerance_mode", "output_schema_version", "julia_version",
                    "code_commit", "experiment_seed")
            haskey(metadata, key) || fail("experiment_config.json", "falta la clave `$key`")
        end
        for obsolete in keys(OOS_OBSOLETE_METADATA_KEYS)
            haskey(metadata, obsolete) && warn(
                "experiment_config.json",
                "clave de metadatos obsoleta `$obsolete` " *
                "(el esquema actual usa `$(OOS_OBSOLETE_METADATA_KEYS[obsolete])`)",
            )
        end
        if haskey(metadata, "pea_tolerance_numeric_eps_unit")
            occursin("kWh", metadata["pea_tolerance_numeric_eps_unit"]) || fail(
                "experiment_config.json",
                "la unidad de pea_tolerance_numeric_eps no declara kWh: " *
                metadata["pea_tolerance_numeric_eps_unit"],
            )
        end
        if haskey(metadata, "output_schema_version")
            version = tryparse(Int, metadata["output_schema_version"])
            if version === nothing
                fail("experiment_config.json", "output_schema_version no es un entero")
            elseif version != OOS_OUTPUT_SCHEMA_VERSION
                fail("experiment_config.json",
                     "esquema $version incompatible con el lector actual " *
                     "($(OOS_OUTPUT_SCHEMA_VERSION)); no mezcles directorios de esquemas distintos")
            end
        end
        if get(metadata, "code_dirty", "false") == "true"
            warn("experiment_config.json",
                 "el árbol de trabajo estaba sucio al generar estos resultados; " *
                 "el commit registrado no los reproduce exactamente")
        end
    end

    # --- solve sequence -------------------------------------------------------------------
    if "solve_log.csv" in complete_files && "pea_recovery.csv" in complete_files
        solve_log = frames["solve_log.csv"]
        recovery = frames["pea_recovery.csv"]
        activated = Set{Tuple{Int,String,String,Int}}()
        for row in eachrow(recovery)
            row.PEA_Tolerance_Activated === true && push!(
                activated,
                (Int(row.Replication), String(row.Controller), String(row.Fairness), Int(row.Period)),
            )
        end
        grouped = Dict{Tuple{Int,String,String,Int},Vector{Tuple{Int,String}}}()
        for row in eachrow(solve_log)
            String(row.Fairness) == "PEA" || continue
            key = (Int(row.Replication), String(row.Controller), String(row.Fairness),
                   Int(row.Period))
            push!(get!(grouped, key, Tuple{Int,String}[]), (Int(row.Phase), String(row.PhaseLabel)))
        end
        for (key, entries) in grouped
            sorted = sort(entries; by=first)
            labels = [label for (_, label) in sorted]
            phases = [phase for (phase, _) in sorted]
            if key in activated
                labels == OOS_PEA_RECOVERY_SEQUENCE || fail(
                    "solve_log.csv",
                    "período recuperado $(key) tiene la secuencia $(labels); se esperaba " *
                    "$(OOS_PEA_RECOVERY_SEQUENCE)",
                )
                phases == [0, 1, 2, 3] || fail(
                    "solve_log.csv",
                    "período recuperado $(key) tiene fases $(phases); se esperaba [0, 1, 2, 3]",
                )
            else
                labels == [OOS_SOLVE_LABEL_STRICT] || fail(
                    "solve_log.csv",
                    "período con PEA estricta factible $(key) tiene $(length(labels)) " *
                    "resolución(es) $(labels); se esperaba exactamente [$(OOS_SOLVE_LABEL_STRICT)]",
                )
            end
            # The diagnostic solve is bookkeeping and must never be read as a policy action.
            for (phase, label) in sorted
                get(OOS_SOLVE_PHASE_INDEX, label, phase) == phase || fail(
                    "solve_log.csv",
                    "la etiqueta `$label` no corresponde a la fase $phase",
                )
            end
        end
    end

    # --- PEA aggregation cross-check -------------------------------------------------------
    if "pea_recovery.csv" in complete_files
        recovery = frames["pea_recovery.csv"]
        warnings = SchemaIssue[]
        eps_column = oos_column(recovery, "PEA_Tolerance_Numeric_Eps_kWh";
                                warnings=warnings, file="pea_recovery.csv")
        append!(issues, warnings)
        any(value -> isapprox(Float64(value), 100.0; atol=1e-9), eps_column) && fail(
            "pea_recovery.csv", "se encontró 100.0 como epsilon numérico: banda fija implícita",
        )
        any(value -> isapprox(Float64(value), 100.0; atol=1e-9), recovery.PEA_Tolerance_Used_kWh) &&
            fail("pea_recovery.csv",
                 "se encontró una banda PEA de exactamente 100.0 kWh: posible tolerancia fija")

        for row in eachrow(recovery)
            String(row.Fairness) == "PEA" && continue
            row.PEA_Tolerance_Activated === false || fail(
                "pea_recovery.csv",
                "la política no-PEA $(row.Fairness) declara una activación de tolerancia",
            )
            Float64(row.PEA_Tolerance_Used_kWh) == 0.0 || fail(
                "pea_recovery.csv",
                "la política no-PEA $(row.Fairness) reporta banda $(row.PEA_Tolerance_Used_kWh)",
            )
        end

        recomputed = recompute_pea_statistics(recovery)
        if "replication_summary.csv" in complete_files
            for row in eachrow(frames["replication_summary.csv"])
                key = (String(row.Controller), String(row.Fairness), Int(row.Replication))
                haskey(recomputed.per_replication, key) || continue
                reference = recomputed.per_replication[key]
                for (column, expected) in (
                    ("PEAToleranceActivations", Float64(reference.activations)),
                    ("PEAToleranceActivationRate", reference.activation_rate),
                    ("PEAToleranceMeanActive", reference.mean_active),
                    ("PEAToleranceMeanAllPeriods", reference.mean_all_periods),
                    ("PEAToleranceMax", reference.maximum_band),
                )
                    reported = Float64(row[column])
                    isapprox(reported, expected; atol=tolerance, rtol=tolerance) || fail(
                        "replication_summary.csv",
                        "$(key) $(column): reportado $reported, recomputado $expected",
                    )
                end
            end
        end
        if "configuration_summary.csv" in complete_files
            for row in eachrow(frames["configuration_summary.csv"])
                key = (String(row.Controller), String(row.Fairness))
                haskey(recomputed.per_configuration, key) || continue
                reference = recomputed.per_configuration[key]
                for (column, expected) in (
                    ("ConfigPEAToleranceActivations", Float64(reference.activations)),
                    ("ConfigPEAToleranceActivationRate", reference.activation_rate),
                    ("ConfigPEAToleranceMeanActive", reference.mean_active),
                    ("ConfigPEAToleranceMeanAllPeriods", reference.mean_all_periods),
                    ("ConfigPEAToleranceMax", reference.maximum_band),
                    ("PeriodsSolved", Float64(reference.periods)),
                )
                    reported = Float64(row[column])
                    isapprox(reported, expected; atol=tolerance, rtol=tolerance) || fail(
                        "configuration_summary.csv",
                        "$(key) $(column): reportado $reported, recomputado $expected",
                    )
                end
            end
        end
    end

    # --- policy matrix, resource and completion -------------------------------------------
    if "replication_summary.csv" in complete_files
        summary = frames["replication_summary.csv"]
        policies = sort(unique(String.(summary.Fairness)))
        for policy in policies
            (startswith(policy, "C") && policy != "CONTROLLER") &&
                policy in ("CPEA", "CSA", "CLEXMMFPEA", "CLEXMMFSA") &&
                fail("replication_summary.csv", "política condicional presente: $policy")
            startswith(policy, "ERDINC") &&
                fail("replication_summary.csv", "política de Erdinç presente: $policy")
        end
        ("NONE" in policies && "STATIC_DEMAND_SHARE" in policies) || warn(
            "replication_summary.csv",
            "NONE y STATIC_DEMAND_SHARE no están ambas presentes; deben permanecer distintas",
        )
        configurations = length(unique(zip(summary.Controller, summary.Fairness)))
        if expected_configurations !== nothing && configurations != expected_configurations
            fail("replication_summary.csv",
                 "se hallaron $configurations configuraciones y se esperaban " *
                 "$expected_configurations")
        end

        for row in eachrow(summary)
            String(row.Resource) in OOS_RESOURCE_VALUES || fail(
                "replication_summary.csv", "Resource inválido: $(row.Resource)",
            )
            String(row.CompletionStatus) in ("completed", "aborted") || fail(
                "replication_summary.csv", "CompletionStatus inválido: $(row.CompletionStatus)",
            )
            covered = Float64(row.HorizonCovered)
            (0.0 <= covered <= 1.0) || fail(
                "replication_summary.csv", "HorizonCovered fuera de [0,1]: $covered",
            )
            if String(row.CompletionStatus) == "completed"
                isapprox(covered, 1.0; atol=1e-12) || fail(
                    "replication_summary.csv",
                    "réplica completa con HorizonCovered=$covered",
                )
            else
                # Horizon-total diagnostics must be missing on a truncated trajectory.
                for column in ("RealizedAlpha", "MaxPVRelativeDeviation", "MinHouseholdPV")
                    column in names(summary) || continue
                    isnan(Float64(row[column])) || fail(
                        "replication_summary.csv",
                        "réplica incompleta con $column=$(row[column]) en lugar de NaN",
                    )
                end
            end
        end
    end

    # --- resource consistency across files --------------------------------------------------
    if "household_summary.csv" in complete_files
        for row in eachrow(frames["household_summary.csv"])
            String(row.Resource) in OOS_RESOURCE_VALUES || fail(
                "household_summary.csv", "Resource inválido: $(row.Resource)",
            )
        end
    end

    return SchemaValidation(
        String(directory), !any(is_blocking, issues), issues, counts, metadata,
    )
end

"""
Print a validation report and raise when a blocking issue was found.

Warnings never block: a historical column or a dirty working tree is worth surfacing, not
worth stopping a campaign for.
"""
function enforce_output_schema!(validation::SchemaValidation; label::AbstractString="salidas OOS")
    println("### Validación de esquema ($label): $(validation.directory)")
    for (file, rows) in sort(collect(validation.files); by=first)
        println("  $(rpad(file, 28)) $(rows) filas")
    end
    for issue in validation.issues
        println("  ", issue.severity === :error ? "[FALLA] " : "[AVISO] ",
                issue.file, " :: ", issue.detail)
    end
    validation.passed || error(
        "El esquema de salida no es compatible: " *
        "$(length(blocking_issues(validation))) problema(s) bloqueante(s)."
    )
    println("  esquema v$(OOS_OUTPUT_SCHEMA_VERSION): compatible " *
            "($(length(warning_issues(validation))) aviso(s)).")
    return validation
end

"""
Report result directories whose schema predates the current reader.

Used to keep historical directories out of a fresh campaign's aggregation rather than to
delete anything: user results are never rewritten or removed.
"""
function scan_for_stale_result_directories(roots::Vector{String})
    stale = Tuple{String,String}[]
    for root in roots
        isdir(root) || continue
        metadata_path = joinpath(root, "experiment_config.json")
        if isfile(metadata_path)
            metadata = read_experiment_metadata(metadata_path)
            version = tryparse(Int, get(metadata, "output_schema_version", ""))
            if version === nothing
                push!(stale, (root, "sin output_schema_version (anterior al esquema " *
                                    "v$(OOS_OUTPUT_SCHEMA_VERSION))"))
            elseif version != OOS_OUTPUT_SCHEMA_VERSION
                push!(stale, (root, "esquema v$version"))
            end
        end
        recovery_path = joinpath(root, "pea_recovery.csv")
        if isfile(recovery_path)
            header = first(eachline(recovery_path))
            for obsolete in keys(OOS_OBSOLETE_COLUMNS)
                occursin(obsolete * ",", header * ",") &&
                    !occursin(OOS_OBSOLETE_COLUMNS[obsolete], header) &&
                    push!(stale, (root, "columna obsoleta `$obsolete`"))
            end
        end
    end
    return stale
end
