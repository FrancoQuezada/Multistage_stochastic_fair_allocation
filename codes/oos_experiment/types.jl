# =====================================================================================
# Out-of-sample receding-horizon experiment: core types.
#
# Terminology (see docs/oos_experiment.md):
#   * shared-battery operating mode  : one binary per information state (node-level)
#   * aggregate charging / discharging: sum over households of z / y at one node
#   * household charging contribution : z[j,n]
#   * household discharge allocation  : y[j,n]
#   * allocation/fairness rule        : FairnessPolicy
#   * controller                      : ControllerKind
#   * out-of-sample trajectory        : one independently simulated realization
#
# There is deliberately no household-indexed battery mode anywhere in this module.
# =====================================================================================

"""Controller (information-structure) used to select the current-period action."""
@enum ControllerKind begin
    DETERMINISTIC_RH
    TWO_STAGE_RH
    MULTISTAGE_RH
end

"""Allocation / fairness rule imposed on the remaining-horizon model."""
@enum FairnessPolicy begin
    NONE
    STATIC_DEMAND_SHARE
    PEA
    SA
    LEXMMFPEA
    LEXMMFSA
end

const OOS_CONTROLLER_KINDS = Dict(string(k) => k for k in instances(ControllerKind))
const OOS_FAIRNESS_POLICIES = Dict(string(f) => f for f in instances(FairnessPolicy))

parse_controller_kind(label::AbstractString) = get(OOS_CONTROLLER_KINDS, uppercase(strip(label))) do
    error("Controlador no soportado: $label. Usa DETERMINISTIC_RH, TWO_STAGE_RH o MULTISTAGE_RH.")
end

parse_fairness_policy(label::AbstractString) = get(OOS_FAIRNESS_POLICIES, uppercase(strip(label))) do
    error(
        "Regla de asignación/equidad no soportada: $label. " *
        "Usa NONE, STATIC_DEMAND_SHARE, PEA, SA, LEXMMFPEA o LEXMMFSA."
    )
end

"""`true` when the policy needs the lexicographic max-min machinery."""
is_lexicographic_policy(policy::FairnessPolicy) = policy in (LEXMMFPEA, LEXMMFSA)

"""
Formulation variants for the shared-battery subsystem.

`:aggregate_only` is the corrected reference formulation. `:aggregate_plus_redundant_links`
adds the household-level linking rows `z[j,n] <= F_c v_n` and `y[j,n] <= F_d (1-v_n)`, which
are mathematically redundant under nonnegative flows. The two variants must never be mixed
inside one campaign: the `formulation_variant` value is written to every output row.
"""
const OOS_FORMULATION_VARIANTS = (:aggregate_only, :aggregate_plus_redundant_links)

"""Resource each allocation/fairness rule distributes. Written to the outputs verbatim."""
function policy_resource(policy::FairnessPolicy)
    policy === NONE && return "none"
    policy in (STATIC_DEMAND_SHARE, PEA, LEXMMFPEA) && return "pv"
    policy in (SA, LEXMMFSA) && return "savings"
    error("Recurso no definido para la regla $policy.")
end

"""
How the PEA equality is handled when the realized past makes it unreachable.

  * `:strict`            — the equality only. An unreachable target aborts the configuration.
  * `:adaptive_minimum`  — strict first; on a *proven* fairness infeasibility, the minimum
                           common absolute band is computed endogenously (Phase I) and the
                           operational objective is then re-optimized at that band (Phase II).
  * `:fixed_band`        — DEPRECATED. Honours `fairness_abs_tol` as a fixed economic band.
                           Retained only for backward compatibility; it changes the economic
                           meaning of PEA and is never used by the default campaign.
"""
const OOS_PEA_TOLERANCE_MODES = (:strict, :adaptive_minimum, :fixed_band)

"""
Threshold above which a computed PEA band counts as an *activation*.

Bands below this value are numerically indistinguishable from a strict solve and are reported
as non-activations, so the activation statistics cannot be inflated by solver noise.
"""
const OOS_PEA_ACTIVATION_THRESHOLD = 1e-9

