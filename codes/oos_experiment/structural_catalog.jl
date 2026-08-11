# =====================================================================================
# Structural instance catalog, deterministic-base isolation and seed hierarchy
# (redesign Stages 2 and 3).
#
# A STRUCTURAL INSTANCE fixes the physical and demand-composition characteristics that stay
# constant while several stochastic trajectories are evaluated. An OOS REPLICATION is one such
# trajectory inside a fixed structural instance. Stage 2 separates the two levels: it builds a
# deterministic, complete, auditable catalog of structural instances and the seed keys the later
# campaign will draw from, and it does not touch the running simulator.
#
# The primary design is
#
#     B base instances  x  2 battery levels  x  2 demand regimes  x  2 uncertainty levels  x  K draws
#
# All periods here remain ABSTRACT MODEL PERIODS. Nothing in this file introduces minutes, hours,
# days or any calendar interpretation; the rolling structure comes from the stage-1 temporal
# contract in `temporal.jl` and the physical period length stays in `template.delta`.
#
# STAGE SCOPE. The catalog and its Stage-3 period support are pre-campaign contracts, not yet a
# simulator driver. `oos_path_rng` and `lookahead_rng` keep their accepted behaviour, no common
# scenario support is generated, and `build_instance_template(config)` keeps its exact default
# behaviour. Wiring a fixed moving look-ahead into the simulator belongs to Stage 4 or later.
#
# PROVISIONAL VALUES. The numeric battery scales and uncertainty intensities are inputs, never
# defaults. Nothing in this file proposes a scientifically calibrated value; every design carries
# `factor_level_status = PROVISIONAL_UNCALIBRATED` until stage 12 approves the levels.
# =====================================================================================

# -------------------------------------------------------------------------------------
# Typed structural factors
# -------------------------------------------------------------------------------------

"""Battery capacity/rate level of a structural instance. Maps to a `battery_scale`."""
@enum BatteryLevel begin
    LOW_BATTERY
    HIGH_BATTERY
end

"""
Demand-composition regime: how the repository's temporal profiles are distributed across
households.

Distinct from `dev_demand`, which keeps controlling stochastic dispersion *around* an assigned
profile. A regime says who consumes when; `dev_demand` says how noisy each household is.
"""
@enum DemandRegime begin
    HOMOGENEOUS
    HETEROGENEOUS
end

"""Uncertainty intensity level of a structural instance. Maps to a `theta`."""
@enum UncertaintyLevel begin
    LOW_UNCERTAINTY
    HIGH_UNCERTAINTY
end

# Canonical orders are declared explicitly rather than inferred from the enum's integer values,
# so the manifest ordering cannot drift if a level is ever inserted into a declaration.
const OOS_BATTERY_LEVEL_ORDER = (LOW_BATTERY, HIGH_BATTERY)
const OOS_DEMAND_REGIME_ORDER = (HOMOGENEOUS, HETEROGENEOUS)
const OOS_UNCERTAINTY_LEVEL_ORDER = (LOW_UNCERTAINTY, HIGH_UNCERTAINTY)

const OOS_BATTERY_LEVELS = Dict(string(k) => k for k in instances(BatteryLevel))
const OOS_DEMAND_REGIMES = Dict(string(k) => k for k in instances(DemandRegime))
const OOS_UNCERTAINTY_LEVELS = Dict(string(k) => k for k in instances(UncertaintyLevel))

parse_battery_level(label::AbstractString) = get(OOS_BATTERY_LEVELS, uppercase(strip(label))) do
    error("Nivel de batería no soportado: $label. Usa LOW_BATTERY o HIGH_BATTERY.")
end

parse_demand_regime(label::AbstractString) = get(OOS_DEMAND_REGIMES, uppercase(strip(label))) do
    error("Régimen de demanda no soportado: $label. Usa HOMOGENEOUS o HETEROGENEOUS.")
end

parse_uncertainty_level(label::AbstractString) =
    get(OOS_UNCERTAINTY_LEVELS, uppercase(strip(label))) do
        error(
            "Nivel de incertidumbre no soportado: $label. " *
            "Usa LOW_UNCERTAINTY o HIGH_UNCERTAINTY."
        )
    end

"""Short stable codes used inside readable identifiers. Never the enum's integer value."""
battery_level_code(level::BatteryLevel) = level === LOW_BATTERY ? "BLO" : "BHI"
demand_regime_code(regime::DemandRegime) = regime === HOMOGENEOUS ? "HOM" : "HET"
uncertainty_level_code(level::UncertaintyLevel) = level === LOW_UNCERTAINTY ? "ULO" : "UHI"

"""
The three repository temporal profiles a structural assignment may use, in canonical order.

`alea` and the legacy composite labels (`mixed`, `mixed2`, `align_*`) are deliberately excluded:
the structural design controls composition itself and never delegates it to an independent
per-household draw.
"""
const OOS_STRUCTURAL_DEMAND_PROFILES = ("morning", "midday", "night")

"""Marker for factor levels that have not yet passed stage-12 calibration."""
const OOS_FACTOR_LEVEL_PROVISIONAL = :PROVISIONAL_UNCALIBRATED
const OOS_FACTOR_LEVEL_STATUSES = (OOS_FACTOR_LEVEL_PROVISIONAL,)

"""Version of the household-assignment algorithm. Moves if the assignment rule ever changes."""
const OOS_STRUCTURAL_ASSIGNMENT_ALGORITHM = "structural_demand_assignment_v1"

"""Version of this catalog's identifier construction."""
const OOS_STRUCTURAL_ID_ALGORITHM = "structural_identifiers_v1"

"""Version of the deterministic-data-block identity introduced by redesign Stage 3."""
const OOS_DETERMINISTIC_DATA_ALGORITHM = "deterministic_data_v1"

# -------------------------------------------------------------------------------------
# Base-instance normalization
# -------------------------------------------------------------------------------------

"""
Normalize a base-instance path to a repository-relative, forward-slash form.

Identifiers must not depend on the absolute checkout location, so an absolute path inside the
repository is rewritten relative to `OOS_REPO_ROOT` and anything already relative is kept.
"""
function normalized_base_instance_file(path::AbstractString)
    text = String(strip(path))
    isempty(text) && error("La ruta de la instancia base no puede estar vacía.")
    candidate = normpath(text)
    if isabspath(candidate)
        root = normpath(OOS_REPO_ROOT)
        relative = relpath(candidate, root)
        startswith(relative, "..") && error(
            "La instancia base debe vivir dentro del repositorio para que su identificador sea " *
            "independiente de la ruta de trabajo; se recibió: $path."
        )
        candidate = relative
    end
    return replace(candidate, '\\' => '/')
end

"""Absolute path of a normalized repository-relative base-instance file."""
absolute_base_instance_file(normalized::AbstractString) =
    normpath(joinpath(OOS_REPO_ROOT, String(normalized)))

"""
Stable, readable identifier of a base instance: its file stem.

Deliberately *not* the repository-generated `InstanceM.id`, which is `"J_V"` (households and
in-sample node count) and therefore identical for every base file of the same geometry. The
repository value is recorded separately as `repository_instance_id`.
"""
function base_instance_id(normalized_file::AbstractString)
    stem = splitext(basename(String(normalized_file)))[1]
    isempty(stem) && error("No se pudo derivar un identificador de: $normalized_file.")
    return replace(stem, r"[^A-Za-z0-9_.-]" => "_")
end

# -------------------------------------------------------------------------------------
# Structural design configuration
# -------------------------------------------------------------------------------------

"""
Complete, immutable specification of a structural factorial design.

Kept separate from `OOSExperimentConfig` on purpose: the legacy configuration describes ONE
instance plus the solver, controller and fairness settings of a campaign, and it keeps its
meaning and its defaults untouched. This type describes the *design space* instead.

The four numeric factor levels and the number of structural draws have NO defaults. A caller must
state them, so nothing in the repository can be mistaken for a calibrated recommendation. Stage 12
fixes the campaign levels; anything used before then — including in this stage's tests — is a
fixture.
"""
struct OOSStructuralDesignConfig
    base_instance_files::Vector{String}        # normalized, repository-relative, sorted, unique
    experiment_seed::Int
    structural_draws_per_cell::Int             # K

    battery_scales::Dict{BatteryLevel,Float64}
    uncertainty_thetas::Dict{UncertaintyLevel,Float64}

    households::Int
    avg_demand::Float64
    dev_demand::Float64
    pv_scale::Float64

    oos_replications::Int

    # Abstract temporal contract, reused verbatim from the stage-1 helpers in `temporal.jl`.
    evaluation_horizon::Int
    lookahead_horizon::Int
    implementation_step::Int

    # Geometry of the repository's legacy in-sample tree, needed by `generateInstance`.
    in_sample_stages::Int
    in_sample_children::Int
    in_sample_periods_per_stage::Int

    """
    The `demand_profile` argument handed to the repository `generateInstance` pipeline.

    It is FIXED across the whole catalog and is *not* the structural demand regime. It enters
    `deterministic_seed`, so letting it vary with the regime would make the repository-generated
    price matrix differ between regimes for no modelled reason. Household composition is decided
    by `structural_demand_assignment` instead.
    """
    repository_demand_profile::String

    factor_level_status::Symbol
