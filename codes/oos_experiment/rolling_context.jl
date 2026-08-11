# =====================================================================================
# Task-local rolling context (OOS redesign stage 4).
#
# Stage 3 materialized prices, the deterministic PV reference and household activity through
# `required_period_support_end(config)`, but left them in a standalone `OOSPeriodDataSupport`
# that no consumer read. Stage 4 moves the simulator onto a fixed L-period moving window, so
# every look-ahead can now reach abstract periods after the repository horizon T0 — and the
# physical model, the realized cost accounting and the fairness aggregates must read their
# prices from that extended support instead of from the J x T0 `template.nu`.
#
# This file is the single place where the three objects are bound together:
#
#     config    the abstract temporal contract (H, L, h)
#     template  the repository instance, UNCHANGED: `template.T` is still T0 and `template.nu`
#               is still exactly J x T0
#     support   the extended deterministic data over 1:materialized_data_end
#
# `rolling_price` is the ONLY price accessor the experiment layers use. No consumer indexes
# `template.nu` by an abstract period any more, and no consumer repeats the period-repetition
# arithmetic: the support already applied `base_period_index` when it was built.
#
# PARALLEL READINESS (plan section 4.9). The context is immutable, holds no RNG, no cache and no
# filesystem handle, and is constructed from the configuration and the instance alone. Two
# contexts built in different processes, in different orders or by different workers are equal.
# Nothing here is worker-global mutable state.
# =====================================================================================

"""
Everything one rolling-horizon simulation needs beyond its own mutable `SimulationState`.

Immutable and task-local. One context serves every controller and every allocation/fairness
rule of a task, which is what lets them share literally the same deterministic inputs.

Invariants enforced at construction:

  * `support.repository_instance_horizon == template.T` — the support extends this instance,
    not another one;
  * `support.households == template.J`;
  * `support.required_period_support_end == required_period_support_end(config)` — the support
    reaches exactly the endpoint the temporal contract asks for; and
  * the support revalidates completely, so a mutated or forged extended array cannot enter.

`template` is a documented readability alias of `context.template`. It is retained because
`refs.template`, `past`-building and the audit layers read physical parameters far more often
than they read prices, and spelling those `context.template` everywhere would obscure them.
"""
struct OOSRollingContext
    config::OOSExperimentConfig
    template::OOSInstanceTemplate
    support::OOSPeriodDataSupport

    function OOSRollingContext(
        config::OOSExperimentConfig,
        template::OOSInstanceTemplate,
        support::OOSPeriodDataSupport,
    )
        validate_period_data_support(support)
        support.repository_instance_horizon == template.T || error(
            "El soporte declara T0=$(support.repository_instance_horizon) y la plantilla " *
            "declara T=$(template.T)."
        )
        support.households == template.J || error(
            "El soporte declara $(support.households) hogares y la plantilla declara " *
            "$(template.J)."
        )
        required = required_period_support_end(config)
        support.required_period_support_end == required || error(
            "El soporte alcanza el período $(support.required_period_support_end) y el contrato " *
            "temporal (H=$(config.evaluation_horizon), L=$(config.lookahead_horizon), " *
            "h=$(config.implementation_step)) requiere $required."
        )
        # The realized trajectory must fit inside the materialized data. This is implied by
        # h <= L, but it is the invariant the simulator actually depends on, so it is checked
        # rather than assumed.
        realized_period_end(config) <= support.materialized_data_end || error(
            "La trayectoria realizada llega al período $(realized_period_end(config)) y los " *
            "datos materializados terminan en $(support.materialized_data_end)."
        )
        return new(config, template, support)
    end
end

"""
Build the context of one instance directly from its temporal contract.

Materializes the extended support at `required_period_support_end(config)`. This is the
constructor every runner and every compatibility method uses; supplying a support explicitly is
reserved for tests that want to probe a specific endpoint.
"""
OOSRollingContext(config::OOSExperimentConfig, template::OOSInstanceTemplate) =
    OOSRollingContext(
        config, template,
        build_period_data_support(template, required_period_support_end(config)),
    )

"""Last abstract period whose deterministic data is materialized in this context."""
rolling_data_end(context::OOSRollingContext) = context.support.materialized_data_end

