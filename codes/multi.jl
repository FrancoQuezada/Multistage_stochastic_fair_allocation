include("structuresMulti.jl")
include("parametersMS.jl")
include("epp.jl")
include("mmf_sa.jl")
include("mmf_pea.jl")
TOL=1.0
include("conditional_fairness.jl")
include("static_demand_share.jl")
# Random.seed!(1234)

function solveMulti(inst::InstanceM,fairness::String,lambdaS=zeros(10,10), EEV=false;
    sa_fairness_abs_tol::Float64=TOL,
    fairness_abs_tol::Float64=0.0,
    fairness_mmr::Float64=1.2,
    conditional_stage::Union{Nothing,Int}=nothing,
    lex_eps_abs::Float64=TOL)
    if fairness == "STATIC_DEMAND_SHARE"
        return solve_static_demand_share(inst)
    end
    if is_new_fairness_label(fairness)
        return solve_new_fairness(
            inst, fairness, lambdaS, EEV;
            fairness_abs_tol=fairness_abs_tol,
            fairness_mmr=fairness_mmr,
            conditional_stage=conditional_stage,
            lex_eps_abs=lex_eps_abs,
        )
    end
    if fairness in ("LEXMMFSA", "MMFSA")
        return lexico_mmf_sa(inst)
    end
    mmf_pea_target_scenarios=nothing
    mmf_extra_solve_time=0.0
    mmf_extra_run_time=0.0
    t_model_start=time()
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
    battery_mode=add_shared_battery_mode_constraints!(
        model, y, z, 1:inst.J, 1:scenarioTree.V;
        discharge_limit=inst.f_bar,
        charge_limit=inst.f_under,
    )
    ################Constraints###################
    if EEV
        lambdaN=[lambdaS[j, timePeriods[t]] for j in 1:inst.J, t in 1:scenarioTree.V]
        fix.(lambda,lambdaN;force = true)
    end
    @constraint(model, [j in 1:inst.J, n in 1:scenarioTree.V], p[j,n] ==lambda[j,n]*inst.c_pv[n])
    @constraint(model, [t in 1:scenarioTree.V], sum(lambda[:,t]) == 1)
    # @constraint(model, [n in 1:scenarioTree.V], sum(p[j,n] for j in 1:inst.J)==inst.c_pv[n])
    @constraint(model, [n in 1:scenarioTree.V], s[n]<=inst.s_max)
    @constraint(model, [n in 2:scenarioTree.V], s[n]==s[scenarioTree.parents[n]]+inst.delta*inst.e_c*sum(z[j,n] for j in 1:inst.J)-inst.delta*sum(y[j,n] for j in 1:inst.J)/inst.e_d)
    @constraint(model, s[1]==inst.s_I+inst.delta*inst.e_c*sum(z[j,1] for j in 1:inst.J)-inst.delta*sum(y[j,1] for j in 1:inst.J)/inst.e_d)
    @constraint(model, [j in 1:inst.J, n in 1:scenarioTree.V], inst.d[j,n]==p[j,n]+y[j,n]+I[j,n]-z[j,n]-G[j,n])
    @constraint(model, [n in 1:scenarioTree.V ; timePeriods[n]==inst.T],s[n]==inst.s_I)
    @constraint(model,[n in 1:scenarioTree.V], s[n]>=inst.s_min)
    
    @expression(model, costs[j in 1:inst.J], (inst.delta)*sum(scenarioTree.rho[n]*(inst.mu*y[j,n] +inst.nu[j,timePeriods[n]]*I[j,n] - inst.beta*G[j,n])  for n in 1:scenarioTree.V)) 
    # @expression(model, costs[j in 1:inst.J], (inst.delta)*sum(scenarioTree.rho[n]*(inst.mu*y[j,n] +inst.nu[1,n]*I[j,n] - inst.beta*G[j,n])  for n in 1:scenarioTree.V)) 
    
    ##### fairness
    if fairness in ("PEA", "PAE", "PPEA", "EPPEA")
        @constraint(model, [j in 1:inst.J] , sum(scenarioTree.rho[scenario[1]]*sum(p[j,t] for t in scenario) for scenario in scenarioTree.scenarios) ==sum(scenarioTree.rho[scenario[1]]*(sum(inst.c_pv[t] for t in scenario)/sum(inst.d[k,t] for t in scenario, k in 1:inst.J))*sum(inst.d[j,t] for t in scenario) for scenario in scenarioTree.scenarios))
    elseif fairness in ("SA", "PSA", "ESA")
        @expression(model, costNode[j in 1:inst.J, n in 1:scenarioTree.V], (inst.delta)*(inst.mu*y[j,n] +inst.nu[j,timePeriods[n]]*I[j,n] - inst.beta*G[j,n]))
        scenario_prob=[scenarioTree.rho[scenario[1]] for scenario in scenarioTree.scenarios]
        grid_house=[[sum(inst.delta*inst.nu[j,timePeriods[n]]*inst.d[j,n] for n in scenario) for j in 1:inst.J] for scenario in scenarioTree.scenarios]
        grid_total=[max(TOL,sum(grid_house[s][j] for j in 1:inst.J)) for s in eachindex(scenarioTree.scenarios)]
        for j in 1:inst.J
            lhs = sum(scenario_prob[s]*(grid_house[s][j]-sum(costNode[j,n] for n in scenarioTree.scenarios[s])) for s in eachindex(scenarioTree.scenarios))
            rhs = sum(scenario_prob[s]*((grid_total[s]-sum(sum(costNode[k,n] for k in 1:inst.J) for n in scenarioTree.scenarios[s]))/grid_total[s])*grid_house[s][j] for s in eachindex(scenarioTree.scenarios))
            if sa_fairness_abs_tol > 0
                @constraint(model, lhs - rhs <= sa_fairness_abs_tol)
                @constraint(model, rhs - lhs <= sa_fairness_abs_tol)
            else
                @constraint(model, lhs == rhs)
            end
        end
    elseif fairness in ("LEXMMFPEA", "MMFPEA", "EMMFPEA")
        assign_expected, assign_scenarios, mmf_extra_solve_time, mmf_extra_run_time=lexico_mmf_pea_targets(inst)
        mmf_pea_target_scenarios=assign_scenarios
        @constraint(model, [j in 1:inst.J], sum(scenarioTree.rho[scenario[1]]*sum(p[j,t] for t in scenario) for scenario in scenarioTree.scenarios)==assign_expected[j])
    elseif !(fairness in ("", "NONE"))
        error("Fairness no soportada: $fairness. Usa PEA/PAE, SA, LEXMMFPEA o LEXMMFSA.")
    end
    ######### 
    

    @objective(model, Min, sum(costs[j] for j in 1:inst.J))

    set_attribute(model, "CPXPARAM_TimeLimit", 60*60)
    # set_attribute(model, "CPXPARAM_Emphasis_Numerical", 1)
    # set_attribute(model, "CPXPARAM_Preprocessing_Presolve", 0)
    # set_attribute(model,"CPXPARAM_Simplex_Tolerances_Feasibility",1e-8)
    set_silent(model)
    optimize!(model)
    model_run_time=time()-t_model_start
    println(termination_status(model))
    if has_values(model)
        println("Objective : ",round(objective_value(model),digits=3))
        costsAux=value.(costs)
        yAux=value.(y)
        zAux=value.(z)
        iAux=value.(I)
        pAux=value.(p)
        if fairness in ("SA", "PSA", "ESA")
            costNode=value.(costNode)
            ssa=[sum(inst.delta*inst.nu[j,timePeriods[t]]*inst.d[j,t] for t in scenario)*sum(costNode[k,t] for t in scenario, k in 1:inst.J)/sum(inst.delta*inst.nu[k,timePeriods[t]]*inst.d[k,t] for t in scenario, k in 1:inst.J) for j in 1:inst.J, scenario in scenarioTree.scenarios]
            obtained=[sum(costNode[j,t] for t in scenario) for j in 1:inst.J, scenario in scenarioTree.scenarios]
            regret=abs.((obtained.-ssa)./ssa)
        elseif fairness in ("PEA", "PAE", "PPEA", "EPPEA")
            spea=[(sum(inst.c_pv[t] for t in scenario)/sum(inst.d[k,t] for t in scenario, k in 1:inst.J))*sum(inst.d[j,t] for t in scenario) for j in 1:inst.J, scenario in scenarioTree.scenarios]
            obtained=[sum(pAux[j,t] for t in scenario) for j in 1:inst.J, scenario in scenarioTree.scenarios]
            regret=abs.((obtained.-spea)./spea)
        elseif fairness in ("LEXMMFPEA", "MMFPEA", "EMMFPEA")
            obtained=[sum(pAux[j,t] for t in scenario) for j in 1:inst.J, scenario in scenarioTree.scenarios]
            target=mmf_pea_target_scenarios === nothing ? fill(TOL,size(obtained)) : mmf_pea_target_scenarios
            regret=abs.((obtained.-target)./max.(target,TOL))
        end
        sTotAux=value.(s)
        GAux=value.(G)
        wAux=zeros(inst.J,inst.T)
        batteryModeAux=collect(value.(battery_mode))
        solTime=round(mmf_extra_solve_time + solve_time(model), digits=2)
        solRunTime=mmf_extra_run_time + model_run_time
        sol=SolutionM(sTotAux,iAux,GAux,batteryModeAux,wAux,zAux,yAux,pAux,costsAux,true,solTime,solRunTime,inst.id)
    else
        costsAux=fill(Inf,inst.J)
        yAux=zeros(inst.J,scenarioTree.V)
        zAux=zeros(inst.J,scenarioTree.V)
        iAux=zeros(inst.J,scenarioTree.V)
        pAux=zeros(inst.J,scenarioTree.V)
        sTotAux=zeros(scenarioTree.V)
        GAux=zeros(inst.J,scenarioTree.V)
        wAux=zeros(inst.J,inst.T)
        batteryModeAux=zeros(scenarioTree.V)
        regret=fill(Inf,(inst.J,inst.T))
        solTime=round(mmf_extra_solve_time + solve_time(model), digits=2)
        solRunTime=mmf_extra_run_time + model_run_time
        sol=SolutionM(sTotAux,iAux,GAux,batteryModeAux,wAux,zAux,yAux,pAux,costsAux,false,solTime,solRunTime,inst.id)
    end
    if fairness in ("PEA", "PAE", "PPEA", "EPPEA", "SA", "PSA", "ESA", "LEXMMFPEA", "MMFPEA", "EMMFPEA")
        return sol, regret
    end
    return sol
