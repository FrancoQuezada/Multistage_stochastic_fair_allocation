include("structuresMulti.jl")
include("parametersMS.jl")
include("epp.jl")
# Random.seed!(1234)
TL=60*10
function solveMulti(inst::InstanceM,fairness::String,lambdaS=zeros(10,10), EEV=false)
    scenarioTree=inst.tree
    model = Model(CPLEX.Optimizer)
    timePeriods=createTime(scenarioTree)
    ################Variables#######################
    @variable(model,s[1:scenarioTree.V]>=0) #total battery
    @variable(model, I[1:inst.J,1:scenarioTree.V]>=0) #grid
    @variable(model, G[1:inst.J,1:scenarioTree.V]>=0) #grid
    @variable(model, z[1:inst.J,1:scenarioTree.V]>=0) #charge of battery
    @variable(model, y[1:inst.J,1:scenarioTree.V]>=0) #discharge of battery
    @variable(model, p[1:inst.J,1:scenarioTree.V]>=0) #photovoltaic production
    @variable(model, lambda[1:inst.J,1:scenarioTree.V]>=0)
    @variable(model, x[1:inst.J,1:scenarioTree.V], Bin) #battery set-up charge
    @variable(model, g[1:inst.J,1:scenarioTree.V], Bin) #vender o comprar grid
    ################Constraints###################
    if EEV
        lambdaN=[lambdaS[j, timePeriods[t]] for j in 1:inst.J, t in 1:scenarioTree.V]
        fix.(lambda,lambdaN;force = true)
    end
    @constraint(model, [j in 1:inst.J, t in 1:scenarioTree.V], z[j,t]<=inst.f_under*x[j,t])
    @constraint(model, [j in 1:inst.J, t in 1:scenarioTree.V], y[j,t]<=(inst.f_bar)*(1-x[j,t]))
    @constraint(model, [j in 1:inst.J, t in 1:scenarioTree.V], I[j,t]<=1000000*g[j,t])
    @constraint(model, [j in 1:inst.J, t in 1:scenarioTree.V], G[j,t]<=1000000*(1-g[j,t]))
    @constraint(model, [j in 1:inst.J, n in 1:scenarioTree.V], p[j,n] ==lambda[j,n]*inst.c_pv[n])
    @constraint(model, [t in 1:scenarioTree.V], sum(lambda[:,t]) == 1)
    # @constraint(model, [n in 1:scenarioTree.V], sum(p[j,n] for j in 1:inst.J)==inst.c_pv[n])
    @constraint(model, [n in 1:scenarioTree.V], s[n]<=inst.s_max)
    @constraint(model, [n in 2:scenarioTree.V], s[n]==s[scenarioTree.parents[n]]+inst.delta*inst.e_c*sum(z[j,n] for j in 1:inst.J)-inst.delta*sum(y[j,n] for j in 1:inst.J)/inst.e_d)
    @constraint(model, s[1]==inst.s_I+inst.delta*inst.e_c*sum(z[j,1] for j in 1:inst.J)-inst.delta*sum(y[j,1] for j in 1:inst.J)/inst.e_d)
    @constraint(model, [n in 1:scenarioTree.V], sum(y[j,n] for j in 1:inst.J)<=inst.f_bar)
    @constraint(model, [n in 1:scenarioTree.V], sum(z[j,n] for j in 1:inst.J)<=inst.f_under)
    @constraint(model, [j in 1:inst.J, n in 1:scenarioTree.V], inst.d[j,n]==p[j,n]+y[j,n]+I[j,n]-z[j,n]-G[j,n])
    @constraint(model, [n in 1:scenarioTree.V ; timePeriods[n]==inst.T],s[n]==inst.s_I)
    @constraint(model,[n in 1:scenarioTree.V], s[n]>=inst.s_min)
    
    @expression(model, costs[j in 1:inst.J], (inst.delta)*sum(scenarioTree.rho[n]*(inst.mu*y[j,n] +inst.nu[j,timePeriods[n]]*I[j,n] - inst.beta*G[j,n])  for n in 1:scenarioTree.V)) 
    # @expression(model, costs[j in 1:inst.J], (inst.delta)*sum(scenarioTree.rho[n]*(inst.mu*y[j,n] +inst.nu[1,n]*I[j,n] - inst.beta*G[j,n])  for n in 1:scenarioTree.V)) 
    
    ##### fairness
    if fairness=="SPEA"
        @constraint(model, [j in 1:inst.J, scenario in scenarioTree.scenarios] , sum(p[j,t] for t in scenario)==(sum(inst.c_pv[t] for t in scenario)/sum(inst.d[k,t] for t in scenario, k in 1:inst.J))*sum(inst.d[j,t] for t in scenario))
    elseif fairness=="EPEA"
        # println("aggregated")
        @constraint(model, [j in 1:inst.J] , sum(scenarioTree.rho[scenario[inst.T]]*sum(p[j,t] for t in scenario) for scenario in scenarioTree.scenarios) ==sum(scenarioTree.rho[scenario[inst.T]]*(sum(inst.c_pv[t] for t in scenario)/sum(inst.d[k,t] for t in scenario, k in 1:inst.J))*sum(inst.d[j,t] for t in scenario) for scenario in scenarioTree.scenarios))
    elseif fairness=="ECPEA"
        for stage in 1:scenarioTree.S
            nodes_parents=[n for n in 1:scenarioTree.V if timePeriods[n]==stage*scenarioTree.T]
            for n in nodes_parents
                scenarios_n=[sort(s) for s in scenarioTree.scenarios if n in s]
                position=timePeriods[n]
                @constraint(model, [j in 1:inst.J] ,sum(scenarioTree.rho[scenario[inst.T]]*sum(p[j,t] for t in scenario[position:inst.T])*sum(inst.d[k,t] for t in scenario[position:inst.T], k in 1:inst.J) for scenario in scenarios_n) == sum(scenarioTree.rho[scenario[inst.T]]*(sum(inst.c_pv[t] for t in scenario[position:inst.T]))*sum(inst.d[j,t] for t in scenario[position:inst.T]) for scenario in scenarios_n))
            end
        end
    elseif fairness=="SWPEA"
        for stage in 1:scenarioTree.S
            # stage_nodes = [n for n in 1:scenarioTree.V if scenarioTree.stages[n] == stage]
            # scenarios_stage = 
            @constraint(model, [j in 1:inst.J], 
            sum(scenarioTree.rho[scenario[inst.T]]*
            sum(p[j,n] for n in scenario if scenarioTree.stages[n] == stage)*
            sum(inst.d[k,n]     for k in 1:inst.J, n in scenario if scenarioTree.stages[n] == stage)  for scenario in scenarioTree.scenarios)
            ==
            sum(scenarioTree.rho[scenario[inst.T]]*
            sum(inst.c_pv[n]    for n in scenario if scenarioTree.stages[n] == stage)*
            sum(inst.d[j,n]     for n in scenario if scenarioTree.stages[n] == stage) for scenario in scenarioTree.scenarios))
        end
    elseif fairness=="SSA"
        @expression(model, costTime[j in 1:inst.J, t in 1:scenarioTree.V], (inst.delta)*(inst.mu*y[j,t] +inst.nu[j,timePeriods[t]]*I[j,t] - inst.beta*G[j,t]))  
        @constraint(model,[j in 1:inst.J, scenario in scenarioTree.scenarios],(inst.delta*sum(inst.nu[j,timePeriods[t]]*inst.d[j,t] for t in scenario)-sum(costTime[j,t] for t in scenario))/sum(inst.delta*inst.nu[j,timePeriods[t]]*inst.d[j,t] for t in scenario)==(sum(inst.delta*inst.nu[k,timePeriods[t]]*inst.d[k,t] for t in scenario, k in 1:inst.J)-sum(costTime[k,t] for t in scenario, k in 1:inst.J))/sum(inst.delta*inst.nu[k,timePeriods[t]]*inst.d[k,t] for t in scenario, k in 1:inst.J))
    elseif fairness=="ESA"
        # SS=length(scenarioTree.scenarios)
        @expression(model, costTime[j in 1:inst.J, t in 1:scenarioTree.V], (inst.delta)*(inst.mu*y[j,t] +inst.nu[j,timePeriods[t]]*I[j,t] - inst.beta*G[j,t]))  
        @constraint(model, [j in 1:inst.J], sum(scenarioTree.rho[scenario[inst.T]]*(inst.delta*sum(inst.nu[j,timePeriods[t]]*inst.d[j,t] for t in scenario)-sum(costTime[j,t] for t in scenario))/sum(inst.delta*inst.nu[j,timePeriods[t]]*inst.d[j,t] for t in scenario) for scenario in scenarioTree.scenarios)==sum(scenarioTree.rho[scenario[inst.T]]*(sum(inst.delta*inst.nu[k,timePeriods[t]]*inst.d[k,t] for t in scenario, k in 1:inst.J)-sum(costTime[k,t] for t in scenario, k in 1:inst.J))/sum(inst.delta*inst.nu[k,timePeriods[t]]*inst.d[k,t] for t in scenario, k in 1:inst.J) for scenario in scenarioTree.scenarios)) #add probabilities not quite sure
    elseif fairness=="ECSA"
        @expression(model, costTime[j in 1:inst.J, t in 1:scenarioTree.V], (inst.delta)*(inst.mu*y[j,t] +inst.nu[j,timePeriods[t]]*I[j,t] - inst.beta*G[j,t]))
        #for n in 1:scenarioTree.V
        for stage in 1:scenarioTree.S
            nodes_parents=[n for n in 1:scenarioTree.V if timePeriods[n]==stage*scenarioTree.T]
            for n in nodes_parents
                scenarios_n=[sort(s) for s in scenarioTree.scenarios if n in s]
                position=timePeriods[n]
                # @constraint(model, [j in 1:inst.J], sum(scenarioTree.rho[scenario[inst.T]]*(inst.delta*sum(inst.nu[j,timePeriods[t]]*inst.d[j,t] for t in scenario[position:inst.T])-sum(costTime[j,t] for t in scenario[position:inst.T])) for scenario in scenarios_n) == sum(scenarioTree.rho[scenario[inst.T]]*(sum(inst.delta*inst.nu[k,timePeriods[t]]*inst.d[k,t] for t in scenario[position:inst.T], k in 1:inst.J)-sum(costTime[k,t] for t in scenario[position:inst.T], k in 1:inst.J))*sum(inst.delta*inst.nu[j,timePeriods[t]]*inst.d[j,t] for t in scenario[position:inst.T])/sum(inst.delta*inst.nu[k,timePeriods[t]]*inst.d[k,t] for t in scenario[position:inst.T], k in 1:inst.J) for scenario in scenarios_n))
                @constraint(model, [j in 1:inst.J], sum(scenarioTree.rho[scenario[inst.T]]*sum(costTime[j,t] for t in scenario[position:inst.T])*sum(inst.delta*inst.nu[k,timePeriods[t]]*inst.d[k,t] for t in scenario[position:inst.T], k in 1:inst.J) for scenario in scenarios_n) == sum(scenarioTree.rho[scenario[inst.T]]*sum(costTime[k,t] for t in scenario[position:inst.T], k in 1:inst.J)*sum(inst.delta*inst.nu[j,timePeriods[t]]*inst.d[j,t] for t in scenario[position:inst.T]) for scenario in scenarios_n))
            end
        end
    elseif fairness=="SWSA"
        @expression(model, costTime[j in 1:inst.J, t in 1:scenarioTree.V], (inst.delta)*(inst.mu*y[j,t] +inst.nu[j,timePeriods[t]]*I[j,t] - inst.beta*G[j,t]))
        for stage in 1:scenarioTree.S
            # stage_nodes = [n for n in 1:scenarioTree.V if scenarioTree.stages[n] == stage]
            # scenarios_stage = 
            @constraint(model, [j in 1:inst.J], 
            sum(scenarioTree.rho[scenario[inst.T]]*
            sum(costTime[j,n] for n in scenario if scenarioTree.stages[n] == stage)*
            sum(inst.delta*inst.nu[k,timePeriods[n]]*inst.d[k,n]     for k in 1:inst.J, n in scenario if scenarioTree.stages[n] == stage)  for scenario in scenarioTree.scenarios)
            ==
            sum(scenarioTree.rho[scenario[inst.T]]*
            sum(costTime[k,n]    for k in 1:inst.J, n in scenario if scenarioTree.stages[n] == stage)*
            sum(inst.delta*inst.nu[j,timePeriods[n]]*inst.d[j,n]     for n in scenario if scenarioTree.stages[n] == stage) for scenario in scenarioTree.scenarios))
        end
    end
    ######### 
    

    @objective(model, Min, sum(costs[j] for j in 1:inst.J))

    set_attribute(model, "CPXPARAM_TimeLimit", TL)
    # set_attribute(model, "CPXPARAM_Emphasis_Numerical", 1)
    # set_attribute(model, "CPXPARAM_Preprocessing_Presolve", 0)
    # set_attribute(model,"CPXPARAM_Simplex_Tolerances_Feasibility",1e-8)
    set_silent(model)
    optimize!(model)
    println(termination_status(model))
    if has_values(model)
        println("Objective : ",round(objective_value(model),digits=3))
        costsAux=value.(costs)
        yAux=value.(y)
        zAux=value.(z)
        iAux=value.(I)
        pAux=value.(p)
        if contains(fairness,"SA")
            costNode=value.(costTime)
            ssa=[sum(inst.delta*inst.nu[j,timePeriods[t]]*inst.d[j,t] for t in scenario)*sum(costNode[k,t] for t in scenario, k in 1:inst.J)/sum(inst.delta*inst.nu[k,timePeriods[t]]*inst.d[k,t] for t in scenario, k in 1:inst.J) for j in 1:inst.J, scenario in scenarioTree.scenarios]
            obtained=[sum(costNode[j,t] for t in scenario) for j in 1:inst.J, scenario in scenarioTree.scenarios]
            regret=abs.((obtained.-ssa)./ssa)
        elseif contains(fairness,"PEA")
            spea=[(sum(inst.c_pv[t] for t in scenario)/sum(inst.d[k,t] for t in scenario, k in 1:inst.J))*sum(inst.d[j,t] for t in scenario) for j in 1:inst.J, scenario in scenarioTree.scenarios]
            obtained=[sum(pAux[j,t] for t in scenario) for j in 1:inst.J, scenario in scenarioTree.scenarios]
            regret=abs.((obtained.-spea)./spea)
        end
        sTotAux=value.(s)
        GAux=value.(G)
        wAux=zeros(inst.J,inst.T)
        xAux=zeros(inst.J,inst.T)
        solTime=round(solve_time(model), digits=2)
        sol=SolutionM(sTotAux,iAux,GAux,xAux,wAux,zAux,yAux,pAux,costsAux,true,solTime,inst.id)
    else
        costsAux=fill(Inf,inst.J)
        yAux=zeros(inst.J,inst.T)
        zAux=zeros(inst.J,inst.T)
        iAux=zeros(inst.J,inst.T)
        pAux=zeros(inst.J,inst.T)
        sTotAux=zeros(inst.T)
        GAux=zeros(inst.J,inst.T)
        wAux=zeros(inst.J,inst.T)
        xAux=zeros(inst.J,inst.T)
        regret=fill(Inf,(inst.J,inst.T))
        solTime=round(solve_time(model), digits=2)  
        sol=SolutionM(sTotAux,iAux,GAux,xAux,wAux,zAux,yAux,pAux,costsAux,false,solTime,inst.id)
    end
    if contains(fairness,"PEA") || contains(fairness,"SA")
        return sol, regret
    end
    return sol
