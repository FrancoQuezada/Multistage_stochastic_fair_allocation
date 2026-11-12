using Random
using Distributions
using DataFrames
using Statistics

function deterministic_seed(
    NBstage::Int64,
    childs::Int64,
    periods::Int64,
    J::Int64,
    inFile::String,
    theta::Float64,
    avg::Float64,
    dev::Float64;
    demand_profile::String="mixed"
)
    key = string(
        basename(inFile), "|",
        NBstage, "|", childs, "|", periods, "|", J, "|",
        repr(theta), "|", repr(avg), "|", repr(dev), "|", demand_profile
    )

    # Deterministic 64-bit FNV-1a style hash for reproducible RNG seeding.
    acc = UInt(1469598103934665603)
    for b in codeunits(key)
        acc = (acc ⊻ UInt(b)) * UInt(1099511628211)
    end
    return Int(mod(acc, UInt(2^31 - 1))) + 1
end


function arma(theta::Float64,T::Int64,p::Int64,errorInit1,errorInit2)
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
    # errorInit1=randn()
    # errorInit2=rand(d)
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

function pvProductionMS(tree::Tree, pvDet,theta)
    newPV=pvDet[1:tree.T]
    d=Normal(0,theta)
    errInit1=randn()
    errInit2=rand(d)
    currentT=tree.T
    currentNode=tree.T+1
    avError=arma(theta,tree.T,tree.T,errInit1,errInit2)
    for s in 2:tree.S
        for c in 1:tree.C
            error=arma(theta,tree.T,tree.T,avError[tree.parents[currentNode]],rand(d))
            vcat(avError,error)
            vcat(newPV,error.*pvDet[(currentT+1):(currentT+tree.T)])
            currentNode+=tree.C
        end
        currentT+=tree.T
    end
    return newPV
end

function pv_ms(tree::Tree,pvDet,theta::Float64)
    d=Normal(0,theta)
    initial_error=randn()
    initial_error2=rand(d)
    error=rand(d,tree.V)
    errorAv=zeros(tree.V)
    errorAv[1]=0.8*initial_error+0.2*initial_error2+error[1]
    timePeriods=createTime(tree)
    newPV=zeros(tree.V)
    for n in 2:tree.V
        errorAv[n]=0.8*errorAv[tree.parents[n]]+0.2*error[tree.parents[n]]+error[n]
        newPV[n]=max(0,pvDet[timePeriods[n]]*(1+errorAv[n]))
    end
    return newPV
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
        PV_det=[sum(prodP[(4*i+1):(4*(i+1))]) for i in 0:23] #Ajustar paso de tiempo en este caso tenemos cada 1 hora. 
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

function demandProfile(type::String,avg::Float64,dev::Float64,tree::Tree)
    """
    function to compute a demand profile with normal distribution of average avg and deviation dev during de consumption periods
        type= morning for consumption between 5am and 12.45 pm
        type= midday for consumption between 1pm and 8.45 pm
        type= night for consumption between 9pm and 4.45 am
        type= alea for consumption all day
    
    """
    d=Normal(avg,dev)
    # days=Int(ceil(T/p))
    # if T<p
    #     periods=T
    # else
    #     periods=p
    # end
    # if mod(periods,3)!=0
    #     println("profile no available")
    #     return rand(d,T)
    # end
    demand=zeros(tree.V)
    demand_det=zeros(tree.T*tree.S)
    timePeriods=createTime(tree)
    if type=="morning"
        demand_det[1:8].=avg
        for n in 1:tree.V
            if timePeriods[n] in 1:8
                demand[n]=rand(d)
            end
        end
        # demand=vcat(rand(d,Int(periods/3)),zeros(Int(periods/3)),zeros(Int(periods/3)))
        # for j in 2:days
        #     day=vcat(rand(d,Int(periods/3)),zeros(Int(periods/3)),zeros(Int(periods/3)))
        #     demand=vcat(demand,day)
        # end
    elseif type=="midday"
        demand_det[9:16].=avg
        for n in 1:tree.V
            if timePeriods[n] in 9:16
                demand[n]=rand(d)
            end
        end
        # demand=vcat(zeros(Int(periods/3)),rand(d,Int(periods/3)),zeros(Int(periods/3)))
        # for j in 2:days
        #     day=vcat(zeros(Int(periods/3)),rand(d,Int(periods/3)),zeros(Int(periods/3)))
        #     demand=vcat(demand,day)
        # end
    elseif type=="night"
        demand_det[17:24].=avg
        for n in 1:tree.V
            if timePeriods[n] in 17:24
                demand[n]=rand(d)
            end
        end
        # demand=vcat(zeros(Int(periods/3)),zeros(Int(periods/3)),rand(d,Int(periods/3)))
        # for j in 2:days
        #     day=vcat(zeros(Int(periods/3)),zeros(64),rand(d,Int(periods/3)))
        #     demand=vcat(demand,day)
        # end
    elseif type=="alea"
        demand=rand(d,tree.V)
        demand_det.=avg
    else
        println("error: profile not found")
    end
    return demand, demand_det
