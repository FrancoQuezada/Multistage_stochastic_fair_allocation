# =====================================================================================
# Look-ahead tree adapter.
#
# The three controllers differ only in the *information structure* they build over the
# remaining calendar horizon. They all hand the same `LookaheadTree` to the single physical
# model builder, so the shared-battery physics cannot diverge between them.
# =====================================================================================

const OOS_PROBABILITY_TOL = 1e-9

"""
Build a `LookaheadTree` from a raw topology and validate its probability structure.

`mode_nodes` is always obtained from the centralized convention, never from the caller.
"""
function make_lookahead_tree(
    controller::ControllerKind,
    parent::Vector{Int},
    probability::Vector{Float64},
    calendar_period::Vector{Int},
    scenarios::Vector{Vector{Int}},
    pv::Vector{Float64},
    demand::Matrix{Float64},
    first_period::Int,
    last_period::Int,
    generated_scenarios::Int,
)
    n_nodes = length(parent)
    n_nodes >= 1 || error("El look-ahead debe tener al menos el nodo raíz.")
    length(probability) == n_nodes || error("probability debe tener una entrada por nodo.")
    length(calendar_period) == n_nodes || error("calendar_period debe tener una entrada por nodo.")
    length(pv) == n_nodes || error("pv debe tener una entrada por nodo.")
    size(demand, 2) == n_nodes || error("demand debe tener una columna por nodo.")
    parent[1] == 0 || error("El nodo 1 debe ser la raíz (parent == 0).")
    count(==(0), parent) == 1 || error("El look-ahead debe tener exactamente una raíz.")

    for n in 2:n_nodes
        1 <= parent[n] < n || error("El padre del nodo $n debe ser un nodo anterior: $(parent[n]).")
        calendar_period[n] == calendar_period[parent[n]] + 1 || error(
            "El nodo $n debe avanzar exactamente un período respecto de su padre."
        )
    end
    abs(probability[1] - 1.0) <= OOS_PROBABILITY_TOL || error(
        "La probabilidad de la raíz debe ser 1, no $(probability[1])."
    )
    all(>=(0.0), probability) || error("Las probabilidades de los nodos deben ser no negativas.")

    # Probability mass is conserved calendar period by calendar period.
    for tau in first_period:last_period
        mass = sum(probability[n] for n in 1:n_nodes if calendar_period[n] == tau; init=0.0)
        abs(mass - 1.0) <= sqrt(eps()) * max(1.0, n_nodes) || error(
            "La masa de probabilidad del período $tau es $mass en lugar de 1."
        )
    end

    isempty(scenarios) && error("El look-ahead debe declarar al menos un escenario.")
    for scenario in scenarios
        isempty(scenario) && error("Un escenario no puede estar vacío.")
        scenario[1] == 1 || error("Los escenarios deben empezar en la raíz (orden raíz -> hoja).")
        for k in 2:length(scenario)
            parent[scenario[k]] == scenario[k-1] || error(
                "El escenario $(scenario) no es un camino raíz -> hoja del árbol."
            )
        end
        calendar_period[scenario[end]] == last_period || error(
            "Cada escenario debe terminar en el período final $last_period."
        )
    end
    scenario_mass = sum(probability[scenario[end]] for scenario in scenarios)
    abs(scenario_mass - 1.0) <= sqrt(eps()) * max(1.0, length(scenarios)) || error(
        "Las probabilidades de escenario suman $scenario_mass en lugar de 1."
    )

    mode_nodes = mode_node_set(parent, calendar_period)

    return LookaheadTree(
        1, collect(1:n_nodes), parent, probability, calendar_period, scenarios,
        pv, demand, mode_nodes, controller, first_period, last_period, generated_scenarios,
    )
end

# -------------------------------------------------------------------------------------
# DETERMINISTIC_RH
# -------------------------------------------------------------------------------------

