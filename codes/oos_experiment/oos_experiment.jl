# =====================================================================================
# Out-of-sample receding-horizon experiment: entry point.
#
# Additive module. It reuses the repository's verified low-level components
# (`InstanceM`, `Tree`, `createTime`, the physical parameters and deterministic profiles, the
# stochastic PV/demand generators, the static demand-share computation and
# `add_shared_battery_mode_constraints!`) and adds its own state, fixed-past, current-action
# and mode-audit layers.
#
# It deliberately does NOT use `solveMulti` as the receding-horizon engine: that function
# assumes a one-shot horizon and provides none of the interfaces this experiment needs.
#
# Usage:
#     include("oos_experiment/oos_experiment.jl")
#     config = oos_config_from_environment()
#     run_oos_experiment(config)
# =====================================================================================

using Dates

const OOS_MODULE_DIRECTORY = @__DIR__
const OOS_CODES_DIRECTORY = normpath(joinpath(OOS_MODULE_DIRECTORY, ".."))
const OOS_REPO_ROOT = normpath(joinpath(OOS_CODES_DIRECTORY, ".."))

# --- verified repository components, loaded once ---------------------------------------
if !isdefined(@__MODULE__, :InstanceM)
    include(joinpath(OOS_CODES_DIRECTORY, "structuresMulti.jl"))
end
if !isdefined(@__MODULE__, :generateInstance)
    include(joinpath(OOS_CODES_DIRECTORY, "parametersMS.jl"))
end
if !isdefined(@__MODULE__, :static_demand_shares)
    include(joinpath(OOS_CODES_DIRECTORY, "static_demand_share.jl"))
end

const MOI = JuMP.MOI

# --- additive experiment layers ---------------------------------------------------------
include(joinpath(OOS_MODULE_DIRECTORY, "types.jl"))
include(joinpath(OOS_MODULE_DIRECTORY, "state.jl"))
include(joinpath(OOS_MODULE_DIRECTORY, "mode_nodes.jl"))
include(joinpath(OOS_MODULE_DIRECTORY, "lookahead_tree.jl"))
include(joinpath(OOS_MODULE_DIRECTORY, "uncertainty_provider.jl"))
include(joinpath(OOS_MODULE_DIRECTORY, "physical_model.jl"))
include(joinpath(OOS_MODULE_DIRECTORY, "fairness_rules.jl"))
include(joinpath(OOS_MODULE_DIRECTORY, "lexicographic.jl"))
include(joinpath(OOS_MODULE_DIRECTORY, "warm_starts.jl"))
include(joinpath(OOS_MODULE_DIRECTORY, "legacy_compatibility.jl"))
include(joinpath(OOS_MODULE_DIRECTORY, "controllers.jl"))
include(joinpath(OOS_MODULE_DIRECTORY, "model_audit.jl"))
include(joinpath(OOS_MODULE_DIRECTORY, "validation.jl"))
include(joinpath(OOS_MODULE_DIRECTORY, "simulator.jl"))
include(joinpath(OOS_MODULE_DIRECTORY, "metrics.jl"))
include(joinpath(OOS_MODULE_DIRECTORY, "output.jl"))
include(joinpath(OOS_MODULE_DIRECTORY, "output_schema.jl"))

# =====================================================================================
# Common in-sample objects
# =====================================================================================

"""Everything computed once, before any configuration runs."""
struct OOSCommonObjects
    template::OOSInstanceTemplate
    provider::RepositoryUncertaintyProvider
    in_sample_tree::Tree
    static_shares::Matrix{Float64}
    oos_paths::Vector{OOSPath}
end

"""
Precompute the common in-sample objects and cache every out-of-sample trajectory.

The static demand-share coefficients are computed once from the common in-sample expected
demand. The out-of-sample trajectories are generated once, cached, identical across all
configurations, and drawn from a stream that is independent of every in-sample stream.
"""
function build_common_objects(config::OOSExperimentConfig; verbose::Bool=true)
    bundle = build_instance_template(config)
    template = bundle.template
    provider = RepositoryUncertaintyProvider(template)
    static = compute_static_demand_shares(
        template, provider, bundle.in_sample_tree, in_sample_rng(config),
    )
    paths = [
        sample_oos_path(provider, template.T, oos_path_rng(config, r); replication_id=r)
        for r in 1:config.oos_replications
    ]
    if verbose
        println("Instancia $(template.id): J=$(template.J), T=$(template.T), " *
                "F_c=$(template.f_under), F_d=$(template.f_bar)")
        println("Perfiles de demanda por hogar: " *
                join([model.profile for model in template.demand_models], ", "))
        println("Trayectorias fuera de muestra generadas y cacheadas: $(length(paths))")
    end
    return OOSCommonObjects(
        template, provider, bundle.in_sample_tree, static.shares, paths,
    )