"""Last abstract period the moving look-ahead reaches: `max T(H, h) + L - 1`."""
rolling_support_end(context::OOSRollingContext) = context.support.required_period_support_end

"""Last abstract period whose out-of-sample realization exists: `max T(H, h) + h - 1`."""
rolling_realized_end(context::OOSRollingContext) = realized_period_end(context.config)

"""Repository instance horizon T0, i.e. the base deterministic profile cycle length."""
rolling_base_cycle(context::OOSRollingContext) = context.support.repository_instance_horizon

"""
Electricity purchase price of household `j` at abstract period `tau`.

The single price accessor of the experiment. Within `1:T0` it returns the instance's own base
price for that household and period, exactly; after `T0` it returns the repeated base entry the
support already resolved through `base_period_index`. No caller performs that arithmetic itself,
and no consumer indexes the base `J x T0` matrix by an abstract period.
"""
function rolling_price(context::OOSRollingContext, household::Int, period::Int)
    support = context.support
    1 <= household <= support.households || error(
        "El hogar $household está fuera de 1:$(support.households)."
    )
    1 <= period <= support.materialized_data_end || error(
        "El período $period no tiene precio materializado; los datos terminan en " *
        "$(support.materialized_data_end)."
    )
    return support.nu[household, period]
end

"""
The extended price matrix, `J x materialized_data_end`.

Returned for bulk model construction, where indexing through `rolling_price` per coefficient
would dominate build time. Read-only by contract: the support owns these arrays and every
consumer treats them as task-local scientific inputs.
"""
rolling_price_matrix(context::OOSRollingContext) = context.support.nu

"""
Assert that an abstract period has materialized deterministic data, naming the endpoint.

Used by the layers that accept a caller-supplied period, so an out-of-range look-ahead is
reported as a support-contract violation rather than as a bounds error deep inside JuMP.
"""
function assert_supported_period(context::OOSRollingContext, period::Int)
    1 <= period <= rolling_data_end(context) || error(
        "El período abstracto $period está fuera del soporte materializado " *
        "1:$(rolling_data_end(context))."
    )
    return period
end

# -------------------------------------------------------------------------------------
# Retained pre-stage-4 call shapes
#
# Several layers were called with a bare `OOSInstanceTemplate` before stage 4 and are still
# called that way by fixtures and by the repository-compatibility tests. Rather than duplicating
# their bodies, each such layer accepts an `OOSPricedSource` and reads its prices, horizon and
# physical parameters through the three accessors below. The stage-4 campaign always passes a
# context; a bare template simply caps the available prices at the base horizon `1:T0`, which is
# exactly the pre-stage-4 contract.
# -------------------------------------------------------------------------------------

"""Anything a stage-4 layer can read deterministic prices and physical parameters from."""
const OOSPricedSource = Union{OOSRollingContext,OOSInstanceTemplate}

"""The repository instance template behind a priced source."""
priced_template(context::OOSRollingContext) = context.template
priced_template(template::OOSInstanceTemplate) = template

"""
The price matrix a priced source exposes.

A context exposes the extended `J x materialized_data_end` support; a bare template exposes its
own `J x T0` matrix and therefore cannot price a period after the repository horizon.
"""
priced_matrix(context::OOSRollingContext) = context.support.nu
priced_matrix(template::OOSInstanceTemplate) = template.nu

"""
Length of the realized out-of-sample history a priced source implies.

With a context this is `realized_period_end(config)`, the end of the final full implementation
block. With a bare template it is the repository horizon, preserving the pre-stage-4 sizing.
"""
priced_realized_end(context::OOSRollingContext) = realized_period_end(context.config)
priced_realized_end(template::OOSInstanceTemplate) = template.T

"""
Reject an abstract period the source cannot price, naming the remedy.

A bare template runs out of prices at `T0`. Saying so explicitly turns what would otherwise be
an opaque `BoundsError` inside a JuMP expression into an actionable message.
"""
function assert_priced_period(source::OOSPricedSource, period::Int)
    available = size(priced_matrix(source), 2)
    1 <= period <= available || error(
        "Se requiere el precio del período abstracto $period y solo hay $available períodos " *
        "con precio disponible. Un OOSInstanceTemplate solo cubre 1:T0; pasa un " *
        "OOSRollingContext para alcanzar el soporte extendido."
    )
    return period
end