end

function _scenario_probabilities(inst::InstanceM)
    return [inst.tree.rho[scenario[1]] for scenario in inst.tree.scenarios]
end

function all_grid_scenario_cost_matrix(inst::InstanceM)
    timePeriods=createTime(inst.tree)
    scen=inst.tree.scenarios
    costs=zeros(inst.J, length(scen))
    for (s_idx, scenario) in enumerate(scen)
        for j in 1:inst.J
            # All-grid benchmark: each house buys all demand from the grid.
            costs[j,s_idx]=sum(inst.delta*inst.nu[j,timePeriods[n]]*inst.d[j,n] for n in scenario)
        end
    end
    return costs
end

function all_grid_expected_costs(inst::InstanceM)
    probs=_scenario_probabilities(inst)
    scenario_costs=all_grid_scenario_cost_matrix(inst)
    expected=zeros(inst.J)
    for j in 1:inst.J
        expected[j]=sum(probs[s]*scenario_costs[j,s] for s in 1:length(probs))
    end
    return expected
end

function _scenario_cost_matrix(inst::InstanceM, sol::SolutionM)
    timePeriods=createTime(inst.tree)
    scen=inst.tree.scenarios
    costs=zeros(inst.J, length(scen))
    for (s_idx, scenario) in enumerate(scen)
        for j in 1:inst.J
            costs[j,s_idx]=sum(inst.delta*(inst.mu*sol.y[j,n] + inst.nu[j,timePeriods[n]]*sol.I[j,n] - inst.beta*sol.G[j,n]) for n in scenario)
        end
    end
    return costs