end



function main()
    NBstage=[3,6]
    childs=[2,3]
    thetas=[0.2,0.6,0.8]
    avg_d=100.0
    dev_d=10.0
    fairness=""
    J=5
    # resultsFolder="../res/stochastic"
    df=DataFrame()
    df[!,"S"]=[]
    df[!,"C"]=[]
    df[!,"P"]=[]
    df[!,"Theta"]=[]
    # df[!,"EEV"]=[]
    # df[!,"RP"]=[]
    df[!,"VSS"]=[]
    # df[!,"Time"]=[]
    # if !isdir(resultsFolder)
    #     mkdir(resultsFolder)
    # end
    
    for s in NBstage
        p=Int(24/s)
        for c in childs
            for theta in thetas
                vssM=0
                for file in readdir("../inst/inst2020")
                    inst=generateInstance(s,c,p,J,"../inst/inst2020/"*file,theta,avg_d,dev_d)
                    costs, barP=solve!(inst,"")
                    eev=solveMulti(inst,fairness, barP, true)
                    rp=solveMulti(inst,fairness)
                    vss= ((sum(eev.costs)-sum(rp.costs))/sum(rp.costs))*100
                    vssM+=vss
                    # push!(df,[s,c,p,ratio,sum(eev.costs),sum(rp.costs),vss])
                end
                push!(df,[s,c,p,theta,vssM/100])
                CSV.write("../res/vss.csv" ,df)
            end
        end
    end

    CSV.write("../res/vss.csv" ,df)
