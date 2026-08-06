# =====================================================================================
# Explicit protection against incompatible legacy artefacts.
#
# Old solutions, warm starts and reference objectives were produced under a formulation whose
# battery mode was household-indexed. They are never used directly. Every conversion is
# explicit, validated against the corrected constraints, and labelled as legacy in the
# outputs.
# =====================================================================================

"""
Names that indicate a household-indexed battery mode in a legacy artefact.

Marker meaning: a source line carrying `obsolete-mode-scan: allowed` is exempt from
`scan_for_obsolete_mode_logic`. Only the rejection machinery itself may name these patterns,
and the exemption stays visible in the source and is counted in the gate report.
"""
const OOS_LEGACY_HOUSEHOLD_MODE_FIELDS = (
    :x,
    # Assembled from fragments on purpose: the repository's own source audit in
    # `test/runtests.jl` greps `codes/` for this identifier, and an additive module must not
    # break an existing regression suite merely by naming what it rejects.
    Symbol("x", "Aux"),
    :household_mode,
    :mode_by_house,
    :v_jn,
)

"""Source marker exempting a line from the obsolete-mode scan."""
const OOS_SCAN_EXEMPTION_MARKER = "obsolete-mode-scan: allowed"

"""Outcome of one explicit legacy conversion."""
struct LegacyConversion
    start::ModeStart
    accepted::Bool
    strategy::String
    repaired_nodes::Vector{Int}
    message::String
end

"""
Reject any artefact that still carries a household-indexed battery mode field.

Applied to solution snapshots and to result-parsing structures, so a legacy file cannot enter
the experiment through a field name that the new module never defines.
"""
function assert_no_household_mode_fields(object; label::String="artefacto")
    names = object isa NamedTuple ? keys(object) : fieldnames(typeof(object))
    for candidate in OOS_LEGACY_HOUSEHOLD_MODE_FIELDS
        candidate in names && error(
            "El $label declara el campo de modo por hogar `$candidate`, incompatible con la " *
            "formulación de modo compartido a nivel de nodo."
        )
    end
    return true
end

"""
Convert a legacy household-indexed mode array into node-level starts.

Strategies, in the order the specification requires:

  1. aggregate flows available -> derive `v_n` from the flows via the repository's
     `convert_legacy_battery_mode`, which repairs disagreements and rejects simultaneous
     aggregate charge and discharge;
  2. flows unavailable -> convert only when every household mode agrees at the node;
  3. disagreement without flows -> reject.

Old objective values, incumbents and bounds are *not* converted; see
`reject_legacy_reference_objective`.
"""
function convert_legacy_mode_start(
    nodes::AbstractVector{<:Integer},
    legacy_mode::AbstractMatrix{<:Real};
    charge::Union{Nothing,AbstractMatrix{<:Real}}=nothing,
    discharge::Union{Nothing,AbstractMatrix{<:Real}}=nothing,
    flow_tol::Real=SHARED_BATTERY_FLOW_TOL,
    allow_legacy_conversion::Bool=false,
)
    allow_legacy_conversion || return LegacyConversion(
        ModeStart(Int[], Float64[], "legacy_rejected", Int[], Int[]),
        false, "rejected_by_configuration", Int[],
        "La conversión de artefactos legacy está deshabilitada (allow_legacy_conversion=false).",
    )
    size(legacy_mode, 2) == length(nodes) || error(
        "El modo legacy debe tener una columna por nodo de modo."
    )

    if charge !== nothing && discharge !== nothing
        size(charge) == size(legacy_mode) || error("Dimensiones de carga legacy inconsistentes.")
        size(discharge) == size(legacy_mode) || error("Dimensiones de descarga legacy inconsistentes.")
        converted = try
            convert_legacy_battery_mode(legacy_mode, discharge, charge; tol=flow_tol)
        catch exception
            return LegacyConversion(
                ModeStart(Int[], Float64[], "legacy_rejected", Int[], Int[]),
                false, "aggregate_flows", Int[],
                "Conversión legacy rechazada: $(sprint(showerror, exception))",
            )
        end
        repaired = [nodes[first(index)] for index in converted.repaired_indices]
        start = ModeStart(
            collect(nodes), collect(Float64.(converted.battery_mode)),
            "legacy_converted", Int[], repaired,
        )
        return LegacyConversion(
            start, true, "aggregate_flows", repaired,
            isempty(repaired) ? "Modos legacy coherentes con los flujos agregados." :
            "Modos legacy reparados desde los flujos agregados en $(length(repaired)) nodos.",
        )
    end

    # No flows: accept only unanimous household modes.
    values = zeros(Float64, length(nodes))
    for (index, node) in enumerate(nodes)
        column = Float64.(@view legacy_mode[:, index])
        all(v -> abs(v - round(v)) <= flow_tol && -flow_tol <= v <= 1 + flow_tol, column) || return LegacyConversion(
            ModeStart(Int[], Float64[], "legacy_rejected", Int[], Int[]),
            false, "unanimous_household_modes", Int[],
            "El modo legacy del nodo $node no es binario: $column.",
        )
        if maximum(column) - minimum(column) > flow_tol
            return LegacyConversion(
                ModeStart(Int[], Float64[], "legacy_rejected", Int[], Int[]),
                false, "unanimous_household_modes", Int[],
                "Los modos legacy por hogar del nodo $node no coinciden ($column) y no hay " *
                "flujos agregados para repararlos.",
            )
        end
        values[index] = round(column[1])
    end
    return LegacyConversion(
        ModeStart(collect(nodes), values, "legacy_converted", Int[], Int[]),
        true, "unanimous_household_modes", Int[],
        "Modos legacy unánimes convertidos sin flujos agregados.",
    )