end

"""Convenience builder for the battery-level mapping, so a caller cannot omit a level silently."""
battery_scale_map(low::Real, high::Real) =
    Dict{BatteryLevel,Float64}(LOW_BATTERY => Float64(low), HIGH_BATTERY => Float64(high))

"""Convenience builder for the uncertainty-level mapping."""
uncertainty_theta_map(low::Real, high::Real) =
    Dict{UncertaintyLevel,Float64}(
        LOW_UNCERTAINTY => Float64(low), HIGH_UNCERTAINTY => Float64(high),
    )

function _require_complete_mapping(mapping::AbstractDict, expected, label::AbstractString)
    present = Set(keys(mapping))
    wanted = Set(expected)
    missing_levels = setdiff(wanted, present)
    isempty(missing_levels) || error(
        "Falta el mapeo de $label para: " *
        join(sort([string(level) for level in missing_levels]), ", ") * "."
    )
    extra_levels = setdiff(present, wanted)
    isempty(extra_levels) || error(
        "Mapeo de $label con niveles desconocidos: " *
        join(sort([string(level) for level in extra_levels]), ", ") * "."
    )
    for level in expected
        value = mapping[level]
        isfinite(value) || error("El valor de $label para $level no es finito: $value.")
    end
    return nothing
end

function OOSStructuralDesignConfig(;
    base_instance_files,
    experiment_seed::Int=12345,
    structural_draws_per_cell::Int,
    battery_scales::AbstractDict,
    uncertainty_thetas::AbstractDict,
    households::Int=5,
    avg_demand::Float64=100.0,
    dev_demand::Float64=10.0,
    pv_scale::Float64=1.0,
    oos_replications::Int=20,
    evaluation_horizon::Int=OOS_DEFAULT_EVALUATION_HORIZON,
    lookahead_horizon::Int=OOS_DEFAULT_LOOKAHEAD_HORIZON,
    implementation_step::Int=OOS_DEFAULT_IMPLEMENTATION_STEP,
    in_sample_stages::Int=3,
    in_sample_children::Int=2,
    in_sample_periods_per_stage::Int=8,
    repository_demand_profile::String="mixed",
    factor_level_status::Symbol=OOS_FACTOR_LEVEL_PROVISIONAL,
)
    files = [normalized_base_instance_file(entry) for entry in base_instance_files]
    isempty(files) && error("El conjunto de instancias base no puede estar vacío.")
    if length(unique(files)) != length(files)
        duplicates = [file for file in unique(files) if count(==(file), files) > 1]
        error("Instancias base duplicadas tras normalizar: " * join(sort(duplicates), ", ") * ".")
    end
    identifiers = [base_instance_id(file) for file in files]
    if length(unique(identifiers)) != length(identifiers)
        error(
            "Dos instancias base distintas comparten identificador derivado: " *
            join(sort(identifiers), ", ") * ". El pipeline del repositorio también usa " *
            "basename(inFile) en deterministic_seed, por lo que colisionarían."
        )
    end
    # Canonical order rule 1: normalized base instance, sorted once here so every consumer of the
    # design sees the same order regardless of how the caller listed the files.
    files = sort(files)

    structural_draws_per_cell >= 1 ||
        error("structural_draws_per_cell (K) debe ser >= 1; se recibió $structural_draws_per_cell.")

    _require_complete_mapping(battery_scales, OOS_BATTERY_LEVEL_ORDER, "battery_scale")
    _require_complete_mapping(uncertainty_thetas, OOS_UNCERTAINTY_LEVEL_ORDER, "theta")

    low_battery = battery_scales[LOW_BATTERY]
    high_battery = battery_scales[HIGH_BATTERY]
    low_battery > 0 || error("La escala de batería LOW_BATTERY debe ser > 0; se recibió $low_battery.")
    high_battery > 0 ||
        error("La escala de batería HIGH_BATTERY debe ser > 0; se recibió $high_battery.")
    low_battery < high_battery || error(
        "Se requiere 0 < LOW_BATTERY < HIGH_BATTERY; se recibió " *
        "LOW_BATTERY=$low_battery y HIGH_BATTERY=$high_battery."
    )

    low_theta = uncertainty_thetas[LOW_UNCERTAINTY]
    high_theta = uncertainty_thetas[HIGH_UNCERTAINTY]
    low_theta >= 0 || error("El theta de LOW_UNCERTAINTY debe ser >= 0; se recibió $low_theta.")
    low_theta < high_theta || error(
        "Se requiere 0 <= LOW_UNCERTAINTY < HIGH_UNCERTAINTY; se recibió " *
        "LOW_UNCERTAINTY=$low_theta y HIGH_UNCERTAINTY=$high_theta."
    )

    households >= 2 || error("Se requieren al menos dos hogares; se recibió $households.")
    for (name, value) in (("avg_demand", avg_demand), ("dev_demand", dev_demand),
                          ("pv_scale", pv_scale))
        isfinite(value) || error("$name no es finito: $value.")
    end
    avg_demand > 0 || error("avg_demand debe ser > 0; se recibió $avg_demand.")
    dev_demand >= 0 || error("dev_demand debe ser >= 0; se recibió $dev_demand.")
    pv_scale > 0 || error("pv_scale debe ser > 0; se recibió $pv_scale.")
    oos_replications >= 1 || error("oos_replications debe ser >= 1; se recibió $oos_replications.")

    # The abstract temporal contract is validated by the stage-1 rule, not restated here.
    validate_temporal_contract(evaluation_horizon, lookahead_horizon, implementation_step)

    in_sample_stages >= 1 || error("in_sample_stages debe ser >= 1.")
    in_sample_children >= 1 || error("in_sample_children debe ser >= 1.")
    in_sample_periods_per_stage >= 1 || error("in_sample_periods_per_stage debe ser >= 1.")

    profile = String(strip(repository_demand_profile))
    isempty(profile) && error("repository_demand_profile no puede estar vacío.")

    factor_level_status in OOS_FACTOR_LEVEL_STATUSES || error(
        "factor_level_status no soportado: $factor_level_status. " *
        "Los niveles numéricos siguen sin calibrar hasta la etapa 12; usa " *
        ":$(OOS_FACTOR_LEVEL_PROVISIONAL)."
    )

    return OOSStructuralDesignConfig(
        files, experiment_seed, structural_draws_per_cell,
        Dict{BatteryLevel,Float64}(battery_scales),
        Dict{UncertaintyLevel,Float64}(uncertainty_thetas),
        households, avg_demand, dev_demand, pv_scale,
        oos_replications,
        evaluation_horizon, lookahead_horizon, implementation_step,
        in_sample_stages, in_sample_children, in_sample_periods_per_stage,
        profile, factor_level_status,
    )
end

battery_scale(design::OOSStructuralDesignConfig, level::BatteryLevel) = design.battery_scales[level]
uncertainty_theta(design::OOSStructuralDesignConfig, level::UncertaintyLevel) =
    design.uncertainty_thetas[level]

# The stage-1 temporal helpers apply verbatim to a structural design: same three numbers, same
# arithmetic kernels, no restated semantics.
known_prefix_length(design::OOSStructuralDesignConfig) = design.implementation_step
rolling_iteration_starts(design::OOSStructuralDesignConfig) =
    _rolling_iteration_starts(design.evaluation_horizon, design.implementation_step)
rolling_solve_count(design::OOSStructuralDesignConfig) =
    _rolling_solve_count(design.evaluation_horizon, design.implementation_step)
is_rolling_iteration_start(design::OOSStructuralDesignConfig, period::Int) =
    _is_rolling_iteration_start(design.evaluation_horizon, design.implementation_step, period)
final_rolling_iteration_start(design::OOSStructuralDesignConfig) =
    _final_rolling_iteration_start(design.evaluation_horizon, design.implementation_step)
required_period_support_end(design::OOSStructuralDesignConfig) =
    final_rolling_iteration_start(design) + design.lookahead_horizon - 1