"""
Default action-validation tolerances, in kWh.

Single source of truth: the struct keyword defaults, the environment parsing and the shell
runners all reference these, so a tolerance can never be silently different depending on how
the campaign was launched.

Both are calibrated an order of magnitude ABOVE the solver's pinned primal feasibility
tolerance (`OOS_SOLVER_FEASIBILITY_TOL` = 1e-6): CPLEX may violate any single row by that much,
so a validator at or below it would reject its own solver's output. 1e-5 kWh is 0.01 Wh against
household demands of order 100 kWh — a 1e-7 relative slack, physically meaningless and
numerically necessary.
"""
const OOS_DEFAULT_FLOW_TOL = 1e-5
const OOS_DEFAULT_FEASIBILITY_TOL = 1e-5
const OOS_DEFAULT_INTEGRALITY_TOL = 1e-6

# -------------------------------------------------------------------------------------
# Solver-status and failure-attribution vocabulary
# -------------------------------------------------------------------------------------

"""
Classification of one solve. Only `SOLVE_PROVEN_INFEASIBLE` may trigger PEA recovery.

A time limit, a numerical error or an unrecognized status is never read as a fairness
infeasibility: without an infeasibility proof there is nothing to recover from.
"""
@enum SolveOutcome begin
    SOLVE_OK
    SOLVE_PROVEN_INFEASIBLE
    SOLVE_PRESUMED_INFEASIBLE
    SOLVE_TIME_LIMIT
    SOLVE_NUMERICAL_ERROR
    SOLVE_UNKNOWN
end

"""Source of a failed solve, established by an explicit diagnostic, never assumed."""
@enum FailureSource begin
    FAILURE_NONE
    FAILURE_FAIRNESS_RULE
    FAILURE_PHYSICAL_MODEL
    FAILURE_UNDETERMINED
end

"""
Per-period record of the strict-first / adaptive-minimum PEA workflow.

`tolerance_used` is a horizon-total PV allocation band in **kWh**, the same unit as the PEA
allocation equation. It is an economically meaningful quantity.

`pea_tolerance_numeric_eps` is **also in kWh** — it is added to `epsilon_pea_star` in the
Phase-II cap, so it must carry the same unit. The distinction is one of *magnitude and
purpose*, not of dimension: `epsilon_pea` is an economically meaningful allocation band, while
`pea_tolerance_numeric_eps` is a small absolute numerical allowance (default `1e-6` kWh) whose
only job is to keep Phase II feasible at the Phase-I optimum under round-off.
"""
struct PEARecoveryRecord
    applicable::Bool
    strict_feasible::Bool
    tolerance_activated::Bool
    tolerance_used::Float64
    strict_status::String
    phase1_status::String
    phase2_status::String
    recovery_status::String
    failure_source::String
end

"""Record for a policy to which the PEA workflow does not apply."""
pea_not_applicable() = PEARecoveryRecord(
    false, true, false, 0.0, "not_applicable", "not_applicable", "not_applicable",
    "not_applicable", string(FAILURE_NONE),
)

"""Record for a PEA solve whose strict equality was feasible: no recovery was run."""
pea_strict_success(status::String) = PEARecoveryRecord(
    true, true, false, 0.0, status, "not_run", "not_run", "not_required", string(FAILURE_NONE),
)

# -------------------------------------------------------------------------------------
# Experiment configuration
# -------------------------------------------------------------------------------------

