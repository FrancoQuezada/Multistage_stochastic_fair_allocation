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
    f_under::Float64 #discharge limit
    f_bar::Float64 #charge limit
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
    x::Array{Float64,2} #battery set-up charge
    w::Array{Float64,2} #vender o comprar grid
    z::Array{Float64,2} #charge of battery
    y::Array{Float64,2} #discharge of battery
    p::Array{Float64,2} #photovoltaic production
    costs::Array{Float64,1} #cost for each house
    status::Bool #if the instance is solved
    time::Float64 #resolution time

    function SolutionM()
        return new()
    end

    function SolutionM(
        # s::Array{Float64,2}, #battery
        sTot::Array{Float64,1}, #total battery level
        I::Array{Float64,2}, #import grid
        G::Array{Float64,2}, #export grid
        x::Array{Float64,2}, #battery set-up charge
        w::Array{Float64,2}, #vender o comprar grid
        z::Array{Float64,2}, #charge of battery
        y::Array{Float64,2}, #discharge of battery
        p::Array{Float64,2}, #photovoltaic production
        costs::Array{Float64,1},
        status::Bool,
        solTime::Float64,
        id::String="none")
        this=SolutionM()
        this.id=id
        # this.s=s 
        this.s=sTot
        this.I=I 
        this.G=G 
        this.x=x 
        this.w=w 
        this.z=z 
        this.y=y 
        this.p=p 
        this.costs=costs
        this.status=status
        this.time=solTime
        return this
    end
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