"""
One point-forecast path over the remaining horizon: the observed current period followed by
the conditional mean of every later period. Every node has probability one.
"""
function deterministic_lookahead_tree(forecast::ForecastPath)
    n_nodes = forecast.last_period - forecast.first_period + 1
    n_nodes == length(forecast.pv) || error("La trayectoria de pronóstico tiene largo inconsistente.")
    parent = collect(0:(n_nodes-1))
    probability = ones(n_nodes)
    calendar_period = collect(forecast.first_period:forecast.last_period)
    scenarios = [collect(1:n_nodes)]
    return make_lookahead_tree(
        DETERMINISTIC_RH, parent, probability, calendar_period, scenarios,
        copy(forecast.pv), copy(forecast.demand),
        forecast.first_period, forecast.last_period, 1,
    )
end

# -------------------------------------------------------------------------------------
# TWO_STAGE_RH
# -------------------------------------------------------------------------------------

"""
Two-stage information structure: one common root (the current period), immediate branching
after the root, and one independent future chain per scenario with no nonanticipativity
beyond the root.

When the current period is the last one there is no future, so the structure collapses to
the single root node and coincides with the deterministic and multistage structures.
"""
function two_stage_lookahead_tree(
    root_pv::Float64,
    root_demand::Vector{Float64},
    scenarios::Vector{ScenarioPath},
    first_period::Int,
    last_period::Int;
    known_prefix::Int=1,
)
    J = length(root_demand)
    window = last_period - first_period + 1
    known_prefix >= 1 || error("El prefijo conocido debe ser >= 1; se recibió $known_prefix.")
    known_prefix <= window || error(
        "El prefijo conocido ($known_prefix) no cabe en la ventana de $window períodos."
    )
    future_periods = window - known_prefix

    isempty(scenarios) && error("Se requiere al menos un escenario para TWO_STAGE_RH.")
    total_probability = sum(sc.probability for sc in scenarios)
    abs(total_probability - 1.0) <= 1e-9 || error(
        "Las probabilidades de escenario de dos etapas suman $total_probability."
    )
    for scenario in scenarios
        scenario.first_period == first_period || error(
            "Todo escenario debe empezar en el período actual $first_period."
        )
        scenario.last_period == last_period || error(
            "Todo escenario debe terminar en el período final $last_period."
        )
        length(scenario.pv) == window || error(
            "Cada escenario debe cubrir los $window períodos de la ventana."
        )
    end

    # The known prefix is a single common chain: every controller was given those realizations,
    # so no scenario may disagree about them and none may branch inside them.
    reference = first(scenarios)
    for scenario in scenarios, k in 1:known_prefix
        scenario.pv[k] == reference.pv[k] || error(
            "Los escenarios discrepan en el período $k del prefijo conocido."
        )
        collect(scenario.demand[:, k]) == collect(reference.demand[:, k]) || error(
            "Los escenarios discrepan en la demanda del período $k del prefijo conocido."
        )
    end
    reference.pv[1] == root_pv || error(
        "El primer período del prefijo no coincide con la raíz observada."
    )
    collect(reference.demand[:, 1]) == root_demand || error(
        "La demanda del primer período del prefijo no coincide con la raíz observada."
    )

    n_nodes = known_prefix + length(scenarios) * future_periods
    parent = zeros(Int, n_nodes)
    probability = zeros(n_nodes)
    calendar_period = zeros(Int, n_nodes)
    pv = zeros(n_nodes)
    demand = zeros(J, n_nodes)

    # 1. The deterministic prefix chain, probability one throughout.
    prefix_nodes = Int[]
    for k in 1:known_prefix
        parent[k] = k == 1 ? 0 : k - 1
        probability[k] = 1.0
        calendar_period[k] = first_period + k - 1
        pv[k] = reference.pv[k]
        demand[:, k] .= @view reference.demand[:, k]
        push!(prefix_nodes, k)
    end

    if future_periods == 0
        # The window is exactly the known prefix: there is no future to represent, so the
        # structure collapses to that single chain.
        return make_lookahead_tree(
            TWO_STAGE_RH, parent, probability, calendar_period, [prefix_nodes],
            pv, demand, first_period, last_period, length(scenarios),
        )
    end

    # 2. One independent recourse chain per scenario, branching only after the prefix.
    scenario_paths = Vector{Vector{Int}}()
    node = known_prefix
    for scenario in scenarios
        path = copy(prefix_nodes)
        previous = last(prefix_nodes)
        for k in (known_prefix+1):window
            node += 1
            parent[node] = previous
            probability[node] = scenario.probability
            calendar_period[node] = first_period + k - 1
            pv[node] = scenario.pv[k]
            demand[:, node] .= @view scenario.demand[:, k]
            push!(path, node)
            previous = node
        end
        push!(scenario_paths, path)
    end
    node == n_nodes || error("Construcción inconsistente del árbol de dos etapas.")

    return make_lookahead_tree(
        TWO_STAGE_RH, parent, probability, calendar_period, scenario_paths,
        pv, demand, first_period, last_period, length(scenarios),
    )
