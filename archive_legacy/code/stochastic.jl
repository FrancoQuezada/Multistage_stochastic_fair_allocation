include("structures.jl")
include("parameters.jl")
include("epp.jl")
 

function twoS(inst::Instance,fairness::String,lambdaS=zeros(10,10),EEV=false)
    """
    Function to solve a two stage stochastic program
    Omega=numero de escenarios
    """
    model = Model(CPLEX.Optimizer)
    ################Variables#######################
    @variable(model,inst.s_min<=s[1:inst.T,1:inst.Omega]<=inst.s_max) #total battery
    @variable(model, I[1:inst.J,1:inst.T,1:inst.Omega]>=0) #grid
    @variable(model, G[1:inst.J,1:inst.T,1:inst.Omega]>=0) #grid
    @variable(model, z[1:inst.J,1:inst.T,1:inst.Omega]>=0) #charge of battery
    @variable(model, y[1:inst.J,1:inst.T,1:inst.Omega]>=0) #discharge of battery
    @variable(model, p[1:inst.J,1:inst.T,1:inst.Omega]>=0) #photovoltaic production
    @variable(model, lambda[1:inst.J,1:inst.T]>=0)
    # @variable(model, x[1:inst.J,1:inst.T,1:inst.Omega], Bin) #battery set-up charge
    # @variable(model, g[1:inst.J,1:inst.T,1:inst.Omega], Bin) #vender o comprar grid
    ################################################
    if EEV
        fix.(lambda,lambdaS;force = true)
    end
    ################Constraints###################
    # @constraint(model, [j in 1:inst.J, t in 1:inst.T,o in 1:inst.Omega], z[j,t,o]<=inst.f_under*x[j,t,o])
    # @constraint(model, [j in 1:inst.J, t in 1:inst.T,o in 1:inst.Omega], y[j,t,o]<=(inst.f_bar)*(1-x[j,t,o]))
    # @constraint(model, [j in 1:inst.J, t in 1:inst.T,o in 1:inst.Omega], I[j,t,o]<=1000000*g[j,t,o])
    # @constraint(model, [j in 1:inst.J, t in 1:inst.T,o in 1:inst.Omega], G[j,t,o]<=1000000*(1-g[j,t,o]))
    @constraint(model, [j in 1:inst.J, t in 1:inst.T, o in 1:inst.Omega], p[j,t,o] ==lambda[j,t]*inst.c_pv[t,o])
    @constraint(model, [t in 1:inst.T], sum(lambda[:,t]) == 1)
    # @constraint(model, [t in 1:inst.T, o in 1:Omega], s[t,o]<=inst.s_max)
    @constraint(model, [t in 2:inst.T, o in 1:inst.Omega], s[t,o]==s[t-1,o]+inst.delta*inst.e_c*sum(z[j,t,o] for j in 1:inst.J)-inst.delta*sum(y[j,t,o] for j in 1:inst.J)/inst.e_d)
    @constraint(model, [o in 1:inst.Omega], s[1,o]==inst.s_I+inst.delta*inst.e_c*sum(z[j,1,o] for j in 1:inst.J)-inst.delta*sum(y[j,1,o] for j in 1:inst.J)/inst.e_d)
    @constraint(model, [t in 1:inst.T, o in 1:inst.Omega], sum(y[j,t,o] for j in 1:inst.J)<=inst.f_bar)
    @constraint(model, [t in 1:inst.T, o in 1:inst.Omega], sum(z[j,t,o] for j in 1:inst.J)<=inst.f_under)
    @constraint(model, [j in 1:inst.J, t in 1:inst.T, o in 1:inst.Omega], inst.d[j,t,o]==p[j,t,o]+y[j,t,o]+I[j,t,o]-z[j,t,o]-G[j,t,o])
    @constraint(model,[o in 1:inst.Omega], s[inst.T, o]==inst.s_I)
    @expression(model, costs[j in 1:inst.J], (inst.delta)*sum((inst.mu*y[j,t,o] +inst.nu[j,t]*I[j,t,o] - inst.beta*G[j,t,o])*inst.rho[o]  for t in 1:inst.T, o in 1:inst.Omega)) 
    
    ##### fairness
    if fairness=="SPEA"
        @constraint(model, [j in 1:inst.J, o in 1:inst.Omega] , sum(p[j,t,o] for t in 1:inst.T)==(sum(inst.c_pv[t,o] for t in 1:inst.T)/sum(inst.d[k,t,o] for t in 1:inst.T, k in 1:inst.J))*sum(inst.d[j,t,o] for t in 1:inst.T))
    elseif fairness=="aggregated PEA"
        @constraint(model, [j in 1:inst.J] , sum(inst.rho[o]*p[j,t,o] for t in 1:inst.T, o in 1:inst.Omega)==sum(inst.rho[o]*(sum(inst.c_pv[t,o] for t in 1:inst.T)/sum(inst.d[k,t,o] for t in 1:inst.T, k in 1:inst.J))*sum(inst.d[j,t,o] for t in 1:inst.T) for o in 1:inst.Omega))
    elseif fairness=="SSA"
        @expression(model, costTime[j in 1:inst.J, o in 1:inst.Omega], (inst.delta)*sum(inst.mu*y[j,t,o] +inst.nu[j,t]*I[j,t,o] - inst.beta*G[j,t,o] for t in 1:inst.T))  
        @constraint(model,[j in 1:inst.J, o in 1:inst.Omega],(inst.delta*sum(inst.nu[j,t]*inst.d[j,t,o] for t in 1:inst.T)-costTime[j,o])/sum(inst.delta*inst.nu[j,t]*inst.d[j,t,o] for t in 1:inst.T)==(sum(inst.delta*inst.nu[k,t]*inst.d[k,t,o] for t in 1:inst.T, k in 1:inst.J)-sum(costTime[k,o] for k in 1:inst.J))/sum(inst.delta*inst.nu[k,t]*inst.d[k,t,o] for t in 1:inst.T, k in 1:inst.J))
    elseif fairness=="aggregated SA"
        @expression(model, costTime[j in 1:inst.J, o in 1:inst.Omega], (inst.delta)*sum(inst.mu*y[j,t,o] +inst.nu[j,t]*I[j,t,o] - inst.beta*G[j,t,o] for t in 1:inst.T))
        @constraint(model, [j in 1:inst.J],sum(inst.rho[o]*(inst.delta*sum(inst.nu[j,t]*inst.d[j,t,o] for t in 1:inst.T)-costTime[j,o]) for o in 1:inst.Omega)==sum(inst.rho[o]*((sum(inst.delta*inst.nu[k,t]*inst.d[k,t,o] for t in 1:inst.T, k in 1:inst.J)-sum(costTime[k,o] for k in 1:inst.J))/sum(inst.delta*inst.nu[k,t]*inst.d[k,t,o] for t in 1:inst.T, k in 1:inst.J))*sum(inst.delta*inst.nu[j,t]*inst.d[j,t,o] for t in 1:inst.T) for o in 1:inst.Omega))
    elseif fairness=="S newPEA"
        @constraint(model, [j in 1:inst.J, o in 1:inst.Omega] , sum(p[j,t,o] + y[j,t,o] - z[j,t,o] for t in 1:inst.T)==(sum(inst.c_pv[t,o] - sum(z[k,t,o] for k in 1:inst.J) for t in 1:inst.T )/sum(inst.d[k,t,o] for t in 1:inst.T, k in 1:inst.J))*sum(inst.d[j,t,o] for t in 1:inst.T))
    elseif fairness=="aggregated newPEA"
        @constraint(model, [j in 1:inst.J] , sum(inst.rho[o]*sum(p[j,t,o] + y[j,t,o] - z[j,t,o] for t in 1:inst.T) for o in 1:inst.Omega)==sum(inst.rho[o]*(sum(inst.c_pv[t,o] - sum(z[k,t,o] for k in 1:inst.J) for t in 1:inst.T )/sum(inst.d[k,t,o] for t in 1:inst.T, k in 1:inst.J))*sum(inst.d[j,t,o] for t in 1:inst.T) for o in 1:inst.Omega))
    end
    ######### 
    

    @objective(model, Min, sum(costs[j] for j in 1:inst.J))
    set_attribute(model, "CPXPARAM_TimeLimit", 60*10)
    # set_attribute(model, "CPXPARAM_Emphasis_Numerical", 1)
    # set_attribute(model, "CPXPARAM_Simplex_Limits_Iterations", 0)
    # set_attribute(model,"CPXPARAM_Simplex_Tolerances_Feasibility",1e-9)
    # set_silent(model)
    optimize!(model)

    if has_values(model)
        println("Objective : ",round(objective_value(model),digits=3))
        sol=Solution()
        sol.costs=value.(costs)
        sol.lambda=value.(lambda)
        sol.y=value.(y)
        sol.z=value.(z)
        sol.I=value.(I)
        sol.p=value.(p)
        sol.s=value.(s)
        sol.G=value.(G)
        # sol.w=value.(g)
        # sol.x=value.(x)
        sol.status=termination_status(model)==OPTIMAL
        sol.time=round(solve_time(model), digits=2)
        sol.id=inst.id
        # sol=Solution(sTotAux,iAux,GAux,xAux,wAux,zAux,yAux,pAux,costsAux,true,solTime,inst.id)
    else
        println("INFEASIBLE")
        costsAux=fill(Inf,inst.J)
        # lambdaAux=zeros(inst.J,inst.T)
        sol=Solution()
        sol.id=inst.id
        sol.status=false
        sol.time=round(solve_time(model), digits=2)
        # yAux=zeros(inst.J,inst.T)
        # zAux=zeros(inst.J,inst.T)
        # iAux=zeros(inst.J,inst.T)
        # pAux=zeros(inst.J,inst.T)
        # sTotAux=zeros(inst.T)
        # GAux=zeros(inst.J,inst.T)
        # wAux=zeros(inst.J,inst.T)
        # xAux=zeros(inst.J,inst.T)
        # solTime=round(solve_time(model), digits=2)  
        # sol=Solution(sTotAux,iAux,GAux,xAux,wAux,zAux,yAux,pAux,costsAux,false,solTime,inst.id)
    end
    
    return sol

