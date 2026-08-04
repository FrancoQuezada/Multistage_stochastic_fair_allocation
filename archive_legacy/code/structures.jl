using DataFrames
using CSV
using JuMP
# using Colors
# using JuMP, AmplNLWriter, Bonmin_jll
using CPLEX
# using Juniper
# using Ipopt
using Random
using Distributions
# using Random
# using PlotlyJS




mutable struct Instance
    """
    Structure to save the instance 
    """
    ######sets##########
    J::Int64 #set of houses
    T::Int64 #time horizon
    Omega::Int64 #number of scenarios
    #######Battery Param######
    s_max::Float64# Storage capacity
    s_min::Float64# Storage capacity
    delta::Float64# time step
    e_c::Float64# charge efficiency
    e_d::Float64#discharge efficiency
    s_I::Float64 #initial state of the battery
    f_under::Float64 #discharge limit
    f_bar::Float64 #charge limit
    ######Prices#########
    mu::Float64 #maintenance cost
    beta::Float64 #price of selling electricity
    nu::Array{Float64,2} #price of energy
    #######stochasticParam#########
    c_pv::Array{Float64,2} #PV production per scenario and time
    pv_det::Array{Float64,1}
    d::Array{Float64,3} #demand
    d_det::Array{Float64,2} #demand
    rho::Vector{Float64} #probabilities
    ##########working Param###########
    id::String # Date (yyyy-mm-dd)
    timeStamp::Array{String,1} #time stamp for each time step

    function Instance()
       return new()
    end
    function Instance(s_max::Float64,
        s_min::Float64,
        delta::Float64,
        eff::Float64,
        e_d::Float64,
        s_I::Float64,
        dda::Array{Float64,3},
        d_det::Array{Float64,2},
        J::Int64,
        T::Int64,
        Omega::Int64,
        mu::Float64,
        beta::Float64,
        b::Array{Float64,2},
        disL::Float64,
        chargeL::Float64,
        photoProd::Array{Float64,2},
        pv_det::Array{Float64,1},
        rho::Vector{Float64},
        timeStamp::Array{String,1},
        id::String="none")


        this=Instance()
        this.id=id
        this.Omega=Omega
        this.pv_det=pv_det
        this.d_det=d_det
        this.rho=rho
        this.s_max=s_max
        this.s_min=s_min
        this.delta=delta
        this.e_c=eff
        this.e_d=e_d
        this.s_I=s_I
        this.d=dda
        this.J=J
        this.T=T
        this.mu=mu
        this.beta=beta
        this.nu=b
        this.f_under=disL
        this.f_bar=chargeL
        this.timeStamp=timeStamp
        this.c_pv=photoProd
        return this
    end

end

mutable struct Solution
    id::String
    s::Array{Float64,2} #total battery level
    I::Array{Float64,3} #import grid
    G::Array{Float64,3} #export grid
    x::Array{Float64,3} #battery set-up charge
    w::Array{Float64,3} #vender o comprar grid
    z::Array{Float64,3} #charge of battery
    y::Array{Float64,3} #discharge of battery
    p::Array{Float64,3} #photovoltaic production
    lambda::Array{Float64,2}
    costs::Array{Float64,1} #cost for each house
    status::Bool #if the instance is solved
    time::Float64 #resolution time

    function Solution()
        return new()
    end

    function Solution(
        # s::Array{Float64,2}, #battery
        sTot::Array{Float64,2}, #total battery level
        I::Array{Float64,3}, #import grid
        G::Array{Float64,3}, #export grid
        x::Array{Float64,3}, #battery set-up charge
        w::Array{Float64,3}, #vender o comprar grid
        z::Array{Float64,3}, #charge of battery
        y::Array{Float64,3}, #discharge of battery
        p::Array{Float64,3}, #photovoltaic production
        lambda::Array{Float64,2},
        costs::Array{Float64,1},
        status::Bool,
        solTime::Float64,
        id::String="none")
        this=Solution()
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
        this.lambda=lambda
        this.costs=costs
        this.status=status
        this.time=solTime
        return this
    end

end

function arma(theta,T)
    """
    Function to compute the error factor for the arma (1,1) method
    """
    errorAv=Float64[]
    days=Int(ceil(T/96))
    if T<96
        periods=T
    else
        periods=96
    end
    d=Normal(0,theta)
    errorInit1=randn()
    errorInit2=rand(d)
    for day in 1:days
        error=rand(d,periods)
        push!(errorAv,0.8*errorInit1+0.2*errorInit2+error[1])
        for t in 2:periods
            e_t=0.8*errorAv[t-1]+0.2*error[t-1]+error[t]
            push!(errorAv,e_t)
        end
    end
    return errorAv
end

function pvProduction(Omega,theta,T,pv_det)
    pvStoch=Vector[]
    for o in 1:Omega
        errors=arma(theta,T).+1
        # println(errors)
        pv=[maximum([pv_det[t]*errors[t],0]) for t in 1:T]
        push!(pvStoch,pv)
    end
    pvStoch=stack(pvStoch,dims=2)
    return pvStoch
end