end

# -------------------------------------------------------------------------------------
# MULTISTAGE_RH
# -------------------------------------------------------------------------------------

"""
Stage layout of a remaining horizon of `remaining` periods.

Returns `(periods_per_stage, branching)`. With `requested_periods` empty the remaining
periods are split as evenly as possible over `length(branching)+1` stages, with the
remainder assigned to the earliest stages. Trailing stages that would receive no period are
dropped together with their branching factor, so the layout is always well defined and
reproducible for every `(period, horizon)` pair.
"""
function multistage_stage_layout(
    remaining::Int,
    branching::Vector{Int},
    requested_periods::Vector{Int},
)
    remaining >= 1 || error("El horizonte restante debe tener al menos un período.")
    if isempty(branching)
        return ([remaining], Int[])
    end
    n_stages = length(branching) + 1

    if !isempty(requested_periods)
        length(requested_periods) == n_stages || error(
            "multistage_periods_per_stage debe tener $n_stages entradas."
        )
        periods = Int[]
        used = 0
        for (idx, want) in enumerate(requested_periods)
            available = remaining - used
            available <= 0 && break
            take = idx == n_stages ? available : min(want, available)
            take >= 1 || break
            push!(periods, take)
            used += take
        end
        if used < remaining && !isempty(periods)
            periods[end] += remaining - used
        end
        return (periods, branching[1:(length(periods)-1)])
    end

    usable_stages = min(n_stages, remaining)
    base = div(remaining, usable_stages)
    extra = remaining - base * usable_stages
    periods = [base + (k <= extra ? 1 : 0) for k in 1:usable_stages]
    return (periods, branching[1:(usable_stages-1)])
end

"""
Stage layout that keeps the whole known prefix inside the first, branch-free stage.

Stage 1 never branches, so a layout whose first stage already covers `known_prefix` periods
satisfies the stage-6 requirement that branching begin no earlier than `t + h`. When it does not,
stage 1 is grown to exactly `known_prefix` and the periods it takes are drawn from the later
stages in order; a stage left with no period is dropped together with the branching factor that
would have entered it.

`known_prefix = 1` therefore returns `multistage_stage_layout` unchanged whenever the configured
first stage is at least one period long, which it always is. That is what makes `h = 1` an exact
regression of the stage-5 behaviour rather than a new layout.
"""
function multistage_stage_layout_with_prefix(
    remaining::Int,
    branching::Vector{Int},
    requested_periods::Vector{Int},
    known_prefix::Int,
)
    known_prefix >= 1 || error("El prefijo conocido debe ser >= 1; se recibió $known_prefix.")
    known_prefix <= remaining || error(
        "El prefijo conocido ($known_prefix) no cabe en la ventana de $remaining períodos."
    )
    periods, stage_branching = multistage_stage_layout(remaining, branching, requested_periods)
    periods[1] >= known_prefix && return (periods, stage_branching)

    periods = copy(periods)
    deficit = known_prefix - periods[1]
    periods[1] = known_prefix
    index = 2
    while deficit > 0 && index <= length(periods)
        taken = min(deficit, periods[index])
        periods[index] -= taken
        deficit -= taken
        index += 1
    end
    deficit == 0 || error(
        "No fue posible reservar $known_prefix períodos para el prefijo conocido dentro de " *
        "una ventana de $remaining períodos."
    )

    kept_periods = Int[periods[1]]
    kept_branching = Int[]
    for stage in 2:length(periods)
        periods[stage] == 0 && continue
        push!(kept_periods, periods[stage])
        push!(kept_branching, stage_branching[stage-1])
    end
    return (kept_periods, kept_branching)