end

function _regret_matrix(inst::InstanceM, sol::SolutionM, fairness::String)
    scen=inst.tree.scenarios
    probs=_scenario_probabilities(inst)
    timePeriods=createTime(inst.tree)
    obtained=[sum(sol.p[j,n] for n in scenario) for j in 1:inst.J, scenario in scen]

    if fairness in ("PEA", "PAE", "PPEA", "EPPEA")
        target=[(sum(inst.c_pv[n] for n in scenario)/sum(inst.d[k,n] for k in 1:inst.J, n in scenario))*sum(inst.d[j,n] for n in scenario) for j in 1:inst.J, scenario in scen]
        return abs.((obtained.-target)./max.(target,TOL))
    elseif fairness in ("LEXMMFPEA", "MMFPEA", "EMMFPEA")
        _, target, _=lexico_mmf_pea_targets(inst)
        return abs.((obtained.-target)./max.(target,TOL))
    elseif fairness in ("SA", "PSA", "ESA", "LEXMMFSA", "MMFSA")
        reg=zeros(inst.J, length(scen))
        for (s_idx, scenario) in enumerate(scen)
            grid_j=[sum(inst.delta*inst.nu[j,timePeriods[n]]*inst.d[j,n] for n in scenario) for j in 1:inst.J]
            cost_j=[sum(inst.delta*(inst.mu*sol.y[j,n] + inst.nu[j,timePeriods[n]]*sol.I[j,n] - inst.beta*sol.G[j,n]) for n in scenario) for j in 1:inst.J]
            grid_tot=sum(grid_j)
            cost_tot=sum(cost_j)
            ratio=(grid_tot-cost_tot)/max(grid_tot,TOL)
            for j in 1:inst.J
                desired=ratio*grid_j[j]
                obtained_sav=grid_j[j]-cost_j[j]
                reg[j,s_idx]=abs((obtained_sav-desired)/max(abs(desired),TOL))
            end
        end
        return reg
    end

    return fill(Inf,inst.J,length(scen))
