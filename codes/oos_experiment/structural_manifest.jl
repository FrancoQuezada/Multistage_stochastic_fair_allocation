# =====================================================================================
# Canonical structural-instance manifest: builder, writer and standalone validator.
#
# The manifest is the authoritative record of a structural factorial design. It is written BEFORE
# any campaign runs, it is byte-for-byte reproducible from its logical inputs, and it is
# self-sufficient: every structural instance can be rematerialized from its own row without
# consulting the design object that produced it.
#
# It carries its OWN schema version (`OOS_STRUCTURAL_MANIFEST_SCHEMA_VERSION`). Adding this
# standalone artefact does not touch `OOS_OUTPUT_SCHEMA_VERSION`, because no results file changed.
#
# The canonical payload deliberately contains NO timestamp, absolute path, hostname, machine
# description, process identifier or git-dirty flag. Operational provenance goes to a separate,
# explicitly noncanonical report, so a manifest generated on two machines from the same inputs is
# the same file.
#
# STAGE SCOPE. The manifest is not consumed by the active simulator. Its OOS-path and
# conditional-support entries are SEED AND IDENTITY CONTRACTS only: no scenario tree, two-stage
# scenario set, deterministic forecast or `ScenarioSupportID` is generated here.
# =====================================================================================

const OOS_STRUCTURAL_MANIFEST_SCHEMA_VERSION = 2

const OOS_STRUCTURAL_MANIFEST_FILES = (
    manifest="structural_instance_manifest.json",
    instances="structural_instance_manifest.csv",
    provenance="structural_instance_manifest_provenance.txt",
)

"""
Canonical record ordering of the catalog, stated in the manifest so a reader never has to infer
it. Never depends on dictionary iteration, filesystem discovery, controller or fairness order,
worker number, task completion order, or `Base.hash` (which has no cross-version stability
contract).
"""
const OOS_STRUCTURAL_CANONICAL_ORDERING = [
    "normalized_base_instance_id",
    "structural_draw",
    "demand_regime",
    "uncertainty_level",
    "battery_level",
]

# -------------------------------------------------------------------------------------
# Seed contract
# -------------------------------------------------------------------------------------

"""
Declarative description of every random stream the experiment uses.

`enforced_exclusions` is what the manifest validator checks mechanically. The three accepted
Stage-2 planning streams and the active Stage-3 deterministic-base stream exclude their declared
operational keys; legacy streams are recorded truthfully, including the fact that the still-active
`lookahead` stream DOES include the controller. Removing it there is Stage 5 and is deliberately
not done here.
"""
const OOS_SEED_CONTRACT = [
    Dict{String,Any}(
        "stream" => OOS_STRUCTURAL_ASSIGNMENT_STREAM,
        "status" => "stage2_contract",
        "purpose" => "household demand-profile assignment of one structural cell",
        "seed_algorithm" => "fnv1a_oos_stream_seed_v1",
        "included_keys" => ["experiment_seed", "base_instance_id", "demand_regime",
                            "structural_draw"],
        "excluded_keys" => ["battery_level", "battery_scale", "uncertainty_level", "theta",
                            "oos_replication", "rolling_start", "controller", "fairness_policy",
                            "solver_phase", "worker", "execution_order"],
        "enforced_exclusions" => ["battery_level", "uncertainty_level", "controller",
                                  "fairness_policy", "solver_phase", "worker", "execution_order"],
    ),
    Dict{String,Any}(
        "stream" => OOS_STRUCTURAL_PATH_STREAM,
        "status" => "stage2_contract",
        "purpose" => "future realized out-of-sample trajectory of one replication",
        "seed_algorithm" => "fnv1a_oos_stream_seed_v1",
        "included_keys" => ["experiment_seed", "base_instance_id", "demand_assignment_id",
                            "demand_regime", "structural_draw", "uncertainty_level",
                            "oos_replication"],
        "excluded_keys" => ["battery_level", "battery_scale", "theta", "rolling_start",
                            "controller", "fairness_policy", "solver_phase", "worker",
                            "execution_order"],
        "enforced_exclusions" => ["battery_level", "controller", "fairness_policy",
                                  "solver_phase", "worker", "execution_order"],
        "note" => "The uncertainty LEVEL is a key; its numeric theta is not, so a stage-12 " *
                  "recalibration of the level values does not renumber the common streams. " *
                  "Excluding battery level is what pairs a low/high battery comparison on one " *
                  "exogenous trajectory. Stage 2 does not introduce common random numbers " *
                  "across different uncertainty levels.",
    ),
    Dict{String,Any}(
        "stream" => OOS_CONDITIONAL_SUPPORT_STREAM,
        "status" => "stage2_contract",
        "purpose" => "future conditional stochastic support at one rolling start",
        "seed_algorithm" => "fnv1a_oos_stream_seed_v1",
        "included_keys" => ["experiment_seed", "base_instance_id", "demand_assignment_id",
                            "demand_regime", "structural_draw", "uncertainty_level",
                            "oos_replication", "rolling_start"],
        "excluded_keys" => ["battery_level", "battery_scale", "theta", "controller",
                            "fairness_policy", "solver_phase", "worker", "execution_order"],
        "enforced_exclusions" => ["battery_level", "controller", "fairness_policy",
                                  "solver_phase", "worker", "execution_order"],
    ),
    Dict{String,Any}(
        "stream" => OOS_DETERMINISTIC_BASE_STREAM,
        "status" => "stage3_active_structural_materializer",
        "purpose" => "uncertainty-independent repository base data shared across the eight " *
                     "battery, demand-regime and uncertainty variants of one structural draw",
        "seed_algorithm" => "fnv1a_oos_stream_seed_v1",
        "included_keys" => copy(OOS_DETERMINISTIC_BASE_INCLUDED_KEYS),
        "excluded_keys" => copy(OOS_DETERMINISTIC_BASE_EXCLUDED_KEYS),
        "enforced_exclusions" => copy(OOS_DETERMINISTIC_BASE_EXCLUDED_KEYS),
        "note" => "This is the actual seed passed through repository_seed_override by the " *
                  "Stage-3 structural materializer. It excludes theta and every experimental " *
                  "factor other than structural_draw, so changing uncertainty cannot change " *
                  "prices or any other deterministic repository input.",
    ),
    Dict{String,Any}(
        "stream" => "repository_instance_seed",
        "status" => "legacy_default_active_outside_structural_materializer",
        "purpose" => "counterfactual seed of the unchanged default generateInstance path",
        "seed_algorithm" => "fnv1a_deterministic_seed_v1",
        "included_keys" => ["in_sample_stages", "in_sample_children",
                            "in_sample_periods_per_stage", "households",
                            "base_instance_file_basename", "theta", "avg_demand", "dev_demand",
                            "repository_demand_profile"],
        "excluded_keys" => ["pv_scale", "battery_scale", "structural_draw", "demand_regime",
                            "oos_replication", "rolling_start", "controller", "fairness_policy",
                            "solver_phase", "worker", "execution_order"],
        "enforced_exclusions" => ["battery_scale", "controller", "fairness_policy",
                                  "solver_phase", "worker", "execution_order"],
        "note" => "The ordinary repository caller still uses this theta-dependent seed exactly " *
                  "as before. Schema-v2 rows retain it only to audit the legacy default and the " *
                  "Stage-2 confound; the structural materializer uses the separate Stage-3 " *
                  "deterministic-base seed recorded as actual_repository_generator_seed.",
    ),
    Dict{String,Any}(
        "stream" => "oos_path",
        "status" => "legacy_active",
        "purpose" => "the single-instance simulator's current realized trajectory stream",
        "seed_algorithm" => "fnv1a_oos_stream_seed_v1",
        "included_keys" => ["experiment_seed", "oos_replication"],
        "excluded_keys" => ["controller", "fairness_policy", "solver_phase", "worker",
                            "execution_order"],
        "enforced_exclusions" => ["controller", "fairness_policy", "solver_phase", "worker",
                                  "execution_order"],
        "note" => "Unchanged by stage 2. Replacing it with the structural key belongs to the " *
                  "later catalog/campaign wiring.",
    ),
    Dict{String,Any}(
        "stream" => "lookahead",
        "status" => "legacy_active",
        "purpose" => "the single-instance simulator's current controller-specific look-ahead",
        "seed_algorithm" => "fnv1a_oos_stream_seed_v1",
        "included_keys" => ["experiment_seed", "oos_replication", "period", "controller"],
        "excluded_keys" => ["fairness_policy", "solver_phase", "worker", "execution_order"],
        "enforced_exclusions" => ["fairness_policy", "solver_phase", "worker", "execution_order"],
        "note" => "Deliberately still INCLUDES the controller. Removing it, so all methods share " *
                  "one conditional support, is stage 5 and is not done here.",
    ),
    Dict{String,Any}(
        "stream" => "in_sample",
        "status" => "legacy_active",
        "purpose" => "static demand-share calibration objects",
        "seed_algorithm" => "fnv1a_oos_stream_seed_v1",
        "included_keys" => ["experiment_seed"],
        "excluded_keys" => ["controller", "fairness_policy", "solver_phase", "worker",
                            "execution_order"],
        "enforced_exclusions" => ["controller", "fairness_policy", "solver_phase", "worker",
                                  "execution_order"],
    ),
    Dict{String,Any}(
        "stream" => "demand_profiles",
        "status" => "legacy_active",
        "purpose" => "the legacy single-instance ex-ante household profile draw",
        "seed_algorithm" => "fnv1a_oos_stream_seed_v1",
        "included_keys" => ["experiment_seed"],
        "excluded_keys" => ["controller", "fairness_policy", "solver_phase", "worker",
                            "execution_order"],
        "enforced_exclusions" => ["controller", "fairness_policy", "solver_phase", "worker",
                                  "execution_order"],
        "note" => "Superseded on the structural path by " *
                  OOS_STRUCTURAL_ASSIGNMENT_STREAM * ", which is controlled rather than an " *
                  "independent per-household draw. Left untouched for the legacy runner.",
    ),
]

"""Operational keys that must never appear in any recorded seed contract's inclusion list."""
const OOS_FORBIDDEN_SEED_KEYS = ("controller", "fairness_policy", "solver_phase", "worker",
                                 "execution_order", "task_order", "output_directory")

"""
Key-name fragments that must not appear anywhere in the canonical manifest payload.

The first group would attach a clock-time or calendar meaning to an abstract model period. The
second would make the payload machine- or moment-dependent and therefore not reproducible.
"""
const OOS_MANIFEST_FORBIDDEN_KEY_FRAGMENTS = (
    "minute", "hour", "day", "week", "month", "calendar", "clock", "duration", "cycle",
    "timestamp", "generated_at", "hostname", "machine", "cpu", "dirty", "absolute_path",
    "wall_time", "elapsed", "worker", "process_id", "task_order", "execution_order",
    "controller_order", "fairness_order", "solver_threads",
)

const OOS_ABSTRACT_PERIOD_SEMANTICS =
    "abstract model period; no clock-time interpretation is implied"

# -------------------------------------------------------------------------------------
# Payload construction
# -------------------------------------------------------------------------------------

function _record_support_summary(record::OOSStructuralInstanceRecord)
    isempty(record.period_data_support_summary) && error(
        "El registro $(record.spec.structural_instance_id) no contiene el resumen de soporte " *
        "de períodos exigido por el esquema estructural v2. Rematerializa el catálogo."
    )
    return record.period_data_support_summary
end

function _assignment_payload(
    assignment::OOSDemandAssignment,
    record::OOSStructuralInstanceRecord,
)
    summary = _record_support_summary(record)
    digests = summary["digests"]
    return Dict{String,Any}(
        "demand_assignment_id" => assignment.demand_assignment_id,
        "deterministic_data_id" => record.spec.deterministic_data_id,
        "base_instance_id" => assignment.base_instance_id,
        "base_instance_file" => assignment.base_instance_file,
        "demand_regime" => string(assignment.demand_regime),
        "structural_draw" => assignment.structural_draw,
        "assignment_seed" => assignment.assignment_seed,
        "household_profiles" => copy(assignment.household_profiles),
        "repository_instance_horizon" => summary["repository_instance_horizon"],
        "required_period_support_end" => summary["required_period_support_end"],
        "materialized_data_end" => summary["materialized_data_end"],
        "base_demand_activity_digest" => digests["base_demand_activity_digest"],
        "demand_activity_digest" => digests["demand_activity_digest"],
        # Two parallel arrays rather than an object keyed by profile name: a profile label is
        # DATA, and data does not belong in a key. Keeping labels in values also keeps every key
        # free of the words the canonical-payload key scan forbids — `midday` contains "day".
        "profile_count_labels" => collect(OOS_STRUCTURAL_DEMAND_PROFILES),
        "profile_counts" => copy(assignment.profile_counts),
    )
end