"""Number of structural instances the design implies: `B x 2 x 2 x 2 x K`."""
expected_structural_instance_count(design::OOSStructuralDesignConfig) =
    length(design.base_instance_files) * 2 * 2 * 2 * design.structural_draws_per_cell

"""Number of battery pairs: one `PairedBaseID` per non-battery cell."""
expected_paired_base_count(design::OOSStructuralDesignConfig) =
    length(design.base_instance_files) * 2 * 2 * design.structural_draws_per_cell

"""Number of distinct household assignments: one per base instance, regime and draw."""
expected_demand_assignment_count(design::OOSStructuralDesignConfig) =
    length(design.base_instance_files) * 2 * design.structural_draws_per_cell

"""Number of deterministic data blocks: one per normalized base instance and structural draw."""
expected_deterministic_data_count(design::OOSStructuralDesignConfig) =
    length(design.base_instance_files) * design.structural_draws_per_cell

# -------------------------------------------------------------------------------------
# Seed hierarchy
# -------------------------------------------------------------------------------------
#
# Every seed below is built on the repository's existing deterministic FNV-1a
# (`oos_stream_seed`), with a distinct stream name so no two hierarchies can consume each other's
# numbers. What each stream includes and excludes is a contract, recorded in the manifest and
# enforced by its validator.
#
# STAGE BOUNDARY. Assignment and deterministic-base streams are active only while building the
# structural catalog. The planned path/support keys remain contracts: the active simulator still
# uses `oos_path_rng` and `lookahead_rng` unchanged; removing the controller from active
# look-ahead generation is Stage 5, and wiring structural path keys into a campaign is later work.

const OOS_STRUCTURAL_ASSIGNMENT_STREAM = "structural_assignment"
const OOS_STRUCTURAL_PATH_STREAM = "structural_oos_path"
const OOS_CONDITIONAL_SUPPORT_STREAM = "conditional_support"
const OOS_DETERMINISTIC_BASE_STREAM = "structural_deterministic_base"

"""Exact scientific inputs of the Stage-3 deterministic repository-base seed."""
const OOS_DETERMINISTIC_BASE_INCLUDED_KEYS = [
    "experiment_seed",
    "normalized_base_instance_file",
    "structural_draw",
    "in_sample_stages",
    "in_sample_children",
    "in_sample_periods_per_stage",
    "households",
    "avg_demand",
    "dev_demand",
    "pv_scale",
    "repository_demand_profile",
]

"""Inputs structurally excluded from the Stage-3 deterministic repository-base seed."""
const OOS_DETERMINISTIC_BASE_EXCLUDED_KEYS = [
    "battery_level",
    "battery_scale",
    "demand_regime",
    "demand_assignment_id",
    "uncertainty_level",
    "theta",
    "oos_replication",
    "rolling_start",
    "controller",
    "fairness_policy",
    "solver_phase",
    "worker",
    "retry",
    "execution_order",
]

"""
The complete key of one deterministic repository data block.

The type deliberately has no field for any experimental factor other than `structural_draw`:
battery, demand regime/assignment and uncertainty cannot leak into the repository seed by a
future call-site edit. Operational fields (controller, worker, retry, order) are equally absent.
The stored path is normalized and repository-relative, never checkout-dependent.
"""
struct OOSDeterministicBaseKey
    experiment_seed::Int
    base_instance_file::String
    structural_draw::Int
    in_sample_stages::Int
    in_sample_children::Int
    in_sample_periods_per_stage::Int
    households::Int
    avg_demand::Float64
    dev_demand::Float64
    pv_scale::Float64
    repository_demand_profile::String
end

function deterministic_base_key(
    design::OOSStructuralDesignConfig,
    normalized_file::AbstractString,
    structural_draw::Int,
)
    1 <= structural_draw <= design.structural_draws_per_cell || error(
        "structural_draw=$structural_draw fuera de 1:$(design.structural_draws_per_cell)."
    )
    file = normalized_base_instance_file(normalized_file)
    file in design.base_instance_files || error(
        "La instancia base $file no pertenece al diseño estructural."
    )
    return OOSDeterministicBaseKey(
        design.experiment_seed,
        file,
        structural_draw,
        design.in_sample_stages,
        design.in_sample_children,
        design.in_sample_periods_per_stage,
        design.households,
        design.avg_demand,
        design.dev_demand,
        design.pv_scale,
        design.repository_demand_profile,
    )
end

"""
Actual repository-generator seed used by the Stage-3 structural materializer.

This is intentionally distinct from `repository_instance_seed(design, file, theta)`, which
retains the legacy theta-dependent default for compatibility and audit. The stream consumes every
field of `OOSDeterministicBaseKey` in declaration order and nothing else.
"""
actual_repository_generator_seed(key::OOSDeterministicBaseKey) = oos_stream_seed(
    key.experiment_seed,
    OOS_DETERMINISTIC_BASE_STREAM,
    key.base_instance_file,
    key.structural_draw,
    key.in_sample_stages,
    key.in_sample_children,
    key.in_sample_periods_per_stage,
    key.households,
    key.avg_demand,
    key.dev_demand,
    key.pv_scale,
    key.repository_demand_profile,
)

actual_repository_generator_seed(
    design::OOSStructuralDesignConfig,
    normalized_file::AbstractString,
    structural_draw::Int,
) = actual_repository_generator_seed(
    deterministic_base_key(design, normalized_file, structural_draw),
)

"""
Seed of the household demand-profile assignment.

Keys: experiment seed, base instance, demand regime, structural draw.

Battery level, uncertainty level, replication, rolling start, controller, fairness policy, solver
phase, worker and execution order are all absent, which is what makes one assignment shared by
every battery and uncertainty variant of the same cell.
"""
structural_assignment_seed(
    experiment_seed::Int,
    base_instance::AbstractString,
    regime::DemandRegime,
    structural_draw::Int,
) = oos_stream_seed(
    experiment_seed, OOS_STRUCTURAL_ASSIGNMENT_STREAM,
    String(base_instance), string(regime), structural_draw,
)

structural_assignment_seed(design::OOSStructuralDesignConfig, base_instance::AbstractString,
                           regime::DemandRegime, structural_draw::Int) =
    structural_assignment_seed(design.experiment_seed, base_instance, regime, structural_draw)

"""RNG of the household demand-profile assignment."""
structural_assignment_rng(args...) = MersenneTwister(structural_assignment_seed(args...))

"""
Exactly the keys of the future OOS-path and conditional-support streams.

Battery level and the numeric `theta` are *structurally* absent: this type cannot carry them, so
no future edit can leak them into a seed by accident. Excluding battery is what will give a
battery pair the same exogenous trajectory. Excluding the numeric `theta` while keeping the
uncertainty *label* means a stage-12 recalibration of the level values does not renumber the
common random streams.
"""
struct OOSPathSeedKey
    experiment_seed::Int
    base_instance_id::String
    demand_assignment_id::String
    demand_regime::DemandRegime
    structural_draw::Int
    uncertainty_level::UncertaintyLevel
end

"""
Seed of one out-of-sample trajectory.

Keys: experiment seed, base instance, demand assignment, demand regime, structural draw,
uncertainty level, replication.

Excludes battery level, controller, fairness policy, solver phase, worker, rolling start and
execution order. The uncertainty level stays in the key: stage 2 does not introduce common random
numbers across different uncertainty levels.
"""
structural_oos_path_seed(key::OOSPathSeedKey, replication::Int) = oos_stream_seed(
    key.experiment_seed, OOS_STRUCTURAL_PATH_STREAM,
    key.base_instance_id, key.demand_assignment_id, string(key.demand_regime),
    key.structural_draw, string(key.uncertainty_level), replication,
)

"""RNG of one out-of-sample trajectory."""
structural_oos_path_rng(key::OOSPathSeedKey, replication::Int) =
    MersenneTwister(structural_oos_path_seed(key, replication))

"""
Seed of the conditional stochastic support at one rolling start.

Keys: the OOS-path keys plus the rolling start. Excludes battery level, controller, fairness
policy, solver phase, worker and execution order — the controller exclusion is the whole point,
and it is why this is a separate stream from the still-active `lookahead` one.
"""
function conditional_support_seed(key::OOSPathSeedKey, replication::Int, rolling_start::Int)
    rolling_start >= 1 || error("El inicio de iteración debe ser >= 1; se recibió $rolling_start.")
    return oos_stream_seed(
        key.experiment_seed, OOS_CONDITIONAL_SUPPORT_STREAM,
        key.base_instance_id, key.demand_assignment_id, string(key.demand_regime),
        key.structural_draw, string(key.uncertainty_level), replication, rolling_start,
    )
