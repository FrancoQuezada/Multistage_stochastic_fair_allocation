# =====================================================================================
# Pure extended abstract-period data support (OOS redesign stage 3).
#
# The repository instance horizon T0 remains the base deterministic profile.  A rolling
# configuration can require exogenous data after T0, so this layer materializes prices, the
# deterministic PV reference and the already-resolved household activity through a separate
# support endpoint.  Every repeated lookup uses `base_period_index`; no consumer carries its own
# modular arithmetic.
#
# A period is an ABSTRACT MODEL PERIOD. Repeating the repository profile does not attach a
# clock-time interpretation to it, and `template.delta` is neither read nor transformed here.
#
# All builders are pure and allocate fresh arrays. There is no cache, RNG, filesystem access or
# worker-dependent state in this file.
# =====================================================================================

const OOS_PERIOD_MAPPING_NAME = "repository_base_period_repeat"
const OOS_PERIOD_MAPPING_VERSION = "base_period_index_v1"
const OOS_PERIOD_MAPPING_FORMULA =
    "1 + ((period - 1) mod repository_instance_horizon)"

"""
Map a positive abstract period to its one-based repository-profile position.

This is the sole period-repetition arithmetic used by the OOS data layer:

    kappa(period; T0) = 1 + ((period - 1) mod T0).
"""
function base_period_index(period::Int, base_horizon::Int)::Int
    period >= 1 || error(
        "El período abstracto debe ser >= 1; se recibió $period."
    )
    base_horizon >= 1 || error(
        "El horizonte base del repositorio debe ser >= 1; se recibió $base_horizon."
    )
    return mod1(period, base_horizon)
end

"""Deep copy one resolved household demand model."""
_copy_oos_demand_model(model::OOSHouseholdDemandModel) = OOSHouseholdDemandModel(
    model.household,
    String(model.profile),
    collect(model.active_periods),
    model.avg,
    model.dev,
)

function _validate_resolved_demand_models(
    models::AbstractVector{OOSHouseholdDemandModel},
    households::Int,
    period_end::Int,
)
    length(models) == households || error(
        "Se requieren $households modelos de demanda resueltos; se recibieron $(length(models))."
    )
    seen = falses(households)
    for model in models
        1 <= model.household <= households || error(
            "El modelo de demanda declara el hogar $(model.household), fuera de 1:$households."
        )
        seen[model.household] && error(
            "Hay más de un modelo de demanda para el hogar $(model.household)."
        )
        seen[model.household] = true
        isempty(strip(model.profile)) && error(
            "El perfil de demanda del hogar $(model.household) no puede estar vacío."
        )
        isfinite(model.avg) || error(
            "La demanda media del hogar $(model.household) no es finita: $(model.avg)."
        )
        isfinite(model.dev) || error(
            "La desviación de demanda del hogar $(model.household) no es finita: $(model.dev)."
        )
        model.dev >= 0 || error(
            "La desviación de demanda del hogar $(model.household) debe ser >= 0."
        )
        issorted(model.active_periods) || error(
            "Los períodos activos del hogar $(model.household) deben estar ordenados."
        )
        length(unique(model.active_periods)) == length(model.active_periods) || error(
            "Los períodos activos del hogar $(model.household) contienen duplicados."
        )
        all(period -> 1 <= period <= period_end, model.active_periods) || error(
            "Los períodos activos del hogar $(model.household) deben pertenecer a 1:$period_end."
        )
    end
    all(seen) || error("Falta al menos un modelo de demanda en 1:$households.")
    return nothing
end