end


function create2S(Omega::Int64,max_d::Float64, theta::Float64, J::Int64, T::Int64,inFile::String)
    inst=Instance()
    inst.T=T
    inst.J=J
    inst.pv_det=pv_det(inFile) #for now, later we will use real predictions
    inst.c_pv=pvProduction(Omega,theta,inst.T,inst.pv_det)
    # inst.d=rand(0:max_d*10,J,T,Omega)./10
    avg=rand((max_d/J):max_d,J)
    dd=[demandScenario(J,avg,0.8,T,T) for _ in 1:Omega]
    inst.d=stack(dd)
    inst.d_det=[avg[j] for j in 1:J, t in 1:T] #change the deterministic values
    nu=rand(1615.1:2228.1,T)./10
    inst.nu=mapreduce(permutedims,vcat,[nu for j in 1:J])
    inst.mu=0.05*100
    inst.beta=0.1*100
    ###################
    inst.delta=1.0
    inst.s_max=63.0
    inst.s_min=0.2
    inst.e_c=0.95
    inst.e_d=0.95
    inst.s_I=0.2
    inst.f_under=4.0
    inst.f_bar=4.0
    inst.timeStamp=[string(t) for t in 1:inst.T]
    inst.id=string(inst.J)*"_"*string(inst.T)
    inst.Omega=Omega
    inst.rho=Float64[1/Omega for o in 1:Omega]
    ##########################"
    # inst=Instance(s_max,s_min,delta,e_c,e_d,s_I,ddaDet,J,T,mu,beta,nu,disL,chargeL,pvDet,time,id)
    return inst