end

"""RNG of the conditional stochastic support at one rolling start."""
conditional_support_rng(key::OOSPathSeedKey, replication::Int, rolling_start::Int) =
    MersenneTwister(conditional_support_seed(key, replication, rolling_start))

"""
Seed the repository's own `generateInstance` pipeline uses, recorded under its own name.

This is `deterministic_seed` from `codes/parametersMS.jl`. It is NOT the structural assignment,
OOS-path or conditional-support seed, and it must never be relabelled as one.

What it controls, inside `generateInstance`: the legacy in-sample scenario-tree PV
(`inst.c_pv`), the legacy in-sample demand (`inst.d`, `inst.d_det`) and — importantly — the
price matrix `inst.nu`, which IS consumed by the out-of-sample physical model.

Its keys are the in-sample tree geometry, the household count, `basename(inFile)`, `theta`,
`avg`, `dev` and the repository `demand_profile`. It excludes `pv_scale` and `battery_scale`.

Two consequences worth stating plainly:

  * a battery pair shares this seed, hence shares prices and the legacy in-sample objects — which
    is exactly what the battery pairing invariant needs;
  * the two uncertainty levels do NOT share it, because `theta` is one of its keys, so they
    receive different price matrices. Stage 2 records the seed per structural instance so this is
    visible and auditable rather than hidden. Changing it would mean editing the verified
    repository pipeline, which is out of scope here.
"""
repository_instance_seed(design::OOSStructuralDesignConfig, normalized_file::AbstractString,
                         theta::Float64) = deterministic_seed(
    design.in_sample_stages, design.in_sample_children, design.in_sample_periods_per_stage,
    design.households, absolute_base_instance_file(normalized_file), theta,
    design.avg_demand, design.dev_demand; demand_profile=design.repository_demand_profile,
)

# -------------------------------------------------------------------------------------
# Controlled demand-profile assignment
# -------------------------------------------------------------------------------------

"""
Fisher-Yates permutation of `1:n`, written out so the algorithm is pinned in this repository.

`Random.shuffle` would work today, but its internals are a Base implementation detail; a manifest
that promises byte reproducibility should not depend on one. Versioned by
`OOS_STRUCTURAL_ASSIGNMENT_ALGORITHM`.
"""
function _seeded_permutation(rng::AbstractRNG, n::Int)
    order = collect(1:n)
    for index in n:-1:2
        swap = rand(rng, 1:index)
        order[index], order[swap] = order[swap], order[index]
    end
    return order
end

"""
Ordered household demand-profile assignment of one structural cell.

Pure: it reads only `households`, the regime and the seed, and touches no global state.

`HOMOGENEOUS` draws ONE profile from `morning`, `midday`, `night` and gives it to every
household. It never uses the legacy independent per-household `mixed` rule, which can turn a
nominally homogeneous instance into a mixed one.

`HETEROGENEOUS` splits the households as evenly as arithmetic allows, hands any remainder to a
seeded ordering of the three profile labels, and then applies a seeded permutation of household
identities. The resulting counts always satisfy `max - min <= 1`. Zero counts occur only when
unavoidable, i.e. when there are fewer households than profiles.
"""
function structural_demand_assignment(
    households::Int,
    regime::DemandRegime,
    assignment_seed::Int,
)
    households >= 1 || error("Se requiere al menos un hogar; se recibió $households.")
    rng = MersenneTwister(assignment_seed)
    profiles = OOS_STRUCTURAL_DEMAND_PROFILES
    count_profiles = length(profiles)

    if regime === HOMOGENEOUS
        chosen = profiles[rand(rng, 1:count_profiles)]
        return [String(chosen) for _ in 1:households]
    elseif regime === HETEROGENEOUS
        base = div(households, count_profiles)
        remainder = mod(households, count_profiles)
        counts = fill(base, count_profiles)
        # Deterministic seeded ordering of the profile labels decides who receives the remainder.
        label_order = _seeded_permutation(rng, count_profiles)
        for position in 1:remainder
            counts[label_order[position]] += 1
        end
        pool = String[]
        for index in 1:count_profiles, _ in 1:counts[index]
            push!(pool, String(profiles[index]))
        end
        length(pool) == households || error("Reparto de perfiles inconsistente.")
        # Seeded permutation of household identities, so composition and identity are separate
        # decisions and neither is an artefact of the loop order.
        identity_order = _seeded_permutation(rng, households)
        assignment = Vector{String}(undef, households)
        for (slot, household) in enumerate(identity_order)
            assignment[household] = pool[slot]
        end
        return assignment
    end
    error("Régimen de demanda no soportado: $regime.")
end

"""Profile counts of an assignment, in the canonical profile order."""
structural_profile_counts(assignment::AbstractVector{<:AbstractString}) =
    [count(==(String(profile)), assignment) for profile in OOS_STRUCTURAL_DEMAND_PROFILES]

"""
Validate an assignment against its regime.

`HOMOGENEOUS` must use exactly one profile. `HETEROGENEOUS` counts must differ by at most one.
Every label must belong to the approved structural profile set.
"""
function validate_structural_assignment(
    assignment::AbstractVector{<:AbstractString},
    regime::DemandRegime,
    households::Int,
)
    length(assignment) == households || error(
        "La asignación cubre $(length(assignment)) hogares y se esperaban $households."
    )
    for profile in assignment
        String(profile) in OOS_STRUCTURAL_DEMAND_PROFILES || error(
            "Perfil de demanda estructural no aprobado: $profile. " *
            "Usa " * join(OOS_STRUCTURAL_DEMAND_PROFILES, ", ") * "."
        )
    end
    counts = structural_profile_counts(assignment)
    if regime === HOMOGENEOUS
        length(unique(assignment)) == 1 || error(
            "Un régimen HOMOGENEOUS debe usar un único perfil; se encontraron " *
            join(sort(unique(String.(assignment))), ", ") * "."
        )
    elseif regime === HETEROGENEOUS
        maximum(counts) - minimum(counts) <= 1 || error(
            "Un régimen HETEROGENEOUS debe estar balanceado (max - min <= 1); conteos = $counts."
        )
    end
    return counts
end

"""
Build the `OOSHouseholdDemandModel` records of a resolved assignment.

The profiles come from the catalog and are never re-sampled here: this function contains no
randomness at all, which is what guarantees that a battery pair and every replication of a cell
see literally the same household composition.
"""
function structural_demand_models(
    assignment::AbstractVector{<:AbstractString},
    horizon::Int,
    avg::Float64,
    dev::Float64,
)
    return [
        OOSHouseholdDemandModel(
            household, String(assignment[household]),
            demand_active_periods(String(assignment[household]), horizon), avg, dev,
        )
        for household in eachindex(assignment)
    ]
end

# -------------------------------------------------------------------------------------
# Deterministic identifiers
# -------------------------------------------------------------------------------------
#
# Every identifier is a readable prefix plus a digest of an explicitly ordered token list. The
# token lists are recorded in the manifest, so a reader can recompute any identifier without
# reading this file. No identifier depends on an absolute path, a timestamp, a process, a host, a
# worker, an output directory or execution order, and none uses Julia's `hash` — which has no
# stability contract across Julia versions or architectures and so cannot back a persisted ID.

const OOS_STRUCTURAL_DIGEST_LENGTH = 10

_digest_prefix(parts::AbstractVector) =
    oos_identity_digest(parts)[1:OOS_STRUCTURAL_DIGEST_LENGTH]

_deterministic_base_identity_tokens(key::OOSDeterministicBaseKey) = Any[
    OOS_DETERMINISTIC_DATA_ALGORITHM,
    key.experiment_seed,
    key.base_instance_file,
    key.structural_draw,
    key.in_sample_stages,
    key.in_sample_children,
    key.in_sample_periods_per_stage,
    key.households,
    key.avg_demand,
    key.dev_demand,
    key.pv_scale,
    key.repository_demand_profile,
]

"""
`DeterministicDataID`: identifies the repository data shared by all eight factor variants of one
`(base instance, structural draw)` cell.

The readable prefix is not part of the digest contract. The digest uses canonical serialization
of exactly the deterministic-base key, never Julia's `hash`, an absolute path or an experimental
factor excluded by `OOSDeterministicBaseKey`.
"""
function deterministic_data_id(key::OOSDeterministicBaseKey)
    identifier = base_instance_id(key.base_instance_file)
    return string(
        "DD-", identifier, "-d", key.structural_draw, "-",
        _digest_prefix(_deterministic_base_identity_tokens(key)),
    )
