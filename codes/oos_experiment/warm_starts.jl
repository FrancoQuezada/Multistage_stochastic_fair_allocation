# =====================================================================================
# MIP starts for the corrected shared-battery formulation.
#
# A valid start provides exactly one `v_n` per node in `V_mode`, derived from the *aggregate*
# flows of the node. A mode is never initialized from one arbitrary household's former mode.
# =====================================================================================

"""Documented deterministic idle value: an idle node starts in discharging mode."""
const OOS_IDLE_MODE_VALUE = 0.0

"""
One MIP start for the shared-battery operating mode.

`source` records provenance (`"current_formulation"` or `"legacy_converted"`), `idle_nodes`
lists nodes whose aggregate flows were both below tolerance, and `repaired_nodes` lists nodes
whose start had to be repaired explicitly.
"""
struct ModeStart
    nodes::Vector{Int}
    values::Vector{Float64}
    source::String
    idle_nodes::Vector{Int}
    repaired_nodes::Vector{Int}
end

mode_start_length(start::ModeStart) = length(start.nodes)

"""
Derive one shared-battery mode per node from aggregate flows.

    Z_n > tol and Y_n <= tol  ->  v_n = 1
    Y_n > tol and Z_n <= tol  ->  v_n = 0
    both <= tol               ->  documented deterministic idle value
    both  > tol               ->  rejected, or repaired when `on_simultaneous == :repair`

`:repair` keeps the dominant direction and records the node, so a repaired start is never
silently indistinguishable from a clean one.
"""
function mode_start_from_flows(
    nodes::AbstractVector{<:Integer},
    charge::AbstractVector{<:Real},
    discharge::AbstractVector{<:Real};
    flow_tol::Real=SHARED_BATTERY_FLOW_TOL,
    idle_value::Real=OOS_IDLE_MODE_VALUE,
    on_simultaneous::Symbol=:reject,
    source::String="current_formulation",
)
    length(charge) == length(nodes) || error("charge debe tener una entrada por nodo de modo.")
    length(discharge) == length(nodes) || error("discharge debe tener una entrada por nodo de modo.")
    on_simultaneous in (:reject, :repair) || error("on_simultaneous debe ser :reject o :repair.")
    idle_value in (0, 1, 0.0, 1.0) || error("El valor de reposo debe ser binario.")

    values = zeros(Float64, length(nodes))
    idle_nodes = Int[]
    repaired_nodes = Int[]
    for (index, node) in enumerate(nodes)
        z_value = charge[index]
        y_value = discharge[index]
        z_value >= -flow_tol || error("Carga agregada negativa en el nodo $node: $z_value.")
        y_value >= -flow_tol || error("Descarga agregada negativa en el nodo $node: $y_value.")
        if z_value > flow_tol && y_value > flow_tol
            if on_simultaneous === :reject
                error(
                    "Arranque inválido: el nodo $node carga ($z_value) y descarga ($y_value) " *
                    "simultáneamente por encima de la tolerancia $flow_tol."
                )
            end
            values[index] = z_value >= y_value ? 1.0 : 0.0
            push!(repaired_nodes, node)
        elseif z_value > flow_tol
            values[index] = 1.0
        elseif y_value > flow_tol
            values[index] = 0.0
        else
            values[index] = Float64(idle_value)
            push!(idle_nodes, node)
        end
    end
    return ModeStart(collect(nodes), values, source, idle_nodes, repaired_nodes)
end

"""
Validate a mode start against the corrected shared-battery constraints.

Returns the maximum charge- and discharge-link residuals; raises when the start is not
binary or violates a link beyond `flow_tol`.
"""
function validate_mode_start(
    start::ModeStart,
    charge::AbstractVector{<:Real},
    discharge::AbstractVector{<:Real};
    charge_limit::Real,
    discharge_limit::Real,
    flow_tol::Real=SHARED_BATTERY_FLOW_TOL,
)
    length(charge) == mode_start_length(start) || error("Dimensión de carga inconsistente.")
    length(discharge) == mode_start_length(start) || error("Dimensión de descarga inconsistente.")
    charge_residual = 0.0
    discharge_residual = 0.0
    for (index, node) in enumerate(start.nodes)
        v = start.values[index]
        abs(v - round(v)) <= flow_tol || error("El arranque del nodo $node no es binario: $v.")
        charge_residual = max(charge_residual, charge[index] - charge_limit * v)
        discharge_residual = max(discharge_residual, discharge[index] - discharge_limit * (1 - v))
    end
    charge_residual <= flow_tol || error(
        "El arranque viola el vínculo de carga por $charge_residual."
    )
    discharge_residual <= flow_tol || error(
        "El arranque viola el vínculo de descarga por $discharge_residual."
    )
    return (charge_residual=max(charge_residual, 0.0), discharge_residual=max(discharge_residual, 0.0))