end

# =====================================================================================
# Preflight: formulation audit and validation gate
# =====================================================================================

"""
Run the whole Phase-0 gate.

Order: repository search for obsolete mode logic, shared-battery micro-instance tests,
binary-count checks, per-controller/per-rule gate solves, and representative LP/MPS export
with structural inspection. The campaign is blocked unless everything passes.
"""
function run_preflight(config::OOSExperimentConfig, common::OOSCommonObjects; verbose::Bool=true)
    reports = GateReport[]
    lines = String[]
    push!(lines, "Compuerta de compatibilidad de batería compartida")
    push!(lines, "formulation_id = $(config.formulation_id)")
    push!(lines, "formulation_variant = $(config.formulation_variant)")
    push!(lines, "mode_node_convention = $(OOS_MODE_NODE_CONVENTION)")
    push!(lines, "")

    for advisory in fairness_reachability_advisories(config, common)
        push!(lines, "[AVISO]  " * advisory)
        verbose && println("AVISO: ", advisory)
    end
    push!(lines, "")

    scan = scan_for_obsolete_mode_logic([
        joinpath(OOS_REPO_ROOT, "codes"), joinpath(OOS_REPO_ROOT, "archive_legacy"),
    ])
    scan_report = GateReport(
        isempty(scan.offenders),
        [GateCheck(
            "repository_has_no_obsolete_mode_logic", isempty(scan.offenders),
            isempty(scan.offenders) ?
            "Sin declaraciones de modo por hogar en el repositorio " *
            "($(length(scan.exemptions)) línea(s) exentas y visibles en el código)." :
            "Coincidencias: " *
            join(["$(path):$(line)" for (path, line, _) in scan.offenders], ", "),
        )],
        config.formulation_id,
    )
    push!(reports, scan_report)

    push!(reports, run_shared_battery_micro_gate(config))
    push!(reports, run_controller_fairness_gate(
        common.template, common.provider, common.static_shares, config,
    ))

    for report in reports
        for check in report.checks
            push!(lines, (check.passed ? "[OK]    " : "[FALLA] ") * check.name * " :: " * check.detail)
        end
    end

    audits = ModelAudit[]
    if config.export_representative_models
        audits = export_representative_models(config, common; verbose=verbose)
        push!(lines, "")
        push!(lines, "Modelos representativos exportados: $(length(audits))")
        for audit in audits
            push!(lines, (audit.passed ? "[OK]    " : "[FALLA] ") * audit.label * " :: " *
                         audit_summary(audit) *
                         " | binarios=$(audit.generated_mode_binaries)/$(audit.expected_mode_nodes)" *
                         " | únicos=$(audit.unique_policy_modes)" *
                         " | legacy |H||V_mode|=$(audit.legacy_household_mode_binaries)")
            for finding in audit.findings
                finding.passed || push!(lines, "        [FALLA] " * finding.name * " :: " * finding.detail)
            end
        end
    end

    if config.require_shared_battery_validation
        for report in reports
            enforce_gate!(report)
        end
        isempty(audits) || enforce_audit!(audits)
    elseif verbose
        println("AVISO: la validación obligatoria está desactivada " *
                "(require_shared_battery_validation=false).")
    end

    return (reports=reports, audits=audits, report_text=join(lines, "\n") * "\n")
end