end

deterministic_data_id(
    design::OOSStructuralDesignConfig,
    normalized_file::AbstractString,
    structural_draw::Int,
) = deterministic_data_id(deterministic_base_key(design, normalized_file, structural_draw))

"""Fixed primary-design tokens shared by every record of one design."""
_fixed_design_tokens(design::OOSStructuralDesignConfig) = Any[
    design.households, design.avg_demand, design.dev_demand, design.pv_scale,
    design.in_sample_stages, design.in_sample_children, design.in_sample_periods_per_stage,
    design.repository_demand_profile,
]

"""
`DemandAssignmentID`: identifies one household composition.

Included: experiment seed, base instance file and ID, demand regime, structural draw, ordered
household-profile vector.

Excluded: battery level, battery scale, uncertainty level, theta, controller, fairness policy,
OOS replication, worker.
"""
function demand_assignment_id(
    design::OOSStructuralDesignConfig,
    normalized_file::AbstractString,
    regime::DemandRegime,
    structural_draw::Int,
    assignment::AbstractVector{<:AbstractString},
)
    identifier = base_instance_id(normalized_file)
    digest = _digest_prefix(Any[
        OOS_STRUCTURAL_ID_ALGORITHM, "demand_assignment",
        design.experiment_seed, String(normalized_file), identifier,
        string(regime), structural_draw, [String(p) for p in assignment],
    ])
    return string("DA-", identifier, "-", demand_regime_code(regime), "-d",
                  structural_draw, "-", digest)
end

"""
`PairedBaseID`: the low-versus-high battery comparison identifier.

Included: everything structural except battery level and battery scale — experiment seed, base
instance, structural draw, demand regime, `DemandAssignmentID`, uncertainty level, theta, and the
fixed primary-design parameters.

Each complete `PairedBaseID` therefore corresponds to exactly two structural instances.
"""
function paired_base_id(
    design::OOSStructuralDesignConfig,
    normalized_file::AbstractString,
    regime::DemandRegime,
    structural_draw::Int,
    uncertainty::UncertaintyLevel,
    assignment_id::AbstractString,
)
    identifier = base_instance_id(normalized_file)
    digest = _digest_prefix(vcat(Any[
        OOS_STRUCTURAL_ID_ALGORITHM, "paired_base",
        design.experiment_seed, String(normalized_file), identifier,
        structural_draw, string(regime), String(assignment_id),
        string(uncertainty), uncertainty_theta(design, uncertainty),
    ], _fixed_design_tokens(design)))
    return string("PB-", identifier, "-d", structural_draw, "-",
                  demand_regime_code(regime), "-", uncertainty_level_code(uncertainty), "-", digest)
end

"""
`StructuralInstanceID`: the complete structural instance, battery level included.

Included: the `PairedBaseID` plus the battery level and its scale. Unique across the catalog.
"""
function structural_instance_id(
    design::OOSStructuralDesignConfig,
    normalized_file::AbstractString,
    regime::DemandRegime,
    structural_draw::Int,
    uncertainty::UncertaintyLevel,
    battery::BatteryLevel,
    pairing_id::AbstractString,
)
    identifier = base_instance_id(normalized_file)
    digest = _digest_prefix(Any[
        OOS_STRUCTURAL_ID_ALGORITHM, "structural_instance",
        String(pairing_id), string(battery), battery_scale(design, battery),
    ])
    return string("SI-", identifier, "-d", structural_draw, "-",
                  demand_regime_code(regime), "-", uncertainty_level_code(uncertainty), "-",
                  battery_level_code(battery), "-", digest)
end

# -------------------------------------------------------------------------------------
# Catalog records
# -------------------------------------------------------------------------------------

"""
One resolved household composition, shared by the four (battery x uncertainty) variants of a cell.
"""
struct OOSDemandAssignment
    demand_assignment_id::String
    base_instance_id::String
    base_instance_file::String
    demand_regime::DemandRegime
    structural_draw::Int
    assignment_seed::Int
    household_profiles::Vector{String}
    profile_counts::Vector{Int}
end

"""
Identity and factor levels of one structural instance, before materialization.

Self-contained on purpose: every parameter needed to rematerialize the instance is present, so a
saved manifest row can be re-run without consulting the design object that produced it.
"""
struct OOSStructuralInstanceSpec
    structural_instance_id::String
    paired_base_id::String
    demand_assignment_id::String
    deterministic_data_id::String
    base_instance_id::String
    base_instance_file::String
    structural_draw::Int
    battery_level::BatteryLevel
    battery_scale::Float64
    demand_regime::DemandRegime
    uncertainty_level::UncertaintyLevel
    theta::Float64
    household_profiles::Vector{String}
    assignment_seed::Int
    # Counterfactual seed of the unchanged legacy default path. Retained so Stage-2 manifests and
    # audits remain interpretable; the Stage-3 structural materializer does NOT use it.
    repository_instance_seed::Int
    # Actual seed passed through `repository_seed_override` to `generateInstance`.
    actual_repository_generator_seed::Int
    # Fixed primary-design parameters, repeated so the record stands alone.
    households::Int
    avg_demand::Float64
    dev_demand::Float64
    pv_scale::Float64
    in_sample_stages::Int
    in_sample_children::Int
    in_sample_periods_per_stage::Int
    repository_demand_profile::String
end

"""Physical parameters resolved by the repository pipeline for one structural instance."""
struct OOSResolvedInstanceParameters
    repository_instance_id::String
    repository_instance_horizon::Int          # template.T, in abstract model periods
    delta::Float64                            # instance period length; no clock unit attached
    s_min::Float64
    s_max::Float64
    s_I::Float64
    f_under::Float64
    f_bar::Float64
    e_c::Float64
    e_d::Float64
    mu::Float64
    beta::Float64
end

# Stage-2 compatibility only: the old ten-argument record did not carry the grid exchange
# coefficients. Keep construction source-compatible while making the missing values explicit;
# Stage-3 materialization below always records the repository's finite `mu` and `beta` values.
OOSResolvedInstanceParameters(
    repository_instance_id::String,
    repository_instance_horizon::Int,
    delta::Float64,
    s_min::Float64,
    s_max::Float64,
    s_I::Float64,
    f_under::Float64,
    f_bar::Float64,
    e_c::Float64,
    e_d::Float64,
) = OOSResolvedInstanceParameters(
    repository_instance_id,
    repository_instance_horizon,
    delta,
    s_min,
    s_max,
    s_I,
    f_under,
    f_bar,
    e_c,
    e_d,
    NaN,
    NaN,
)

"""One complete catalog row: identity, factor levels and resolved physical parameters."""
struct OOSStructuralInstanceRecord
    ordinal::Int
    spec::OOSStructuralInstanceSpec
    resolved::OOSResolvedInstanceParameters
    period_data_support_summary::Dict{String,Any}
end

# Additive Stage-3 field: callers that only need the Stage-2 identity/physics record keep their
# three-argument construction contract. A generated Stage-3 catalog always fills the summary.
OOSStructuralInstanceRecord(
    ordinal::Int,
    spec::OOSStructuralInstanceSpec,
    resolved::OOSResolvedInstanceParameters,
) = OOSStructuralInstanceRecord(ordinal, spec, resolved, Dict{String,Any}())

"""The seed key of a record, with battery level and numeric theta structurally dropped."""
oos_path_seed_key(spec::OOSStructuralInstanceSpec, experiment_seed::Int) = OOSPathSeedKey(
    experiment_seed, spec.base_instance_id, spec.demand_assignment_id,
    spec.demand_regime, spec.structural_draw, spec.uncertainty_level,
)

oos_path_seed_key(design::OOSStructuralDesignConfig, spec::OOSStructuralInstanceSpec) =
    oos_path_seed_key(spec, design.experiment_seed)

oos_path_seed_key(design::OOSStructuralDesignConfig, record::OOSStructuralInstanceRecord) =
    oos_path_seed_key(design, record.spec)

# -------------------------------------------------------------------------------------
# Catalog construction
# -------------------------------------------------------------------------------------

"""
Resolve every unique household assignment of a design, in canonical order.

Canonical order: base instance, then structural draw, then demand regime. One assignment per
`(base instance, regime, draw)` cell, reused by all four battery/uncertainty variants.
"""
function structural_demand_assignments(design::OOSStructuralDesignConfig)
    assignments = OOSDemandAssignment[]
    for file in design.base_instance_files,
        draw in 1:design.structural_draws_per_cell,
        regime in OOS_DEMAND_REGIME_ORDER

        identifier = base_instance_id(file)
        seed = structural_assignment_seed(design, identifier, regime, draw)
        profiles = structural_demand_assignment(design.households, regime, seed)
        counts = validate_structural_assignment(profiles, regime, design.households)
        push!(assignments, OOSDemandAssignment(
            demand_assignment_id(design, file, regime, draw, profiles),
            identifier, file, regime, draw, seed, profiles, counts,
        ))
    end
    return assignments