"""
Resolved configuration of one out-of-sample campaign.

The fields required by the experiment specification are declared verbatim. The trailing
fields are documented additive extensions used by the runner (instance selection, solver
threading, warm starts and the shared-battery formulation variant).
"""
struct OOSExperimentConfig
    experiment_seed::Int
    oos_replications::Int

    controller_set::Vector{ControllerKind}
    fairness_set::Vector{FairnessPolicy}

    two_stage_scenarios::Int
    multistage_branching::Vector{Int}
    multistage_periods_per_stage::Vector{Int}

    # DEPRECATED as a fixed economic band: honoured only when
    # `pea_tolerance_mode === :fixed_band`. See `OOS_PEA_TOLERANCE_MODES`.
    fairness_abs_tol::Float64
    sa_fairness_abs_tol::Float64
    lex_eps_abs::Float64

    pea_tolerance_mode::Symbol
    # Absolute numerical allowance in kWh, added to epsilon_pea_star in the Phase-II cap.
    # Same unit as epsilon_pea; it is NOT dimensionless.
    pea_tolerance_numeric_eps::Float64

    flow_tol::Float64
    feasibility_tol::Float64
    integrality_tol::Float64

    solver_time_limit_sec::Float64

    formulation_id::String
    allow_legacy_conversion::Bool
    export_representative_models::Bool

    output_directory::String

    # --- documented additive extensions -------------------------------------------------
    instance_file::String
    in_sample_stages::Int
    in_sample_children::Int
    in_sample_periods_per_stage::Int
    households::Int
    theta::Float64
    avg_demand::Float64
    dev_demand::Float64
    demand_profile::String
    battery_scale::Float64
    pv_scale::Float64
    formulation_variant::Symbol
    use_warm_starts::Bool
    solver_threads::Int
    require_shared_battery_validation::Bool
    experiment_id::String
    prompt_version::String
end

