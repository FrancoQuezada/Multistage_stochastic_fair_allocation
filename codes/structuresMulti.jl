using DataFrames
using CSV
using JuMP
# using Colors
# using JuMP, AmplNLWriter, Bonmin_jll
using CPLEX
# using Juniper
# using Ipopt
using Random
# using PlotlyJS
mutable struct Tree
    """
    structure to save the scenario-tree data
    """
    V::Int64 #number of nodes
    C::Int64 #number of nodes
    T::Int64 #number of periods per stage
    S::Int64 #number of stages
    stages::Vector{Int64} #vector to with the stage of each node
    parents::Vector{Int64} #vector with the parent-node of each node
    rho::Vector{Float64} #vector with the probabilities of each node
    scenarios::Vector{Vector{Int64}} #vector to save scenarios
    # function Tree()
    #     return new
    # end
    # function Tree(childs::Int64, #number of nodes
    #     periods::Int64, #number of periods per stage
    #     nStage::Int64)
    #     this=Tree()
    #     this.childs=childs
    #     this.periods=periods
    #     this.nStage=nStage
    #     this.nodes=Int(periods*((1-childs^nStage)/(1-childs)))
    # end
end


mutable struct InstanceM
    """
    Structure to save the instance 
    """
    id::String # Date (yyyy-mm-dd)
    s_max::Float64# Storage capacity
    s_min::Float64# Storage capacity
    delta::Float64# time step
    e_c::Float64# charge efficiency
    e_d::Float64#discharge efficiency
    s_I::Float64 #initial state of the battery
    d::Array{Float64,2} #demand
    J::Int64 #set of houses
    T::Int64 #time horizon
    mu::Float64 #maintenance cost
    beta::Float64 #price of selling electricity
    nu::Array{Float64,2} #price of energy
    f_under::Float64 #aggregate battery charging-rate limit
    f_bar::Float64 #aggregate battery discharging-rate limit
    c_pv::Array{Float64,1} #PV production
    timeStamp::Array{String,1} #time stamp for each time step
    tree::Tree #
    pv_det::Array{Float64,1} #pv determinista
    d_det::Array{Float64,2} #demand determinista
    function InstanceM()
       return new()
    end
end

mutable struct SolutionM
    id::String
    # s::Array{Float64,2} #battery
    s::Array{Float64,1} #total battery level
    I::Array{Float64,2} #import grid
    G::Array{Float64,2} #export grid
    battery_mode::Array{Float64,1} #one shared-battery charge-mode value per tree node
    w::Array{Float64,2} #vender o comprar grid
    z::Array{Float64,2} #charge of battery
    y::Array{Float64,2} #discharge of battery
    p::Array{Float64,2} #photovoltaic production
    costs::Array{Float64,1} #cost for each house
    status::Bool #if the instance is solved
    time::Float64 #resolution time
    run_time::Float64 # model build + solve wall time

    function SolutionM()
        return new()
    end

    function SolutionM(
        # s::Array{Float64,2}, #battery
        sTot::Array{Float64,1}, #total battery level
        I::Array{Float64,2}, #import grid
        G::Array{Float64,2}, #export grid
        batteryMode::Array{Float64,1}, #one shared-battery charge-mode value per tree node
        w::Array{Float64,2}, #vender o comprar grid
        z::Array{Float64,2}, #charge of battery
        y::Array{Float64,2}, #discharge of battery
        p::Array{Float64,2}, #photovoltaic production
        costs::Array{Float64,1},
        status::Bool,
        solTime::Float64,
        runTime::Float64=solTime,
        id::String="none")
        this=SolutionM()
        this.id=id
        # this.s=s 
        this.s=sTot
        this.I=I 
        this.G=G 
        this.battery_mode=batteryMode
        this.w=w 
        this.z=z 
        this.y=y 
        this.p=p 
        this.costs=costs
        this.status=status
        this.time=solTime
        this.run_time=runTime
        return this
    end
end

const SHARED_BATTERY_FLOW_TOL = 1e-7