end

"""
Every structural-instance specification of a design, in the canonical order

    base instance, structural draw, demand regime, uncertainty level, battery level.

Pure and cheap: no instance is materialized and no file is read, so identity, pairing and seed
properties can be tested without invoking the solver-facing pipeline.
"""
function structural_instance_specs(design::OOSStructuralDesignConfig)
    lookup = Dict{Tuple{String,DemandRegime,Int},OOSDemandAssignment}()
    for assignment in structural_demand_assignments(design)
        lookup[(assignment.base_instance_file, assignment.demand_regime,
                assignment.structural_draw)] = assignment
    end

    specs = OOSStructuralInstanceSpec[]
    for file in design.base_instance_files,
        draw in 1:design.structural_draws_per_cell,
        regime in OOS_DEMAND_REGIME_ORDER,
        uncertainty in OOS_UNCERTAINTY_LEVEL_ORDER,
        battery in OOS_BATTERY_LEVEL_ORDER

        assignment = lookup[(file, regime, draw)]
        deterministic_key = deterministic_base_key(design, file, draw)
        data_id = deterministic_data_id(deterministic_key)
        generator_seed = actual_repository_generator_seed(deterministic_key)
        theta = uncertainty_theta(design, uncertainty)
        pairing = paired_base_id(
            design, file, regime, draw, uncertainty, assignment.demand_assignment_id,
        )
        push!(specs, OOSStructuralInstanceSpec(
            structural_instance_id(design, file, regime, draw, uncertainty, battery, pairing),
            pairing, assignment.demand_assignment_id, data_id, base_instance_id(file), file, draw,
            battery, battery_scale(design, battery), regime, uncertainty, theta,
            copy(assignment.household_profiles), assignment.assignment_seed,
            repository_instance_seed(design, file, theta),
            generator_seed,
            design.households, design.avg_demand, design.dev_demand, design.pv_scale,
            design.in_sample_stages, design.in_sample_children,
            design.in_sample_periods_per_stage, design.repository_demand_profile,
        ))
    end
    return specs
end

# -------------------------------------------------------------------------------------
# Materialization
# -------------------------------------------------------------------------------------

"""
Derive the single-instance `OOSExperimentConfig` of one structural instance.

Every field of `base_config` is preserved except the ones the structural design owns. The result
goes through the ordinary keyword constructor, so it is validated exactly like any hand-written
campaign configuration.
"""
function structural_experiment_config(
    base_config::OOSExperimentConfig,
    spec::OOSStructuralInstanceSpec,
)
    overrides = Dict{Symbol,Any}(
        field => getfield(base_config, field) for field in fieldnames(OOSExperimentConfig)
    )
    overrides[:instance_file] = absolute_base_instance_file(spec.base_instance_file)
    overrides[:households] = spec.households
    overrides[:theta] = spec.theta
    overrides[:avg_demand] = spec.avg_demand
    overrides[:dev_demand] = spec.dev_demand
    overrides[:pv_scale] = spec.pv_scale
    overrides[:battery_scale] = spec.battery_scale
    overrides[:demand_profile] = spec.repository_demand_profile
    overrides[:in_sample_stages] = spec.in_sample_stages
    overrides[:in_sample_children] = spec.in_sample_children
    overrides[:in_sample_periods_per_stage] = spec.in_sample_periods_per_stage
    return OOSExperimentConfig(; overrides...)
end

"""
Materialize one structural instance through the repository's verified pipeline.

Steps, in order:

  1. derive the single-instance configuration of this structural cell;
  2. call `generateInstance` with the spec's explicit, uncertainty-independent repository seed
     override and call `scaleInstance!` via the existing `build_instance_template`, which applies
     the selected `battery_scale` and `theta`;
  3. inject the catalog's FIXED household assignment — no profile is re-sampled here;
  4. materialize pure deterministic/exogenous data through `required_period_support_end`; and
  5. read back the resolved physical battery parameters and period-data summary.

Returns the `OOSInstanceTemplate` accepted by the existing physical-model builder, the resolved
parameters, the derived configuration, and the legacy in-sample tree.

The returned tree is named `legacy_in_sample_tree` deliberately: it is the repository's
calibration object, not the conditional scenario support a rolling-horizon controller uses.

MUST BE CALLED SEQUENTIALLY. `generateInstance` reseeds the *global*, task-local RNG and draws
from it, so materializing the catalog across Julia tasks or threads would give each task its own
stream and destroy reproducibility. Every result here is nonetheless order-independent, because
that reseeding happens at the top of each call.
"""
_default_structural_period_support_end(config::OOSExperimentConfig) =
    required_period_support_end(config)

function materialize_structural_instance(
    base_config::OOSExperimentConfig,
    spec::OOSStructuralInstanceSpec,
    ;
    required_period_support_end::Int=_default_structural_period_support_end(base_config),
)
    required_period_support_end >= 1 || error(
        "required_period_support_end debe ser >= 1; se recibió " *
        "$required_period_support_end."
    )
    config = structural_experiment_config(base_config, spec)
    absolute = absolute_base_instance_file(spec.base_instance_file)
    isfile(absolute) || error("No existe el archivo de instancia base: $absolute")

    bundle = build_instance_template(
        config;
        household_profiles=spec.household_profiles,
        repository_seed_override=spec.actual_repository_generator_seed,
    )
    bundle.actual_repository_generator_seed == spec.actual_repository_generator_seed || error(
        "La materialización de $(spec.structural_instance_id) usó la semilla de repositorio " *
        "$(bundle.actual_repository_generator_seed), distinta de la registrada " *
        "$(spec.actual_repository_generator_seed)."
    )
    template = bundle.template
    period_support = build_period_data_support(template, required_period_support_end)
    support_summary = period_data_support_summary(period_support)

    length(template.demand_models) == length(spec.household_profiles) || error(
        "La materialización produjo $(length(template.demand_models)) modelos de demanda y la " *
        "asignación fija tiene $(length(spec.household_profiles))."
    )
    for (index, model) in enumerate(template.demand_models)
        model.profile == spec.household_profiles[index] || error(
            "La materialización re-muestreó el perfil del hogar $index: " *
            "$(model.profile) en lugar de $(spec.household_profiles[index])."
        )
    end

    resolved = OOSResolvedInstanceParameters(
        template.id, template.T, template.delta,
        template.s_min, template.s_max, template.s_I,
        template.f_under, template.f_bar, template.e_c, template.e_d,
        template.mu, template.beta,
    )
    return (
        template=template,
        resolved=resolved,
        config=config,
        legacy_in_sample_tree=bundle.in_sample_tree,
        period_data_support=period_support,
        period_data_support_summary=support_summary,
        actual_repository_generator_seed=bundle.actual_repository_generator_seed,
    )
end

# -------------------------------------------------------------------------------------
# Deterministic-base and factor-isolation checks
# -------------------------------------------------------------------------------------

_demand_model_signature(model::OOSHouseholdDemandModel) = (
    model.household,
    model.profile,
    model.active_periods,
    model.avg,
    model.dev,
)

_demand_model_signatures(models::AbstractVector{OOSHouseholdDemandModel}) =
    [_demand_model_signature(model) for model in models]

_full_physical_signature(template::OOSInstanceTemplate) = (
    template.id,
    template.J,
    template.T,
    template.delta,
    template.e_c,
    template.e_d,
    template.s_I,
    template.s_min,
    template.s_max,
    template.f_under,
    template.f_bar,
    template.mu,
    template.beta,
)

_nonbattery_physical_signature(template::OOSInstanceTemplate) = (
    template.id,
    template.J,
    template.T,
    template.delta,
    template.e_c,
    template.e_d,
    template.s_I,
    template.s_min,
    template.mu,
    template.beta,
)

_resolved_battery_signature(template::OOSInstanceTemplate) = (
    template.s_min,
    template.s_max,
    template.s_I,
    template.f_under,
    template.f_bar,
)

function _require_exact_match(context::AbstractString, field::AbstractString, left, right)
    left == right || error(
        "Aislamiento estructural incumplido en $context: `$field` difiere entre variantes."
    )
    return nothing
end