function OOSExperimentConfig(;
    experiment_seed::Int=12345,
    oos_replications::Int=20,
    controller_set::Vector{ControllerKind}=collect(instances(ControllerKind)),
    fairness_set::Vector{FairnessPolicy}=collect(instances(FairnessPolicy)),
    two_stage_scenarios::Int=20,
    multistage_branching::Vector{Int}=[2, 2],
    multistage_periods_per_stage::Vector{Int}=Int[],
    fairness_abs_tol::Float64=0.0,
    sa_fairness_abs_tol::Float64=1.0,
    lex_eps_abs::Float64=1.0,
    pea_tolerance_mode::Symbol=:adaptive_minimum,
    # A small absolute numerical allowance in kWh (same unit as epsilon_pea). It exists only so
    # the Phase-II cap cannot be made infeasible by round-off in the Phase-I optimum, and is
    # nine or more orders of magnitude below the bands actually observed, so it never relaxes
    # the rule economically.
    pea_tolerance_numeric_eps::Float64=1e-6,
    flow_tol::Float64=OOS_DEFAULT_FLOW_TOL,
    feasibility_tol::Float64=OOS_DEFAULT_FEASIBILITY_TOL,
    integrality_tol::Float64=OOS_DEFAULT_INTEGRALITY_TOL,
    solver_time_limit_sec::Float64=600.0,
    formulation_id::String="shared_battery_mode_node_level_v1",
    allow_legacy_conversion::Bool=false,
    export_representative_models::Bool=true,
    output_directory::String="results_oos",
    instance_file::String="inst/inst2020/Drahi_1.csv",
    in_sample_stages::Int=3,
    in_sample_children::Int=2,
    in_sample_periods_per_stage::Int=8,
    households::Int=5,
    theta::Float64=0.2,
    avg_demand::Float64=100.0,
    dev_demand::Float64=10.0,
    demand_profile::String="mixed",
    battery_scale::Float64=1.0,
    pv_scale::Float64=1.0,
    formulation_variant::Symbol=:aggregate_only,
    use_warm_starts::Bool=false,
    solver_threads::Int=0,
    require_shared_battery_validation::Bool=true,
    experiment_id::String="oos_experiment",
    prompt_version::String="oos_receding_horizon_prompt_v1",
)
    oos_replications >= 1 || error("oos_replications debe ser >= 1.")
    isempty(controller_set) && error("controller_set no puede estar vacío.")
    isempty(fairness_set) && error("fairness_set no puede estar vacío.")
    two_stage_scenarios >= 1 || error("two_stage_scenarios debe ser >= 1.")
    all(b -> b >= 1, multistage_branching) || error("Todo factor de ramificación debe ser >= 1.")
    all(p -> p >= 1, multistage_periods_per_stage) ||
        error("Todo número de períodos por etapa debe ser >= 1.")
    if !isempty(multistage_periods_per_stage) &&
       length(multistage_periods_per_stage) != length(multistage_branching) + 1
        error(
            "multistage_periods_per_stage debe tener length(multistage_branching)+1 = " *
            "$(length(multistage_branching)+1) entradas, o quedar vacío para reparto automático."
        )
    end
    fairness_abs_tol >= 0 || error("fairness_abs_tol debe ser >= 0.")
    sa_fairness_abs_tol >= 0 || error("sa_fairness_abs_tol debe ser >= 0.")
    lex_eps_abs >= 0 || error("lex_eps_abs debe ser >= 0.")
    pea_tolerance_mode in OOS_PEA_TOLERANCE_MODES || error(
        "pea_tolerance_mode no soportado: $pea_tolerance_mode. " *
        "Usa :strict, :adaptive_minimum o :fixed_band."
    )
    pea_tolerance_numeric_eps > 0 ||
        error("pea_tolerance_numeric_eps (kWh) debe ser > 0.")
    if fairness_abs_tol > 0 && pea_tolerance_mode !== :fixed_band
        error(
            "fairness_abs_tol=$fairness_abs_tol es una banda económica fija y está en desuso. " *
            "Con pea_tolerance_mode=:$pea_tolerance_mode se ignoraría en silencio, lo que " *
            "cambiaría la política PEA sin dejar rastro. Usa pea_tolerance_mode=:fixed_band " *
            "de forma explícita, o deja fairness_abs_tol=0.0."
        )
    end
    if pea_tolerance_mode === :fixed_band && fairness_abs_tol <= 0
        error(
            "pea_tolerance_mode=:fixed_band requiere fairness_abs_tol > 0; en caso contrario " *
            "usa :strict."
        )
    end
    flow_tol > 0 || error("flow_tol debe ser > 0.")
    feasibility_tol > 0 || error("feasibility_tol debe ser > 0.")
    integrality_tol > 0 || error("integrality_tol debe ser > 0.")
    solver_time_limit_sec > 0 || error("solver_time_limit_sec debe ser > 0.")
    isempty(strip(formulation_id)) && error("formulation_id no puede estar vacío.")
    formulation_variant in OOS_FORMULATION_VARIANTS ||
        error("formulation_variant no soportada: $formulation_variant.")
    households >= 2 || error("Se requieren al menos dos hogares para la experimentación OOS.")

    return OOSExperimentConfig(
        experiment_seed, oos_replications,
        unique(controller_set), unique(fairness_set),
        two_stage_scenarios, copy(multistage_branching), copy(multistage_periods_per_stage),
        fairness_abs_tol, sa_fairness_abs_tol, lex_eps_abs,
        pea_tolerance_mode, pea_tolerance_numeric_eps,
        flow_tol, feasibility_tol, integrality_tol,
        solver_time_limit_sec,
        String(strip(formulation_id)), allow_legacy_conversion, export_representative_models,
        output_directory,
        instance_file, in_sample_stages, in_sample_children, in_sample_periods_per_stage,
        households, theta, avg_demand, dev_demand, demand_profile,
        battery_scale, pv_scale, formulation_variant, use_warm_starts, solver_threads,
        require_shared_battery_validation, experiment_id, prompt_version,
    )
end

"""Number of (controller, fairness) configurations implied by the configuration."""
configuration_count(config::OOSExperimentConfig) =
    length(config.controller_set) * length(config.fairness_set)

# -------------------------------------------------------------------------------------
# Instance template
# -------------------------------------------------------------------------------------

"""
Per-household demand model of the calibrated stochastic process.

`active_periods` follows the repository convention in `demandProfile`: morning = 1:8,
midday = 9:16, night = 17:24 and `alea` = every period. Demand is drawn independently per
period from `Normal(avg, dev)` inside the active window and is zero elsewhere, exactly as
in `codes/parametersMS.jl`.
"""
struct OOSHouseholdDemandModel
    household::Int
    profile::String
    active_periods::Vector{Int}
    avg::Float64
    dev::Float64
end

