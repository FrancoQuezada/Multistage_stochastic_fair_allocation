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

function demandProfile(type::String,avg::Float64,dev::Float64,T::Int64)
    """
    function to compute a demand profile with normal distribution of average avg and deviation dev during de consumption periods
        type= morning for consumption between 5am and 12.45 pm
        type= midday for consumption between 1pm and 8.45 pm
        type= night for consumption between 9pm and 4.45 am
        type= alea for consumption all day
    only for T >= 96
    """
    d=Normal(avg,dev)
    days=Int(T/96)
    if type=="morning"
        demand=vcat(zeros(20),rand(d,32),zeros(44))
        for j in 2:days
            day=vcat(zeros(20),rand(d,32),zeros(44))
            demand=vcat(demand,day)
        end
    elseif type=="midday"
        demand=vcat(zeros(52),rand(d,32),zeros(12))
        for j in 2:days
            day=vcat(zeros(52),rand(d,32),zeros(12))
            demand=vcat(demand,day)
        end
    elseif type=="night"
        demand=vcat(rand(d,20),zeros(64),rand(d,12))
        for j in 2:days
            day=vcat(rand(d,20),zeros(64),rand(d,12))
            demand=vcat(demand,day)
        end
    elseif type=="alea"
        demand=rand(d,T)
    else
        println("error: profile not found")
        return zeros(T)
    end
    return demand
end

function demandProfile(type::String,avg::Float64,dev::Float64,T::Int64,p::Int64)
    """
    function to compute a demand profile with normal distribution of average avg and deviation dev during de consumption periods
        type= morning for consumption between 5am and 12.45 pm
        type= midday for consumption between 1pm and 8.45 pm
        type= night for consumption between 9pm and 4.45 am
        type= alea for consumption all day
    
    """
    d=Normal(avg,dev)
    days=Int(ceil(T/p))
    if T<p
        periods=T
    else
        periods=p
    end
    if mod(periods,3)!=0
        println("profile no available")
        return rand(d,T)
    end
    if type=="morning"
        demand=vcat(rand(d,Int(periods/3)),zeros(Int(periods/3)),zeros(Int(periods/3)))
        for j in 2:days
            day=vcat(rand(d,Int(periods/3)),zeros(Int(periods/3)),zeros(Int(periods/3)))
            demand=vcat(demand,day)
        end
    elseif type=="midday"
        demand=vcat(zeros(Int(periods/3)),rand(d,Int(periods/3)),zeros(Int(periods/3)))
        for j in 2:days
            day=vcat(zeros(Int(periods/3)),rand(d,Int(periods/3)),zeros(Int(periods/3)))
            demand=vcat(demand,day)
        end
    elseif type=="night"
        demand=vcat(zeros(Int(periods/3)),zeros(Int(periods/3)),rand(d,Int(periods/3)))
        for j in 2:days
            day=vcat(zeros(Int(periods/3)),zeros(64),rand(d,Int(periods/3)))
            demand=vcat(demand,day)
        end
    elseif type=="alea"
        demand=rand(d,T)
    else
        println("error: profile not found")
        return zeros(T)
    end
    return demand
end

function demandScenario(J::Int64,avg,dev::Float64,T::Int64,p::Int64)
    """
    function to compute a demand matrix for a single scenario with J profiles 
        avg=Vector of mean for each j in J
    """
    types=["morning","midday","night"]
    # avg1=rand((avg/J):avg)
    demand=demandProfile(rand(types),avg[1],dev,T,p)
    for j in 2:J
        type=rand(types)
        # avg1=rand((avg/J):avg)
        dd=demandProfile(type,avg[j],dev,T,p)
        demand=[demand dd]
    end
    return permutedims(demand,[2,1])
end

function pv_det(inFile::String)
    if contains(inFile,"Drahi")
        # Random.seed!(1234)
        # J=7
        df=dropmissing(CSV.read(inFile,DataFrame))
        # id=String(df[:,"Date and time (UTC)"][1][1:findfirst(" ",df[:,"Date and time (UTC)"][1])[1]-1])
        # dda=[df[:,"T"*string(i)] for i in 1:J]
        # dda=mapreduce(permutedims, vcat, dda)
        prodP=df[:,:Pmax]
        PV_det=[sum(prodP[(4*i+1):(4*(i+1))]) for i in 0:23]
        # T=24
        # time=[String(df[:,"Date and time (UTC)"][4*(i-1)+1][1:(findfirst(" ",df[:,"Date and time (UTC)"][i])[4*1]+5)]) for i in 1:T]
        # dTot=[(sum(dda[j,t] for t in 1:T),j) for j in 1:J]
        # sort!(dTot, by = x -> x[1])
        # dda_order=[dda[j[2],t] for j in dTot, t in 1:T]
        # delta=1.0
        # if alea && prices
        #     nu=rand(0.1615:0.0001:0.2228,J,T)
        # elseif alea
        #     # prices=Float64[]
        #     # p=[900:0.5:910, 900:0.5:910, 5:0.1:10, 5:0.1:10, 5:0.1:10, 5:0.1:10, 900:0.1:910, 900:0.5:910]
        #     # for i in 1:8
        #     #     pr=rand(p[i],12)
        #     #     prices=[prices ; pr]
        #     # end
        #     # nu=repeat(prices,Int(T/96))
        #     nu=rand(0.1615:0.0001:0.2228,T)
        #     nu=mapreduce(permutedims,vcat,[nu for j in 1:J])
        # else
        #     nu=[0.2228 for j in 1:J, t in 1:T]
        # end
        # inst=Instance(s_max,s_min,delta,e_c,e_d,s_I,dda_order,J,T,mu,beta,10*nu,minimum([disL,sum(dda_order)/(e_c*e_d)]),minimum([disL,sum(dda_order)/(e_c*e_d)]),prodP.*(300/1000),time,id)
        return PV_det.*(300/1000)
    end
end