"""
Add one shared-battery mode and its aggregate flow constraints per node.

`binary=true` (default) declares the mode as `Bin`, exactly as before. `binary=false`
declares it as a continuous variable in `[0,1]` instead -- an LP relaxation of the same two
constraint rows, used to measure the cost of integrality without changing the formulation's
structure.
"""
function add_shared_battery_mode_constraints!(
    model::Model,
    y,
    z,
    households,
    nodes;
    discharge_limit::Real,
    charge_limit::Real,
    binary::Bool=true,
)
    discharge_limit >= 0 || error("The aggregate discharge limit must be nonnegative.")
    charge_limit >= 0 || error("The aggregate charge limit must be nonnegative.")
    if binary
        @variable(model, battery_mode[n in nodes], Bin)
    else
        @variable(model, 0 <= battery_mode[n in nodes] <= 1)
    end
    @constraint(model, battery_discharge_mode[n in nodes],
        sum(y[j,n] for j in households) <= discharge_limit * (1 - battery_mode[n]))
    @constraint(model, battery_charge_mode[n in nodes],
        sum(z[j,n] for j in households) <= charge_limit * battery_mode[n])
    return battery_mode
end

"""Infer one mode per non-household index, rejecting simultaneous aggregate flows."""
function battery_mode_from_flows(
    y::AbstractArray,
    z::AbstractArray;
    tol::Real=SHARED_BATTERY_FLOW_TOL,
    idle_mode::Real=0.0,
)
    size(y) == size(z) || error("Charge and discharge arrays must have identical dimensions.")
    ndims(y) >= 2 || error("Battery flow arrays must be indexed by household and at least one operating index.")
    tol >= 0 || error("Battery flow tolerance must be nonnegative.")
    idle_mode in (0, 1, 0.0, 1.0) || error("idle_mode must be binary.")
    trailing_size = Base.tail(size(y))
    mode = fill(Float64(idle_mode), trailing_size)
    for index in CartesianIndices(mode)
        tail = Tuple(index)
        discharge = sum(y[j, tail...] for j in axes(y, 1))
        charge = sum(z[j, tail...] for j in axes(z, 1))
        discharge >= -tol || error("Negative aggregate battery discharge at index $tail: $discharge.")
        charge >= -tol || error("Negative aggregate battery charge at index $tail: $charge.")
        if discharge > tol && charge > tol
            error("Physically inconsistent battery flows at index $tail: discharge=$discharge, charge=$charge.")
        elseif charge > tol
            mode[index] = 1.0
        elseif discharge > tol
            mode[index] = 0.0
        end
    end
    return mode
end

"""
Convert a legacy household-indexed mode matrix. Disagreements are repaired from
aggregate flows, reported through `repaired_indices`, and simultaneous flows are rejected.
"""
function convert_legacy_battery_mode(
    legacy_mode::AbstractArray,
    y::AbstractArray,
    z::AbstractArray;
    tol::Real=SHARED_BATTERY_FLOW_TOL,
)
    size(legacy_mode) == size(y) == size(z) || error(
        "Legacy mode, discharge, and charge arrays must have identical dimensions."
    )
    inferred = battery_mode_from_flows(y, z; tol=tol)
    converted = similar(inferred)
    repaired_indices = Tuple[]
    for index in CartesianIndices(converted)
        tail = Tuple(index)
        values = Float64[legacy_mode[j, tail...] for j in axes(legacy_mode, 1)]
        all(
            -tol <= value <= 1 + tol && abs(value - round(value)) <= tol
            for value in values
        ) || error(
            "Legacy battery mode contains a non-binary value at index $tail: $values."
        )
        agrees = maximum(values) - minimum(values) <= tol
        discharge = sum(y[j, tail...] for j in axes(y, 1))
        charge = sum(z[j, tail...] for j in axes(z, 1))
        if agrees
            candidate = round(values[1])
            compatible = (candidate == 1 && discharge <= tol) ||
                         (candidate == 0 && charge <= tol)
            if compatible
                converted[index] = candidate
                continue
            end
        end
        converted[index] = inferred[index]
        push!(repaired_indices, tail)
    end
    return (battery_mode=converted, repaired_indices=repaired_indices)