function _instance_payload(record::OOSStructuralInstanceRecord)
    spec = record.spec
    resolved = record.resolved
    summary = _record_support_summary(record)
    digests = summary["digests"]
    return Dict{String,Any}(
        "manifest_ordinal" => record.ordinal,
        "structural_instance_id" => spec.structural_instance_id,
        "paired_base_id" => spec.paired_base_id,
        "demand_assignment_id" => spec.demand_assignment_id,
        "deterministic_data_id" => spec.deterministic_data_id,
        "base_instance_id" => spec.base_instance_id,
        "base_instance_file" => spec.base_instance_file,
        "structural_draw" => spec.structural_draw,
        "battery_level" => string(spec.battery_level),
        "battery_scale" => spec.battery_scale,
        "demand_regime" => string(spec.demand_regime),
        "uncertainty_level" => string(spec.uncertainty_level),
        "theta" => spec.theta,
        "household_profiles" => copy(spec.household_profiles),
        "assignment_seed" => spec.assignment_seed,
        "legacy_default_repository_instance_seed" => spec.repository_instance_seed,
        "actual_repository_generator_seed" => spec.actual_repository_generator_seed,
        "repository_instance_id" => resolved.repository_instance_id,
        "repository_instance_horizon" => resolved.repository_instance_horizon,
        "required_period_support_end" => summary["required_period_support_end"],
        "materialized_data_end" => summary["materialized_data_end"],
        "period_mapping_name" => summary["period_mapping_name"],
        "period_mapping_version" => summary["period_mapping_version"],
        "period_mapping_formula" => summary["period_mapping_formula"],
        "base_price_digest" => digests["base_price_digest"],
        "extended_price_digest" => digests["extended_price_digest"],
        "base_pv_reference_digest" => digests["base_pv_reference_digest"],
        "extended_pv_reference_digest" => digests["extended_pv_reference_digest"],
        "base_demand_activity_digest" => digests["base_demand_activity_digest"],
        "demand_activity_digest" => digests["demand_activity_digest"],
        "instance_period_length_delta" => resolved.delta,
        "resolved_s_min" => resolved.s_min,
        "resolved_s_max" => resolved.s_max,
        "resolved_s_I" => resolved.s_I,
        "resolved_f_under" => resolved.f_under,
        "resolved_f_bar" => resolved.f_bar,
        "resolved_e_c" => resolved.e_c,
        "resolved_e_d" => resolved.e_d,
        "resolved_mu" => resolved.mu,
        "resolved_beta" => resolved.beta,
        "households" => spec.households,
        "avg_demand" => spec.avg_demand,
        "dev_demand" => spec.dev_demand,
        "pv_scale" => spec.pv_scale,
        "in_sample_stages" => spec.in_sample_stages,
        "in_sample_children" => spec.in_sample_children,
        "in_sample_periods_per_stage" => spec.in_sample_periods_per_stage,
        "repository_demand_profile" => spec.repository_demand_profile,
    )
end

function _deterministic_data_payloads(records::Vector{OOSStructuralInstanceRecord})
    identifiers = String[]
    groups = Dict{String,Vector{OOSStructuralInstanceRecord}}()
    for record in records
        identifier = record.spec.deterministic_data_id
        if !haskey(groups, identifier)
            push!(identifiers, identifier)
            groups[identifier] = OOSStructuralInstanceRecord[]
        end
        push!(groups[identifier], record)
    end

    payloads = Dict{String,Any}[]
    for identifier in identifiers
        members = groups[identifier]
        reference = first(members)
        spec = reference.spec
        summary = _record_support_summary(reference)
        digests = summary["digests"]

        activity_by_assignment = Dict{String,Dict{String,Any}}()
        for member in members
            candidate = _record_support_summary(member)
            candidate_digests = candidate["digests"]
            for field in ("repository_instance_horizon", "required_period_support_end",
                          "materialized_data_end", "period_mapping_name",
                          "period_mapping_version", "period_mapping_formula")
                candidate[field] == summary[field] || error(
                    "$identifier contiene valores incompatibles de `$field`."
                )
            end
            member.spec.actual_repository_generator_seed ==
                spec.actual_repository_generator_seed || error(
                    "$identifier contiene más de una semilla real del generador."
                )
            for field in ("base_price_digest", "extended_price_digest",
                          "base_pv_reference_digest", "extended_pv_reference_digest")
                candidate_digests[field] == digests[field] || error(
                    "$identifier contiene más de un `$field`."
                )
            end
            assignment_id = member.spec.demand_assignment_id
            entry = Dict{String,Any}(
                "demand_assignment_id" => assignment_id,
                "demand_regime" => string(member.spec.demand_regime),
                "base_demand_activity_digest" =>
                    candidate_digests["base_demand_activity_digest"],
                "demand_activity_digest" => candidate_digests["demand_activity_digest"],
            )
            if haskey(activity_by_assignment, assignment_id)
                activity_by_assignment[assignment_id] == entry || error(
                    "$identifier registra dos actividades para $assignment_id."
                )
            else
                activity_by_assignment[assignment_id] = entry
            end
        end
        activity_entries = sort(
            collect(values(activity_by_assignment));
            by=entry -> String(entry["demand_assignment_id"]),
        )
        aggregate_activity_digest = oos_stable_digest(canonical_json(activity_entries))

        push!(payloads, Dict{String,Any}(
            "deterministic_data_id" => identifier,
            "actual_repository_generator_seed" => spec.actual_repository_generator_seed,
            "included_seed_keys" => copy(OOS_DETERMINISTIC_BASE_INCLUDED_KEYS),
            "excluded_seed_keys" => copy(OOS_DETERMINISTIC_BASE_EXCLUDED_KEYS),
            "base_instance_id" => spec.base_instance_id,
            "normalized_base_instance_file" => spec.base_instance_file,
            "structural_draw" => spec.structural_draw,
            "in_sample_stages" => spec.in_sample_stages,
            "in_sample_children" => spec.in_sample_children,
            "in_sample_periods_per_stage" => spec.in_sample_periods_per_stage,
            "households" => spec.households,
            "avg_demand" => spec.avg_demand,
            "dev_demand" => spec.dev_demand,
            "pv_scale" => spec.pv_scale,
            "repository_demand_profile" => spec.repository_demand_profile,
            "repository_instance_horizon" => summary["repository_instance_horizon"],
            "required_period_support_end" => summary["required_period_support_end"],
            "materialized_data_end" => summary["materialized_data_end"],
            "period_mapping_name" => summary["period_mapping_name"],
            "period_mapping_version" => summary["period_mapping_version"],
            "period_mapping_formula" => summary["period_mapping_formula"],
            "base_price_digest" => digests["base_price_digest"],
            "extended_price_digest" => digests["extended_price_digest"],
            "base_pv_reference_digest" => digests["base_pv_reference_digest"],
            "extended_pv_reference_digest" => digests["extended_pv_reference_digest"],
            "demand_activity_digest" => aggregate_activity_digest,
            "demand_activity_digests" => activity_entries,
        ))
    end
    return payloads
end

"""
Assemble the canonical manifest payload, excluding the `manifest_id` field itself.

`records` must already be in canonical order; the ordinals are taken from them verbatim.
"""
function structural_manifest_payload(
    design::OOSStructuralDesignConfig,
    records::Vector{OOSStructuralInstanceRecord},
)
    assignments = structural_demand_assignments(design)
    starts = rolling_iteration_starts(design)
    deterministic_data = _deterministic_data_payloads(records)

    record_by_assignment = Dict{String,OOSStructuralInstanceRecord}()
    for record in records
        get!(record_by_assignment, record.spec.demand_assignment_id, record)
    end
    for assignment in assignments
        haskey(record_by_assignment, assignment.demand_assignment_id) || error(
            "No hay un registro materializado para $(assignment.demand_assignment_id)."
        )
    end

    repository_horizons = unique([
        _record_support_summary(record)["repository_instance_horizon"] for record in records
    ])
    required_endpoints = unique([
        _record_support_summary(record)["required_period_support_end"] for record in records
    ])
    data_endpoints = unique([
        _record_support_summary(record)["materialized_data_end"] for record in records
    ])
    length(repository_horizons) == 1 || error(
        "El diseño materializado contiene varios horizontes de instancia: $repository_horizons."
    )
    required_endpoints == [required_period_support_end(design)] || error(
        "El catálogo no materializó exactamente el extremo de soporte requerido por el diseño."
    )
    length(data_endpoints) == 1 || error(
        "El diseño materializado contiene varios extremos de datos: $data_endpoints."
    )

    # One planned OOS-path entry per PairedBaseID x replication, never duplicated by battery.
    pairing_seen = String[]
    pairing_specs = OOSStructuralInstanceSpec[]
    for record in records
        if !(record.spec.paired_base_id in pairing_seen)
            push!(pairing_seen, record.spec.paired_base_id)
            push!(pairing_specs, record.spec)
        end
    end

    path_entries = Dict{String,Any}[]
    support_entries = Dict{String,Any}[]
    for spec in pairing_specs
        key = oos_path_seed_key(design, spec)
        for replication in 1:design.oos_replications
            push!(path_entries, Dict{String,Any}(
                "paired_base_id" => spec.paired_base_id,
                "demand_assignment_id" => spec.demand_assignment_id,
                "base_instance_id" => spec.base_instance_id,
                "demand_regime" => string(spec.demand_regime),
                "structural_draw" => spec.structural_draw,
                "uncertainty_level" => string(spec.uncertainty_level),
                "oos_replication" => replication,
                "oos_path_seed" => structural_oos_path_seed(key, replication),
            ))
            for start in starts
                push!(support_entries, Dict{String,Any}(
                    "paired_base_id" => spec.paired_base_id,
                    "oos_replication" => replication,
                    "rolling_start" => start,
                    "conditional_support_seed" =>
                        conditional_support_seed(key, replication, start),
                ))
            end
        end
    end

    design_metadata = Dict{String,Any}(
        "structural_manifest_schema_version" => OOS_STRUCTURAL_MANIFEST_SCHEMA_VERSION,
        "canonical_json_version" => OOS_CANONICAL_JSON_VERSION,
        "digest_algorithm" => OOS_STABLE_DIGEST_ALGORITHM,
        "identifier_algorithm" => OOS_STRUCTURAL_ID_ALGORITHM,
        "assignment_algorithm" => OOS_STRUCTURAL_ASSIGNMENT_ALGORITHM,
        "experiment_seed" => design.experiment_seed,
        "factor_level_status" => string(design.factor_level_status),
        "factor_level_note" =>
            "The battery scales and uncertainty intensities below are explicit inputs, not " *
            "repository defaults and not calibrated recommendations. Stage 12 fixes the " *
            "campaign levels; any value recorded here is provisional.",
        "base_instance_files" => copy(design.base_instance_files),
        "base_instance_ids" => [base_instance_id(file) for file in design.base_instance_files],
        "base_instance_count" => length(design.base_instance_files),
        "structural_draws_per_cell" => design.structural_draws_per_cell,
        "expected_structural_instance_count" => expected_structural_instance_count(design),
        "actual_structural_instance_count" => length(records),
        "expected_paired_base_count" => expected_paired_base_count(design),
        "expected_demand_assignment_count" => expected_demand_assignment_count(design),
        "expected_deterministic_data_count" => expected_deterministic_data_count(design),
        "actual_deterministic_data_count" => length(deterministic_data),
        "battery_level_scales" => Dict{String,Any}(
            string(level) => battery_scale(design, level) for level in OOS_BATTERY_LEVEL_ORDER
        ),
        "battery_level_order" => [string(level) for level in OOS_BATTERY_LEVEL_ORDER],
        "uncertainty_level_thetas" => Dict{String,Any}(
            string(level) => uncertainty_theta(design, level)
            for level in OOS_UNCERTAINTY_LEVEL_ORDER
        ),
        "uncertainty_level_order" => [string(level) for level in OOS_UNCERTAINTY_LEVEL_ORDER],
        "demand_regimes" => [string(regime) for regime in OOS_DEMAND_REGIME_ORDER],
        "structural_demand_profiles" => collect(OOS_STRUCTURAL_DEMAND_PROFILES),
        "households" => design.households,
        "avg_demand" => design.avg_demand,
        "dev_demand" => design.dev_demand,
        "pv_scale" => design.pv_scale,
        "repository_demand_profile" => design.repository_demand_profile,
        "in_sample_stages" => design.in_sample_stages,
        "in_sample_children" => design.in_sample_children,
        "in_sample_periods_per_stage" => design.in_sample_periods_per_stage,
        "oos_replication_count" => design.oos_replications,
        # Abstract model periods only. No clock-time or calendar quantity appears anywhere.
        "period_semantics" => OOS_ABSTRACT_PERIOD_SEMANTICS,
        "evaluation_horizon" => design.evaluation_horizon,
        "lookahead_horizon" => design.lookahead_horizon,
        "implementation_step" => design.implementation_step,
        "known_prefix_length" => known_prefix_length(design),
        "rolling_iteration_starts" => starts,
        "rolling_solve_count" => rolling_solve_count(design),
        "required_period_support_end" => required_period_support_end(design),
        "repository_instance_horizon" => only(repository_horizons),
        "materialized_data_end" => only(data_endpoints),
        "period_mapping_name" => OOS_PERIOD_MAPPING_NAME,
        "period_mapping_version" => OOS_PERIOD_MAPPING_VERSION,
        "period_mapping_formula" => OOS_PERIOD_MAPPING_FORMULA,
        "deterministic_base_isolation_status" => "passed",
        "stage3_ready" => true,
        "canonical_ordering" => copy(OOS_STRUCTURAL_CANONICAL_ORDERING),
        # Stage 13 connected the manifest: `oos_tasks_from_manifest` regenerates this catalog and
        # refuses to run if a single identifier differs. The flag records that fact rather than
        # the stage-3 scope condition it replaced.
        "consumed_by_active_simulator" => true,
        "scope_note" =>
            "Structural catalog, deterministic period-data support and seed contract. Since " *
            "stage 13 the campaign runner enumerates its tasks from this document and verifies " *
            "the regenerated catalog against the identifiers recorded here. The manifest still " *
            "generates no scenario support: the conditional support is drawn per task from the " *
            "seed contract below, and its ScenarioSupportID is produced at run time.",
    )

    return Dict{String,Any}(
        "design" => design_metadata,
        "seed_contract" => deepcopy(OOS_SEED_CONTRACT),
        "deterministic_data_blocks" => deterministic_data,
        "demand_assignments" => [
            _assignment_payload(a, record_by_assignment[a.demand_assignment_id])
            for a in assignments
        ],
        "structural_instances" => [_instance_payload(record) for record in records],
        "planned_oos_replication_keys" => path_entries,
        "planned_conditional_support_keys" => support_entries,
    )