"""
Non-blocking advisories about allocation/fairness rules that may become unreachable.

A horizon-total *equality* imposed period after period on a fixed realized past is not
guaranteed to stay reachable: the target moves with new information while past allocations
cannot be taken back. The sharpest case is a calendar tail with no remaining PV, where the
PEA equality degenerates into a consistency condition on the past alone.

These advisories never block the campaign. They exist so an aborted `PEA` configuration is
recognized as a property of the rule rather than as a defect of the physical model, and so the
documented lever (`fairness_abs_tol > 0`) is visible before the run rather than after it.
"""
function fairness_reachability_advisories(config::OOSExperimentConfig, common::OOSCommonObjects)
    advisories = String[]
    template = common.template
    zero_pv_tail = 0
    for t in template.T:-1:1
        template.pv_det[t] > 0 && break
        zero_pv_tail += 1
    end

    if PEA in config.fairness_set
        reachability =
            "PEA impone una igualdad sobre el total del horizonte con el pasado realizado fijo. " *
            "Puede volverse inalcanzable cuando el objetivo proporcional actualizado queda fuera " *
            "del rango alcanzable con los recursos físicos restantes; una cola sin PV " *
            "($zero_pv_tail período(s) aquí) es solo el caso extremo."
        if config.pea_tolerance_mode === :adaptive_minimum
            push!(advisories, reachability *
                " Modo :adaptive_minimum: se intenta primero la igualdad estricta y, solo ante " *
                "infactibilidad probada atribuida a la regla, se calcula endógenamente la banda " *
                "mínima común (Fase I) y se reoptimiza el costo con esa banda (Fase II).")
        elseif config.pea_tolerance_mode === :strict
            push!(advisories, reachability *
                " Modo :strict: sin recuperación; se espera que las configuraciones PEA aborten " *
                "cuando el objetivo deje de ser alcanzable.")
        else
            push!(advisories, reachability *
                " Modo :fixed_band (EN DESUSO) con fairness_abs_tol=$(config.fairness_abs_tol) kWh: " *
                "es una relajación económica fija de la regla, no una tolerancia numérica.")
        end
    end

    if SA in config.fairness_set && config.sa_fairness_abs_tol <= 0
        push!(advisories,
            "SA con sa_fairness_abs_tol=0 impone una igualdad exacta de ahorros sobre el total del " *
            "horizonte; la calibración del repositorio usa una banda de 1.0.",
        )
    end
    return advisories
end

"""
Export and inspect one representative model per major builder path.

Covers the three controllers crossed with `NONE`, `STATIC_DEMAND_SHARE`, `PEA`, `SA`, and the
lexicographic PV and savings phase models (the phase model is the physical model carrying the
lexicographic envelope, exported with its first phase objective installed).
"""
function export_representative_models(
    config::OOSExperimentConfig,
    common::OOSCommonObjects;
    period::Int=1,
    verbose::Bool=true,
)
    template = common.template
    audits = ModelAudit[]
    path = common.oos_paths[1]
    state = initial_simulation_state(template, path.replication_id)
    reveal_period!(state, path, period)
    history = observed_history(state)
    past = fairness_past_state(state)

    for controller in config.controller_set
        tree = build_lookahead_tree(
            common.provider, config, controller, history, period, template.T, path.replication_id,
        )
        for policy in config.fairness_set
            refs = build_remaining_horizon_model(template, state, tree, config)
            context = add_fairness_constraints!(
                refs, policy, past, config; static_shares=common.static_shares,
            )
            label = "$(controller)__$(policy)"
            if is_lexicographic_policy(policy)
                # Install the envelope and the first phase objective so the exported file is the
                # actual phase model, not the cost model.
                J = template.J
                outcome = lexicographic_outcome_expressions(refs, policy, past, context.aggregates)
                @variable(refs.model, lex_zeta[1:J])
                @variable(refs.model, lex_slack[1:J, 1:J] >= 0)
                @constraint(refs.model, lex_envelope[k in 1:J, j in 1:J],
                    lex_zeta[k] - lex_slack[k, j] <= outcome[j])
                @objective(refs.model, Max, lex_zeta[1] - sum(lex_slack[1, j] for j in 1:J))
                label *= "__phase1"
            end
            audit = audit_and_export_model(refs, label, config; export_files=true)
            push!(audits, audit)
            verbose && println("  exportado $(label): binarios=$(audit.generated_mode_binaries)/" *
                               "$(audit.expected_mode_nodes), variables=$(audit.variables), " *
                               "restricciones=$(audit.constraints)")

            # PEA has three model shapes worth inspecting: the strict equality just exported,
            # the Phase-I minimum-band model and the Phase-II operational model at that band.
            if policy === PEA && config.pea_tolerance_mode === :adaptive_minimum
                adaptive = build_remaining_horizon_model(template, state, tree, config)
                aggregates = scenario_aggregates(template, adaptive.tree)
                phase1 = solve_minimum_pea_tolerance!(adaptive, past, aggregates, config)
                push!(audits, audit_and_export_model(
                    adaptive, "$(controller)__PEA__adaptive_phase1", config; export_files=true,
                ))
                if phase1.outcome === SOLVE_OK
                    solve_pea_operational_phase!(adaptive, phase1.handles, phase1.epsilon_star, config)
                    push!(audits, audit_and_export_model(
                        adaptive, "$(controller)__PEA__adaptive_phase2", config; export_files=true,
                    ))
                    verbose && println("  exportado $(controller)__PEA__adaptive_phase1/2: " *
                                       "epsilon_pea* = $(round(phase1.epsilon_star, digits=6)) kWh")
                end
            end
        end
    end
    return audits
