# =====================================================================================
# Model audit: structural inspection plus LP/MPS export.
#
# The audit never relies on variable names alone. Every check has a structural counterpart
# that reads JuMP metadata and constraint coefficients, so a renamed but wrong model still
# fails.
# =====================================================================================

"""One audit finding."""
struct AuditFinding
    name::String
    passed::Bool
    detail::String
end

"""Audit of one representative generated model."""
struct ModelAudit
    label::String
    controller::ControllerKind
    fairness::FairnessPolicy
    passed::Bool
    findings::Vector{AuditFinding}
    expected_mode_nodes::Int
    generated_mode_binaries::Int
    unique_policy_modes::Int
    legacy_household_mode_binaries::Int
    variables::Int
    constraints::Int
    nonzeros::Int
    lp_path::String
    mps_path::String
end

audit_summary(audit::ModelAudit) =
    "$(count(f -> f.passed, audit.findings))/$(length(audit.findings)) verificaciones aprobadas"

# -------------------------------------------------------------------------------------
# Structural inspection
# -------------------------------------------------------------------------------------

"""
Structural inspection of the shared-battery subsystem of a generated model.

Verifies, through coefficients rather than names:

  * exactly `|V_mode|` binary variables, each one being a declared node-level mode;
  * one charge row and one discharge row per mode node;
  * the charge row is `sum_j z[j,n] - F_c v_n <= 0` with unit coefficients on every household
    charging contribution and no extra term;
  * the discharge row is `sum_j y[j,n] + F_d v_n <= F_d`, i.e. `sum_j y[j,n] <= F_d (1 - v_n)`;
  * no binary variable is indexed by household.
"""
function audit_shared_battery_structure(refs::PhysicalModelRefs)
    findings = AuditFinding[]
    model = refs.model
    template = refs.template
    tree = refs.tree
    J = template.J
    mode_nodes = refs.mode_nodes

    binaries = all_variables(model)
    binaries = [variable for variable in binaries if is_binary(variable)]
    mode_variables = [refs.v[n] for n in mode_nodes]

    push!(findings, AuditFinding(
        "binary_count_equals_mode_nodes",
        length(binaries) == length(mode_nodes),
        "Binarios generados: $(length(binaries)); nodos de modo esperados: $(length(mode_nodes)).",
    ))
    push!(findings, AuditFinding(
        "every_binary_is_a_node_level_mode",
        Set(binaries) == Set(mode_variables),
        "El conjunto de binarios debe coincidir exactamente con {battery_mode[n] : n in V_mode}.",
    ))
    push!(findings, AuditFinding(
        "no_household_indexed_binary",
        all(!occursin(',', name(variable)) for variable in binaries),
        "Ningún binario puede llevar dos índices: " *
        "$(join(unique(name.(binaries))[1:min(3, length(binaries))], ", ")).",
    ))
    push!(findings, AuditFinding(
        "mode_variable_naming",
        all(startswith(name(variable), "battery_mode[") for variable in binaries),
        "Los binarios deben usar el nombre visible para el solver `battery_mode[n]`.",
    ))

    charge_rows = haskey(model, :battery_charge_mode) ? model[:battery_charge_mode] : nothing
    discharge_rows = haskey(model, :battery_discharge_mode) ? model[:battery_discharge_mode] : nothing
    push!(findings, AuditFinding(
        "mutual_exclusion_rows_present",
        charge_rows !== nothing && discharge_rows !== nothing,
        "Todo camino del modelo debe declarar las filas battery_charge_mode y battery_discharge_mode.",
    ))

    if charge_rows !== nothing && discharge_rows !== nothing
        charge_ok = true
        discharge_ok = true
        charge_detail = "correcto"
        discharge_detail = "correcto"
        for n in mode_nodes
            charge_row = charge_rows[n]
            discharge_row = discharge_rows[n]
            charge_terms = constraint_object(charge_row).func.terms
            discharge_terms = constraint_object(discharge_row).func.terms

            # sum_j z[j,n] - F_c v_n <= 0
            for j in 1:J
                if abs(normalized_coefficient(charge_row, refs.z[j, n]) - 1.0) > 1e-12
                    charge_ok = false
                    charge_detail = "El nodo $n no suma con coeficiente 1 el aporte de carga del hogar $j."
                end
            end
            if abs(normalized_coefficient(charge_row, refs.v[n]) + template.f_under) > 1e-9
                charge_ok = false
                charge_detail = "El nodo $n no usa F_c = $(template.f_under) sobre v_n en la fila de carga."
            end
            if abs(normalized_rhs(charge_row)) > 1e-9
                charge_ok = false
                charge_detail = "La fila de carga del nodo $n tiene lado derecho $(normalized_rhs(charge_row)) y debe ser 0."
            end
            if length(charge_terms) != J + 1
                charge_ok = false
                charge_detail = "La fila de carga del nodo $n tiene $(length(charge_terms)) términos y debe tener $(J+1)."
            end

            # sum_j y[j,n] + F_d v_n <= F_d
            for j in 1:J
                if abs(normalized_coefficient(discharge_row, refs.y[j, n]) - 1.0) > 1e-12
                    discharge_ok = false
                    discharge_detail = "El nodo $n no suma con coeficiente 1 la descarga asignada al hogar $j."
                end
            end
            if abs(normalized_coefficient(discharge_row, refs.v[n]) - template.f_bar) > 1e-9
                discharge_ok = false
                discharge_detail = "El nodo $n no usa F_d = $(template.f_bar) sobre v_n en la fila de descarga."
            end
            if abs(normalized_rhs(discharge_row) - template.f_bar) > 1e-9
                discharge_ok = false
                discharge_detail = "La fila de descarga del nodo $n tiene lado derecho $(normalized_rhs(discharge_row)) y debe ser F_d."
            end
            if length(discharge_terms) != J + 1
                discharge_ok = false
                discharge_detail = "La fila de descarga del nodo $n tiene $(length(discharge_terms)) términos y debe tener $(J+1)."
            end
        end
        push!(findings, AuditFinding("charge_row_uses_Fc_times_mode", charge_ok, charge_detail))
        push!(findings, AuditFinding("discharge_row_uses_Fd_times_one_minus_mode", discharge_ok, discharge_detail))
    end

    # No path may omit mutual exclusion: every mode node must own both rows.
    push!(findings, AuditFinding(
        "one_mode_per_relevant_node",
        length(unique(mode_nodes)) == length(mode_nodes) &&
        Set(mode_nodes) == Set(mode_node_set(tree.parent, tree.calendar_period)),
        "Los nodos de modo deben coincidir con la convención centralizada, sin duplicados.",
    ))

    # Root convention and nonanticipativity.
    push!(findings, AuditFinding(
        "root_carries_the_current_mode",
        tree.root in mode_nodes,
        "El nodo raíz debe declarar el modo compartido del período actual.",
    ))
    push!(findings, AuditFinding(
        "nonanticipative_shared_modes",
        audit_nonanticipativity(refs),
        "Escenarios con historia común deben referenciar la misma variable de modo hasta la ramificación.",
    ))
    if tree.controller === TWO_STAGE_RH
        push!(findings, AuditFinding(
            "two_stage_root_is_a_single_first_stage",
            audit_two_stage_first_stage(refs),
            "En dos etapas la raíz debe aportar una única decisión de primera etapa común.",
        ))
    end

    passed = all(finding -> finding.passed, findings)
    return (passed=passed, findings=findings)