end

"""
`ManifestID`: a stable digest of the canonical payload, excluding the identifier field itself.

Defined as the digest of `canonical_json(payload)` where `payload` is the document with
`manifest_id` removed. A validator therefore recomputes it by dropping that one key and
re-rendering, which is exactly what `validate_structural_manifest` does.
"""
structural_manifest_id(payload::AbstractDict) =
    string("MF-", oos_stable_digest(canonical_json(_payload_without_id(payload))))

function _payload_without_id(document::AbstractDict)
    payload = Dict{String,Any}(String(string(k)) => v for (k, v) in document)
    delete!(payload, "manifest_id")
    return payload
end

"""Render the complete manifest document, `manifest_id` included, as canonical JSON text."""
function structural_manifest_document(
    design::OOSStructuralDesignConfig,
    records::Vector{OOSStructuralInstanceRecord},
)
    payload = structural_manifest_payload(design, records)
    document = Dict{String,Any}(payload)
    document["manifest_id"] = structural_manifest_id(payload)
    return document
end

structural_manifest_text(document::AbstractDict) = canonical_json(document) * "\n"

# -------------------------------------------------------------------------------------
# Normalized CSV companion
# -------------------------------------------------------------------------------------

"""
Flat one-row-per-structural-instance view, in canonical ordinal order.

A convenience for downstream tooling only. The JSON manifest remains the authority and the sole
input to the `ManifestID`; this file is never digested.
"""
function structural_manifest_frame(records::Vector{OOSStructuralInstanceRecord})
    frame = DataFrame(
        ManifestOrdinal=Int[], StructuralInstanceID=String[], PairedBaseID=String[],
        DemandAssignmentID=String[], BaseInstanceID=String[], BaseInstanceFile=String[],
        StructuralDraw=Int[], BatteryLevel=String[], BatteryScale=Float64[],
        DemandRegime=String[], UncertaintyLevel=String[], Theta=Float64[],
        HouseholdProfiles=String[], AssignmentSeed=Int[], DeterministicDataID=String[],
        LegacyDefaultRepositoryInstanceSeed=Int[], ActualRepositoryGeneratorSeed=Int[],
        RepositoryInstanceID=String[], RepositoryInstanceHorizon=Int[],
        RequiredPeriodSupportEnd=Int[], MaterializedDataEnd=Int[],
        BasePriceDigest=String[], ExtendedPriceDigest=String[],
        BasePVReferenceDigest=String[], ExtendedPVReferenceDigest=String[],
        BaseDemandActivityDigest=String[], DemandActivityDigest=String[],
        InstancePeriodLengthDelta=Float64[],
        ResolvedSMin=Float64[], ResolvedSMax=Float64[], ResolvedSI=Float64[],
        ResolvedFUnder=Float64[], ResolvedFBar=Float64[],
        Households=Int[], AvgDemand=Float64[], DevDemand=Float64[], PVScale=Float64[],
    )
    for record in records
        spec = record.spec
        resolved = record.resolved
        summary = _record_support_summary(record)
        digests = summary["digests"]
        push!(frame, (
            record.ordinal, spec.structural_instance_id, spec.paired_base_id,
            spec.demand_assignment_id, spec.base_instance_id, spec.base_instance_file,
            spec.structural_draw, string(spec.battery_level), spec.battery_scale,
            string(spec.demand_regime), string(spec.uncertainty_level), spec.theta,
            join(spec.household_profiles, ";"), spec.assignment_seed, spec.deterministic_data_id,
            spec.repository_instance_seed, spec.actual_repository_generator_seed,
            resolved.repository_instance_id, resolved.repository_instance_horizon,
            summary["required_period_support_end"], summary["materialized_data_end"],
            digests["base_price_digest"], digests["extended_price_digest"],
            digests["base_pv_reference_digest"], digests["extended_pv_reference_digest"],
            digests["base_demand_activity_digest"], digests["demand_activity_digest"],
            resolved.delta,
            resolved.s_min, resolved.s_max, resolved.s_I, resolved.f_under, resolved.f_bar,
            spec.households, spec.avg_demand, spec.dev_demand, spec.pv_scale,
        ))
    end
    return frame
end

# -------------------------------------------------------------------------------------
# Generation
# -------------------------------------------------------------------------------------

"""Outcome of writing (or declining to write) a structural manifest."""
struct StructuralManifestWrite
    path::String
    manifest_id::String
    written::Bool
    status::String          # "created", "unchanged" or "overwritten"
    structural_instances::Int
    paired_bases::Int
    demand_assignments::Int
    deterministic_data_blocks::Int
    planned_oos_keys::Int
    planned_support_keys::Int
    companion_files::Vector{String}
end

"""
Generate and write the canonical structural manifest.

Validates the design, materializes the whole catalog through the approved repository pipeline,
checks every internal invariant, and only then writes — atomically.

Idempotence: if the destination already holds byte-identical content the write is a no-op
reported as `"unchanged"`. Conflicting content is an error unless `overwrite=true`, so a
different manifest is never silently replaced.
"""
function generate_structural_manifest(
    base_config::OOSExperimentConfig,
    design::OOSStructuralDesignConfig,
    path::AbstractString;
    overwrite::Bool=false,
    write_companions::Bool=true,
    verbose::Bool=true,
)
    verbose && println("Materializando el catálogo estructural " *
                       "($(expected_structural_instance_count(design)) instancias)...")
    records = build_structural_catalog(base_config, design; verbose=verbose)
    document = structural_manifest_document(design, records)
    text = structural_manifest_text(document)

    # Validate the in-memory document before anything reaches disk.
    report = validate_structural_manifest_document(document)
    enforce_structural_manifest!(report)

    destination = String(path)
    status = "created"
    written = true
    if isfile(destination)
        existing = read(destination, String)
        if existing == text
            status = "unchanged"
            written = false
            verbose && println("El manifiesto existente es idéntico; no se reescribe.")
        elseif overwrite
            status = "overwritten"
        else
            error(
                "Ya existe un manifiesto DISTINTO en $destination. No se sobrescribe en " *
                "silencio: revisa las diferencias y vuelve a ejecutar con " *
                "STRUCTURAL_MANIFEST_OVERWRITE=1 si realmente quieres reemplazarlo."
            )
        end
    end
    written && write_atomically(destination, text)

    companions = String[]
    if write_companions
        directory = dirname(abspath(destination))
        csv_path = joinpath(directory, OOS_STRUCTURAL_MANIFEST_FILES.instances)
        CSV.write(csv_path, structural_manifest_frame(records))
        push!(companions, csv_path)
        push!(companions, write_structural_manifest_provenance(directory, document))
    end

    return StructuralManifestWrite(
        destination, document["manifest_id"], written, status,
        length(document["structural_instances"]),
        length(unique([row["paired_base_id"] for row in document["structural_instances"]])),
        length(document["demand_assignments"]),
        length(document["deterministic_data_blocks"]),
        length(document["planned_oos_replication_keys"]),
        length(document["planned_conditional_support_keys"]),
        companions,
    )
end

"""
Write the explicitly NONCANONICAL provenance report.

Everything a canonical payload must not contain — the generation moment, the machine, the git
state, the absolute destination — lives here instead, so operational traceability does not cost
byte reproducibility.
"""
function write_structural_manifest_provenance(directory::AbstractString, document::AbstractDict)
    path = joinpath(String(directory), OOS_STRUCTURAL_MANIFEST_FILES.provenance)
    lines = [
        "Reporte de procedencia NO CANÓNICO del manifiesto estructural.",
        "Este archivo queda deliberadamente fuera del payload canónico y del ManifestID: " *
        "contiene datos dependientes del momento y de la máquina.",
        "",
        "manifest_id        = $(document["manifest_id"])",
        "esquema            = $(document["design"]["structural_manifest_schema_version"])",
        "instancias         = $(length(document["structural_instances"]))",
        "datos_deterministas= $(length(document["deterministic_data_blocks"]))",
        "generado_utc       = $(now_utc_string())",
        "julia              = $(VERSION)",
        "commit             = $(_git_commit())",
        "arbol_sucio        = $(_git_dirty())",
        "maquina            = $(Sys.MACHINE)",
        "directorio_destino = $(abspath(String(directory)))",
    ]
    write_atomically(path, join(lines, "\n") * "\n")
    return path
end

# -------------------------------------------------------------------------------------
# Validation
# -------------------------------------------------------------------------------------

"""One problem found while validating a structural manifest."""
struct StructuralManifestIssue
    section::String
    severity::Symbol        # :error or :warning
    detail::String
end

structural_issue_is_blocking(issue::StructuralManifestIssue) = issue.severity === :error

"""Outcome of validating one structural manifest."""
struct StructuralManifestReport
    passed::Bool
    issues::Vector{StructuralManifestIssue}
    counts::Dict{String,Int}
    manifest_id::String
end

structural_blocking_issues(report::StructuralManifestReport) =
    filter(structural_issue_is_blocking, report.issues)

"""Print a manifest report and raise when it did not pass."""
function enforce_structural_manifest!(report::StructuralManifestReport)
    for issue in report.issues
        println("  ", structural_issue_is_blocking(issue) ? "[FALLA] " : "[AVISO] ",
                issue.section, " :: ", issue.detail)
    end
    report.passed || error(
        "La validación del manifiesto estructural no pasó " *
        "($(length(structural_blocking_issues(report))) problema(s) bloqueante(s))."
    )
    return report
end

_as_int(value) = value isa Integer ? Int(value) : Int(round(Float64(value)))
_as_float(value) = value isa AbstractFloat ? Float64(value) : Float64(value)
_as_strings(value) = [String(item) for item in value]

"""
Collect every key name appearing anywhere in a nested document.

Used to prove that no clock-time, calendar, timestamp or machine-dependent field slipped into the
canonical payload.
"""
function _collect_keys(value, into::Set{String}=Set{String}())
    if value isa AbstractDict
        for (key, inner) in value
            push!(into, String(string(key)))
            _collect_keys(inner, into)
        end
    elseif value isa AbstractVector
        for item in value
            _collect_keys(item, into)
        end
    end
    return into
end