end

"""Return aggregate shared-battery violations for solution and simulation checks."""
function shared_battery_violations(
    battery_mode::AbstractArray,
    y::AbstractArray,
    z::AbstractArray;
    discharge_limit::Real=Inf,
    charge_limit::Real=Inf,
    tol::Real=SHARED_BATTERY_FLOW_TOL,
)
    Base.tail(size(y)) == size(battery_mode) || error("Battery-mode dimensions do not match discharge flows.")
    size(y) == size(z) || error("Charge and discharge arrays must have identical dimensions.")
    simultaneous = 0.0
    mode = 0.0
    rate = 0.0
    for index in CartesianIndices(battery_mode)
        tail = Tuple(index)
        discharge = sum(y[j, tail...] for j in axes(y, 1))
        charge = sum(z[j, tail...] for j in axes(z, 1))
        value = battery_mode[index]
        simultaneous = max(simultaneous, min(max(discharge, 0.0), max(charge, 0.0)))
        mode = max(mode, abs(value - round(value)), max(-value, value - 1, 0.0))
        mode = max(mode, value >= 0.5 ? max(discharge, 0.0) : max(charge, 0.0))
        rate = max(rate, max(discharge - discharge_limit, charge - charge_limit, 0.0))
    end
    return (
        simultaneous_flow=simultaneous <= tol ? 0.0 : simultaneous,
        mode_violation=mode <= tol ? 0.0 : mode,
        rate_violation=rate <= tol ? 0.0 : rate,
    )
end

function findScenario(NBnodes::Int64,NBstage::Int64,periods::Int64,stages::Vector{Int64},parents::Vector{Int64})
    scenarios=Vector{Vector{Int64}}()
    it=NBnodes
        while stages[it] == NBstage
            node=it
            scenario=Int[]
            while node!=0
                push!(scenario,Int(node))
                node=deepcopy(parents[node])
            end
            push!(scenarios,scenario)
            it-=periods
        end
    return scenarios
end


function buildTree(NBstage::Int64,childs::Int64,periods::Int64)
    """
    function to create an array with the parent of each node, the stage and the probabilities
    """
    nodes=Int(periods*((1-childs^NBstage)/(1-childs)))
    NBparents=Int(((1-childs^(NBstage-1))/(1-childs)))
    # @show NBparents
    parents=zeros(Int64,nodes)
    lims=[periods*(childs^(s-1)) for s in 1:NBstage]
    stages=[s for s in 1:NBstage for _ in 1:lims[s]]
    # @show stages
    for t in 1:periods
        parents[t]=t-1
    end
    j=periods+1    
    for i in 1:NBparents
        for e in 1:childs
            parents[j]+=Int(periods*i)
            j+=1
            for t in 1:(periods-1)
                parents[j]+=Int(periods*i+periods*(childs-1)*(i-1)+(e-1)*periods+t)
                # println((j,parents[j]))
                j+=1
            end
        end
    end

    rho=Float64[1/(childs^(stages[n]-1)) for n in 1:nodes]

    scenariosVar=findScenario(nodes,NBstage,periods,stages,parents)
    scenarioTree=Tree(nodes,childs,periods,NBstage,stages,parents,rho,scenariosVar)
    return scenarioTree
end

function createTime(tree::Tree)
    timePeriod=zeros(Int64,tree.V)
    it=tree.V
    while tree.stages[it] == tree.S
        node=it
        t=Int(tree.S*tree.T)
        while node!=0 && timePeriod[node]==0
            timePeriod[node]=t
            t-=1
            node=deepcopy(tree.parents[node])
        end
        it-=tree.T
    end
    return timePeriod
end

# function get_nodes_for_stage(tree::Tree, s::Int)
#     return [n for n in 1:tree.V if tree.stages[n] == s]
# end
# function get_scenarios(n,scenarios)
#     ss=[sort(s) for s in scenarios if n in s]
#     return ss
# end