end

function mainFairness(S,C)
    NBstage=[S]
    childs=[C]
    thetas=[0.2,0.6,0.8]
    fairness=["EPEA","ECPEA","SWPEA","ESA","ECSA","SWSA"]
    avg_d=100.0
    dev_d=10.0
    J=5
    # resultsFolder="../res/stochastic"
    df=DataFrame()
    df[!,"S"]=[]
    df[!,"C"]=[]
    df[!,"P"]=[]
    df[!,"Theta"]=[]
    df[!,"Fairness"]=[]
    df[!,"Instance"]=[]
    df[!,"Cost"]=[]
    df[!,"Max Regret"]=[]
    df[!,"Min Regret"]=[]
    df[!,"Avg Regret"]=[]
    for s in NBstage
        p=Int(24/s)
        for c in childs
            for theta in thetas
                vssM=0
                for file in readdir("../inst/inst2020_2")
                    inst=generateInstance(s,c,p,J,"../inst/inst2020_2/"*file,theta,avg_d,dev_d)
                    for f in fairness
                        println("**************************************************************************************")
                        println((s,c,p,theta,f,file))
                        rp,regret=solveMulti(inst,f)
                        push!(df,[s,c,p,theta,f,file,sum(rp.costs),maximum(regret),minimum(regret),mean(regret)])
                        CSV.write("../res/stoch_fair_"*string(S)*"_"*string(C)*".csv" ,df)
                    # push!(df,[s,c,p,ratio,sum(eev.costs),sum(rp.costs),vss])
                    end
                end
                
            end
        end
    end
    # df[!,"EEV"]=[]
    # df[!,"RP"]=[]
    # df[!,"VSS"]=[]
end
# file="../inst/inst2020/Drahi_1.csv"
# # generateInstance(NBstage::Int64,childs::Int64,periods::Int64, J::Int64,inFile::String,theta::Float64,avg::Float64,dev::Float64)
# ins=generateInstance(6,3,4,7,file,0.8,100.0,5.0)
# # sol1=solveMulti(ins,"conditional SA")
# # sol2=solveMulti(ins,"Aggregated SA")

function read()
    mode=ARGS[1]
    if mode=="fairness"
        S=parse(Int,ARGS[2])
        C=parse(Int,ARGS[3])
        mainFairness(S,C)
    elseif mode=="vss"
        main()
    end
end

read()
# sol1=solveMulti(ins,"stage-wise")
# sol2=solveMulti(ins,"aggregated")

# costs, lambdaS=solve!(inst,"")
# eev=solveMulti(inst,"",lambdaS,true)
# mainFairness()