end

function run_fairness_instance_report(inst_folder::String="inst/inst2020";
    instance_from::Int64=1,
    instance_to::Int64=10,
    NBstage::Int64=2,
    childs::Int64=2,
    periods::Int64=12,
    J::Int64=5,
    theta::Float64=0.2,
    avg_d::Float64=100.0,
    dev_d::Float64=10.0,
    demand_profile::String="mixed",
    battery_scale::Float64=1.0,
    pv_scale::Float64=1.0,
    sa_fairness_abs_tol::Float64=TOL,
    fairness_list::Vector{String}=["NONE","PEA","SA","LEXMMFPEA","LEXMMFSA"],
    out_csv::String="fairness_instance_report.csv",
    out_csv_house::String="fairness_instance_report_by_house.csv")

    if !isdir(inst_folder)
        error("No existe el directorio de instancias: $inst_folder")
    end
    files=sort(readdir(inst_folder))
    if isempty(files)
        error("No se encontraron archivos en: $inst_folder")
    end
    from=max(1,instance_from)
    to=min(length(files),instance_to)
    if from>to
        error("Rango de instancias inválido: [$instance_from,$instance_to] para $(length(files)) archivos.")
    end
    selected_files=files[from:to]

    df=DataFrame()
    df[!,"InstanceNo"]=Int64[]
    df[!,"InstanceFile"]=String[]
    df[!,"InstanceID"]=String[]
    df[!,"Fairness"]=String[]
    df[!,"Status"]=Bool[]
    df[!,"ExpectedCost"]=Float64[]
    df[!,"ScenarioCostExpected"]=Float64[]
    df[!,"ScenarioCostMin"]=Float64[]
    df[!,"ScenarioCostMax"]=Float64[]
    df[!,"RegretExpected"]=Float64[]
    df[!,"RegretMin"]=Float64[]
    df[!,"RegretMax"]=Float64[]
    df[!,"DemandProfile"]=String[]
    df[!,"BatteryScale"]=Float64[]
    df[!,"PVScale"]=Float64[]
    df[!,"RunTimeSec"]=Float64[]
    df[!,"ModelSolveTimeSec"]=Float64[]

    df_house=DataFrame()
    df_house[!,"InstanceNo"]=Int64[]
    df_house[!,"InstanceFile"]=String[]
    df_house[!,"InstanceID"]=String[]
    df_house[!,"Fairness"]=String[]
    df_house[!,"House"]=Int64[]
    df_house[!,"Status"]=Bool[]
    df_house[!,"PVReceivedExpected"]=Float64[]
    df_house[!,"PVReceivedMin"]=Float64[]
    df_house[!,"PVReceivedMax"]=Float64[]
    df_house[!,"CostExpected"]=Float64[]
    df_house[!,"CostMin"]=Float64[]
    df_house[!,"CostMax"]=Float64[]
    df_house[!,"RegretExpected"]=Float64[]
    df_house[!,"RegretMin"]=Float64[]
    df_house[!,"RegretMax"]=Float64[]
    df_house[!,"DemandProfile"]=String[]
    df_house[!,"BatteryScale"]=Float64[]
    df_house[!,"PVScale"]=Float64[]
    df_house[!,"RunTimeSec"]=Float64[]
    df_house[!,"ModelSolveTimeSec"]=Float64[]

    for (local_idx,file) in enumerate(selected_files)
        global_idx=from+local_idx-1
        inFile=joinpath(inst_folder,file)
        inst=generateInstance(NBstage,childs,periods,J,inFile,theta,avg_d,dev_d; pv_scale=pv_scale, demand_profile=demand_profile)
        scaleInstance!(inst; battery_scale=battery_scale)
        probs=_scenario_probabilities(inst)
        total_prob=max(sum(probs),TOL)

        for fair in fairness_list
            reg_from_solve=nothing
            if fair in ("LEXMMFSA","MMFSA","","NONE")
                sol=solveMulti(inst,fair)
            else
                sol, reg_from_solve=solveMulti(inst,fair; sa_fairness_abs_tol=sa_fairness_abs_tol)
            end
            run_time=sol.run_time

            if sol.status
                scenario_costs_house=_scenario_cost_matrix(inst,sol)
                scenario_pv_house=[sum(sol.p[j,n] for n in scenario) for j in 1:inst.J, scenario in inst.tree.scenarios]
                scenario_total=[sum(scenario_costs_house[:,s]) for s in 1:size(scenario_costs_house,2)]
                scenario_expected=sum(probs[s]*scenario_total[s] for s in eachindex(scenario_total))/total_prob
                if fair in ("","NONE")
                    reg=fill(NaN,inst.J,length(inst.tree.scenarios))
                    regret_expected=NaN
                elseif reg_from_solve !== nothing
                    reg=reg_from_solve
                    regret_expected=sum(probs[s]*sum(reg[:,s])/inst.J for s in 1:size(reg,2))/total_prob
                else
                    reg=_regret_matrix(inst,sol,fair)
                    regret_expected=sum(probs[s]*sum(reg[:,s])/inst.J for s in 1:size(reg,2))/total_prob
                end
            else
                scenario_costs_house=fill(Inf,inst.J,length(inst.tree.scenarios))
                scenario_pv_house=fill(Inf,inst.J,length(inst.tree.scenarios))
                reg=fill(Inf,inst.J,length(inst.tree.scenarios))
                scenario_total=fill(Inf,length(inst.tree.scenarios))
                scenario_expected=Inf
                regret_expected=Inf
            end

            push!(df,(
                global_idx,
                file,
                inst.id,
                fair,
                sol.status,
                sum(sol.costs),
                scenario_expected,
                minimum(scenario_total),
                maximum(scenario_total),
                regret_expected,
                minimum(reg),
                maximum(reg),
                demand_profile,
                battery_scale,
                pv_scale,
                run_time,
                sol.time
            ))
    
            for j in 1:inst.J
                pv_j=[scenario_pv_house[j,s] for s in 1:size(scenario_pv_house,2)]
                cost_j=[scenario_costs_house[j,s] for s in 1:size(scenario_costs_house,2)]
                reg_j=[reg[j,s] for s in 1:size(reg,2)]
                pv_expected=sum(probs[s]*pv_j[s] for s in eachindex(pv_j))/total_prob
                cost_expected=sum(probs[s]*cost_j[s] for s in eachindex(cost_j))/total_prob
                reg_expected=sum(probs[s]*reg_j[s] for s in eachindex(reg_j))/total_prob
                push!(df_house,(
                    global_idx,
                    file,
                    inst.id,
                    fair,
                    j,
                    sol.status,
                    pv_expected,
                    minimum(pv_j),
                    maximum(pv_j),
                    cost_expected,
                    minimum(cost_j),
                    maximum(cost_j),
                    reg_expected,
                    minimum(reg_j),
                    maximum(reg_j),
                    demand_profile,
                    battery_scale,
                    pv_scale,
                    run_time,
                    sol.time
                ))
            end
        end
    end

    CSV.write(out_csv,df)
    CSV.write(out_csv_house,df_house)
    return df