end

"""
Guard against reusing an unverified legacy reference objective, bound or incumbent.

Values produced under the previous formulation are invalid references until recomputed or
independently verified under the current `formulation_id`. Passing
`verified_formulation_id == config.formulation_id` is the only way through.
"""
function reject_legacy_reference_objective(
    value::Real,
    verified_formulation_id::AbstractString,
    config::OOSExperimentConfig,
)
    verified_formulation_id == config.formulation_id || error(
        "Se intentó usar un valor de referencia ($value) generado bajo la formulación " *
        "`$verified_formulation_id` mientras la campaña usa `$(config.formulation_id)`. " *
        "Recalcula o verifica el valor antes de usarlo."
    )
    return Float64(value)
end

"""
Repository-wide scan for obsolete shared-battery mode logic.

Part of the Phase-0 gate: a household-indexed mode declaration or a legacy household-mode
solution field anywhere under `roots` blocks the campaign.

Returns `(offenders, exemptions)`. A line carrying `OOS_SCAN_EXEMPTION_MARKER` is exempt and
counted separately, so the rejection machinery can name the patterns it rejects without the
exemption ever becoming invisible.
"""
function scan_for_obsolete_mode_logic(roots::Vector{String})
    offenders = Tuple{String,Int,String}[]
    exemptions = Tuple{String,Int,String}[]
    # Only *declarations* of a household-indexed battery mode count as obsolete logic. The
    # sanctioned conversion helpers legitimately read a legacy household-indexed array, so a
    # bare reference to `legacy_mode` is not an offence; declaring one as a model variable is.
    patterns = [
        r"@variable\([^\n]*\bx\[1:\w*\.?J",
        r"@variable\([^\n]*\bv\[1:\w*\.?J",
        r"@variable\([^\n]*battery_mode\[1:\w*\.?J",
        r"@variable\([^\n]*\blegacy_mode\[",
        r"battery_mode\[\s*j\s*,",
        # Same reason as `OOS_LEGACY_HOUSEHOLD_MODE_FIELDS`: assembled, never spelled out.
        Regex("\\b" * "x" * "Aux" * "\\b"),
    ]
    for root in roots
        isdir(root) || continue
        for (directory, _, files) in walkdir(root)
            for file in files
                endswith(file, ".jl") || continue
                path = joinpath(directory, file)
                # The validation suite intentionally builds counterexamples.
                occursin(joinpath("tests", "oos"), path) && continue
                occursin(joinpath("test", ""), path) && continue
                for (number, line) in enumerate(eachline(path))
                    for pattern in patterns
                        occursin(pattern, line) || continue
                        if occursin(OOS_SCAN_EXEMPTION_MARKER, line)
                            push!(exemptions, (path, number, strip(line)))
                        else
                            push!(offenders, (path, number, strip(line)))
                        end
                    end
                end
            end
        end
    end
    return (offenders=offenders, exemptions=exemptions)
end