end

# =====================================================================================
# Campaign
# =====================================================================================

"""Complete campaign result, kept in memory for programmatic use and for the tests."""
struct OOSCampaignResult
    config::OOSExperimentConfig
    common::OOSCommonObjects
    runs::Vector{ReplicationRun}
    metrics::Vector{ReplicationMetrics}
    statistics::Vector{PairedSummary}
    configuration_summaries::Vector{ConfigurationPEASummary}
    audits::Vector{ModelAudit}
    gate_reports::Vector{GateReport}
    written_files::Vector{String}
end

"""
Run the full out-of-sample experiment.

    perform the repository formulation preflight
    run the shared-battery validation instance
    export and inspect representative LP/MPS models
    abort unless all validation gates pass

    precompute the common in-sample objects
    compute the STATIC_DEMAND_SHARE coefficients once
    generate and cache all out-of-sample paths

    for each replication
        cache the look-ahead information by period and controller
        for each allocation/fairness rule
            for each controller
                initialize an identical, unshared state and simulate the horizon
"""
function run_oos_experiment(
    config::OOSExperimentConfig;
    verbose::Bool=true,
    write_outputs::Bool=true,
)
    verbose && println("=== Experimento fuera de muestra: $(config.experiment_id) ===")
    verbose && println("Configuraciones: $(configuration_count(config)) " *
                       "($(length(config.controller_set)) controladores x " *
                       "$(length(config.fairness_set)) reglas), " *
                       "réplicas: $(config.oos_replications)")

    common = build_common_objects(config; verbose=verbose)
    preflight = run_preflight(config, common; verbose=verbose)

    runs = ReplicationRun[]
    metrics = ReplicationMetrics[]

    for path in common.oos_paths
        verbose && println("--- réplica $(path.replication_id) ---")
        cache = cache_lookahead_trees(common.provider, config, common.template, path)
        for policy in config.fairness_set, controller in config.controller_set
            run = simulate_configuration(
                common.template, config, path, cache, controller, policy,
                common.static_shares; verbose=verbose,
            )
            push!(runs, run)
            push!(metrics, compute_replication_metrics(common.template, run, config))
            verbose && println(
                "  $(controller) / $(policy): ",
                run.completed ? "completada" : "abortada en el período $(run.periods_completed + 1)",
                ", costo=", round(sum(run.final_state.cumulative_operating_cost), digits=3),
                ", solve=", round(run.total_solve_time_sec, digits=2), "s",
            )
        end
    end

    statistics = campaign_statistics(metrics)
    configuration_summaries = configuration_pea_summaries(metrics)
    written = String[]
    if write_outputs
        written = write_campaign_outputs(
            config, common.template, runs, metrics, statistics,
            preflight.audits, preflight.reports; validation_text=preflight.report_text,
            configuration_summaries=configuration_summaries,
        )
        verbose && println("Archivos escritos: ", join(written, ", "))
    end

    verbose && report_model_size_effect(config, common, runs)
    verbose && report_pea_recovery(config, configuration_summaries)

    return OOSCampaignResult(
        config, common, runs, metrics, statistics, configuration_summaries,
        preflight.audits, preflight.reports, written,
    )
end