end

# function main()
#     # NBstage=[6,8]
#     # childs=[2,4]
#     # periods=[1,2,4]
#     Omega=[32,128,512,1024,16384]
#     ratio_pv=[0.2,0.4,0.6]
#     max_d=200.0
#     fairness="aggregated SA"
#     J=5
#     T=24
#     # resultsFolder="../res/stochastic"
#     df=DataFrame()
#     df[!,"Scenarios"]=[]
#     # df[!,"C"]=[]
#     # df[!,"P"]=[]
#     df[!,"ratio"]=[]
#     # df[!,"EEV"]=[]
#     # df[!,"RP"]=[]
#     df[!,"VSS"]=[]
#     # df[!,"Time"]=[]
#     # if !isdir(resultsFolder)
#     #     mkdir(resultsFolder)
#     # end
#     for ss in Omega
#         # for c in childs
#         #     for p in periods
#         #         scenarioTree=buildTree(s,c, p)
#                 for ratio in ratio_pv
#                     vssM=0
#                     for _ in 1:10
#                         inst=create2S(ss,max_d,ratio,J,T)
#                         solDet, barP=solve!(inst,"Proportional SA")
#                         # barP=[detSol.p[j,t]/inst.c_pv[t] for j in 1:inst.J, t in 1:inst.T]
#                         # twoS(Omega::Int64,d::Array{Float64,3},c_pv::Array{Float64,2}, inst::Instance,lambdaS=zeros(10,10),EEV=false)
#                         eev=twoS(inst,fairness,barP,true)
#                         rp=twoS(inst,fairness)
#                         # println(rp)
#                         vss=((sum(eev.costs)-sum(rp.costs))/sum(rp.costs))*100
#                         vssM+=vss
#                         # push!(df,[s,c,p,ratio,sum(eev.costs),sum(rp.costs),vss])
#                     end
#                     push!(df,[ss,ratio,vssM/10])
#                     CSV.write("../figs/excel/stoch2sASA.csv" ,df)
#                 end
#             # end
#         # end
#     end
#     CSV.write("../figs/excel/stoch2sASA.csv" ,df)
# end