"""
Validate a structural-manifest document against the accepted Stage-2 invariants and every
Stage-3 schema-v2 data-support/isolation invariant.

Enforces, in order: schema and digest identity; cardinality; identifier uniqueness; battery
pairing (exactly two records, sharing everything non-battery, differing only in the battery
label, its scale, the battery-dependent physical parameters and the full instance ID); demand
assignment sharing and composition rules; the seed contract's declared exclusions; that a
battery-level change leaves the assignment, path and support seeds untouched; that support seeds
differ across rolling starts; that structural draws stay distinguishable; and that the payload
contains no clock-time, timestamp or machine-dependent field.

`rematerialize` additionally re-runs the repository pipeline for a bounded set of records and
compares the resolved physical parameters; it needs a `base_config` and never runs a campaign.
"""
function validate_structural_manifest_document(
    document::AbstractDict;
    base_config::Union{Nothing,OOSExperimentConfig}=nothing,
    rematerialize::Bool=false,
    rematerialize_limit::Int=0,
)
    issues = StructuralManifestIssue[]
    counts = Dict{String,Int}()
    fail(section, detail) = push!(issues, StructuralManifestIssue(section, :error, detail))
    warn(section, detail) = push!(issues, StructuralManifestIssue(section, :warning, detail))

    for section in ("design", "manifest_id")
        haskey(document, section) || fail("manifest", "falta la sección `$section`")
    end
    if any(structural_issue_is_blocking, issues)
        return StructuralManifestReport(false, issues, counts, "")
    end

    design = document["design"]
    manifest_id = String(document["manifest_id"])
    recorded_schema = _as_int(get(design, "structural_manifest_schema_version", -1))
    if recorded_schema == 1
        fail(
            "design",
            "el esquema v1 conserva el contrato aceptado de la etapa 2, pero no demuestra " *
            "aislamiento determinista ni soporte extendido y no está listo para la etapa 3; " *
            "regenerate as schema v2",
        )
        return StructuralManifestReport(false, issues, counts, manifest_id)
    end
    for section in ("seed_contract", "deterministic_data_blocks", "demand_assignments",
                    "structural_instances", "planned_oos_replication_keys",
                    "planned_conditional_support_keys")
        haskey(document, section) || fail("manifest", "falta la sección `$section`")
    end
    # Without every schema-v2 section present the checks below cannot be evaluated meaningfully.
    if any(structural_issue_is_blocking, issues)
        return StructuralManifestReport(false, issues, counts, manifest_id)
    end

    instances_payload = document["structural_instances"]
    deterministic_payload = document["deterministic_data_blocks"]
    assignments_payload = document["demand_assignments"]
    path_keys = document["planned_oos_replication_keys"]
    support_keys = document["planned_conditional_support_keys"]

    counts["structural_instances"] = length(instances_payload)
    counts["deterministic_data_blocks"] = length(deterministic_payload)
    counts["demand_assignments"] = length(assignments_payload)
    counts["planned_oos_replication_keys"] = length(path_keys)
    counts["planned_conditional_support_keys"] = length(support_keys)

    # --- schema and identity ------------------------------------------------------------
    recorded_schema == OOS_STRUCTURAL_MANIFEST_SCHEMA_VERSION || fail(
        "design",
        "esquema de manifiesto $recorded_schema incompatible con el lector actual " *
        "($(OOS_STRUCTURAL_MANIFEST_SCHEMA_VERSION))",
    )
    recomputed = structural_manifest_id(document)
    recomputed == manifest_id || fail(
        "manifest_id", "digest recomputado $recomputed distinto del registrado $manifest_id",
    )
    String(get(design, "canonical_json_version", "")) == OOS_CANONICAL_JSON_VERSION || fail(
        "design", "canonical_json_version distinta de $(OOS_CANONICAL_JSON_VERSION)",
    )
    for (field, expected_value) in (
        ("digest_algorithm", OOS_STABLE_DIGEST_ALGORITHM),
        ("identifier_algorithm", OOS_STRUCTURAL_ID_ALGORITHM),
        ("assignment_algorithm", OOS_STRUCTURAL_ASSIGNMENT_ALGORITHM),
    )
        String(get(design, field, "")) == expected_value || fail(
            "design", "`$field` distinto del contrato declarado por el módulo",
        )
    end
    String(get(design, "factor_level_status", "")) == string(OOS_FACTOR_LEVEL_PROVISIONAL) || fail(
        "design",
        "factor_level_status debe ser $(OOS_FACTOR_LEVEL_PROVISIONAL) mientras los niveles " *
        "numéricos no estén calibrados (etapa 12)",
    )
    get(design, "consumed_by_active_simulator", false) === true || fail(
        "design",
        "consumed_by_active_simulator debe ser true: desde la etapa 13 el runner de campaña " *
        "enumera sus tareas desde el manifiesto y verifica el catálogo regenerado contra los " *
        "identificadores registrados aquí",
    )
    get(design, "stage3_ready", false) === true || fail(
        "design", "stage3_ready debe ser true en un manifiesto de esquema v2",
    )
    String(get(design, "deterministic_base_isolation_status", "")) == "passed" || fail(
        "design", "deterministic_base_isolation_status debe ser `passed`",
    )
    String(get(design, "period_mapping_name", "")) == OOS_PERIOD_MAPPING_NAME || fail(
        "design", "period_mapping_name distinto de $(OOS_PERIOD_MAPPING_NAME)",
    )
    String(get(design, "period_mapping_version", "")) == OOS_PERIOD_MAPPING_VERSION || fail(
        "design", "period_mapping_version distinto de $(OOS_PERIOD_MAPPING_VERSION)",
    )
    String(get(design, "period_mapping_formula", "")) == OOS_PERIOD_MAPPING_FORMULA || fail(
        "design", "period_mapping_formula no describe la función centralizada aprobada",
    )
    String(get(design, "period_semantics", "")) == OOS_ABSTRACT_PERIOD_SEMANTICS || fail(
        "design",
        "period_semantics debe declarar únicamente períodos abstractos, sin interpretación " *
        "de reloj o calendario",
    )

    evaluation_horizon = _as_int(get(design, "evaluation_horizon", 0))
    lookahead_horizon = _as_int(get(design, "lookahead_horizon", 0))
    implementation_step = _as_int(get(design, "implementation_step", 0))
    expected_starts = Int[]
    if evaluation_horizon >= 1 && lookahead_horizon >= 1 && implementation_step >= 1
        try
            validate_temporal_contract(
                evaluation_horizon, lookahead_horizon, implementation_step,
            )
            expected_starts = _rolling_iteration_starts(
                evaluation_horizon, implementation_step,
            )
            expected_support_end = _final_rolling_iteration_start(
                evaluation_horizon, implementation_step,
            ) + lookahead_horizon - 1
            _as_int(get(design, "required_period_support_end", -1)) ==
                expected_support_end || fail(
                    "design",
                    "required_period_support_end incorrecto: se esperaba $expected_support_end",
                )
            [_as_int(value) for value in get(
                design, "rolling_iteration_starts", Any[],
            )] == expected_starts || fail(
                "design",
                "rolling_iteration_starts no coincide exactamente con el contrato temporal: " *
                "se esperaba $expected_starts",
            )
            _as_int(get(design, "rolling_solve_count", -1)) == length(expected_starts) || fail(
                "design",
                "rolling_solve_count no coincide con los $(length(expected_starts)) inicios " *
                "derivados",
            )
            _as_int(get(design, "known_prefix_length", -1)) == implementation_step || fail(
                "design", "known_prefix_length debe coincidir exactamente con implementation_step",
            )
        catch exception
            fail("design", "contrato temporal inválido: $(sprint(showerror, exception))")
        end
    else
        fail("design", "faltan H, L o h positivos para recomputar el soporte requerido")
    end
    repository_horizon = _as_int(get(design, "repository_instance_horizon", 0))
    required_support_end = _as_int(get(design, "required_period_support_end", 0))
    materialized_data_end = _as_int(get(design, "materialized_data_end", 0))
    repository_horizon >= 1 || fail("design", "repository_instance_horizon debe ser >= 1")
    materialized_data_end == max(repository_horizon, required_support_end) || fail(
        "design",
        "materialized_data_end debe ser max(repository_instance_horizon, " *
        "required_period_support_end)",
    )

    # --- cardinality --------------------------------------------------------------------
    base_count = _as_int(get(design, "base_instance_count", 0))
    draws = _as_int(get(design, "structural_draws_per_cell", 0))
    replications = _as_int(get(design, "oos_replication_count", 0))
    starts = [_as_int(v) for v in get(design, "rolling_iteration_starts", Any[])]
    expected_instances = base_count * 2 * 2 * 2 * draws
    expected_pairs = base_count * 2 * 2 * draws
    expected_assignments = base_count * 2 * draws
    expected_deterministic = base_count * draws

    # Reconcile the declared design with every scientific row below. A canonical digest only
    # proves that a document is self-consistently serialized; these checks prove that its design
    # metadata actually describes the rows and deterministic blocks it contains.
    declared_base_files = _as_strings(get(design, "base_instance_files", String[]))
    normalized_declared_files = String[]
    try
        normalized_declared_files = normalized_base_instance_file.(declared_base_files)
    catch exception
        fail(
            "design",
            "base_instance_files no puede normalizarse: $(sprint(showerror, exception))",
        )
    end
    declared_base_files == normalized_declared_files || fail(
        "design", "base_instance_files no está normalizado en forma canónica",
    )
    declared_base_files == sort(unique(declared_base_files)) || fail(
        "design", "base_instance_files debe estar ordenado y no contener duplicados",
    )
    declared_base_ids = _as_strings(get(design, "base_instance_ids", String[]))
    expected_base_ids = base_instance_id.(declared_base_files)
    declared_base_ids == expected_base_ids || fail(
        "design", "base_instance_ids no se deriva exactamente de base_instance_files",
    )
    base_count == length(declared_base_files) || fail(
        "design", "base_instance_count no coincide con base_instance_files",
    )

    battery_labels = string.(collect(OOS_BATTERY_LEVEL_ORDER))
    uncertainty_labels = string.(collect(OOS_UNCERTAINTY_LEVEL_ORDER))
    demand_labels = string.(collect(OOS_DEMAND_REGIME_ORDER))
    _as_strings(get(design, "battery_level_order", String[])) == battery_labels || fail(
        "design", "battery_level_order no coincide con el orden canónico",
    )
    _as_strings(get(design, "uncertainty_level_order", String[])) == uncertainty_labels || fail(
        "design", "uncertainty_level_order no coincide con el orden canónico",
    )
    _as_strings(get(design, "demand_regimes", String[])) == demand_labels || fail(
        "design", "demand_regimes no coincide con los dos regímenes aprobados",
    )
    _as_strings(get(design, "structural_demand_profiles", String[])) ==
        collect(OOS_STRUCTURAL_DEMAND_PROFILES) || fail(
            "design", "structural_demand_profiles difiere del contrato estructural",
        )

    battery_scale_by_label = Dict{String,Float64}()
    battery_mapping = get(design, "battery_level_scales", nothing)
    if battery_mapping isa AbstractDict
        recorded_labels = Set(String(string(key)) for key in keys(battery_mapping))
        recorded_labels == Set(battery_labels) || fail(
            "design", "battery_level_scales debe cubrir exactamente LOW/HIGH_BATTERY",
        )
        for label in battery_labels
            haskey(battery_mapping, label) || continue
            value = _as_float(battery_mapping[label])
            battery_scale_by_label[label] = value
            isfinite(value) && value > 0 || fail(
                "design", "battery_level_scales[$label] debe ser finito y > 0",
            )
        end
        if all(haskey(battery_scale_by_label, label) for label in battery_labels)
            battery_scale_by_label["LOW_BATTERY"] <
                battery_scale_by_label["HIGH_BATTERY"] || fail(
                    "design", "battery_level_scales debe satisfacer LOW < HIGH",
                )
        end
    else
        fail("design", "battery_level_scales debe ser un objeto con ambos niveles")
    end

    theta_by_label = Dict{String,Float64}()
    theta_mapping = get(design, "uncertainty_level_thetas", nothing)
    if theta_mapping isa AbstractDict
        recorded_labels = Set(String(string(key)) for key in keys(theta_mapping))
        recorded_labels == Set(uncertainty_labels) || fail(
            "design", "uncertainty_level_thetas debe cubrir exactamente LOW/HIGH_UNCERTAINTY",
        )
        for label in uncertainty_labels
            haskey(theta_mapping, label) || continue
            value = _as_float(theta_mapping[label])
            theta_by_label[label] = value
            isfinite(value) && value >= 0 || fail(
                "design", "uncertainty_level_thetas[$label] debe ser finito y >= 0",
            )
        end
        if all(haskey(theta_by_label, label) for label in uncertainty_labels)
            theta_by_label["LOW_UNCERTAINTY"] <
                theta_by_label["HIGH_UNCERTAINTY"] || fail(
                    "design", "uncertainty_level_thetas debe satisfacer LOW < HIGH",
                )
        end
    else
        fail("design", "uncertainty_level_thetas debe ser un objeto con ambos niveles")
    end

    design_int_fields = Dict{String,Int}(
        "households" => _as_int(get(design, "households", 0)),
        "in_sample_stages" => _as_int(get(design, "in_sample_stages", 0)),
        "in_sample_children" => _as_int(get(design, "in_sample_children", 0)),
        "in_sample_periods_per_stage" =>
            _as_int(get(design, "in_sample_periods_per_stage", 0)),
    )
    design_float_fields = Dict{String,Float64}(
        "avg_demand" => _as_float(get(design, "avg_demand", NaN)),
        "dev_demand" => _as_float(get(design, "dev_demand", NaN)),
        "pv_scale" => _as_float(get(design, "pv_scale", NaN)),
    )
    design_string_fields = Dict{String,String}(
        "repository_demand_profile" =>
            String(get(design, "repository_demand_profile", "")),
    )
    design_int_fields["households"] >= 2 || fail("design", "households debe ser >= 2")
    for field in ("in_sample_stages", "in_sample_children", "in_sample_periods_per_stage")
        design_int_fields[field] >= 1 || fail("design", "$field debe ser >= 1")
    end
    isfinite(design_float_fields["avg_demand"]) &&
        design_float_fields["avg_demand"] > 0 || fail(
            "design", "avg_demand debe ser finito y > 0",
        )
    isfinite(design_float_fields["dev_demand"]) &&
        design_float_fields["dev_demand"] >= 0 || fail(
            "design", "dev_demand debe ser finito y >= 0",
        )
    isfinite(design_float_fields["pv_scale"]) &&
        design_float_fields["pv_scale"] > 0 || fail(
            "design", "pv_scale debe ser finito y > 0",
        )
    isempty(strip(design_string_fields["repository_demand_profile"])) && fail(
        "design", "repository_demand_profile no puede estar vacío",
    )

    declared_structural_design = nothing
    if all(haskey(battery_scale_by_label, label) for label in battery_labels) &&
       all(haskey(theta_by_label, label) for label in uncertainty_labels)
        try
            declared_structural_design = OOSStructuralDesignConfig(
                base_instance_files=declared_base_files,
                experiment_seed=_as_int(get(design, "experiment_seed", 0)),
                structural_draws_per_cell=draws,
                battery_scales=battery_scale_map(
                    battery_scale_by_label["LOW_BATTERY"],
                    battery_scale_by_label["HIGH_BATTERY"],
                ),
                uncertainty_thetas=uncertainty_theta_map(
                    theta_by_label["LOW_UNCERTAINTY"],
                    theta_by_label["HIGH_UNCERTAINTY"],
                ),
                households=design_int_fields["households"],
                avg_demand=design_float_fields["avg_demand"],
                dev_demand=design_float_fields["dev_demand"],
                pv_scale=design_float_fields["pv_scale"],
                oos_replications=replications,
                evaluation_horizon=evaluation_horizon,
                lookahead_horizon=lookahead_horizon,
                implementation_step=implementation_step,
                in_sample_stages=design_int_fields["in_sample_stages"],
                in_sample_children=design_int_fields["in_sample_children"],
                in_sample_periods_per_stage=
                    design_int_fields["in_sample_periods_per_stage"],
                repository_demand_profile=
                    design_string_fields["repository_demand_profile"],
                factor_level_status=OOS_FACTOR_LEVEL_PROVISIONAL,
            )
            declared_structural_design.base_instance_files == declared_base_files || fail(
                "design", "base_instance_files no conserva el orden canónico del diseño",
            )
        catch exception
            fail(
                "design",
                "los metadatos no reconstruyen un OOSStructuralDesignConfig válido: " *
                sprint(showerror, exception),
            )
        end
    end

    draws >= 1 || fail("design", "structural_draws_per_cell debe ser >= 1; se registró $draws")
    base_count >= 1 || fail("design", "el conjunto de instancias base no puede estar vacío")
    _as_int(get(design, "expected_structural_instance_count", -1)) == expected_instances || fail(
        "design", "expected_structural_instance_count inconsistente con B x 2 x 2 x 2 x K",
    )
    _as_int(get(design, "expected_paired_base_count", -1)) == expected_pairs || fail(
        "design", "expected_paired_base_count inconsistente con B x 2 x 2 x K",
    )
    _as_int(get(design, "expected_demand_assignment_count", -1)) == expected_assignments || fail(
        "design", "expected_demand_assignment_count inconsistente con B x 2 x K",
    )
    length(instances_payload) == expected_instances || fail(
        "structural_instances",
        "hay $(length(instances_payload)) registros y B x 2 x 2 x 2 x K = $expected_instances",
    )
    _as_int(get(design, "actual_structural_instance_count", -1)) == length(instances_payload) ||
        fail("design", "actual_structural_instance_count no coincide con las filas registradas")
    length(assignments_payload) == expected_assignments || fail(
        "demand_assignments",
        "hay $(length(assignments_payload)) asignaciones y se esperaban $expected_assignments",
    )
    _as_int(get(design, "expected_deterministic_data_count", -1)) ==
        expected_deterministic || fail(
            "design", "expected_deterministic_data_count inconsistente con B x K",
        )
    _as_int(get(design, "actual_deterministic_data_count", -1)) ==
        length(deterministic_payload) || fail(
            "design", "actual_deterministic_data_count no coincide con los bloques guardados",
        )
    length(deterministic_payload) == expected_deterministic || fail(
        "deterministic_data_blocks",
        "hay $(length(deterministic_payload)) bloques y B x K = $expected_deterministic",
    )

    # --- structural-draw index range ----------------------------------------------------
    for row in instances_payload
        draw = _as_int(row["structural_draw"])
        1 <= draw <= draws || fail(
            "structural_instances",
            "structural_draw $draw fuera de 1:$draws en $(row["structural_instance_id"])",
        )
        base_file = String(get(row, "base_instance_file", ""))
        base_id = String(get(row, "base_instance_id", ""))
        base_file in declared_base_files || fail(
            "structural_instances",
            "$(row["structural_instance_id"]) usa una instancia base ajena al diseño: $base_file",
        )
        base_id == base_instance_id(base_file) || fail(
            "structural_instances",
            "$(row["structural_instance_id"]) registra un base_instance_id incompatible",
        )
        for (field, expected_value) in design_int_fields
            _as_int(get(row, field, typemin(Int))) == expected_value || fail(
                "structural_instances",
                "$(row["structural_instance_id"]) difiere del diseño en `$field`",
            )
        end
        for (field, expected_value) in design_float_fields
            _as_float(get(row, field, NaN)) == expected_value || fail(
                "structural_instances",
                "$(row["structural_instance_id"]) difiere del diseño en `$field`",
            )
        end
        for (field, expected_value) in design_string_fields
            String(get(row, field, "")) == expected_value || fail(
                "structural_instances",
                "$(row["structural_instance_id"]) difiere del diseño en `$field`",
            )
        end

        battery_label = String(get(row, "battery_level", ""))
        if haskey(battery_scale_by_label, battery_label)
            _as_float(get(row, "battery_scale", NaN)) ==
                battery_scale_by_label[battery_label] || fail(
                    "structural_instances",
                    "$(row["structural_instance_id"]) no usa la escala declarada para " *
                    battery_label,
                )
        else
            fail(
                "structural_instances",
                "$(row["structural_instance_id"]) usa un battery_level no declarado: " *
                battery_label,
            )
        end
        uncertainty_label = String(get(row, "uncertainty_level", ""))
        if haskey(theta_by_label, uncertainty_label)
            _as_float(get(row, "theta", NaN)) == theta_by_label[uncertainty_label] || fail(
                "structural_instances",
                "$(row["structural_instance_id"]) no usa el theta declarado para " *
                uncertainty_label,
            )
        else
            fail(
                "structural_instances",
                "$(row["structural_instance_id"]) usa un uncertainty_level no declarado: " *
                uncertainty_label,
            )
        end
        demand_label = String(get(row, "demand_regime", ""))
        if demand_label in demand_labels
            regime = parse_demand_regime(demand_label)
            expected_assignment_seed = structural_assignment_seed(
                _as_int(get(design, "experiment_seed", 0)), base_id, regime, draw,
            )
            _as_int(get(row, "assignment_seed", 0)) == expected_assignment_seed || fail(
                "structural_instances",
                "$(row["structural_instance_id"]) registra una assignment_seed no derivada",
            )
        else
            fail(
                "structural_instances",
                "$(row["structural_instance_id"]) usa un demand_regime no declarado: " *
                demand_label,
            )
        end
        length(_as_strings(get(row, "household_profiles", String[]))) ==
            design_int_fields["households"] || fail(
                "structural_instances",
                "$(row["structural_instance_id"]) no registra un perfil por hogar",
            )
        if haskey(theta_by_label, uncertainty_label) && base_file in declared_base_files
            expected_legacy_seed = deterministic_seed(
                design_int_fields["in_sample_stages"],
                design_int_fields["in_sample_children"],
                design_int_fields["in_sample_periods_per_stage"],
                design_int_fields["households"],
                absolute_base_instance_file(base_file),
                theta_by_label[uncertainty_label],
                design_float_fields["avg_demand"],
                design_float_fields["dev_demand"];
                demand_profile=design_string_fields["repository_demand_profile"],
            )
            _as_int(get(row, "legacy_default_repository_instance_seed", 0)) ==
                expected_legacy_seed || fail(
                    "structural_instances",
                    "$(row["structural_instance_id"]) altera la semilla legacy derivada",
                )
        end
        if declared_structural_design !== nothing && demand_label in demand_labels &&
           battery_label in battery_labels && uncertainty_label in uncertainty_labels
            parsed_regime = parse_demand_regime(demand_label)
            parsed_uncertainty = parse_uncertainty_level(uncertainty_label)
            parsed_battery = parse_battery_level(battery_label)
            expected_pairing_id = paired_base_id(
                declared_structural_design,
                base_file,
                parsed_regime,
                draw,
                parsed_uncertainty,
                String(get(row, "demand_assignment_id", "")),
            )
            String(get(row, "paired_base_id", "")) == expected_pairing_id || fail(
                "structural_instances",
                "$(row["structural_instance_id"]) registra un PairedBaseID no derivado",
            )
            expected_instance_id = structural_instance_id(
                declared_structural_design,
                base_file,
                parsed_regime,
                draw,
                parsed_uncertainty,
                parsed_battery,
                expected_pairing_id,
            )
            String(get(row, "structural_instance_id", "")) == expected_instance_id || fail(
                "structural_instances",
                "$(row["structural_instance_id"]) no coincide con $expected_instance_id",
            )
        end
    end
    sort(unique(String(get(row, "base_instance_file", "")) for row in instances_payload)) ==
        declared_base_files || fail(
            "structural_instances",
            "las filas no cubren exactamente base_instance_files del diseño",
        )

    # --- identifier uniqueness ----------------------------------------------------------
    instance_ids = [String(row["structural_instance_id"]) for row in instances_payload]
    if length(unique(instance_ids)) != length(instance_ids)
        duplicates = unique([id for id in instance_ids if count(==(id), instance_ids) > 1])
        fail("structural_instances",
             "StructuralInstanceID duplicado(s): " * join(sort(duplicates), ", "))
    end
    ordinals = [_as_int(row["manifest_ordinal"]) for row in instances_payload]
    ordinals == collect(1:length(instances_payload)) || fail(
        "structural_instances", "los ordinales no son 1:$(length(instances_payload)) en orden",
    )

    # --- canonical ordering -------------------------------------------------------------
    _as_strings(get(design, "canonical_ordering", String[])) ==
        OOS_STRUCTURAL_CANONICAL_ORDERING || fail(
        "design", "canonical_ordering distinto del orden canónico declarado por el módulo",
    )

    # --- deterministic repository-data blocks -----------------------------------------
    deterministic_index = Dict{String,Any}()
    deterministic_cells = Set{Tuple{String,Int}}()
    for block in deterministic_payload
        identifier = String(get(block, "deterministic_data_id", ""))
        isempty(identifier) && begin
            fail("deterministic_data_blocks", "bloque sin DeterministicDataID")
            continue
        end
        haskey(deterministic_index, identifier) && fail(
            "deterministic_data_blocks", "DeterministicDataID duplicado: $identifier",
        )
        deterministic_index[identifier] = block

        normalized_file = String(get(block, "normalized_base_instance_file", ""))
        draw = _as_int(get(block, "structural_draw", 0))
        normalized_file in declared_base_files || fail(
            "deterministic_data_blocks",
            "$identifier usa una instancia base que no pertenece al diseño: $normalized_file",
        )
        String(get(block, "base_instance_id", "")) == base_instance_id(normalized_file) || fail(
            "deterministic_data_blocks",
            "$identifier registra un base_instance_id incompatible con $normalized_file",
        )
        1 <= draw <= draws || fail(
            "deterministic_data_blocks", "$identifier tiene structural_draw fuera de 1:$draws",
        )
        for (field, expected_value) in design_int_fields
            _as_int(get(block, field, typemin(Int))) == expected_value || fail(
                "deterministic_data_blocks", "$identifier difiere del diseño en `$field`",
            )
        end
        for (field, expected_value) in design_float_fields
            _as_float(get(block, field, NaN)) == expected_value || fail(
                "deterministic_data_blocks", "$identifier difiere del diseño en `$field`",
            )
        end
        for (field, expected_value) in design_string_fields
            String(get(block, field, "")) == expected_value || fail(
                "deterministic_data_blocks", "$identifier difiere del diseño en `$field`",
            )
        end
        cell = (normalized_file, draw)
        cell in deterministic_cells && fail(
            "deterministic_data_blocks", "más de un bloque para la celda $cell",
        )
        push!(deterministic_cells, cell)
        key = OOSDeterministicBaseKey(
            _as_int(get(design, "experiment_seed", 0)),
            normalized_file,
            draw,
            _as_int(get(block, "in_sample_stages", 0)),
            _as_int(get(block, "in_sample_children", 0)),
            _as_int(get(block, "in_sample_periods_per_stage", 0)),
            _as_int(get(block, "households", 0)),
            _as_float(get(block, "avg_demand", 0.0)),
            _as_float(get(block, "dev_demand", 0.0)),
            _as_float(get(block, "pv_scale", 0.0)),
            String(get(block, "repository_demand_profile", "")),
        )
        deterministic_data_id(key) == identifier || fail(
            "deterministic_data_blocks", "$identifier no coincide con su clave canónica",
        )
        actual_seed = _as_int(get(block, "actual_repository_generator_seed", 0))
        actual_repository_generator_seed(key) == actual_seed || fail(
            "deterministic_data_blocks",
            "$identifier registra una semilla real distinta de la derivada de su clave",
        )
        _as_strings(get(block, "included_seed_keys", String[])) ==
            OOS_DETERMINISTIC_BASE_INCLUDED_KEYS || fail(
                "deterministic_data_blocks", "$identifier altera las claves incluidas",
            )
        _as_strings(get(block, "excluded_seed_keys", String[])) ==
            OOS_DETERMINISTIC_BASE_EXCLUDED_KEYS || fail(
                "deterministic_data_blocks", "$identifier altera las claves excluidas",
            )
        for forbidden in ("battery_level", "battery_scale", "demand_regime",
                          "demand_assignment_id", "uncertainty_level", "theta", "controller",
                          "fairness_policy", "solver_phase", "worker", "retry",
                          "execution_order")
            forbidden in _as_strings(get(block, "included_seed_keys", String[])) && fail(
                "deterministic_data_blocks", "$identifier incluye la clave prohibida $forbidden",
            )
        end
        for field in ("repository_instance_horizon", "required_period_support_end",
                      "materialized_data_end")
            _as_int(get(block, field, -1)) == _as_int(get(design, field, -2)) || fail(
                "deterministic_data_blocks", "$identifier difiere del diseño en `$field`",
            )
        end
        for (field, expected_value) in (
            ("period_mapping_name", OOS_PERIOD_MAPPING_NAME),
            ("period_mapping_version", OOS_PERIOD_MAPPING_VERSION),
            ("period_mapping_formula", OOS_PERIOD_MAPPING_FORMULA),
        )
            String(get(block, field, "")) == expected_value || fail(
                "deterministic_data_blocks", "$identifier difiere en `$field`",
            )
        end
        for field in ("base_price_digest", "extended_price_digest",
                      "base_pv_reference_digest", "extended_pv_reference_digest",
                      "demand_activity_digest")
            value = String(get(block, field, ""))
            length(value) == 16 || fail(
                "deterministic_data_blocks", "$identifier tiene `$field` inválido: $value",
            )
        end
        activity_entries = get(block, "demand_activity_digests", Any[])
        length(activity_entries) == 2 || fail(
            "deterministic_data_blocks",
            "$identifier debe registrar una actividad por cada régimen de demanda",
        )
        activity_assignment_ids = [
            String(get(entry, "demand_assignment_id", "")) for entry in activity_entries
        ]
        length(unique(activity_assignment_ids)) == length(activity_assignment_ids) || fail(
            "deterministic_data_blocks",
            "$identifier repite una asignación en demand_activity_digests",
        )
        activity_assignment_ids == sort(activity_assignment_ids) || fail(
            "deterministic_data_blocks",
            "$identifier no ordena demand_activity_digests por DemandAssignmentID",
        )
        activity_regimes = [String(get(entry, "demand_regime", ""))
                            for entry in activity_entries]
        sort(activity_regimes) == sort(string.(collect(OOS_DEMAND_REGIME_ORDER))) || fail(
            "deterministic_data_blocks",
            "$identifier no registra exactamente ambos regímenes de demanda",
        )
        for entry in activity_entries, field in (
            "base_demand_activity_digest", "demand_activity_digest",
        )
            length(String(get(entry, field, ""))) == 16 || fail(
                "deterministic_data_blocks",
                "$identifier tiene `$field` inválido en una actividad",
            )
        end
        oos_stable_digest(canonical_json(activity_entries)) ==
            String(get(block, "demand_activity_digest", "")) || fail(
                "deterministic_data_blocks",
                "$identifier tiene un demand_activity_digest agregado incorrecto",
            )
    end

    deterministic_usage = Dict{String,Vector{Any}}()
    for row in instances_payload
        identifier = String(get(row, "deterministic_data_id", ""))
        push!(get!(deterministic_usage, identifier, Any[]), row)
        if !haskey(deterministic_index, identifier)
            fail(
                "structural_instances",
                "$(row["structural_instance_id"]) referencia un bloque determinista inexistente",
            )
            continue
        end
        block = deterministic_index[identifier]
        for field in ("actual_repository_generator_seed", "repository_instance_horizon",
                      "required_period_support_end", "materialized_data_end",
                      "period_mapping_name", "period_mapping_version", "period_mapping_formula",
                      "base_price_digest", "extended_price_digest",
                      "base_pv_reference_digest", "extended_pv_reference_digest")
            row[field] == block[field] || fail(
                "structural_instances",
                "$(row["structural_instance_id"]) difiere de $identifier en `$field`",
            )
        end
        String(row["base_instance_file"]) ==
            String(block["normalized_base_instance_file"]) || fail(
                "structural_instances",
                "$(row["structural_instance_id"]) no comparte la instancia base de $identifier",
            )
        _as_int(row["structural_draw"]) == _as_int(block["structural_draw"]) || fail(
            "structural_instances",
            "$(row["structural_instance_id"]) no comparte el sorteo de $identifier",
        )
    end
    for (identifier, rows) in deterministic_usage
        length(rows) == 8 || fail(
            "deterministic_data_blocks",
            "$identifier se usa en $(length(rows)) instancias y debe compartirse entre " *
            "2 baterías x 2 regímenes x 2 incertidumbres = 8",
        )
        length(unique([String(row["battery_level"]) for row in rows])) == 2 || fail(
            "deterministic_data_blocks", "$identifier no cubre ambos niveles de batería",
        )
        length(unique([String(row["demand_regime"]) for row in rows])) == 2 || fail(
            "deterministic_data_blocks", "$identifier no cubre ambos regímenes de demanda",
        )
        length(unique([String(row["uncertainty_level"]) for row in rows])) == 2 || fail(
            "deterministic_data_blocks", "$identifier no cubre ambos niveles de incertidumbre",
        )
    end
    sort(unique(
        String(get(block, "normalized_base_instance_file", ""))
        for block in deterministic_payload
    )) == declared_base_files || fail(
        "deterministic_data_blocks",
        "los bloques no cubren exactamente base_instance_files del diseño",
    )

    # --- battery pairing ----------------------------------------------------------------
    pairs = Dict{String,Vector{Any}}()
    for row in instances_payload
        push!(get!(pairs, String(row["paired_base_id"]), Any[]), row)
    end
    counts["paired_bases"] = length(pairs)
    length(pairs) == expected_pairs || fail(
        "structural_instances",
        "hay $(length(pairs)) PairedBaseID y se esperaban $expected_pairs",
    )

    shared_fields = ("base_instance_id", "base_instance_file", "structural_draw", "demand_regime",
                     "uncertainty_level", "theta", "demand_assignment_id", "household_profiles",
                     "assignment_seed", "deterministic_data_id",
                     "legacy_default_repository_instance_seed",
                     "actual_repository_generator_seed", "repository_instance_id",
                     "repository_instance_horizon", "required_period_support_end",
                     "materialized_data_end", "period_mapping_name", "period_mapping_version",
                     "period_mapping_formula", "base_price_digest", "extended_price_digest",
                     "base_pv_reference_digest", "extended_pv_reference_digest",
                     "base_demand_activity_digest", "demand_activity_digest",
                     "instance_period_length_delta",
                     "households", "avg_demand", "dev_demand", "pv_scale",
                     "in_sample_stages", "in_sample_children", "in_sample_periods_per_stage",
                     "repository_demand_profile", "resolved_s_min", "resolved_s_I",
                     "resolved_e_c", "resolved_e_d", "resolved_mu", "resolved_beta")
    for (pairing, rows) in pairs
        if length(rows) != 2
            fail("structural_instances",
                 "$pairing aparece $(length(rows)) vez/veces y debe aparecer exactamente 2")
            continue
        end
        levels = sort([String(row["battery_level"]) for row in rows])
        levels == sort([string(level) for level in OOS_BATTERY_LEVEL_ORDER]) || fail(
            "structural_instances",
            "$pairing no cubre exactamente LOW_BATTERY y HIGH_BATTERY; tiene " * join(levels, ", "),
        )
        low_index = findfirst(row -> String(row["battery_level"]) == "LOW_BATTERY", rows)
        high_index = findfirst(row -> String(row["battery_level"]) == "HIGH_BATTERY", rows)
        if low_index === nothing || high_index === nothing
            continue      # the level-coverage check above already recorded the failure
        end
        low = rows[low_index]
        high = rows[high_index]
        for field in shared_fields
            low[field] == high[field] || fail(
                "structural_instances",
                "$pairing difiere en `$field` entre niveles de batería: " *
                "$(low[field]) frente a $(high[field])",
            )
        end
        _as_float(low["battery_scale"]) < _as_float(high["battery_scale"]) || fail(
            "structural_instances",
            "$pairing no satisface battery_scale(LOW) < battery_scale(HIGH)",
        )
        String(low["structural_instance_id"]) != String(high["structural_instance_id"]) || fail(
            "structural_instances", "$pairing repite el StructuralInstanceID en ambos niveles",
        )
        low_physical = [low[field] for field in
                        ("resolved_s_min", "resolved_s_max", "resolved_s_I",
                         "resolved_f_under", "resolved_f_bar")]
        high_physical = [high[field] for field in
                         ("resolved_s_min", "resolved_s_max", "resolved_s_I",
                          "resolved_f_under", "resolved_f_bar")]
        low_physical != high_physical || fail(
            "structural_instances",
            "$pairing no conserva parámetros físicos distintos entre los niveles de batería",
        )
    end

    # --- demand assignments -------------------------------------------------------------
    assignment_index = Dict{String,Any}()
    for row in assignments_payload
        identifier = String(row["demand_assignment_id"])
        haskey(assignment_index, identifier) && fail(
            "demand_assignments", "DemandAssignmentID duplicado: $identifier",
        )
        assignment_index[identifier] = row
        deterministic_identifier = String(get(row, "deterministic_data_id", ""))
        haskey(deterministic_index, deterministic_identifier) || fail(
            "demand_assignments",
            "$identifier referencia un bloque determinista inexistente: $deterministic_identifier",
        )
        for field in ("repository_instance_horizon", "required_period_support_end",
                      "materialized_data_end")
            _as_int(get(row, field, -1)) == _as_int(get(design, field, -2)) || fail(
                "demand_assignments", "$identifier difiere del diseño en `$field`",
            )
        end
        for field in ("base_demand_activity_digest", "demand_activity_digest")
            length(String(get(row, field, ""))) == 16 || fail(
                "demand_assignments", "$identifier tiene `$field` inválido",
            )
        end
        regime = String(row["demand_regime"])
        profiles = _as_strings(row["household_profiles"])
        base_file = String(get(row, "base_instance_file", ""))
        base_id = String(get(row, "base_instance_id", ""))
        draw = _as_int(get(row, "structural_draw", 0))
        base_file in declared_base_files || fail(
            "demand_assignments", "$identifier usa una instancia base ajena al diseño",
        )
        base_id == base_instance_id(base_file) || fail(
            "demand_assignments", "$identifier registra un base_instance_id incompatible",
        )
        1 <= draw <= draws || fail(
            "demand_assignments", "$identifier tiene structural_draw fuera de 1:$draws",
        )
        length(profiles) == design_int_fields["households"] || fail(
            "demand_assignments", "$identifier no registra un perfil por hogar",
        )
        if regime in demand_labels
            parsed_regime = parse_demand_regime(regime)
            expected_seed = structural_assignment_seed(
                _as_int(get(design, "experiment_seed", 0)), base_id, parsed_regime, draw,
            )
            _as_int(get(row, "assignment_seed", 0)) == expected_seed || fail(
                "demand_assignments", "$identifier registra una assignment_seed no derivada",
            )
            if declared_structural_design !== nothing
                demand_assignment_id(
                    declared_structural_design, base_file, parsed_regime, draw, profiles,
                ) == identifier || fail(
                    "demand_assignments", "$identifier no coincide con su identidad canónica",
                )
            end
        end
        if haskey(deterministic_index, deterministic_identifier)
            block = deterministic_index[deterministic_identifier]
            String(get(block, "normalized_base_instance_file", "")) == base_file || fail(
                "demand_assignments",
                "$identifier no comparte la instancia base de $deterministic_identifier",
            )
            _as_int(get(block, "structural_draw", 0)) == draw || fail(
                "demand_assignments",
                "$identifier no comparte el sorteo de $deterministic_identifier",
            )
        end
        for profile in profiles
            profile in OOS_STRUCTURAL_DEMAND_PROFILES || fail(
                "demand_assignments", "perfil no aprobado `$profile` en $identifier",
            )
        end
        _as_strings(get(row, "profile_count_labels", String[])) ==
            collect(OOS_STRUCTURAL_DEMAND_PROFILES) || fail(
            "demand_assignments",
            "profile_count_labels de $identifier no está en el orden canónico de perfiles",
        )
        recorded_counts = [_as_int(value) for value in get(row, "profile_counts", Any[])]
        expected_counts = [count(==(String(profile)), profiles)
                           for profile in OOS_STRUCTURAL_DEMAND_PROFILES]
        recorded_counts == expected_counts || fail(
            "demand_assignments",
            "profile_counts inconsistente en $identifier: $recorded_counts frente a " *
            "$expected_counts",
        )
        tally = [count(==(String(profile)), profiles)
                 for profile in OOS_STRUCTURAL_DEMAND_PROFILES]
        if regime == "HOMOGENEOUS"
            length(unique(profiles)) == 1 || fail(
                "demand_assignments",
                "$identifier es HOMOGENEOUS y usa varios perfiles: " *
                join(sort(unique(profiles)), ", "),
            )
        elseif regime == "HETEROGENEOUS"
            maximum(tally) - minimum(tally) <= 1 || fail(
                "demand_assignments",
                "$identifier es HETEROGENEOUS y sus conteos difieren en más de uno: $tally",
            )
        else
            fail("demand_assignments", "régimen de demanda inválido en $identifier: $regime")
        end
    end
    sort(unique(
        String(get(row, "base_instance_file", "")) for row in assignments_payload
    )) == declared_base_files || fail(
        "demand_assignments",
        "las asignaciones no cubren exactamente base_instance_files del diseño",
    )

    # Each assignment is shared by 2 battery x 2 uncertainty levels, and every instance row
    # reproduces its assignment's profile vector verbatim.
    usage = Dict{String,Vector{Any}}()
    for row in instances_payload
        identifier = String(row["demand_assignment_id"])
        push!(get!(usage, identifier, Any[]), row)
        if haskey(assignment_index, identifier)
            _as_strings(row["household_profiles"]) ==
                _as_strings(assignment_index[identifier]["household_profiles"]) || fail(
                "structural_instances",
                "$(row["structural_instance_id"]) no reproduce los perfiles de $identifier",
            )
            _as_int(row["assignment_seed"]) ==
                _as_int(assignment_index[identifier]["assignment_seed"]) || fail(
                "structural_instances",
                "$(row["structural_instance_id"]) registra otra assignment_seed que $identifier",
            )
            String(row["deterministic_data_id"]) ==
                String(assignment_index[identifier]["deterministic_data_id"]) || fail(
                    "structural_instances",
                    "$(row["structural_instance_id"]) registra otro DeterministicDataID que " *
                    identifier,
                )
            for field in ("base_demand_activity_digest", "demand_activity_digest")
                String(row[field]) == String(assignment_index[identifier][field]) || fail(
                    "structural_instances",
                    "$(row["structural_instance_id"]) difiere de $identifier en `$field`",
                )
            end
        else
            fail("structural_instances",
                 "$(row["structural_instance_id"]) referencia una asignación inexistente: " *
                 identifier)
        end
    end
    for (identifier, rows) in usage
        length(rows) == 4 || fail(
            "demand_assignments",
            "$identifier se usa en $(length(rows)) instancias y debe cubrir " *
            "2 niveles de batería x 2 de incertidumbre = 4",
        )
        length(unique([String(row["battery_level"]) for row in rows])) == 2 || fail(
            "demand_assignments", "$identifier no cubre ambos niveles de batería",
        )
        length(unique([String(row["uncertainty_level"]) for row in rows])) == 2 || fail(
            "demand_assignments", "$identifier no cubre ambos niveles de incertidumbre",
        )
    end
    for block in deterministic_payload
        block_id = String(block["deterministic_data_id"])
        expected_activity_ids = sort([
            identifier for (identifier, assignment) in assignment_index
            if String(assignment["deterministic_data_id"]) == block_id
        ])
        observed_activity_ids = [
            String(activity["demand_assignment_id"])
            for activity in block["demand_activity_digests"]
        ]
        observed_activity_ids == expected_activity_ids || fail(
            "deterministic_data_blocks",
            "$block_id no cubre exactamente sus DemandAssignmentID: " *
            "$(observed_activity_ids) frente a $(expected_activity_ids)",
        )
        for activity in block["demand_activity_digests"]
            assignment_id = String(activity["demand_assignment_id"])
            if !haskey(assignment_index, assignment_id)
                fail(
                    "deterministic_data_blocks",
                    "$block_id registra una actividad para una asignación inexistente: " *
                    assignment_id,
                )
                continue
            end
            assignment = assignment_index[assignment_id]
            String(assignment["deterministic_data_id"]) == block_id || fail(
                "deterministic_data_blocks",
                "$assignment_id no pertenece realmente a $block_id",
            )
            for field in ("base_demand_activity_digest", "demand_activity_digest")
                String(activity[field]) == String(assignment[field]) || fail(
                    "deterministic_data_blocks",
                    "$block_id difiere de $assignment_id en `$field`",
                )
            end
        end
    end

    # Assignment seeds must exclude battery and uncertainty: one seed per (base, regime, draw).
    seed_by_cell = Dict{Tuple{String,String,Int},Set{Int}}()
    for row in instances_payload
        cell = (String(row["base_instance_id"]), String(row["demand_regime"]),
                _as_int(row["structural_draw"]))
        push!(get!(seed_by_cell, cell, Set{Int}()), _as_int(row["assignment_seed"]))
    end
    for (cell, seeds) in seed_by_cell
        length(seeds) == 1 || fail(
            "demand_assignments",
            "la celda $cell tiene $(length(seeds)) assignment_seed distintas: la semilla de " *
            "asignación debe excluir el nivel de batería y de incertidumbre",
        )
    end

    # Distinct structural draws must stay distinguishable even if two assignments coincide.
    draw_seeds = Dict{Tuple{String,String},Set{Int}}()
    for row in assignments_payload
        key = (String(row["base_instance_id"]), String(row["demand_regime"]))
        push!(get!(draw_seeds, key, Set{Int}()), _as_int(row["assignment_seed"]))
    end
    for (key, seeds) in draw_seeds
        length(seeds) == draws || fail(
            "demand_assignments",
            "la celda $key tiene $(length(seeds)) semillas para $draws sorteos estructurales: " *
            "los sorteos deben tener claves distintas aunque sus perfiles coincidan",
        )
    end
    assignment_ids_by_cell = Dict{Tuple{String,String},Vector{Int}}()
    for row in assignments_payload
        key = (String(row["base_instance_id"]), String(row["demand_regime"]))
        push!(get!(assignment_ids_by_cell, key, Int[]), _as_int(row["structural_draw"]))
    end
    for (key, list) in assignment_ids_by_cell
        sort(list) == collect(1:draws) || fail(
            "demand_assignments", "la celda $key no cubre los sorteos 1:$draws; tiene $list",
        )
    end

    # --- seed contract ------------------------------------------------------------------
    contract_by_stream = Dict{String,Any}()
    recorded_contract = document["seed_contract"]
    expected_streams = [String(entry["stream"]) for entry in OOS_SEED_CONTRACT]
    recorded_streams = [String(get(entry, "stream", "")) for entry in recorded_contract]
    length(recorded_contract) == length(OOS_SEED_CONTRACT) || fail(
        "seed_contract",
        "el contrato registra $(length(recorded_contract)) flujos y se esperaban " *
        "$(length(OOS_SEED_CONTRACT))",
    )
    length(unique(recorded_streams)) == length(recorded_streams) || fail(
        "seed_contract", "el contrato contiene uno o más nombres de flujo duplicados",
    )
    Set(recorded_streams) == Set(expected_streams) || fail(
        "seed_contract", "el conjunto de flujos no coincide exactamente con el contrato del módulo",
    )
    for entry in recorded_contract
        stream = String(get(entry, "stream", ""))
        haskey(contract_by_stream, stream) || (contract_by_stream[stream] = entry)
    end
    for expected_entry in OOS_SEED_CONTRACT
        stream = String(expected_entry["stream"])
        if !haskey(contract_by_stream, stream)
            fail("seed_contract", "falta el flujo `$stream`")
            continue
        end
        recorded = contract_by_stream[stream]
        for field in ("included_keys", "excluded_keys", "enforced_exclusions", "seed_algorithm",
                      "status")
            recorded_value = field == "seed_algorithm" || field == "status" ?
                String(get(recorded, field, "")) : _as_strings(get(recorded, field, String[]))
            expected_value = field == "seed_algorithm" || field == "status" ?
                String(expected_entry[field]) : _as_strings(expected_entry[field])
            recorded_value == expected_value || fail(
                "seed_contract", "`$stream` registra un `$field` distinto del contrato del módulo",
            )
        end
        included = _as_strings(get(recorded, "included_keys", String[]))
        for forbidden in _as_strings(get(recorded, "enforced_exclusions", String[]))
            forbidden in included && fail(
                "seed_contract",
                "`$stream` declara excluir `$forbidden` pero lo lista como clave incluida",
            )
        end
    end
    for stream in (OOS_STRUCTURAL_ASSIGNMENT_STREAM, OOS_STRUCTURAL_PATH_STREAM,
                   OOS_CONDITIONAL_SUPPORT_STREAM, OOS_DETERMINISTIC_BASE_STREAM)
        haskey(contract_by_stream, stream) || continue
        included = _as_strings(contract_by_stream[stream]["included_keys"])
        for forbidden in OOS_FORBIDDEN_SEED_KEYS
            forbidden in included && fail(
                "seed_contract", "el flujo de la etapa 2 `$stream` incluye `$forbidden`",
            )
        end
        "battery_level" in included && fail(
            "seed_contract", "el flujo estructural `$stream` incluye `battery_level`",
        )
    end

    # Reconstruct one scientific seed key per PairedBaseID from its structural rows. The battery
    # pair has already been checked for exact agreement on all key fields, so choosing its first
    # row is deterministic and does not introduce battery into either seed.
    seed_key_by_pair = Dict{String,OOSPathSeedKey}()
    scientific_row_by_pair = Dict{String,Any}()
    for (pairing, rows) in pairs
        isempty(rows) && continue
        reference = first(rows)
        try
            seed_key_by_pair[pairing] = OOSPathSeedKey(
                _as_int(get(design, "experiment_seed", 0)),
                String(reference["base_instance_id"]),
                String(reference["demand_assignment_id"]),
                parse_demand_regime(String(reference["demand_regime"])),
                _as_int(reference["structural_draw"]),
                parse_uncertainty_level(String(reference["uncertainty_level"])),
            )
            scientific_row_by_pair[pairing] = reference
        catch exception
            fail(
                "planned_oos_replication_keys",
                "$pairing no reconstruye una clave científica válida: " *
                sprint(showerror, exception),
            )
        end
    end

    # --- planned OOS-path keys ----------------------------------------------------------
    expected_path_keys = Set(
        (pairing, replication)
        for pairing in keys(pairs), replication in 1:replications
    )
    length(path_keys) == length(expected_path_keys) || fail(
        "planned_oos_replication_keys",
        "hay $(length(path_keys)) entradas y PairedBaseID x réplicas = " *
        "$(length(expected_path_keys))",
    )
    path_seed_by_pair = Dict{Tuple{String,Int},Int}()
    for row in path_keys
        pairing = String(get(row, "paired_base_id", ""))
        replication = _as_int(get(row, "oos_replication", 0))
        key = (pairing, replication)
        haskey(path_seed_by_pair, key) && fail(
            "planned_oos_replication_keys", "entrada duplicada para $key",
        )
        if !haskey(path_seed_by_pair, key)
            path_seed_by_pair[key] = _as_int(get(row, "oos_path_seed", 0))
        end
        key in expected_path_keys || fail(
            "planned_oos_replication_keys", "$key no pertenece a PairedBaseID x réplicas",
        )
        haskey(row, "battery_level") && fail(
            "planned_oos_replication_keys",
            "$key registra un battery_level: la clave de trayectoria debe excluirlo y no debe " *
            "duplicarse por nivel de batería",
        )
        if haskey(seed_key_by_pair, pairing) && key in expected_path_keys
            reference = scientific_row_by_pair[pairing]
            for field in ("demand_assignment_id", "base_instance_id", "demand_regime",
                          "structural_draw", "uncertainty_level")
                row[field] == reference[field] || fail(
                    "planned_oos_replication_keys",
                    "$key no enlaza `$field` con su fila estructural",
                )
            end
            expected_seed = structural_oos_path_seed(
                seed_key_by_pair[pairing], replication,
            )
            _as_int(get(row, "oos_path_seed", 0)) == expected_seed || fail(
                "planned_oos_replication_keys",
                "$key registra una semilla $(_as_int(get(row, "oos_path_seed", 0))) " *
                "distinta de la derivada $expected_seed",
            )
        end
    end
    Set(keys(path_seed_by_pair)) == expected_path_keys || fail(
        "planned_oos_replication_keys",
        "las entradas no cubren exactamente todos los PairedBaseID x réplicas",
    )
    # A path seed must depend on the replication, and differ across uncertainty levels.
    for pairing in keys(pairs)
        seeds = [path_seed_by_pair[(pairing, r)]
                 for r in 1:replications if haskey(path_seed_by_pair, (pairing, r))]
        length(unique(seeds)) == length(seeds) || fail(
            "planned_oos_replication_keys",
            "$pairing repite la semilla de trayectoria entre réplicas",
        )
    end

    # --- planned conditional-support keys -----------------------------------------------
    expected_support_keys = Set(
        (pairing, replication, start)
        for pairing in keys(pairs), replication in 1:replications,
            start in expected_starts
    )
    length(support_keys) == length(expected_support_keys) || fail(
        "planned_conditional_support_keys",
        "hay $(length(support_keys)) entradas y PairedBaseID x réplicas x inicios = " *
        "$(length(expected_support_keys))",
    )
    support_by_pair_replication = Dict{Tuple{String,Int},Dict{Int,Int}}()
    observed_support_keys = Set{Tuple{String,Int,Int}}()
    for row in support_keys
        pairing = String(get(row, "paired_base_id", ""))
        replication = _as_int(get(row, "oos_replication", 0))
        start = _as_int(get(row, "rolling_start", 0))
        scientific_key = (pairing, replication, start)
        scientific_key in expected_support_keys || fail(
            "planned_conditional_support_keys",
            "$scientific_key no pertenece a PairedBaseID x réplicas x inicios válidos",
        )
        scientific_key in observed_support_keys && fail(
            "planned_conditional_support_keys", "entrada duplicada para $scientific_key",
        )
        push!(observed_support_keys, scientific_key)
        bucket = get!(support_by_pair_replication, (pairing, replication), Dict{Int,Int}())
        haskey(bucket, start) ||
            (bucket[start] = _as_int(get(row, "conditional_support_seed", 0)))
        haskey(row, "battery_level") && fail(
            "planned_conditional_support_keys",
            "$scientific_key registra un battery_level: debe excluirlo",
        )
        if haskey(seed_key_by_pair, pairing) && scientific_key in expected_support_keys
            expected_seed = conditional_support_seed(
                seed_key_by_pair[pairing], replication, start,
            )
            _as_int(get(row, "conditional_support_seed", 0)) == expected_seed || fail(
                "planned_conditional_support_keys",
                "$scientific_key registra una semilla distinta de la derivada $expected_seed",
            )
        end
    end
    observed_support_keys == expected_support_keys || fail(
        "planned_conditional_support_keys",
        "las entradas no cubren exactamente todos los PairedBaseID x réplicas x inicios",
    )
    for (key, bucket) in support_by_pair_replication
        Set(keys(bucket)) == Set(expected_starts) || fail(
            "planned_conditional_support_keys", "$key no cubre exactamente los inicios válidos",
        )
        seeds = collect(values(bucket))
        length(unique(seeds)) == length(seeds) || fail(
            "planned_conditional_support_keys",
            "$key repite la semilla de soporte entre inicios de iteración distintos",
        )
    end

    # --- Stage-3 factor isolation ------------------------------------------------------
    uncertainty_pairs = Dict{Tuple{String,Int,String,String},Vector{Any}}()
    for row in instances_payload
        key = (
            String(row["base_instance_file"]),
            _as_int(row["structural_draw"]),
            String(row["demand_regime"]),
            String(row["battery_level"]),
        )
        push!(get!(uncertainty_pairs, key, Any[]), row)
    end
    uncertainty_shared_fields = (
        "base_instance_id", "base_instance_file", "structural_draw", "battery_level",
        "battery_scale", "demand_regime", "deterministic_data_id",
        "demand_assignment_id", "household_profiles",
        "assignment_seed", "actual_repository_generator_seed", "repository_instance_id",
        "repository_instance_horizon", "required_period_support_end", "materialized_data_end",
        "period_mapping_name", "period_mapping_version", "period_mapping_formula",
        "base_price_digest", "extended_price_digest", "base_pv_reference_digest",
        "extended_pv_reference_digest", "base_demand_activity_digest",
        "demand_activity_digest", "instance_period_length_delta", "resolved_s_min",
        "resolved_s_max", "resolved_s_I", "resolved_f_under", "resolved_f_bar",
        "resolved_e_c", "resolved_e_d", "resolved_mu", "resolved_beta", "households",
        "avg_demand", "dev_demand", "pv_scale", "in_sample_stages",
        "in_sample_children", "in_sample_periods_per_stage", "repository_demand_profile",
    )
    for (key, rows) in uncertainty_pairs
        length(rows) == 2 || begin
            fail("structural_instances", "la celda $key no contiene dos incertidumbres")
            continue
        end
        low_index = findfirst(row -> String(row["uncertainty_level"]) == "LOW_UNCERTAINTY", rows)
        high_index = findfirst(row -> String(row["uncertainty_level"]) == "HIGH_UNCERTAINTY", rows)
        if low_index === nothing || high_index === nothing
            fail("structural_instances", "la celda $key no cubre LOW/HIGH_UNCERTAINTY")
            continue
        end
        low = rows[low_index]
        high = rows[high_index]
        for field in uncertainty_shared_fields
            low[field] == high[field] || fail(
                "structural_instances",
                "la celda $key confunde incertidumbre con `$field`: $(low[field]) frente a " *
                "$(high[field])",
            )
        end
        _as_float(low["theta"]) < _as_float(high["theta"]) || fail(
            "structural_instances", "la celda $key no conserva theta LOW < HIGH",
        )
        _as_int(low["legacy_default_repository_instance_seed"]) !=
            _as_int(high["legacy_default_repository_instance_seed"]) || fail(
                "structural_instances",
                "la celda $key no conserva evidencia de la semilla legacy dependiente de theta",
            )
        String(low["paired_base_id"]) != String(high["paired_base_id"]) || fail(
            "structural_instances", "la celda $key comparte por error el PairedBaseID",
        )
        for replication in 1:replications
            low_path_key = (String(low["paired_base_id"]), replication)
            high_path_key = (String(high["paired_base_id"]), replication)
            if haskey(path_seed_by_pair, low_path_key) && haskey(path_seed_by_pair, high_path_key)
                path_seed_by_pair[low_path_key] != path_seed_by_pair[high_path_key] || fail(
                    "planned_oos_replication_keys",
                    "la celda $key reutiliza trayectoria entre niveles de incertidumbre",
                )
            end
            for start in starts
                low_support = get(
                    get(support_by_pair_replication, low_path_key, Dict{Int,Int}()), start, 0,
                )
                high_support = get(
                    get(support_by_pair_replication, high_path_key, Dict{Int,Int}()), start, 0,
                )
                low_support != 0 && high_support != 0 && low_support == high_support && fail(
                    "planned_conditional_support_keys",
                    "la celda $key reutiliza soporte entre niveles de incertidumbre",
                )
            end
        end
    end

    # Demand regimes and battery levels may alter only their approved structural component;
    # deterministic prices and the deterministic PV reference stay on the shared data block.
    for factors in (
        ("demand_regime", ("base_instance_file", "structural_draw", "uncertainty_level",
                           "battery_level")),
        ("battery_level", ("base_instance_file", "structural_draw", "demand_regime",
                           "uncertainty_level")),
    )
        varying, fixed = factors
        groups = Dict{Tuple,Vector{Any}}()
        for row in instances_payload
            key = Tuple(row[field] for field in fixed)
            push!(get!(groups, key, Any[]), row)
        end
        for (key, rows) in groups
            length(rows) == 2 || continue
            for field in ("deterministic_data_id", "actual_repository_generator_seed",
                          "base_price_digest", "extended_price_digest",
                          "base_pv_reference_digest", "extended_pv_reference_digest")
                rows[1][field] == rows[2][field] || fail(
                    "structural_instances",
                    "cambiar $varying en $key alteró `$field`",
                )
            end
        end
    end

    # --- no clock-time, timestamp or machine-dependent field ----------------------------
    for key in _collect_keys(document)
        lowered = lowercase(key)
        for fragment in OOS_MANIFEST_FORBIDDEN_KEY_FRAGMENTS
            if occursin(fragment, lowered)
                fail("manifest",
                     "la clave `$key` sugiere un campo de reloj/calendario o dependiente de " *
                     "la máquina (`$fragment`), prohibido en el payload canónico")
            end
        end
    end

    # --- optional rematerialization -----------------------------------------------------
    if rematerialize
        if base_config === nothing
            fail("structural_instances",
                 "se pidió rematerializar sin una configuración base de referencia")
        else
            limit = rematerialize_limit <= 0 ? length(instances_payload) :
                    min(rematerialize_limit, length(instances_payload))
            checked = 0
            for row in instances_payload[1:limit]
                spec = _spec_from_payload(row)
                materialized = materialize_structural_instance(
                    base_config,
                    spec;
                    required_period_support_end=required_support_end,
                )
                resolved = materialized.resolved
                for (field, stored) in (
                    ("resolved_s_min", resolved.s_min), ("resolved_s_max", resolved.s_max),
                    ("resolved_s_I", resolved.s_I), ("resolved_f_under", resolved.f_under),
                    ("resolved_f_bar", resolved.f_bar), ("resolved_e_c", resolved.e_c),
                    ("resolved_e_d", resolved.e_d), ("resolved_mu", resolved.mu),
                    ("resolved_beta", resolved.beta),
                    ("instance_period_length_delta", resolved.delta),
                )
                    _as_float(row[field]) == stored || fail(
                        "structural_instances",
                        "$(row["structural_instance_id"]): `$field` registrado " *
                        "$(row[field]) frente a $stored al rematerializar",
                    )
                end
                _as_int(row["repository_instance_horizon"]) ==
                    resolved.repository_instance_horizon || fail(
                    "structural_instances",
                    "$(row["structural_instance_id"]): horizonte de instancia distinto al " *
                    "rematerializar",
                )
                [model.profile for model in materialized.template.demand_models] ==
                    _as_strings(row["household_profiles"]) || fail(
                    "structural_instances",
                    "$(row["structural_instance_id"]): los modelos de demanda rematerializados " *
                        "no coinciden con la asignación almacenada",
                    )
                materialized.actual_repository_generator_seed ==
                    _as_int(row["actual_repository_generator_seed"]) || fail(
                    "structural_instances",
                    "$(row["structural_instance_id"]): la semilla real del generador " *
                    "cambió al rematerializar",
                )
                summary = materialized.period_data_support_summary
                for field in (
                    "repository_instance_horizon",
                    "required_period_support_end",
                    "materialized_data_end",
                    "period_mapping_name",
                    "period_mapping_version",
                    "period_mapping_formula",
                )
                    summary[field] == row[field] || fail(
                        "structural_instances",
                        "$(row["structural_instance_id"]): `$field` rematerializado " *
                        "$(summary[field]) frente a $(row[field])",
                    )
                end
                regenerated_digests = summary["digests"]
                for field in (
                    "base_price_digest",
                    "extended_price_digest",
                    "base_pv_reference_digest",
                    "extended_pv_reference_digest",
                    "base_demand_activity_digest",
                    "demand_activity_digest",
                )
                    String(regenerated_digests[field]) == String(row[field]) || fail(
                        "structural_instances",
                        "$(row["structural_instance_id"]): `$field` no coincide con la " *
                        "rematerialización",
                    )
                end
                checked += 1
            end
            counts["rematerialized"] = checked
            checked < length(instances_payload) && warn(
                "structural_instances",
                "se rematerializaron $checked de $(length(instances_payload)) instancias " *
                "(límite explícito); el resto no se comprobó físicamente",
            )
        end
    end

    passed = !any(structural_issue_is_blocking, issues)
    return StructuralManifestReport(passed, issues, counts, manifest_id)