end

"""
Multistage information structure with progressive revelation.

Node-indexed storage makes nonanticipativity implicit: two scenarios that share a history
literally share the same node, hence the same shared-battery mode variable.
`sampler(node_calendar_period, history_nodes, node_index)` returns the `(pv, demand)` pair
realized at a freshly created node.

STAGE 6. `known_prefix` is the length `h` of the deterministic initial information stage. The
first `known_prefix` periods form a single branch-free chain whose values come from
`known_values` — the REALIZED prefix — instead of from the sampler, and branching cannot begin
before `first_period + known_prefix`. `known_values` is a `(pv, demand)` pair covering
`first_period : first_period + known_prefix - 1`; the root's own values still come from
`root_pv`/`root_demand`, which must agree with its first entry.

With `known_prefix = 1` this is exactly the pre-stage-6 construction.
"""
function multistage_lookahead_tree(
    J::Int,
    first_period::Int,
    last_period::Int,
    root_pv::Float64,
    root_demand::Vector{Float64},
    branching::Vector{Int},
    requested_periods::Vector{Int},
    sampler;
    known_prefix::Int=1,
    known_values::Union{Nothing,Tuple{Vector{Float64},Matrix{Float64}}}=nothing,
)
    remaining = last_period - first_period + 1
    periods_per_stage, stage_branching = multistage_stage_layout_with_prefix(
        remaining, branching, requested_periods, known_prefix,
    )
    sum(periods_per_stage) == remaining || error("El reparto de períodos por etapa es inconsistente.")
    periods_per_stage[1] >= known_prefix || error(
        "La primera etapa cubre $(periods_per_stage[1]) períodos y el prefijo conocido exige " *
        "$known_prefix."
    )

    prefix_end = first_period + known_prefix - 1
    if known_prefix > 1
        known_values === nothing && error(
            "Un prefijo conocido de $known_prefix períodos requiere sus valores realizados."
        )
        length(known_values[1]) == known_prefix || error(
            "El prefijo realizado declara $(length(known_values[1])) períodos de PV y se " *
            "esperaban $known_prefix."
        )
        size(known_values[2]) == (J, known_prefix) || error(
            "El prefijo realizado de demanda tiene dimensión $(size(known_values[2])); se " *
            "esperaba ($J, $known_prefix)."
        )
        known_values[1][1] == root_pv || error(
            "El primer valor del prefijo realizado no coincide con la raíz observada."
        )
        collect(known_values[2][:, 1]) == root_demand || error(
            "La primera columna del prefijo realizado no coincide con la demanda observada."
        )
    end

    length(root_demand) == J || error("root_demand debe tener una entrada por hogar.")

    parent = Int[0]
    probability = Float64[1.0]
    calendar_period = Int[first_period]
    pv = Float64[root_pv]
    demand_columns = Vector{Vector{Float64}}([copy(root_demand)])

    add_node! = function (par::Int, prob::Float64, period::Int)
        push!(parent, par)
        push!(probability, prob)
        push!(calendar_period, period)
        idx = length(parent)
        history = Int[]
        current = par
        while current != 0
            push!(history, current)
            current = parent[current]
        end
        reverse!(history)
        if period <= prefix_end
            # Inside the known prefix nothing is sampled: the value is the realization every
            # controller was given. The frontier holds exactly one node here, so the assignment
            # is unambiguous.
            offset = period - first_period + 1
            push!(pv, known_values[1][offset])
            push!(demand_columns, collect(known_values[2][:, offset]))
            return idx
        end
        sampled_pv, sampled_demand = sampler(period, history, idx)
        length(sampled_demand) == J || error("El muestreador devolvió una demanda de largo incorrecto.")
        push!(pv, Float64(sampled_pv))
        push!(demand_columns, Vector{Float64}(sampled_demand))
        return idx
    end

    # Layer of currently open nodes; every stage transition multiplies it by its branching.
    frontier = Int[1]
    tau = first_period

    for (stage_index, stage_periods) in enumerate(periods_per_stage)
        # The first period of stage 1 is the root, which already exists.
        periods_to_add = stage_index == 1 ? stage_periods - 1 : stage_periods
        if stage_index > 1
            children = stage_branching[stage_index-1]
            new_frontier = Int[]
            tau += 1
            for node in frontier, _ in 1:children
                push!(new_frontier, add_node!(node, probability[node] / children, tau))
            end
            frontier = new_frontier
            periods_to_add -= 1
        end
        for _ in 1:periods_to_add
            tau += 1
            new_frontier = Int[]
            for node in frontier
                push!(new_frontier, add_node!(node, probability[node], tau))
            end
            frontier = new_frontier
        end
    end
    tau == last_period || error("El árbol multietapa terminó en $tau en lugar de $last_period.")

    demand = reduce(hcat, demand_columns)

    scenarios = Vector{Vector{Int}}()
    for leaf in frontier
        path = Int[]
        current = leaf
        while current != 0
            push!(path, current)
            current = parent[current]
        end
        push!(scenarios, reverse!(path))
    end

    return make_lookahead_tree(
        MULTISTAGE_RH, parent, probability, calendar_period, scenarios,
        pv, demand, first_period, last_period, length(scenarios),
    )