"""
Read-only physical/economic template shared by every configuration.

Physical parameters, prices and the deterministic PV profile come from the repository's
verified `generateInstance` / `scaleInstance!` pipeline. The stochastic structure lives in
the uncertainty provider so that the in-sample look-ahead world and the out-of-sample world
are generated by one calibrated process.
"""
struct OOSInstanceTemplate
    id::String
    instance_file::String
    J::Int
    T::Int
    delta::Float64
    e_c::Float64
    e_d::Float64
    s_I::Float64
    s_min::Float64
    s_max::Float64
    f_under::Float64
    f_bar::Float64
    mu::Float64
    beta::Float64
    nu::Matrix{Float64}      # J x T electricity purchase prices
    pv_det::Vector{Float64}  # deterministic PV profile, length T
    theta::Float64           # PV multiplicative-error standard deviation
    demand_models::Vector{OOSHouseholdDemandModel}
    metadata::Dict{String,Any}
end

# -------------------------------------------------------------------------------------
# Uncertainty representations
# -------------------------------------------------------------------------------------

"""
Exogenous history the controller is allowed to condition on.

`pv[k]` and `demand[j,k]` refer to calendar period `k` for `k in 1:periods`. Nothing beyond
`periods` is ever stored here, which is what makes look-ahead leakage structurally
impossible.
"""
struct ObservedHistory
    periods::Int
    pv::Vector{Float64}
    demand::Matrix{Float64}
end

"""Current-period exogenous realization revealed before the action is selected."""
struct PeriodObservation
    period::Int
    pv::Float64
    demand::Vector{Float64}
end

"""Branching specification of a conditional scenario tree."""
struct BranchingSpec
    branching::Vector{Int}
    periods_per_stage::Vector{Int}
end

BranchingSpec(branching::Vector{Int}) = BranchingSpec(branching, Int[])

"""
One conditional point-forecast path over the calendar periods `first_period:last_period`.

`pv[k]` and `demand[j,k]` refer to calendar period `first_period + k - 1`. Entry `k = 1` is
the *observed* current period, never a forecast.
"""
struct ForecastPath
    first_period::Int
    last_period::Int
    pv::Vector{Float64}
    demand::Matrix{Float64}
end

"""One conditional complete future scenario with its probability."""
struct ScenarioPath
    first_period::Int
    last_period::Int
    probability::Float64
    pv::Vector{Float64}
    demand::Matrix{Float64}
end

"""
Conditional scenario tree with progressive information revelation.

Nodes are numbered `1:length(parent)` with node `1` as the root (the observed current
period). `probability[n]` is the unconditional probability of reaching node `n` given the
root, so `probability[1] == 1` and the leaf probabilities sum to one.
`scenarios[s]` lists the nodes of scenario `s` ordered from the root to its leaf.
"""
struct ConditionalTree
    first_period::Int
    last_period::Int
    parent::Vector{Int}
    probability::Vector{Float64}
    calendar_period::Vector{Int}
    scenarios::Vector{Vector{Int}}
    pv::Vector{Float64}
    demand::Matrix{Float64}
end

"""One independently simulated out-of-sample trajectory (the simulated real world)."""
struct OOSPath
    replication_id::Int
    horizon::Int
    pv::Vector{Float64}
    demand::Matrix{Float64}
end

# -------------------------------------------------------------------------------------
# Look-ahead tree adapter
# -------------------------------------------------------------------------------------

"""
Controller-independent adapter consumed by the single physical model builder.

`mode_nodes` is produced by the centralized convention in `mode_nodes.jl` and never
duplicated per controller. `root_probability` must equal one.
"""
struct LookaheadTree
    root::Int
    nodes::Vector{Int}
    parent::Vector{Int}
    probability::Vector{Float64}
    calendar_period::Vector{Int}
    scenarios::Vector{Vector{Int}}

    pv::Vector{Float64}
    demand::Matrix{Float64}

    mode_nodes::Vector{Int}

    controller::ControllerKind
    first_period::Int
    last_period::Int
    generated_scenarios::Int
end