"""Validate exact repetition of every extended deterministic/activity value."""
function _validate_period_repetition(
    nu::AbstractMatrix{<:Real},
    pv_det::AbstractVector{<:Real},
    demand_models::AbstractVector{OOSHouseholdDemandModel},
    repository_instance_horizon::Int,
    materialized_data_end::Int,
)
    materialized_data_end <= repository_instance_horizon && return nothing
    activity_sets = Dict(
        model.household => Set(model.active_periods) for model in demand_models
    )
    for period in (repository_instance_horizon + 1):materialized_data_end
        base = base_period_index(period, repository_instance_horizon)
        @views nu[:, period] == nu[:, base] || error(
            "El precio extendido del período $period no repite exactamente el período base " *
            "$base."
        )
        pv_det[period] == pv_det[base] || error(
            "El PV determinista del período $period no repite exactamente el período base " *
            "$base."
        )
        for model in demand_models
            activity = activity_sets[model.household]
            ((period in activity) == (base in activity)) || error(
                "La actividad extendida del hogar $(model.household) en el período $period " *
                "no repite el período base $base."
            )
        end
    end
    return nothing
end

"""
Immutable contract for deterministic and exogenous data over an extended abstract-period range.

`repository_instance_horizon` is T0, the unchanged repository horizon.
`required_period_support_end` is the endpoint required by the rolling temporal contract.
`materialized_data_end` is `max(T0, required_period_support_end)`, so the complete repository
profile is retained even when a smaller support endpoint is requested.

The struct is immutable and its constructor defensively copies every nested array. Callers must
treat those task-local arrays as read-only inputs; no controller or fairness rule mutates them.
"""
struct OOSPeriodDataSupport
    repository_instance_horizon::Int
    required_period_support_end::Int
    materialized_data_end::Int
    households::Int
    period_mapping_name::String
    period_mapping_version::String
    period_mapping_formula::String
    nu::Matrix{Float64}
    pv_det::Vector{Float64}
    demand_models::Vector{OOSHouseholdDemandModel}

    function OOSPeriodDataSupport(
        repository_instance_horizon::Int,
        required_period_support_end::Int,
        materialized_data_end::Int,
        households::Int,
        nu::AbstractMatrix{<:Real},
        pv_det::AbstractVector{<:Real},
        demand_models::AbstractVector{OOSHouseholdDemandModel},
    )
        repository_instance_horizon >= 1 || error(
            "El horizonte de instancia del repositorio debe ser >= 1."
        )
        required_period_support_end >= 1 || error(
            "El extremo de soporte requerido debe ser >= 1."
        )
        expected_data_end = max(repository_instance_horizon, required_period_support_end)
        materialized_data_end == expected_data_end || error(
            "materialized_data_end=$materialized_data_end; se esperaba $expected_data_end " *
            "a partir de T0=$repository_instance_horizon y soporte=$required_period_support_end."
        )
        households >= 1 || error("Se requiere al menos un hogar.")
        size(nu) == (households, materialized_data_end) || error(
            "La matriz de precios extendida tiene dimensión $(size(nu)); se esperaba " *
            "($households, $materialized_data_end)."
        )
        length(pv_det) == materialized_data_end || error(
            "El PV determinista extendido tiene $(length(pv_det)) períodos; se esperaban " *
            "$materialized_data_end."
        )
        all(isfinite, nu) || error("La matriz de precios extendida contiene valores no finitos.")
        all(isfinite, pv_det) || error("El PV determinista extendido contiene valores no finitos.")
        _validate_resolved_demand_models(demand_models, households, materialized_data_end)
        _validate_period_repetition(
            nu,
            pv_det,
            demand_models,
            repository_instance_horizon,
            materialized_data_end,
        )

        ordered_models = Vector{OOSHouseholdDemandModel}(undef, households)
        for model in demand_models
            ordered_models[model.household] = _copy_oos_demand_model(model)
        end
        return new(
            repository_instance_horizon,
            required_period_support_end,
            materialized_data_end,
            households,
            OOS_PERIOD_MAPPING_NAME,
            OOS_PERIOD_MAPPING_VERSION,
            OOS_PERIOD_MAPPING_FORMULA,
            Matrix{Float64}(nu),
            Float64.(collect(pv_det)),
            ordered_models,
        )
    end