end

function createDemands(J::Int64,avg::Float64,dev::Float64,tree::Tree; demand_profile::String="mixed")
    """
    function to compute a demand matrix for a single scenario with J profiles 
        avg=Vector of mean for each j in J

        demand_profile="mixed": random house-by-house choice among morning/midday/night
        demand_profile="mixed2": random house-by-house choice among morning/night
        demand_profile="align_high": weighted random choice favoring midday (high PV alignment)
        demand_profile="align_medium": balanced random choice among morning/midday/night
        demand_profile="align_low": weighted random choice favoring night (low PV alignment)
    """
    types=["morning","midday","night"]
    types_mixed2=["morning","night"]
    valid_profiles=vcat(types, ["alea", "mixed", "mixed2", "align_high", "align_medium", "align_low"])
    demand_profile in valid_profiles || error("Perfil de demanda no soportado: $demand_profile")

    function pick_type()
        if demand_profile == "mixed"
            return rand(types)
        elseif demand_profile == "mixed2"
            return rand(types_mixed2)
        elseif demand_profile == "align_medium"
            return rand(types)
        elseif demand_profile == "align_high"
            u = rand()
            return u < 0.15 ? "morning" : (u < 0.85 ? "midday" : "night")
        elseif demand_profile == "align_low"
            u = rand()
            return u < 0.15 ? "morning" : (u < 0.30 ? "midday" : "night")
        end
        return demand_profile
    end

    demand, demand_det=demandProfile(pick_type(),avg,dev,tree)
    for j in 2:J
        type=pick_type()
        dd, dd_det=demandProfile(type,avg,dev,tree)
        demand=[demand dd]
        demand_det=[demand_det dd_det]
    end
    return permutedims(demand,[2,1]), permutedims(demand_det,[2,1])
end

function pea_scenarios_feasible(d::Array{Float64,2}, c_pv::Array{Float64,1}, tree::Tree)
    for scenario in tree.scenarios
        total_pv=sum(c_pv[n] for n in scenario)
        total_demand=sum(d[j,n] for j in 1:size(d,1), n in scenario)
        if total_pv > total_demand + 1e-8
            return false
        end
    end
    return true
end

function repairDemandsForPEA!(d::Array{Float64,2}, c_pv::Array{Float64,1}, tree::Tree)
    J=size(d,1)
    for n in 1:tree.V
        house_totals=d[:,n]
        total_demand=sum(house_totals)
        deficit=c_pv[n]-total_demand
        if deficit > 1e-8
            weights=total_demand > 0 ? house_totals./total_demand : fill(1.0/J, J)
            for j in 1:J
                d[j,n]+=deficit*weights[j]
            end
        end
    end
    return d
end

function deterministicDemandFromScenarios(d::Array{Float64,2}, tree::Tree)
    timePeriods=createTime(tree)
    d_det=zeros(size(d,1), tree.S*tree.T)
    for t in 1:(tree.S*tree.T)
        nodes_t=[n for n in 1:tree.V if timePeriods[n] == t]
        for j in 1:size(d,1)
            d_det[j,t]=isempty(nodes_t) ? 0.0 : mean(d[j,n] for n in nodes_t)
        end
    end
    return d_det