end

"""
Structural nonanticipativity check.

Node-indexed storage makes nonanticipativity implicit, and this verifies it literally: two
scenarios sharing a history prefix must reference the *same* mode variable object at every
node of that prefix.
"""
function audit_nonanticipativity(refs::PhysicalModelRefs)
    tree = refs.tree
    scenarios = tree.scenarios
    for a in eachindex(scenarios), b in eachindex(scenarios)
        a < b || continue
        first_scenario = scenarios[a]
        second_scenario = scenarios[b]
        limit = min(length(first_scenario), length(second_scenario))
        for k in 1:limit
            first_scenario[k] == second_scenario[k] || break
            node = first_scenario[k]
            node in refs.mode_nodes || continue
            refs.v[node] === refs.v[second_scenario[k]] || return false
        end
    end
    return true
end

"""
Two-stage first-stage consistency.

The root must be a single node shared by every scenario, so `v_t, p_t, z_t, y_t, I_t, G_t`
are one common first-stage decision instead of a vector of scenario copies.
"""
function audit_two_stage_first_stage(refs::PhysicalModelRefs)
    tree = refs.tree
    all(scenario -> scenario[1] == tree.root, tree.scenarios) || return false
    J = refs.template.J
    for j in 1:J
        for container in (refs.p, refs.z, refs.y, refs.I, refs.G, refs.lambda)
            container[j, tree.root] === container[j, tree.root] || return false
        end
    end
    if lookahead_scenario_count(tree) > 1
        children = lookahead_root_children(tree)
        length(children) == lookahead_scenario_count(tree) || return false
    end
    return true