# Omega=10
# J=3
# T=6
# d=100.0
# ratio=0.2
# instance2S=create2S(Omega,200.0,0.2,J,T)
# fairness="SSA"
# lambdass,costsss=twoS(Omega, dda,c_pv, instance2S, fairness, Float64[1/Omega for o in 1:Omega])
# detSol=solve!(instance2S,"Proportional SA")
# barP=[detSol.p[j,t]/instance2S.c_pv[t] for j in 1:instance2S.J, t in 1:instance2S.T]
# sol1 = twoS(instance2S, fairness)
# inst=create2S(Omega,d,ratio,J,T)
# sol=twoS(inst,fairness)
# main()
# NBstage=12
# childs=2
# periods=8
# NBnodes=Int(periods*((1-childs^NBstage)/(1-childs)))
# parents, stages, rho= buildTree(NBstage,childs, periods)
# timeHorizon=Int(NBstage*periods)
# scenariosVar=findScenario(NBnodes,NBstage,stages,parents)

# @show timeperiods=createTime(stages,NBstage,periods,parents,nodes)
# scenarioTree=buildTree(NBstage,childs, periods)
# houses=10
# barP=[1/houses for j in 1:houses, t in 1:timeHorizon]

# fairness="_"
# inst, instDet=generatesInstance(scenarioTree,houses,400.0,200.0,true)
# instDet=deepcopy(inst)
# instDet.T=timeHorizon
# instDet.d=[sum(inst.d[j,n] for n in 1:scenarioTree.V)/(scenarioTree.V) for j in 1:instDet.J, t in 1:instDet.T]
# inst.c_pv.=(37*15/2)
# detSol=solve!(instDet,"EPPL")
# barP=[detSol.p[j,t]/instDet.c_pv[t] for j in 1:instDet.J, t in 1:instDet.T]
# eev=EEV(inst,scenarioTree,fairness, barP)
# rp=solveStochastic(inst,scenarioTree,fairness)
# dif= ((sum(eev.costs)-sum(rp.costs))/sum(rp.costs))*100

# sol2=solveStochastic(inst,NBstage,childs,periods,"_")