"""Compare the deterministic period-data block, optionally including assigned demand activity."""
function _require_same_period_data(
    context::AbstractString,
    left::OOSPeriodDataSupport,
    right::OOSPeriodDataSupport;
    include_demand_activity::Bool,
)
    for field in (
        :repository_instance_horizon,
        :required_period_support_end,
        :materialized_data_end,
        :households,
        :period_mapping_name,
        :period_mapping_version,
        :period_mapping_formula,
        :nu,
        :pv_det,
    )
        _require_exact_match(context, string(field), getfield(left, field), getfield(right, field))
    end
    if include_demand_activity
        _require_exact_match(
            context,
            "demand_models",
            _demand_model_signatures(left.demand_models),
            _demand_model_signatures(right.demand_models),
        )
        _require_exact_match(
            context,
            "demand_activity",
            period_demand_activity(left),
            period_demand_activity(right),
        )
    end
    return nothing
end

function _require_same_base_deterministic_data(context::AbstractString, left, right)
    _require_exact_match(context, "template.nu", left.template.nu, right.template.nu)
    _require_exact_match(context, "template.pv_det", left.template.pv_det, right.template.pv_det)
    _require_same_period_data(
        context, left.period_data_support, right.period_data_support;
        include_demand_activity=false,
    )
    return nothing
end

function _require_uncertainty_isolation(design, reference, candidate)
    left = reference.spec
    right = candidate.spec
    context = string(
        "base=", left.base_instance_id,
        ", draw=", left.structural_draw,
        ", regime=", left.demand_regime,
        ", battery=", left.battery_level,
        ", uncertainty ", left.uncertainty_level, " vs ", right.uncertainty_level,
    )
    left.uncertainty_level != right.uncertainty_level || error(
        "La comparación de aislamiento repitió $(left.uncertainty_level) en $context."
    )
    left.theta != right.theta || error(
        "Los niveles de incertidumbre de $context deben conservar theta distintos."
    )
    for field in (
        :deterministic_data_id,
        :actual_repository_generator_seed,
        :base_instance_id,
        :base_instance_file,
        :structural_draw,
        :battery_level,
        :battery_scale,
        :demand_regime,
        :demand_assignment_id,
        :assignment_seed,
        :household_profiles,
        :households,
        :avg_demand,
        :dev_demand,
        :pv_scale,
        :in_sample_stages,
        :in_sample_children,
        :in_sample_periods_per_stage,
        :repository_demand_profile,
    )
        _require_exact_match(context, string(field), getfield(left, field), getfield(right, field))
    end
    _require_exact_match(
        context,
        "physical_parameters",
        _full_physical_signature(reference.template),
        _full_physical_signature(candidate.template),
    )
    _require_same_base_deterministic_data(context, reference, candidate)
    _require_same_period_data(
        context, reference.period_data_support, candidate.period_data_support;
        include_demand_activity=true,
    )

    left_seed_key = oos_path_seed_key(design, left)
    right_seed_key = oos_path_seed_key(design, right)
    structural_oos_path_seed(left_seed_key, 1) !=
        structural_oos_path_seed(right_seed_key, 1) || error(
        "Los niveles de incertidumbre de $context comparten indebidamente la semilla OOS."
    )
    start = first(rolling_iteration_starts(design))
    conditional_support_seed(left_seed_key, 1, start) !=
        conditional_support_seed(right_seed_key, 1, start) || error(
        "Los niveles de incertidumbre de $context comparten indebidamente la semilla de soporte."
    )
    return nothing
end

function _require_battery_isolation(design, reference, candidate)
    left = reference.spec
    right = candidate.spec
    context = string(
        "base=", left.base_instance_id,
        ", draw=", left.structural_draw,
        ", regime=", left.demand_regime,
        ", uncertainty=", left.uncertainty_level,
        ", battery ", left.battery_level, " vs ", right.battery_level,
    )
    left.battery_level != right.battery_level || error(
        "La comparación de batería repitió $(left.battery_level) en $context."
    )
    left.battery_scale != right.battery_scale || error(
        "Los niveles de batería de $context deben conservar escalas distintas."
    )
    for field in (
        :paired_base_id,
        :demand_assignment_id,
        :deterministic_data_id,
        :actual_repository_generator_seed,
        :base_instance_id,
        :base_instance_file,
        :structural_draw,
        :demand_regime,
        :uncertainty_level,
        :theta,
        :household_profiles,
        :assignment_seed,
        :households,
        :avg_demand,
        :dev_demand,
        :pv_scale,
        :in_sample_stages,
        :in_sample_children,
        :in_sample_periods_per_stage,
        :repository_demand_profile,
    )
        _require_exact_match(context, string(field), getfield(left, field), getfield(right, field))
    end
    _require_exact_match(
        context,
        "nonbattery_physical_parameters",
        _nonbattery_physical_signature(reference.template),
        _nonbattery_physical_signature(candidate.template),
    )
    _resolved_battery_signature(reference.template) !=
        _resolved_battery_signature(candidate.template) || error(
        "Los niveles de batería de $context no producen vectores físicos distintos."
    )
    _require_same_base_deterministic_data(context, reference, candidate)
    _require_same_period_data(
        context, reference.period_data_support, candidate.period_data_support;
        include_demand_activity=true,
    )
    left.actual_repository_generator_seed == right.actual_repository_generator_seed || error(
        "La semilla determinista depende del nivel de batería en $context."
    )
    oos_path_seed_key(design, left) == oos_path_seed_key(design, right) || error(
        "La clave OOS Stage-2 depende del nivel de batería en $context."
    )
    return nothing
end

function _require_demand_regime_isolation(reference, candidate)
    left = reference.spec
    right = candidate.spec
    context = string(
        "base=", left.base_instance_id,
        ", draw=", left.structural_draw,
        ", battery=", left.battery_level,
        ", uncertainty=", left.uncertainty_level,
        ", regime ", left.demand_regime, " vs ", right.demand_regime,
    )
    left.demand_regime != right.demand_regime || error(
        "La comparación de regímenes repitió $(left.demand_regime) en $context."
    )
    left.demand_assignment_id != right.demand_assignment_id || error(
        "Los regímenes de $context comparten indebidamente DemandAssignmentID."
    )
    for field in (
        :deterministic_data_id,
        :actual_repository_generator_seed,
        :base_instance_id,
        :base_instance_file,
        :structural_draw,
        :battery_level,
        :battery_scale,
        :uncertainty_level,
        :theta,
        :households,
        :avg_demand,
        :dev_demand,
        :pv_scale,
        :in_sample_stages,
        :in_sample_children,
        :in_sample_periods_per_stage,
        :repository_demand_profile,
    )
        _require_exact_match(context, string(field), getfield(left, field), getfield(right, field))
    end
    _require_exact_match(
        context,
        "physical_parameters",
        _full_physical_signature(reference.template),
        _full_physical_signature(candidate.template),
    )
    _require_same_base_deterministic_data(context, reference, candidate)
    left.actual_repository_generator_seed == right.actual_repository_generator_seed || error(
        "La semilla determinista depende del régimen de demanda en $context."
    )
    return nothing
end

"""
Non-blocking advisories about the repository's battery-scaling rule.

`scaleInstance!` applies `s_max *= scale` but `f_under *= scale * 4` and `f_bar *= scale * 4`, and
it does nothing at all when `scale == 1.0`. Two consequences a calibration probe must know:

  * the capacity and the rate limits do not scale together — the rate limits move four times as
    fast, so a "low battery" below `scale = 0.25` ends up with a LARGER rate limit than the
    repository default;
  * `scale = 1.0` is a discontinuity: it leaves `f_under = f_bar = 4.0`, whereas the scaling curve
    would give `16.0` there. A level placed exactly at `1.0` is therefore off-curve relative to
    every other level.

These are properties of the verified repository pipeline, not defects introduced here, and
correcting them would mean editing that pipeline — out of scope. Stage 12 calibrates the levels;
these advisories exist so the trap is visible before then rather than after.
"""
function battery_scale_calibration_advisories(design::OOSStructuralDesignConfig)
    advisories = String[]
    for level in OOS_BATTERY_LEVEL_ORDER
        scale = battery_scale(design, level)
        if scale == 1.0
            push!(advisories,
                "$level usa battery_scale=1.0, valor en el que scaleInstance! no escala nada: " *
                "conserva f_under=f_bar=4.0 en lugar del 16.0 que daría la curva. Ese nivel " *
                "queda fuera de la curva frente a los demás.")
        end
    end
    low = battery_scale(design, LOW_BATTERY)
    high = battery_scale(design, HIGH_BATTERY)
    push!(advisories,
        "La regla del repositorio escala la capacidad con `scale` y los límites de potencia con " *
        "`scale*4`: capacidad y potencia NO se mueven juntas. Con LOW=$low y HIGH=$high los " *
        "límites agregados resultantes son " *
        "$(low == 1.0 ? 4.0 : 4.0 * low * 4) y $(high == 1.0 ? 4.0 : 4.0 * high * 4). " *
        "Los valores numéricos siguen provisionales hasta la calibración de la etapa 12.")
    return advisories