end

function run_single_fairness_instance(;
    fairness::String="NONE",
    inFile::String="inst/inst2020/Drahi_1.csv",
    NBstage::Int64=2,
    childs::Int64=2,
    periods::Int64=12,
    J::Int64=5,
    theta::Float64=0.2,
    avg_d::Float64=100.0,
    dev_d::Float64=10.0,
    demand_profile::String="mixed",
    battery_scale::Float64=1.0,
    pv_scale::Float64=1.0,
    sa_fairness_abs_tol::Float64=TOL,
    out_csv::String="single_fairness_run.csv",
    out_csv_house::String="single_fairness_run_by_house.csv",
    write_csv::Bool=true)

    if !isfile(inFile)
        error("No existe el archivo de instancia: $inFile")
    end

    inst=generateInstance(NBstage,childs,periods,J,inFile,theta,avg_d,dev_d; pv_scale=pv_scale, demand_profile=demand_profile)
    scaleInstance!(inst; battery_scale=battery_scale)
    probs=_scenario_probabilities(inst)
    total_prob=max(sum(probs),TOL)

    df=DataFrame()
    df[!,"InstanceNo"]=Int64[]
    df[!,"InstanceFile"]=String[]
    df[!,"InstanceID"]=String[]
    df[!,"Fairness"]=String[]
    df[!,"Status"]=Bool[]
    df[!,"ExpectedCost"]=Float64[]
    df[!,"ScenarioCostExpected"]=Float64[]
    df[!,"ScenarioCostMin"]=Float64[]
    df[!,"ScenarioCostMax"]=Float64[]
    df[!,"RegretExpected"]=Float64[]
    df[!,"RegretMin"]=Float64[]
    df[!,"RegretMax"]=Float64[]
    df[!,"DemandProfile"]=String[]
    df[!,"BatteryScale"]=Float64[]
    df[!,"PVScale"]=Float64[]
    df[!,"RunTimeSec"]=Float64[]
    df[!,"ModelSolveTimeSec"]=Float64[]

    df_house=DataFrame()
    df_house[!,"InstanceNo"]=Int64[]
    df_house[!,"InstanceFile"]=String[]
    df_house[!,"InstanceID"]=String[]
    df_house[!,"Fairness"]=String[]
    df_house[!,"House"]=Int64[]
    df_house[!,"Status"]=Bool[]
    df_house[!,"PVReceivedExpected"]=Float64[]
    df_house[!,"PVReceivedMin"]=Float64[]
    df_house[!,"PVReceivedMax"]=Float64[]
    df_house[!,"CostExpected"]=Float64[]
    df_house[!,"CostMin"]=Float64[]
    df_house[!,"CostMax"]=Float64[]
    df_house[!,"RegretExpected"]=Float64[]
    df_house[!,"RegretMin"]=Float64[]
    df_house[!,"RegretMax"]=Float64[]
    df_house[!,"DemandProfile"]=String[]
    df_house[!,"BatteryScale"]=Float64[]
    df_house[!,"PVScale"]=Float64[]
    df_house[!,"RunTimeSec"]=Float64[]
    df_house[!,"ModelSolveTimeSec"]=Float64[]

    reg_from_solve=nothing
    if fairness in ("LEXMMFSA","MMFSA","","NONE")
        sol=solveMulti(inst,fairness)
    else
        sol, reg_from_solve=solveMulti(inst,fairness; sa_fairness_abs_tol=sa_fairness_abs_tol)
    end
    run_time=sol.run_time

    if sol.status
        scenario_costs_house=_scenario_cost_matrix(inst,sol)
        scenario_pv_house=[sum(sol.p[j,n] for n in scenario) for j in 1:inst.J, scenario in inst.tree.scenarios]
        scenario_total=[sum(scenario_costs_house[:,s]) for s in 1:size(scenario_costs_house,2)]
        scenario_expected=sum(probs[s]*scenario_total[s] for s in eachindex(scenario_total))/total_prob
        if fairness in ("","NONE")
            reg=fill(NaN,inst.J,length(inst.tree.scenarios))
            regret_expected=NaN
        elseif reg_from_solve !== nothing
            reg=reg_from_solve
            regret_expected=sum(probs[s]*sum(reg[:,s])/inst.J for s in 1:size(reg,2))/total_prob
        else
            reg=_regret_matrix(inst,sol,fairness)
            regret_expected=sum(probs[s]*sum(reg[:,s])/inst.J for s in 1:size(reg,2))/total_prob
        end
    else
        scenario_costs_house=fill(Inf,inst.J,length(inst.tree.scenarios))
        scenario_pv_house=fill(Inf,inst.J,length(inst.tree.scenarios))
        reg=fill(Inf,inst.J,length(inst.tree.scenarios))
        scenario_total=fill(Inf,length(inst.tree.scenarios))
        scenario_expected=Inf
        regret_expected=Inf
    end

    instance_file=basename(inFile)
    push!(df,(
        1,
        instance_file,
        inst.id,
        fairness,
        sol.status,
        sum(sol.costs),
        scenario_expected,
        minimum(scenario_total),
        maximum(scenario_total),
        regret_expected,
        minimum(reg),
        maximum(reg),
        demand_profile,
        battery_scale,
        pv_scale,
        run_time,
        sol.time
    ))

    for j in 1:inst.J
        pv_j=[scenario_pv_house[j,s] for s in 1:size(scenario_pv_house,2)]
        cost_j=[scenario_costs_house[j,s] for s in 1:size(scenario_costs_house,2)]
        reg_j=[reg[j,s] for s in 1:size(reg,2)]
        pv_expected=sum(probs[s]*pv_j[s] for s in eachindex(pv_j))/total_prob
        cost_expected=sum(probs[s]*cost_j[s] for s in eachindex(cost_j))/total_prob
        reg_expected=sum(probs[s]*reg_j[s] for s in eachindex(reg_j))/total_prob
        push!(df_house,(
            1,
            instance_file,
            inst.id,
            fairness,
            j,
            sol.status,
            pv_expected,
            minimum(pv_j),
            maximum(pv_j),
            cost_expected,
            minimum(cost_j),
            maximum(cost_j),
            reg_expected,
            minimum(reg_j),
            maximum(reg_j),
            demand_profile,
            battery_scale,
            pv_scale,
            run_time,
            sol.time
        ))
    end

    if write_csv
        CSV.write(out_csv,df)
        CSV.write(out_csv_house,df_house)
    end
    return df, df_house
