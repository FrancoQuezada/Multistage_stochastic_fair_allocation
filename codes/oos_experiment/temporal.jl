# =====================================================================================
# Abstract temporal contract of the rolling-horizon experiment.
#
# Three configured quantities, in the notation of docs/oos_redesign_plan.md:
#
#   H = evaluation_horizon    periods whose realized outcomes enter the OOS evaluation
#   L = lookahead_horizon     consecutive periods represented in every rolling optimization
#   h = implementation_step   consecutive decisions committed before the next optimization
#
# A period is an ABSTRACT MODEL PERIOD. None of H, L or h defines minutes, hours, days or any
# other clock-time interval, and no calendar cycle may be inferred from them. The physical
# duration of a period is encoded only in the underlying instance (`template.delta`).
#
# Everything in this file is pure: the helpers read the configuration and nothing else. They
# touch no solver, no scenario tree, no instance file and no filesystem state, which is what
# makes them safe to call from validation, metadata and tests alike.
#
# STAGE SCOPE. As of redesign stage 4 these helpers DRIVE the experiment: the simulator loop
# runs over `rolling_iteration_starts`, every look-ahead spans `lookahead_periods`, the terminal
# state-of-charge target binds at `lookahead_end_period`, the realized trajectory covers
# `realized_period_end` and the exogenous data support reaches `required_period_support_end`.
# `template.T` keeps its own separate meaning — the repository instance horizon and the base
# profile cycle — and is never redefined as H, L or a support endpoint.
#
# Still NOT wired as of stage 4: `known_prefix_length` and multi-period implementation blocks.
# Stage 4 reveals and implements exactly one period per rolling start; generalizing that to
# `h > 1` is stage 6.
# =====================================================================================

"""
Validate the abstract temporal contract, fail-fast and with an attributable message.

Admissible parameters satisfy

    H >= 1,   L >= 1,   1 <= h <= min(H, L).

`implementation_step` is deliberately **not** restricted to a fixed set and is **not** required
to divide `evaluation_horizon`: `H = 24, h = 10` is a valid configuration whose last committed
block runs past the evaluation horizon. See `implementation_block` and `evaluation_block`.
"""
function validate_temporal_contract(
    evaluation_horizon::Int,
    lookahead_horizon::Int,
    implementation_step::Int,
)
    evaluation_horizon >= 1 || error(
        "evaluation_horizon debe ser >= 1; se recibió $evaluation_horizon. Es un número de " *
        "períodos abstractos del modelo, no una duración de reloj."
    )
    lookahead_horizon >= 1 || error(
        "lookahead_horizon debe ser >= 1; se recibió $lookahead_horizon. Es un número de " *
        "períodos abstractos del modelo, no una duración de reloj."
    )
    implementation_step >= 1 || error(
        "implementation_step debe ser >= 1; se recibió $implementation_step."
    )
    implementation_step <= evaluation_horizon || error(
        "implementation_step=$implementation_step excede evaluation_horizon=$evaluation_horizon: " *
        "no se puede comprometer un bloque más largo que el horizonte de evaluación completo."
    )
    implementation_step <= lookahead_horizon || error(
        "implementation_step=$implementation_step excede lookahead_horizon=$lookahead_horizon: " *
        "el prefijo conocido no puede exceder la ventana optimizada."
    )
    # Deliberately NOT required: evaluation_horizon % implementation_step == 0. A non-divisible
    # step is admissible; the final full block simply extends beyond the evaluation horizon and
    # only its evaluated portion contributes to reported metrics.
    return nothing
end

# -------------------------------------------------------------------------------------
# Integer kernels
#
# The helpers below are the public, configuration-level interface. Each one forwards to a kernel
# that takes plain integers, so any other configuration type carrying the same three numbers can
# reuse this exact arithmetic instead of restating it. `OOSStructuralDesignConfig`
# (`structural_catalog.jl`) does precisely that; the semantics are defined once, here.
# -------------------------------------------------------------------------------------

_rolling_iteration_starts(evaluation_horizon::Int, implementation_step::Int) =
    collect(1:implementation_step:evaluation_horizon)

_rolling_solve_count(evaluation_horizon::Int, implementation_step::Int) =
    length(1:implementation_step:evaluation_horizon)

_is_rolling_iteration_start(evaluation_horizon::Int, implementation_step::Int, period::Int) =
    1 <= period <= evaluation_horizon && mod(period - 1, implementation_step) == 0

_final_rolling_iteration_start(evaluation_horizon::Int, implementation_step::Int) =
    last(1:implementation_step:evaluation_horizon)

"""
Length of the known prefix `K_t` revealed to every controller at a rolling start.

Equals `implementation_step`: the block a controller commits is exactly the block whose
realizations it is allowed to condition on.

Stage-1 scope: this records the eventual information contract and is not yet wired into
scenario generation or into `ObservedHistory`.
"""
known_prefix_length(config::OOSExperimentConfig) = config.implementation_step