end

function _require_complete_two_level_groups(
    label::AbstractString,
    counts::AbstractDict,
    expected_structural_instances::Int,
)
    expected_groups = div(expected_structural_instances, 2)
    length(counts) == expected_groups || error(
        "El catálogo produjo $(length(counts)) grupos de $label y se esperaban " *
        "$expected_groups."
    )
    all(count -> count == 2, values(counts)) || error(
        "Cada grupo de $label debe contener exactamente dos niveles."
    )
    return nothing
end

"""
Build the complete structural catalog, materializing every instance.

The order is the canonical one, and `ordinal` is the position in that order. Materialization is
what supplies the resolved battery parameters the manifest records, so the manifest can never
claim a physical value the approved pipeline would not produce.

Built sequentially by design; see `materialize_structural_instance`.
"""
function build_structural_catalog(
    base_config::OOSExperimentConfig,
    design::OOSStructuralDesignConfig;
    verbose::Bool=false,
)
    verbose && for advisory in battery_scale_calibration_advisories(design)
        println("AVISO: ", advisory)
    end
    specs = structural_instance_specs(design)
    expected = expected_structural_instance_count(design)
    length(specs) == expected || error(
        "El catálogo produjo $(length(specs)) especificaciones y se esperaban $expected."
    )

    # `generateInstance` touches the task-local default RNG, so this loop deliberately remains
    # sequential. The dictionaries are validation indexes only; they never drive materialization
    # order or data generation.
    support_end = required_period_support_end(design)
    records = OOSStructuralInstanceRecord[]
    deterministic_references = Dict{String,Any}()
    deterministic_counts = Dict{String,Int}()
    deterministic_seeds = Dict{String,Int}()
    data_id_by_coordinate = Dict{Tuple{String,Int},String}()
    coordinate_by_data_id = Dict{String,Tuple{String,Int}}()

    uncertainty_references =
        Dict{Tuple{String,Int,DemandRegime,BatteryLevel},Any}()
    uncertainty_counts =
        Dict{Tuple{String,Int,DemandRegime,BatteryLevel},Int}()
    battery_references =
        Dict{Tuple{String,Int,DemandRegime,UncertaintyLevel},Any}()
    battery_counts =
        Dict{Tuple{String,Int,DemandRegime,UncertaintyLevel},Int}()
    demand_regime_references =
        Dict{Tuple{String,Int,BatteryLevel,UncertaintyLevel},Any}()
    demand_regime_counts =
        Dict{Tuple{String,Int,BatteryLevel,UncertaintyLevel},Int}()

    for (ordinal, spec) in enumerate(specs)
        materialized = materialize_structural_instance(
            base_config,
            spec;
            required_period_support_end=support_end,
        )
        summary = materialized.period_data_support_summary
        isempty(summary) && error(
            "La materialización de $(spec.structural_instance_id) produjo un resumen de " *
            "soporte vacío."
        )
        observed_support_end = summary["required_period_support_end"]
        observed_support_end == support_end || error(
            "La materialización de $(spec.structural_instance_id) terminó en " *
            "$observed_support_end; el diseño requiere $support_end."
        )
        haskey(summary, "digests") && !isempty(summary["digests"]) || error(
            "La materialización de $(spec.structural_instance_id) no produjo digests de datos."
        )

        snapshot = (
            spec=spec,
            template=materialized.template,
            period_data_support=materialized.period_data_support,
        )

        # Exactly one deterministic data block per (normalized base, structural draw), shared by
        # all 2 x 2 x 2 experimental factor variants.
        coordinate = (spec.base_instance_file, spec.structural_draw)
        if haskey(data_id_by_coordinate, coordinate)
            data_id_by_coordinate[coordinate] == spec.deterministic_data_id || error(
                "La celda $coordinate recibió más de un DeterministicDataID."
            )
        else
            data_id_by_coordinate[coordinate] = spec.deterministic_data_id
        end
        if haskey(coordinate_by_data_id, spec.deterministic_data_id)
            coordinate_by_data_id[spec.deterministic_data_id] == coordinate || error(
                "$(spec.deterministic_data_id) identifica más de una celda base/draw."
            )
        else
            coordinate_by_data_id[spec.deterministic_data_id] = coordinate
        end
        deterministic_counts[spec.deterministic_data_id] =
            get(deterministic_counts, spec.deterministic_data_id, 0) + 1
        if haskey(deterministic_references, spec.deterministic_data_id)
            deterministic_seeds[spec.deterministic_data_id] ==
                spec.actual_repository_generator_seed || error(
                "$(spec.deterministic_data_id) usa más de una semilla real del generador."
            )
            _require_same_base_deterministic_data(
                spec.deterministic_data_id,
                deterministic_references[spec.deterministic_data_id],
                snapshot,
            )
        else
            deterministic_references[spec.deterministic_data_id] = snapshot
            deterministic_seeds[spec.deterministic_data_id] =
                spec.actual_repository_generator_seed
        end

        # Every two-level comparison is checked on the materialized values, not inferred merely
        # from the seed contract.
        uncertainty_key = (
            spec.base_instance_file,
            spec.structural_draw,
            spec.demand_regime,
            spec.battery_level,
        )
        uncertainty_counts[uncertainty_key] =
            get(uncertainty_counts, uncertainty_key, 0) + 1
        if haskey(uncertainty_references, uncertainty_key)
            _require_uncertainty_isolation(
                design,
                uncertainty_references[uncertainty_key],
                snapshot,
            )
        else
            uncertainty_references[uncertainty_key] = snapshot
        end

        battery_key = (
            spec.base_instance_file,
            spec.structural_draw,
            spec.demand_regime,
            spec.uncertainty_level,
        )
        battery_counts[battery_key] = get(battery_counts, battery_key, 0) + 1
        if haskey(battery_references, battery_key)
            _require_battery_isolation(
                design,
                battery_references[battery_key],
                snapshot,
            )
        else
            battery_references[battery_key] = snapshot
        end

        demand_regime_key = (
            spec.base_instance_file,
            spec.structural_draw,
            spec.battery_level,
            spec.uncertainty_level,
        )
        demand_regime_counts[demand_regime_key] =
            get(demand_regime_counts, demand_regime_key, 0) + 1
        if haskey(demand_regime_references, demand_regime_key)
            _require_demand_regime_isolation(
                demand_regime_references[demand_regime_key],
                snapshot,
            )
        else
            demand_regime_references[demand_regime_key] = snapshot
        end

        push!(records, OOSStructuralInstanceRecord(
            ordinal,
            spec,
            materialized.resolved,
            deepcopy(summary),
        ))
        verbose && println(
            "  [", ordinal, "/", expected, "] ", spec.structural_instance_id,
            " : deterministic_data_id=", spec.deterministic_data_id,
            ", s_max=", materialized.resolved.s_max,
            ", f_under=", materialized.resolved.f_under,
            ", f_bar=", materialized.resolved.f_bar,
            ", theta=", spec.theta,
        )
    end

    expected_data_blocks = expected_deterministic_data_count(design)
    length(deterministic_references) == expected_data_blocks || error(
        "El catálogo produjo $(length(deterministic_references)) bloques deterministas y se " *
        "esperaban $expected_data_blocks."
    )
    length(data_id_by_coordinate) == expected_data_blocks || error(
        "No hay una correspondencia uno-a-uno entre celdas base/draw y datos deterministas."
    )
    variants_per_data_block =
        length(OOS_BATTERY_LEVEL_ORDER) *
        length(OOS_DEMAND_REGIME_ORDER) *
        length(OOS_UNCERTAINTY_LEVEL_ORDER)
    all(count -> count == variants_per_data_block, values(deterministic_counts)) || error(
        "Cada DeterministicDataID debe compartirse por exactamente " *
        "$variants_per_data_block variantes estructurales."
    )
    _require_complete_two_level_groups("incertidumbre", uncertainty_counts, expected)
    _require_complete_two_level_groups("batería", battery_counts, expected)
    _require_complete_two_level_groups("régimen de demanda", demand_regime_counts, expected)
    return records
end