end

function run_fairness_config_set(configs::Vector{<:NamedTuple};
    out_csv::String="fairness_config_set_report.csv",
    out_csv_house::String="fairness_config_set_report_by_house.csv")

    all_df=DataFrame()
    all_df_house=DataFrame()
    defaults=(fairness="NONE", NBstage=2, childs=2, periods=12, J=5, theta=0.2, avg_d=100.0, dev_d=10.0, demand_profile="mixed", battery_scale=1.0, pv_scale=1.0, sa_fairness_abs_tol=TOL)

    for (cfg_id, cfg_raw) in enumerate(configs)
        cfg=merge(defaults,cfg_raw)
        if !haskey(cfg,:inFile)
            error("Cada configuración debe incluir inFile. Error en cfg_id=$cfg_id")
        end
        df, df_house = run_single_fairness_instance(
            fairness=cfg.fairness,
            inFile=cfg.inFile,
            NBstage=cfg.NBstage,
            childs=cfg.childs,
            periods=cfg.periods,
            J=cfg.J,
            theta=cfg.theta,
            avg_d=cfg.avg_d,
            dev_d=cfg.dev_d,
            demand_profile=cfg.demand_profile,
            battery_scale=cfg.battery_scale,
            pv_scale=cfg.pv_scale,
            sa_fairness_abs_tol=cfg.sa_fairness_abs_tol,
            write_csv=false
        )
        df[!,"ConfigID"]=fill(cfg_id,nrow(df))
        df_house[!,"ConfigID"]=fill(cfg_id,nrow(df_house))
        append!(all_df,df,cols=:union)
        append!(all_df_house,df_house,cols=:union)
    end

    CSV.write(out_csv,all_df)
    CSV.write(out_csv_house,all_df_house)
    return all_df, all_df_house