end

"""
Revalidate a support object at a consumer boundary.

Although the container itself is immutable, Julia arrays are mutable. Scientific callers treat
its nested values as task-local read-only data; this check also prevents a mutated or manually
forged support from entering a provider unnoticed.
"""
function validate_period_data_support(support::OOSPeriodDataSupport)
    T0 = support.repository_instance_horizon
    required_end = support.required_period_support_end
    data_end = support.materialized_data_end
    T0 >= 1 || error("El horizonte base del soporte debe ser >= 1.")
    required_end >= 1 || error("El extremo de soporte requerido debe ser >= 1.")
    data_end == max(T0, required_end) || error(
        "El extremo materializado no coincide con max(T0, soporte requerido)."
    )
    support.period_mapping_name == OOS_PERIOD_MAPPING_NAME || error(
        "El soporte no usa el mapeo abstracto aprobado."
    )
    support.period_mapping_version == OOS_PERIOD_MAPPING_VERSION || error(
        "El soporte no usa la versión de mapeo aprobada."
    )
    support.period_mapping_formula == OOS_PERIOD_MAPPING_FORMULA || error(
        "El soporte no registra la fórmula de mapeo aprobada."
    )
    size(support.nu) == (support.households, data_end) || error(
        "Dimensión de precios incompatible con el soporte materializado."
    )
    length(support.pv_det) == data_end || error(
        "Longitud de PV incompatible con el soporte materializado."
    )
    all(isfinite, support.nu) || error("El soporte contiene precios no finitos.")
    all(isfinite, support.pv_det) || error("El soporte contiene PV no finito.")
    _validate_resolved_demand_models(support.demand_models, support.households, data_end)
    _validate_period_repetition(
        support.nu, support.pv_det, support.demand_models, T0, data_end,
    )
    return support
end

"""Required abstract-period endpoint recorded by a materialized support object."""
required_period_support_end(support::OOSPeriodDataSupport) =
    support.required_period_support_end

"""
Build extended period data from an unmodified repository instance template.

The template must expose exactly one finite J x T0 price matrix and one finite length-T0 PV
reference. The first T0 entries are copied exactly. Later entries repeat those base values through
`base_period_index`. Household profiles are never sampled: each extended activity vector is
derived solely from the resolved model's stored activity over 1:T0.
"""
function build_period_data_support(
    template::OOSInstanceTemplate,
    required_period_support_end::Int,
)
    T0 = template.T
    J = template.J
    T0 >= 1 || error("El horizonte de instancia del repositorio debe ser >= 1.")
    required_period_support_end >= 1 || error(
        "El extremo de soporte requerido debe ser >= 1; se recibió " *
        "$required_period_support_end."
    )
    J >= 1 || error("La plantilla debe declarar al menos un hogar.")
    size(template.nu) == (J, T0) || error(
        "La matriz base de precios tiene dimensión $(size(template.nu)); se esperaba ($J, $T0)."
    )
    length(template.pv_det) == T0 || error(
        "El perfil base de PV tiene $(length(template.pv_det)) períodos; se esperaban $T0."
    )
    all(isfinite, template.nu) || error("La matriz base de precios contiene valores no finitos.")
    all(isfinite, template.pv_det) || error("El perfil base de PV contiene valores no finitos.")
    _validate_resolved_demand_models(template.demand_models, J, T0)

    data_end = max(T0, required_period_support_end)
    base_indices = [base_period_index(period, T0) for period in 1:data_end]

    extended_nu = Matrix{Float64}(undef, J, data_end)
    for period in 1:data_end
        extended_nu[:, period] .= @view template.nu[:, base_indices[period]]
    end
    extended_pv = [template.pv_det[base_indices[period]] for period in 1:data_end]

    model_by_household = Dict(model.household => model for model in template.demand_models)
    extended_models = OOSHouseholdDemandModel[]
    for household in 1:J
        model = model_by_household[household]
        base_activity = Set(model.active_periods)
        active_periods = [
            period for period in 1:data_end if base_indices[period] in base_activity
        ]
        push!(extended_models, OOSHouseholdDemandModel(
            household,
            String(model.profile),
            active_periods,
            model.avg,
            model.dev,
        ))
    end

    # Explicit exact-preservation gates. These deliberately use `==`, not a tolerance: extension
    # copies deterministic repository values and performs no floating-point transformation.
    extended_nu[:, 1:T0] == template.nu || error(
        "La extensión alteró al menos un precio dentro del horizonte base."
    )
    extended_pv[1:T0] == template.pv_det || error(
        "La extensión alteró el PV determinista dentro del horizonte base."
    )
    for household in 1:J
        extended_models[household].active_periods[
            extended_models[household].active_periods .<= T0
        ] == model_by_household[household].active_periods || error(
            "La extensión alteró la actividad base del hogar $household."
        )
    end

    return OOSPeriodDataSupport(
        T0,
        required_period_support_end,
        data_end,
        J,
        extended_nu,
        extended_pv,
        extended_models,
    )