end

"""
Install a mode start on a generated model.

Fails when the start does not cover exactly the model's mode nodes, which is the Phase-5
failure condition "warm starts contain one mode per relevant node".
"""
function apply_mode_start!(refs::PhysicalModelRefs, start::ModeStart)
    Set(start.nodes) == Set(refs.mode_nodes) || error(
        "El arranque cubre $(mode_start_length(start)) nodos y el modelo declara " *
        "$(length(refs.mode_nodes)) nodos de modo."
    )
    for (index, node) in enumerate(start.nodes)
        set_start_value(refs.v[node], start.values[index])
    end
    return refs
end

"""
Build a mode start for the next rolling start's look-ahead from the previous solve.

The previous solve is mapped forward BY CALENDAR PERIOD along its reference scenario. That is
what makes it correct for a shifted fixed window: the previous window `t : t+L-1` and the new one
`t+h : t+h+L-1` overlap on `t+h : t+L-1`, those periods map across by their own labels, and the
`h` newly entered periods at the tail simply have no predecessor and fall back to the documented
idle value. Nothing is aligned by node index, which would be wrong the moment the window moves.

It is a heuristic: a MIP start affects solver effort only, never the feasibility or optimality of
the returned action. A warm start that fails is a performance problem and never permission to
change the model or the implemented action — the simulator catches the failure and solves cold.

The start is always validated against the corrected constraints before use, and the aggregate
flows of the *previous* tree are the only input, so no household mode is ever consulted.
"""
function derive_mode_start_from_previous(
    previous_tree::LookaheadTree,
    previous_charge::AbstractVector{<:Real},
    previous_discharge::AbstractVector{<:Real},
    new_tree::LookaheadTree;
    flow_tol::Real=SHARED_BATTERY_FLOW_TOL,
)
    length(previous_charge) == lookahead_node_count(previous_tree) || error(
        "Los flujos agregados previos deben tener una entrada por nodo del árbol previo."
    )
    reference = previous_tree.scenarios[1]
    by_period = Dict{Int,Tuple{Float64,Float64}}()
    for node in reference
        by_period[previous_tree.calendar_period[node]] =
            (Float64(previous_charge[node]), Float64(previous_discharge[node]))
    end

    nodes = copy(new_tree.mode_nodes)
    charge = zeros(length(nodes))
    discharge = zeros(length(nodes))
    carried = 0
    for (index, node) in enumerate(nodes)
        period = new_tree.calendar_period[node]
        if haskey(by_period, period)
            charge[index], discharge[index] = by_period[period]
            carried += 1
        end
    end
    start = mode_start_from_flows(
        nodes, charge, discharge;
        flow_tol=flow_tol, on_simultaneous=:repair, source="current_formulation",
    )
    return (start=start, carried_nodes=carried, fresh_nodes=length(nodes) - carried)
end

"""
Overlap between two successive look-ahead windows, in abstract periods.

`max(0, previous_last - new_first + 1)`. With a fixed window of length `L` shifted by `h` this is
`L - h`, and it is zero exactly when `h >= L`, i.e. when the next window starts at or after the
previous one ended and no warm-start information can carry across.
"""
lookahead_window_overlap(previous_tree::LookaheadTree, new_tree::LookaheadTree) =
    max(0, previous_tree.last_period - new_tree.first_period + 1)

"""Aggregate flows of a solved model, indexed by node; the canonical warm-start input."""
function aggregate_flows_from_solution(refs::PhysicalModelRefs)
    nodes = refs.tree.nodes
    charge = [value(refs.aggregate_charge[n]) for n in nodes]
    discharge = [value(refs.aggregate_discharge[n]) for n in nodes]
    return (charge=charge, discharge=discharge)
end