"""
The rolling starts `T(H, h) = {1, 1+h, 1+2h, ...} ∩ {1, ..., H}`.

    H = 24, h = 1   ->  1, 2, ..., 24
    H = 24, h = 4   ->  1, 5, 9, 13, 17, 21
    H = 24, h = 10  ->  1, 11, 21
"""
rolling_iteration_starts(config::OOSExperimentConfig) =
    _rolling_iteration_starts(config.evaluation_horizon, config.implementation_step)

"""Number of rolling optimizations, i.e. the number of valid rolling starts."""
rolling_solve_count(config::OOSExperimentConfig) =
    _rolling_solve_count(config.evaluation_horizon, config.implementation_step)

"""`true` when `period` is one of `rolling_iteration_starts(config)`."""
is_rolling_iteration_start(config::OOSExperimentConfig, period::Int) =
    _is_rolling_iteration_start(
        config.evaluation_horizon, config.implementation_step, period,
    )

"""
Reject a period that is not a valid rolling start, naming why.

A start outside `1:H` and a start inside `1:H` that is off the `h`-grid are distinguished, so a
caller can tell a range error from an alignment error.
"""
function assert_rolling_iteration_start(config::OOSExperimentConfig, period::Int)
    if !(1 <= period <= config.evaluation_horizon)
        error(
            "El inicio de iteración $period está fuera de 1:$(config.evaluation_horizon) " *
            "(evaluation_horizon)."
        )
    end
    if mod(period - 1, config.implementation_step) != 0
        error(
            "El período $period no es un inicio de iteración válido con " *
            "implementation_step=$(config.implementation_step); los inicios válidos son " *
            "$(rolling_iteration_starts(config))."
        )
    end
    return period
end

"""
The **full** committed block `B_t = t:(t+h-1)` at a valid rolling start `t`.

The block is **never clipped** at the evaluation horizon:

    H = 24, h = 10, t = 21  ->  21:30

This is intentional. The controller commits the complete block; only its intersection with
`1:H` contributes to reported OOS metrics (see `evaluation_block`).
"""
function implementation_block(config::OOSExperimentConfig, period::Int)
    assert_rolling_iteration_start(config, period)
    return period:(period + config.implementation_step - 1)
end

"""
The evaluated portion `E_t = B_t ∩ {1, ..., H} = t:min(t+h-1, H)` of a committed block.

    H = 24, h = 10, t = 21  ->  21:24

Distinguishes the full committed block from the periods included in reported OOS evaluation
metrics. A valid final block is never rejected merely because it extends beyond `H`.
"""
function evaluation_block(config::OOSExperimentConfig, period::Int)
    assert_rolling_iteration_start(config, period)
    return period:min(period + config.implementation_step - 1, config.evaluation_horizon)
end

"""
The moving look-ahead window `L_t = t:(t+L-1)` at a valid rolling start `t`.

Not clipped at the evaluation horizon: every rolling optimization represents exactly `L`
consecutive periods, including the last one.
"""
function lookahead_periods(config::OOSExperimentConfig, period::Int)
    assert_rolling_iteration_start(config, period)
    return period:(period + config.lookahead_horizon - 1)
end

"""Last period of the moving look-ahead window at a valid rolling start: `t + L - 1`."""
function lookahead_end_period(config::OOSExperimentConfig, period::Int)
    assert_rolling_iteration_start(config, period)
    return period + config.lookahead_horizon - 1
end

"""
Last rolling start, i.e. `max T(H, h)`: the first period of the final committed block.
"""
final_rolling_iteration_start(config::OOSExperimentConfig) =
    _final_rolling_iteration_start(config.evaluation_horizon, config.implementation_step)

"""
Last abstract period for which exogenous data must exist: `max T(H, h) + L - 1`.

With `H = L = 24`:

    h = 1   ->  47
    h = 4   ->  44
    h = 10  ->  44

This is the endpoint the *look-ahead* reaches. It is what `build_period_data_support`
materializes, and it is generally larger than the endpoint that must actually be *realized*
out of sample; see `realized_period_end`.
"""
required_period_support_end(config::OOSExperimentConfig) =
    final_rolling_iteration_start(config) + config.lookahead_horizon - 1

"""
Last abstract period whose out-of-sample **realization** must exist: `max T(H, h) + h - 1`.

This is the end of the final full implementation block, i.e. the last period a controller can
be asked to observe as part of a known prefix or to implement:

    H = 24, h = 1   ->  24
    H = 24, h = 4   ->  24
    H = 24, h = 10  ->  30   (final block 21:30, evaluated 21:24)

Two orderings hold for every admissible `(H, L, h)` and are relied on by the simulator:

  * `realized_period_end >= H`, because the final full block always covers the evaluation
    horizon — a realized trajectory of this length can never come up short of `1:H`; and
  * `realized_period_end <= required_period_support_end`, because `h <= L` — the realized
    trajectory always fits inside the materialized data support.

The excess over `H` is committed and physically validated but never enters reported metrics
(see `evaluation_block`).
"""
realized_period_end(config::OOSExperimentConfig) =
    final_rolling_iteration_start(config) + config.implementation_step - 1