end



function main()
    NBstage=[3,6]
    childs=[2,3,5]
    thetas=[0.2,0.6,0.8]
    avg_d=100.0
    dev_d=10.0
    fairness=""
    J=5
    # resultsFolder="../res/stochastic"
    df=DataFrame()
    df[!,"Instance"]=[]
    df[!,"S"]=[]
    df[!,"C"]=[]
    df[!,"P"]=[]
    df[!,"Theta"]=[]
    df[!,"EEV"]=[]
    df[!,"RP"]=[]
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
                for file in readdir("inst/inst2020")
                    inst=generateInstance(s,c,p,J,"inst/inst2020/"*file,theta,avg_d,dev_d)
                    costs, barP=solve!(inst,"")
                    eev=solveMulti(inst,fairness, barP, true)
                    rp=solveMulti(inst,fairness)
                    vss= ((sum(eev.costs)-sum(rp.costs))/sum(rp.costs))
                    # vssM+=vss
                    push!(df,[file,s,c,p,theta,sum(eev.costs),sum(rp.costs),vss])
                    CSV.write("../figs/excel/stochFinalVSS.csv" ,df)
                    # push!(df,[s,c,p,ratio,sum(eev.costs),sum(rp.costs),vss])
                end
                
            end
        end
    end

    # CSV.write("../figs/excel/stoch12.csv" ,df)
