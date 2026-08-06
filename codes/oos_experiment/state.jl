# =====================================================================================
# Simulation state for the out-of-sample receding-horizon experiment.
#
# The state holds exactly one authoritative copy of every cumulative realized quantity.
# Realized savings are *derived* from the cumulative all-grid benchmark and the cumulative
# operating cost; they are never stored as an independent mutable field.
# =====================================================================================

"""
Physical and fairness state entering one period of one configuration.

`period` is the calendar period about to be decided. `soc_before` is the state of charge
entering that period. History matrices are filled progressively and only the columns
`1:revealed_periods` are visible to the controller.
"""
mutable struct SimulationState
    replication_id::Int
    period::Int
    soc_before::Float64

    cumulative_pv::Vector{Float64}
    cumulative_demand::Vector{Float64}
    cumulative_operating_cost::Vector{Float64}
    cumulative_all_grid_cost::Vector{Float64}

    realized_pv_history::Vector{Float64}
    realized_demand_history::Matrix{Float64}

    previous_action::Union{Nothing,PeriodAction}

    # --- documented additive bookkeeping ------------------------------------------------
    revealed_periods::Int
    previous_shared_battery_mode::Int   # reporting only; never an optimization state
end

"""Fresh state for one (replication, controller, fairness) configuration."""
function initial_simulation_state(template::OOSInstanceTemplate, replication_id::Int)
    return SimulationState(
        replication_id,
        1,
        template.s_I,
        zeros(template.J),
        zeros(template.J),
        zeros(template.J),
        zeros(template.J),
        zeros(template.T),
        zeros(template.J, template.T),
        nothing,
        0,
        -1,
    )
end

"""
Reveal the current-period exogenous realization.

Called once per period, before the controller builds its remaining-horizon model. Only the
current period becomes visible; the out-of-sample suffix is never touched.
"""
function reveal_period!(state::SimulationState, path::OOSPath, period::Int)
    period == state.period || error(
        "Se intentó revelar el período $period mientras el estado espera el período $(state.period)."
    )
    state.revealed_periods == period - 1 || error(
        "Historia observada inconsistente: revealed_periods=$(state.revealed_periods), período=$period."
    )
    state.realized_pv_history[period] = path.pv[period]
    for j in axes(path.demand, 1)
        state.realized_demand_history[j, period] = path.demand[j, period]
    end
    state.revealed_periods = period
    return state
end

"""
Observed history the controller is allowed to condition on.

Only the revealed prefix is copied out, so no controller can reach the out-of-sample suffix
even accidentally.
"""
function observed_history(state::SimulationState)
    k = state.revealed_periods
    return ObservedHistory(
        k,
        collect(state.realized_pv_history[1:k]),
        collect(state.realized_demand_history[:, 1:k]),
    )
end

"""Cumulative realized savings, derived from the benchmark and the operating cost."""
realized_savings(state::SimulationState) =
    state.cumulative_all_grid_cost .- state.cumulative_operating_cost

"""Cumulative realized community PV, i.e. the fixed past `C^past`."""
realized_total_pv(state::SimulationState) = sum(state.cumulative_pv)

"""
Apply the implemented current-period action and advance to the next period.

`soc_after` is the value recomputed by the simulator from the implemented flows, not the
value reported by the optimization model.
"""
function apply_action!(
    state::SimulationState,
    template::OOSInstanceTemplate,
    action::PeriodAction,
    soc_after::Float64,
)
    t = state.period
    action.period == t || error(
        "La acción corresponde al período $(action.period) pero el estado está en $t."
    )
    demand_t = @view state.realized_demand_history[:, t]
    for j in 1:template.J
        state.cumulative_pv[j] += action.p[j]
        state.cumulative_demand[j] += demand_t[j]
        state.cumulative_operating_cost[j] += template.delta * (
            template.mu * action.y[j] +
            template.nu[j, t] * action.I[j] -
            template.beta * action.G[j]
        )
        state.cumulative_all_grid_cost[j] += template.delta * template.nu[j, t] * demand_t[j]
    end
    state.soc_before = soc_after
    state.previous_action = action
    state.previous_shared_battery_mode = action.shared_battery_mode
    state.period = t + 1
    return state
end

"""
State of charge induced by the implemented flows.

`s_after = s_before + delta * e_c * Z - (delta / e_d) * Y`.
"""
function induced_soc(template::OOSInstanceTemplate, soc_before::Float64, charge::Float64, discharge::Float64)
    return soc_before + template.delta * template.e_c * charge - template.delta * discharge / template.e_d
end

"""Per-household operating cost of the implemented action at its own period."""
function action_household_costs(template::OOSInstanceTemplate, action::PeriodAction)
    t = action.period
    return [
        template.delta * (
            template.mu * action.y[j] +
            template.nu[j, t] * action.I[j] -
            template.beta * action.G[j]
        )
        for j in 1:template.J
    ]
end