"""
Report the model-size effect of the corrected formulation explicitly.

The corrected formulation changes the expected mode-binary count from roughly
`|H||V_mode|` to `|V_mode|`. Runtime, memory and branch-and-bound differences must therefore
never be attributed to the algorithm alone.
"""
function report_model_size_effect(
    config::OOSExperimentConfig,
    common::OOSCommonObjects,
    runs::Vector{ReplicationRun},
)
    println("=== Efecto de tamaño del modelo (corregido vs. convención por hogar) ===")
    println("Convención de nodos de modo: $(OOS_MODE_NODE_CONVENTION)")
    grouped = Dict{ControllerKind,Vector{Tuple{Int,Int,Int}}}()
    for run in runs, record in run.records
        statistics = record.result.statistics
        entries = get!(grouped, run.controller, Tuple{Int,Int,Int}[])
        push!(entries, (
            statistics.expected_mode_nodes,
            statistics.generated_mode_binaries,
            common.template.J * statistics.expected_mode_nodes,
        ))
    end
    for controller in sort(collect(keys(grouped)); by=Int)
        entries = grouped[controller]
        isempty(entries) && continue
        expected = sum(first(entry) for entry in entries) / length(entries)
        generated = sum(entry[2] for entry in entries) / length(entries)
        legacy = sum(entry[3] for entry in entries) / length(entries)
        println("  $(controller): |V_mode| medio = $(round(expected, digits=1)), " *
                "binarios generados = $(round(generated, digits=1)), " *
                "|H||V_mode| legacy = $(round(legacy, digits=1)) " *
                "(reducción x$(round(legacy / max(generated, 1), digits=2)))")
    end
    println("Los tiempos y esfuerzos de ramificación no deben atribuirse solo al algoritmo: " *
            "parte de la diferencia viene de la formulación corregida y más pequeña.")
    return nothing
end

"""
Report the strict-first / adaptive-minimum PEA outcome, pooled over replications.

`mean_active` is pooled over *periods*, not averaged over replication means, so a replication
that activated once does not weigh as much as one that activated twenty times.
"""
function report_pea_recovery(
    config::OOSExperimentConfig,
    summaries::Vector{ConfigurationPEASummary},
)
    pea_rows = [s for s in summaries if s.fairness === PEA]
    isempty(pea_rows) && return nothing
    println("=== Recuperación PEA (modo $(config.pea_tolerance_mode)) ===")
    println("  Banda epsilon_pea en kWh: desviación absoluta máxima por hogar sobre el total " *
            "del horizonte.")
    for summary in pea_rows
        println("  $(summary.controller): activaciones=$(summary.activations)/" *
                "$(summary.periods_solved) períodos " *
                "(tasa $(round(summary.activation_rate, digits=4))), " *
                "media activa=$(round(summary.mean_active, digits=4)) kWh, " *
                "media todos los períodos=$(round(summary.mean_all_periods, digits=4)) kWh, " *
                "máximo=$(round(summary.maximum_tolerance, digits=4)) kWh, " *
                "réplicas completas=$(summary.completed_replications)/$(summary.replications)")
    end
    return nothing
end

# =====================================================================================
# Environment-driven configuration
# =====================================================================================

_env(name::AbstractString, default::AbstractString) = get(ENV, String(name), String(default))

function _env_int_list(name::AbstractString, default::Vector{Int})
    raw = strip(_env(name, ""))
    isempty(raw) && return default
    return [parse(Int, strip(item)) for item in split(raw, ',') if !isempty(strip(item))]
end

function _env_list(name::AbstractString, default::Vector{String})
    raw = strip(_env(name, ""))
    isempty(raw) && return default
    return [String(strip(item)) for item in split(raw, ',') if !isempty(strip(item))]
end

_env_int(name, default::Int) = parse(Int, _env(name, string(default)))
_env_float(name, default::Float64) = parse(Float64, _env(name, string(default)))
_env_bool(name, default::Bool) = lowercase(_env(name, default ? "1" : "0")) in ("1", "true", "yes", "si", "sí")