lookahead_node_count(tree::LookaheadTree) = length(tree.nodes)
lookahead_scenario_count(tree::LookaheadTree) = length(tree.scenarios)

"""Nodes whose parent is the root, i.e. the first branching layer."""
lookahead_root_children(tree::LookaheadTree) = [n for n in tree.nodes if tree.parent[n] == tree.root]

# -------------------------------------------------------------------------------------
# Actions and solver results
# -------------------------------------------------------------------------------------

"""
The complete current-period action that the simulator implements.

`shared_battery_mode` is a scalar: one shared-battery operating mode for the current
physical period. There is no household-indexed mode field, and legacy household-by-time
fields (`x`, `w`) are never reused to store it.
"""
struct PeriodAction
    period::Int

    shared_battery_mode::Int

    p::Vector{Float64}
    z::Vector{Float64}
    y::Vector{Float64}
    I::Vector{Float64}
    G::Vector{Float64}
    lambda::Vector{Float64}

    aggregate_charge::Float64
    aggregate_discharge::Float64
    soc_after_model::Float64
end

"""Model dimensions measured on the generated solver model, never hard-coded."""
struct ModelStatistics
    variables::Int
    binary_variables::Int
    continuous_variables::Int
    constraints::Int
    nonzeros::Int
    expected_mode_nodes::Int
    generated_mode_binaries::Int
    unique_policy_modes::Int
    presolve_reduced_variables::Int
    presolve_reduced_constraints::Int
    root_relaxation::Float64
    branch_and_bound_nodes::Int
    final_gap::Float64
    peak_memory_mb::Float64
end

"""Residual bundle used both for solver auditing and for implemented-action validation."""
struct ActionResiduals
    pv_allocation::Float64
    household_balance::Float64
    battery_transition::Float64
    charge_link::Float64
    discharge_link::Float64
    simultaneous_flow::Float64
    integrality::Float64
    soc_bounds::Float64
    terminal::Float64
    fairness::Float64
end

zero_residuals() = ActionResiduals(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)

max_residual(r::ActionResiduals) = maximum((
    r.pv_allocation, r.household_balance, r.battery_transition, r.charge_link,
    r.discharge_link, r.simultaneous_flow, r.integrality, r.soc_bounds, r.terminal,
))

"""
One optimization solve.

`phase == 0` is a single solve. For lexicographic rules, `phase` runs `1:J` over the
max-min phases and `J+1` is the economic tie-break, so `solve_log.csv` really has one row per
solve rather than one row per period.
"""
struct SolvePhaseRecord
    phase::Int
    label::String
    termination_status::String
    primal_status::String
    objective_value::Float64
    objective_bound::Float64
    wall_time_sec::Float64
    solver_time_sec::Float64
    variables::Int
    binary_variables::Int
    continuous_variables::Int
    constraints::Int
    nonzeros::Int
    branch_and_bound_nodes::Int
    final_gap::Float64
    root_relaxation::Float64
end

"""Outcome of one `solve_current_action` call."""
struct ControllerResult
    controller::ControllerKind
    fairness::FairnessPolicy
    period::Int

    termination_status::String
    primal_status::String
    solved::Bool

    action::Union{Nothing,PeriodAction}

    objective_value::Float64
    objective_bound::Float64
    fairness_phase_objectives::Vector{Float64}

    build_time_sec::Float64
    solve_time_sec::Float64
    solver_time_sec::Float64

    statistics::ModelStatistics
    residuals::ActionResiduals

    soc_before::Float64
    failure_message::String

    """
    Node-level aggregate flows of the provisional plan, kept only when warm starts are
    enabled. A MIP start is solver guidance, not a decision: the plan itself is still
    discarded, and only these aggregates are reused to derive one `v_n` per mode node.
    """
    plan_aggregate_flows::Union{Nothing,NamedTuple{(:charge, :discharge),Tuple{Vector{Float64},Vector{Float64}}}}

    """One entry per optimization solve performed for this period."""
    phases::Vector{SolvePhaseRecord}

    """Strict-first / adaptive-minimum PEA workflow record for this period."""
    pea::PEARecoveryRecord
end