end

function mainFairness(S,C)
    NBstage=[S]
    childs=[C]
    thetas=[0.2,0.6,0.8]
    fairness=["PEA","SA","LEXMMFPEA","LEXMMFSA"]
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
                for file in readdir("inst/inst2020")
                    inst=generateInstance(s,c,p,J,"inst/inst2020/"*file,theta,avg_d,dev_d)
                    for f in fairness
                        println("**************************************************************************************")
                        println((s,c,p,theta,f,file))
                        if f=="LEXMMFSA"
                            rp=solveMulti(inst,f)
                            push!(df,[s,c,p,theta,f,file,sum(rp.costs),missing,missing,missing])
                        else
                            rp,regret=solveMulti(inst,f)
                            push!(df,[s,c,p,theta,f,file,sum(rp.costs),maximum(regret),minimum(regret),mean(regret)])
                        end
                        CSV.write("../figs/excel/stoch_fair_"*string(S)*"_"*string(C)*".csv" ,df)
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


# function read()
#     mode=ARGS[1]
#     if mode=="fairness"
#         S=parse(Int,ARGS[2])
#         C=parse(Int,ARGS[3])
#         mainFairness(S,C)
#     elseif mode=="vss"
#         main()
#     end
# end

# inst=generateInstance(2,2,12,5,"../inst/inst2020_2/Drahi_1.csv",0.2,100.0,10.0)
# sol=solveMulti(inst,"EMMFPEA")
# read()