"""
Resolve an `OOSExperimentConfig` from the environment.

Supports the repository's usual instance variables (`INST_FOLDER`, `INSTANCE_FROM`,
`TREE_SET`, `J_SET`, `THETA_SET`, `AVG_D_SET`, `DEV_D_SET`, `DEMAND_PROFILE_SET`,
`BATTERY_SCALE_SET`, `PV_SCALE_SET`) using their first entry, since one campaign runs on one
instance configuration.
"""
function oos_config_from_environment()
    instance_folder = _env("INST_FOLDER", joinpath(OOS_CODES_DIRECTORY, "inst", "inst2020"))
    instance_from = _env_int("INSTANCE_FROM", 1)
    instance_to = _env_int("INSTANCE_TO", instance_from)
    instance_to == instance_from || @warn(
        "El experimento OOS corre sobre una configuración de instancia; se usa INSTANCE_FROM=" *
        "$instance_from e se ignora INSTANCE_TO=$instance_to."
    )
    files = isdir(instance_folder) ? sort(readdir(instance_folder)) : String[]
    isempty(files) && error("No se encontraron archivos de instancia en: $instance_folder")
    1 <= instance_from <= length(files) || error(
        "INSTANCE_FROM=$instance_from fuera de rango para $(length(files)) archivos."
    )
    instance_file = _env("INSTANCE_FILE", joinpath(instance_folder, files[instance_from]))

    tree_spec = first(_env_list("TREE_SET", ["3:2:8"]))
    parts = split(tree_spec, ':')
    length(parts) == 3 || error("TREE_SET debe tener el formato S:C:P, por ejemplo 3:2:8.")
    stages, children, periods = parse.(Int, parts)

    controllers = [parse_controller_kind(label) for label in
                   _env_list("CONTROLLER_SET", ["DETERMINISTIC_RH", "TWO_STAGE_RH", "MULTISTAGE_RH"])]
    policies = [parse_fairness_policy(label) for label in
                _env_list("FAIRNESS_SET",
                          ["NONE", "STATIC_DEMAND_SHARE", "PEA", "SA", "LEXMMFPEA", "LEXMMFSA"])]

    return OOSExperimentConfig(
        experiment_seed=_env_int("EXPERIMENT_SEED", 12345),
        oos_replications=_env_int("OOS_REPLICATIONS", 20),
        controller_set=controllers,
        fairness_set=policies,
        two_stage_scenarios=_env_int("TWO_STAGE_SCENARIOS", 20),
        multistage_branching=_env_int_list("MULTISTAGE_BRANCHING", [2, 2]),
        multistage_periods_per_stage=_env_int_list("MULTISTAGE_PERIODS_PER_STAGE", Int[]),
        fairness_abs_tol=_env_float("FAIRNESS_ABS_TOL", 0.0),
        pea_tolerance_mode=Symbol(_env("PEA_TOLERANCE_MODE", "adaptive_minimum")),
        pea_tolerance_numeric_eps=_env_float("PEA_TOLERANCE_NUMERIC_EPS", 1e-6),
        sa_fairness_abs_tol=_env_float("SA_FAIRNESS_ABS_TOL", 1.0),
        lex_eps_abs=_env_float("LEX_EPS_ABS", 1.0),
        flow_tol=_env_float("FLOW_TOL", OOS_DEFAULT_FLOW_TOL),
        feasibility_tol=_env_float("FEASIBILITY_TOL", OOS_DEFAULT_FEASIBILITY_TOL),
        integrality_tol=_env_float("INTEGRALITY_TOL", OOS_DEFAULT_INTEGRALITY_TOL),
        solver_time_limit_sec=_env_float("SOLVER_TIME_LIMIT_SEC", 600.0),
        formulation_id=_env("FORMULATION_ID", ""),
        allow_legacy_conversion=_env_bool("ALLOW_LEGACY_CONVERSION", false),
        export_representative_models=_env_bool("EXPORT_REPRESENTATIVE_MODELS", true),
        output_directory=_env("OOS_OUTPUT_DIR", joinpath(OOS_REPO_ROOT, "results_oos")),
        instance_file=instance_file,
        in_sample_stages=stages,
        in_sample_children=children,
        in_sample_periods_per_stage=periods,
        households=first(_env_int_list("J_SET", [5])),
        theta=first([parse(Float64, x) for x in _env_list("THETA_SET", ["0.2"])]),
        avg_demand=first([parse(Float64, x) for x in _env_list("AVG_D_SET", ["100.0"])]),
        dev_demand=first([parse(Float64, x) for x in _env_list("DEV_D_SET", ["10.0"])]),
        demand_profile=first(_env_list("DEMAND_PROFILE_SET", ["mixed"])),
        battery_scale=first([parse(Float64, x) for x in _env_list("BATTERY_SCALE_SET", ["1.0"])]),
        pv_scale=first([parse(Float64, x) for x in _env_list("PV_SCALE_SET", ["1.0"])]),
        formulation_variant=Symbol(_env("FORMULATION_VARIANT", "aggregate_only")),
        use_warm_starts=_env_bool("USE_WARM_STARTS", false),
        solver_threads=_env_int("SOLVER_THREADS", 0),
        require_shared_battery_validation=_env_bool("REQUIRE_SHARED_BATTERY_VALIDATION", true),
        experiment_id=_env("EXPERIMENT_ID", "oos_experiment"),
        prompt_version=_env("PROMPT_VERSION", "oos_receding_horizon_prompt_v1"),
    )
end
