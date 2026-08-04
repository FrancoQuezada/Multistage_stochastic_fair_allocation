using Random
using Distributions
using DataFrames

function arma(theta::Float64,T::Int64,p::Int64)
    """
    Function to compute T error factors with the arma (1,1) method
    with theta de deviation of the error, p the number of periods per day
    """
    errorAv=Float64[]
    days=Int(ceil(T/p))
    if T<p
        periods=T
    else
        periods=p
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

function pvProduction(Omega::Int64,theta::Float64,T::Int64,pv_det::Array{Float64,1},p::Int64)
    """
    function to compute the pv electricity production for a set of Omega scenarios given a deterministic prediction of the pv
    with p periods per day
    """
    pvStoch=Vector[]
    for o in 1:Omega
        errors=arma(theta,T,p).+1
        # println(errors)
        pv=[maximum([pv_det[t]*errors[t],0]) for t in 1:T]
        push!(pvStoch,pv)
    end
    pvStoch=stack(pvStoch,dims=2)
    return pvStoch
end