end

function createDemandsFeasible(
    J::Int64,
    avg::Float64,
    dev::Float64,
    tree::Tree,
    c_pv::Array{Float64,1};
    demand_profile::String="mixed"
)
    demand, _=createDemands(J,avg,dev,tree; demand_profile=demand_profile)
    repairDemandsForPEA!(demand,c_pv,tree)
    pea_scenarios_feasible(demand,c_pv,tree) || error("No se pudo reparar la demanda para garantizar factibilidad PEA.")
    demand_det=deterministicDemandFromScenarios(demand,tree)
    return demand, demand_det
end

function generateInstance(
    NBstage::Int64,
    childs::Int64,
    periods::Int64,
    J::Int64,
    inFile::String,
    theta::Float64,
    avg::Float64,
    dev::Float64;
    pv_scale::Float64=1.0,
    demand_profile::String="mixed"
)
    # nodes=Int(periods*((1-childs^NBstage)/(1-childs)))
    Random.seed!(deterministic_seed(NBstage, childs, periods, J, inFile, theta, avg, dev; demand_profile=demand_profile))
    pv_scale > 0 || error("pv_scale debe ser positivo.")
    inst=InstanceM()
    inst.J=J
    inst.tree=buildTree(NBstage,childs,periods)
    # inst.c_pv=rand((ratio_pv*max_d-0.1*max_d):(ratio_pv*max_d+0.1*max_d),inst.tree.V)
    inst.T=Int(NBstage*periods)
    inst.pv_det=pv_det(inFile)
    if pv_scale != 1.0
        inst.pv_det .*= pv_scale
    end
    inst.c_pv=pv_ms(inst.tree,inst.pv_det,theta)
    # inst.pv_det=[(ratio_pv*max_d-0.1*max_d+ratio_pv*max_d+0.1*max_d)/2 for t in 1:inst.T]
    nu=rand(1615.1:2228.1,inst.T)./10
    inst.nu=mapreduce(permutedims,vcat,[nu for j in 1:J])
    inst.mu=0.05*100
    inst.beta=0.1*100
    #####################################################################
    inst.d, inst.d_det=createDemandsFeasible(J,avg,dev,inst.tree,inst.c_pv; demand_profile=demand_profile)
    # dda1=[]
    # ddaDet1=[]
    # for j in 1:J
    #     # dd=zeros(96)
    #     a=rand(0:0.1:1)
    #     if a<0.5
    #         dd=rand(0:(max_d*10/J)*j,inst.tree.V)./10
    #         ddDet=[((max_d/J)*j)/2 for t in 1:inst.T]
    #     else
    #         dd=rand((max_d*10/(2*J))*j:(max_d*10/J)*j,inst.tree.V)./10
    #         ddDet=[((max_d/J)*j+(max_d/(2*J))*j)/2 for t in 1:inst.T]
    #     end
    #     push!(dda1,dd)
    #     push!(ddaDet1,ddDet)
    # end
    # inst.d=mapreduce(permutedims,vcat,dda1)
    # inst.d_det=mapreduce(permutedims,vcat,ddaDet1)
    ###################
    inst.delta=1.0
    inst.s_max=63.0
    inst.s_min=0.2
    inst.e_c=0.95
    inst.e_d=0.95
    inst.s_I=0.2
    inst.f_under=4.0
    inst.f_bar=4.0
    inst.timeStamp=[string(t) for t in 1:inst.tree.V]
    inst.id=string(J)*"_"*string(inst.tree.V)
    ##########################"
    return inst
end

function scaleInstance!(inst::InstanceM; battery_scale::Float64=1.0)
    battery_scale > 0 || error("battery_scale debe ser positivo.")

    if battery_scale != 1.0
        inst.s_max *= battery_scale
        inst.f_under *= battery_scale*4
        inst.f_bar *= battery_scale*4
    end

    return inst
end