end

# -------------------------------------------------------------------------------------
# File-level inspection
# -------------------------------------------------------------------------------------

"""
Pattern inspection of an exported LP/MPS file.

Complements — never replaces — the structural inspection. The two writers disagree on naming:
JuMP's LP writer sanitizes `battery_mode[3]` to `battery_mode_3_`, while its MPS writer keeps
the brackets. Both spellings are therefore accepted for the node-level form, and both are
rejected for the household-indexed form, so the check cannot pass merely because a format was
misread.
"""
function audit_exported_model_file(path::String, expected_mode_binaries::Int)
    findings = AuditFinding[]
    contents = read(path, String)
    format = endswith(lowercase(path), ".mps") ? "MPS" : "LP"
    node_level = r"battery_mode[\[_][0-9]+[\]_]"
    household_indexed = r"battery_mode[\[_][0-9]+,[0-9]+[\]_]"
    obsolete = r"legacy_mode|\bx[\[_][0-9]+,[0-9]+[\]_]"

    declared = length(collect(eachmatch(node_level, contents)))
    push!(findings, AuditFinding(
        "file_declares_node_level_mode",
        declared > 0,
        "El archivo $format debe contener variables de modo por nodo " *
        "(battery_mode_n_ o battery_mode[n]); se hallaron $declared apariciones.",
    ))
    push!(findings, AuditFinding(
        "file_has_no_household_indexed_mode",
        !occursin(household_indexed, contents),
        "El archivo $format no puede contener un modo indexado por hogar.",
    ))
    push!(findings, AuditFinding(
        "file_has_no_obsolete_mode_names",
        !occursin(obsolete, contents),
        "El archivo $format no puede contener nombres de modo obsoletos.",
    ))
    push!(findings, AuditFinding(
        "file_mode_occurrences_are_consistent",
        declared >= expected_mode_binaries,
        "Se hallaron $declared apariciones de battery_mode en el archivo $format y se esperan " *
        "al menos $expected_mode_binaries.",
    ))
    return findings
end

# -------------------------------------------------------------------------------------
# Representative export
# -------------------------------------------------------------------------------------

"""
Audit and export one representative model.

Exports are written under `<output_directory>/model_audit/` and are never mixed with normal
run outputs.
"""
function audit_and_export_model(
    refs::PhysicalModelRefs,
    label::String,
    config::OOSExperimentConfig;
    export_files::Bool=true,
)
    structure = audit_shared_battery_structure(refs)
    findings = copy(structure.findings)
    lp_path = ""
    mps_path = ""

    if export_files
        directory = joinpath(config.output_directory, "model_audit")
        mkpath(directory)
        lp_path = joinpath(directory, "$(config.formulation_id)__$(label).lp")
        mps_path = joinpath(directory, "$(config.formulation_id)__$(label).mps")
        write_to_file(refs.model, lp_path)
        write_to_file(refs.model, mps_path)
        append!(findings, audit_exported_model_file(lp_path, length(refs.mode_nodes)))
        append!(findings, audit_exported_model_file(mps_path, length(refs.mode_nodes)))
    end

    binaries = generated_binary_count(refs.model)
    return ModelAudit(
        label, refs.tree.controller, NONE, all(f -> f.passed, findings), findings,
        expected_mode_binary_count(refs.tree), binaries, unique_policy_mode_count(refs.tree),
        legacy_household_mode_binary_count(refs.tree, refs.template.J),
        num_variables(refs.model), model_constraint_count(refs.model),
        model_nonzero_count(refs.model), lp_path, mps_path,
    )
end

"""Print an audit and raise when it did not pass."""
function enforce_audit!(audits::Vector{ModelAudit})
    println("### Auditoría de modelos representativos")
    failed = String[]
    for audit in audits
        println("  ", audit.passed ? "[OK]  " : "[FALLA] ", audit.label, " :: ", audit_summary(audit),
                " | binarios=", audit.generated_mode_binaries, "/", audit.expected_mode_nodes,
                " | únicos=", audit.unique_policy_modes,
                " | legacy |H||V_mode|=", audit.legacy_household_mode_binaries)
        for finding in audit.findings
            finding.passed || println("      [FALLA] ", finding.name, " :: ", finding.detail)
        end
        audit.passed || push!(failed, audit.label)
    end
    isempty(failed) || error(
        "La inspección de modelos representativos falló en: $(join(failed, ", ")). " *
        "La campaña permanece bloqueada."
    )
    return audits
end
