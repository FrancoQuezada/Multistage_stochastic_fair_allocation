using Random
using Distributions
using DataFrames
using Statistics



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
"""
function to read pv predictions from drahi building. returns values for one day with time step of 1 hour (24 values)
"""
    if contains(inFile,"Drahi")
        df=dropmissing(CSV.read(inFile,DataFrame))
        prodP=df[:,:Pmax]
        PV_det=[sum(prodP[(4*i+1):(4*(i+1))]) for i in 0:23]
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

function createDemands(J::Int64,avg::Float64,dev::Float64,tree::Tree)
    """
    function to compute a demand matrix for a single scenario with J profiles 
        avg=Vector of mean for each j in J
    """
    types=["morning","midday","night"]
    # avg1=rand((avg/J):avg)
    demand, demand_det=demandProfile(rand(types),avg,dev,tree)
    for j in 2:J
        type=rand(types)
        # avg1=rand((avg/J):avg)
        dd, dd_det=demandProfile(type,avg,dev,tree)
        demand=[demand dd]
        demand_det=[demand_det dd_det]
    end
    return permutedims(demand,[2,1]), permutedims(demand_det,[2,1])
end

function generateInstance(NBstage::Int64,childs::Int64,periods::Int64, J::Int64,inFile::String,theta::Float64,avg::Float64,dev::Float64)
    # nodes=Int(periods*((1-childs^NBstage)/(1-childs)))
    inst=InstanceM()
    inst.J=J
    inst.tree=buildTree(NBstage,childs,periods)
    # inst.c_pv=rand((ratio_pv*max_d-0.1*max_d):(ratio_pv*max_d+0.1*max_d),inst.tree.V)
    inst.T=Int(NBstage*periods)
    inst.pv_det=pv_det(inFile)
    inst.c_pv=pv_ms(inst.tree,inst.pv_det,theta)
    # inst.pv_det=[(ratio_pv*max_d-0.1*max_d+ratio_pv*max_d+0.1*max_d)/2 for t in 1:inst.T]
    nu=rand(1615.1:2228.1,inst.T)./10
    inst.nu=mapreduce(permutedims,vcat,[nu for j in 1:J])
    inst.mu=0.05*100
    inst.beta=0.1*100
    #####################################################################
    inst.d, inst.d_det=createDemands(J,avg,dev,inst.tree)
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
    inst.delta=0.25
    inst.s_max=10.0
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