end

"""Boolean household-by-period activity table, returned as a fresh matrix."""
function period_demand_activity(support::OOSPeriodDataSupport)
    activity = falses(support.households, support.materialized_data_end)
    for model in support.demand_models, period in model.active_periods
        activity[model.household, period] = true
    end
    return activity
end

_period_matrix_payload(matrix::AbstractMatrix, period_end::Int) = [
    [Float64(matrix[household, period]) for period in 1:period_end]
    for household in axes(matrix, 1)
]

function _period_activity_payload(support::OOSPeriodDataSupport, period_end::Int)
    return [
        Dict{String,Any}(
            "household" => model.household,
            "profile" => model.profile,
            "active_periods" => [period for period in model.active_periods if period <= period_end],
        )
        for model in support.demand_models
    ]
end

_period_payload_digest(value) = oos_stable_digest(canonical_json(value))

"""
Stable content digests for manifest recording and independent rematerialization checks.

Matrices are serialized in household-major, period-minor order. The canonical JSON writer fixes
object-key ordering, and the digest uses the repository's persisted FNV-1a contract rather than
Julia's non-persisted `hash` interface.
"""
function period_data_support_digests(support::OOSPeriodDataSupport)
    T0 = support.repository_instance_horizon
    data_end = support.materialized_data_end
    base_activity = _period_activity_payload(support, T0)
    extended_activity = _period_activity_payload(support, data_end)
    return Dict{String,Any}(
        "base_price_digest" =>
            _period_payload_digest(_period_matrix_payload(support.nu, T0)),
        "extended_price_digest" =>
            _period_payload_digest(_period_matrix_payload(support.nu, data_end)),
        "base_pv_reference_digest" =>
            _period_payload_digest(collect(support.pv_det[1:T0])),
        "extended_pv_reference_digest" =>
            _period_payload_digest(copy(support.pv_det)),
        "base_demand_activity_digest" => _period_payload_digest(base_activity),
        "demand_activity_digest" => _period_payload_digest(extended_activity),
    )
end

"""Compact deterministic manifest-ready description of one materialized support object."""
function period_data_support_summary(support::OOSPeriodDataSupport)
    return Dict{String,Any}(
        "repository_instance_horizon" => support.repository_instance_horizon,
        "required_period_support_end" => support.required_period_support_end,
        "materialized_data_end" => support.materialized_data_end,
        "period_mapping_name" => support.period_mapping_name,
        "period_mapping_version" => support.period_mapping_version,
        "period_mapping_formula" => support.period_mapping_formula,
        "price_rows" => support.households,
        "price_periods" => size(support.nu, 2),
        "pv_reference_periods" => length(support.pv_det),
        "demand_model_count" => length(support.demand_models),
        "digests" => period_data_support_digests(support),
    )
end
