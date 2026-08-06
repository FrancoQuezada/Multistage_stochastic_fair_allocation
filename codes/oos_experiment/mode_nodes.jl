# =====================================================================================
# Centralized shared-battery mode-node convention.
#
# Exactly one function decides which information states carry a shared-battery operating
# mode. Every controller, every fairness rule and every audit uses it; the convention is
# never duplicated or re-derived at a call site.
# =====================================================================================

"""
Convention identifier recorded in the outputs.

`:every_information_state` means: every node of a remaining-horizon look-ahead structure
represents one physical period in which the shared battery may charge or discharge, so
every node carries exactly one mode binary.
"""
const OOS_MODE_NODE_CONVENTION = :every_information_state

"""
Nodes carrying a shared-battery operating mode, given the raw tree topology.

`parent[n] == 0` marks the root. The returned vector is sorted and duplicate-free, and its
length is the expected mode-binary count of any model built on this topology.
"""
function mode_node_set(
    parent::AbstractVector{<:Integer},
    calendar_period::AbstractVector{<:Integer};
    convention::Symbol=OOS_MODE_NODE_CONVENTION,
)
    length(parent) == length(calendar_period) || error(
        "parent y calendar_period deben tener la misma longitud."
    )
    convention === :every_information_state || error(
        "Convención de nodos de modo no soportada: $convention."
    )
    isempty(parent) && error("La topología del look-ahead no puede estar vacía.")
    return collect(1:length(parent))
end

"""Mode nodes of a `ConditionalTree`, via the centralized convention."""
mode_node_set(tree::ConditionalTree; convention::Symbol=OOS_MODE_NODE_CONVENTION) =
    mode_node_set(tree.parent, tree.calendar_period; convention=convention)

"""Mode nodes already stored on a `LookaheadTree`."""
mode_node_set(tree::LookaheadTree; convention::Symbol=OOS_MODE_NODE_CONVENTION) =
    mode_node_set(tree.parent, tree.calendar_period; convention=convention)

"""
Expected number of shared-battery mode binaries, `|V_mode|`.

Under the corrected node-level formulation this equals the number of mode nodes. It is
*not* multiplied by the number of households: the previous household-indexed convention
would have produced `|H| * |V_mode|` binaries.
"""
expected_mode_binary_count(tree::LookaheadTree) = length(tree.mode_nodes)

"""
Number of unique nonanticipative shared-mode decisions of the policy.

For the node-indexed models built by this module every mode binary already corresponds to
one distinct information state, so the generated and unique counts coincide. Scenario-
indexed implementations would report a larger generated count than this value.
"""
function unique_policy_mode_count(tree::LookaheadTree)
    histories = Set{Vector{Int}}()
    for n in tree.mode_nodes
        push!(histories, node_history(tree, n))
    end
    return length(histories)
end

"""Node path from the root down to `node`, inclusive; the node's information history."""
function node_history(tree::LookaheadTree, node::Int)
    path = Int[]
    current = node
    while current != 0
        push!(path, current)
        current = tree.parent[current]
    end
    return reverse!(path)
end

"""
Assert that a generated model matches the centralized expectation.

Raises when the number of mode nodes disagrees with the convention applied to the same
topology, which is the Phase-0 failure condition "the mode-node count differs from the
centralized expected count".
"""
function assert_mode_node_consistency(tree::LookaheadTree)
    expected = mode_node_set(tree.parent, tree.calendar_period)
    tree.mode_nodes == expected || error(
        "El conjunto de nodos de modo del look-ahead ($(length(tree.mode_nodes))) no coincide " *
        "con la convención centralizada ($(length(expected)))."
    )
    return length(expected)
end

"""
Number of shared-battery mode binaries the *previous* household-indexed convention would
have generated. Reported so that model-size differences are never attributed to the
algorithm alone.
"""
legacy_household_mode_binary_count(tree::LookaheadTree, households::Int) =
    households * length(tree.mode_nodes)