end

# -------------------------------------------------------------------------------------
# Diagnostics
# -------------------------------------------------------------------------------------

"""Expected value of an exogenous node quantity over the look-ahead."""
function lookahead_expectation(tree::LookaheadTree, values::AbstractVector{<:Real})
    length(values) == lookahead_node_count(tree) || error("Dimensión inconsistente.")
    return sum(tree.probability[n] * values[n] for n in tree.nodes)
end

"""Scenario probability vector, aligned with `tree.scenarios`."""
scenario_probabilities(tree::LookaheadTree) =
    [tree.probability[scenario[end]] for scenario in tree.scenarios]

"""Interface-level `ConditionalTree` view of a built look-ahead structure."""
function conditional_tree_from_lookahead(tree::LookaheadTree)
    return ConditionalTree(
        tree.first_period, tree.last_period,
        copy(tree.parent), copy(tree.probability), copy(tree.calendar_period),
        [copy(scenario) for scenario in tree.scenarios],
        copy(tree.pv), copy(tree.demand),
    )
end

"""Adapt a provider-supplied `ConditionalTree` into the physical builder's input."""
function lookahead_from_conditional_tree(
    tree::ConditionalTree,
    controller::ControllerKind,
    generated_scenarios::Int=length(tree.scenarios),
)
    return make_lookahead_tree(
        controller, copy(tree.parent), copy(tree.probability), copy(tree.calendar_period),
        [copy(scenario) for scenario in tree.scenarios], copy(tree.pv), copy(tree.demand),
        tree.first_period, tree.last_period, generated_scenarios,
    )
end

"""Human-readable summary used in the solve log and the model audit."""
function lookahead_summary(tree::LookaheadTree)
    return (
        controller=string(tree.controller),
        nodes=lookahead_node_count(tree),
        scenarios=lookahead_scenario_count(tree),
        mode_nodes=length(tree.mode_nodes),
        first_period=tree.first_period,
        last_period=tree.last_period,
    )
end