end

"""Rebuild a self-contained spec from one manifest row, so a saved manifest can be re-run."""
function _spec_from_payload(row::AbstractDict)
    return OOSStructuralInstanceSpec(
        String(row["structural_instance_id"]), String(row["paired_base_id"]),
        String(row["demand_assignment_id"]), String(row["deterministic_data_id"]),
        String(row["base_instance_id"]), String(row["base_instance_file"]),
        _as_int(row["structural_draw"]),
        parse_battery_level(String(row["battery_level"])), _as_float(row["battery_scale"]),
        parse_demand_regime(String(row["demand_regime"])),
        parse_uncertainty_level(String(row["uncertainty_level"])), _as_float(row["theta"]),
        _as_strings(row["household_profiles"]), _as_int(row["assignment_seed"]),
        _as_int(row["legacy_default_repository_instance_seed"]),
        _as_int(row["actual_repository_generator_seed"]), _as_int(row["households"]),
        _as_float(row["avg_demand"]), _as_float(row["dev_demand"]), _as_float(row["pv_scale"]),
        _as_int(row["in_sample_stages"]), _as_int(row["in_sample_children"]),
        _as_int(row["in_sample_periods_per_stage"]), String(row["repository_demand_profile"]),
    )
end

"""Read a saved manifest from disk and validate it. Never runs an OOS campaign."""
function validate_structural_manifest(
    path::AbstractString;
    base_config::Union{Nothing,OOSExperimentConfig}=nothing,
    rematerialize::Bool=false,
    rematerialize_limit::Int=0,
)
    isfile(path) || error("No existe el manifiesto estructural: $path")
    document = canonical_json_parse(read(String(path), String))
    document isa AbstractDict || error("El manifiesto no es un objeto JSON: $path")
    report = validate_structural_manifest_document(
        document; base_config=base_config, rematerialize=rematerialize,
        rematerialize_limit=rematerialize_limit,
    )
    # A saved manifest must also be byte-canonical: a hand-edited file that happens to parse must
    # not pass, because its bytes would not reproduce.
    rendered = structural_manifest_text(document)
    if rendered != read(String(path), String)
        push!(report.issues, StructuralManifestIssue(
            "manifest", :error,
            "el archivo no está en forma canónica byte a byte; se reescribiría distinto",
        ))
        return StructuralManifestReport(false, report.issues, report.counts, report.manifest_id)
    end
    return report
end
