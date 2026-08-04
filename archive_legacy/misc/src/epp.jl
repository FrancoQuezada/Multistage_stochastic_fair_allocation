# include("utility.jl")
function solve!(inst, solver::String)
    dTot=[(sum(inst.d_det[j,t] for t in 1:inst.T),j) for j in 1:inst.J]
    model = Model(CPLEX.Optimizer)
    ################Variables#######################
    @variable(model,s[1:inst.T]>=0) #total battery
    @variable(model, I[1:inst.J,1:inst.T]>=0) #grid
    @variable(model, G[1:inst.J,1:inst.T]>=0) #grid
    @variable(model, z[1:inst.J,1:inst.T]>=0) #charge of battery
    @variable(model, y[1:inst.J,1:inst.T]>=0) #discharge of battery
    @variable(model, p[1:inst.J,1:inst.T]>=0) #photovoltaic production
    @variable(model, lambda[1:inst.J,1:inst.T]>=0)
    ################Constraints###################
    @constraint(model, [j in 1:inst.J, t in 1:inst.T], p[j,t] ==lambda[j,t]*inst.pv_det[t])
    @constraint(model, [t in 1:inst.T], sum(lambda[:,t]) == 1)
    # @constraint(model, [t in 1:inst.T], sum(p[j,t] for j in 1:inst.J)==inst.pv_det[t])
    @constraint(model, [t in 1:inst.T], s[t]<=inst.s_max)
    @constraint(model, [t in 2:inst.T], s[t]==s[t-1]+inst.delta*inst.e_c*sum(z[j,t] for j in 1:inst.J)-inst.delta*sum(y[j,t] for j in 1:inst.J)/inst.e_d)
    @constraint(model, s[1]==inst.s_I+inst.delta*inst.e_c*sum(z[j,1] for j in 1:inst.J)-inst.delta*sum(y[j,1] for j in 1:inst.J)/inst.e_d)
    @constraint(model, [t in 1:inst.T], sum(y[j,t] for j in 1:inst.J)<=inst.f_bar)
    @constraint(model, [t in 1:inst.T], sum(z[j,t] for j in 1:inst.J)<=inst.f_under)
    @constraint(model, [j in 1:inst.J, t in 1:inst.T], inst.d_det[j,t]==p[j,t]+y[j,t]+I[j,t]-z[j,t]-G[j,t])
    @constraint(model, s[inst.T]==inst.s_I)
    @constraint(model,[t in 1:inst.T], s[t]>=inst.s_min)
    @expression(model, costs[j in 1:inst.J], (inst.delta)*sum(inst.mu*y[j,t] +inst.nu[1,t]*I[j,t] - inst.beta*G[j,t]  for t in 1:inst.T)) 
    # @constraint(model,[j in 1:inst.J],costs[j]>=0)
    #####################Battery#########################
    # @variable(model, x[1:inst.J,1:inst.T], Bin) #battery set-up charge
    # @variable(model, g[1:inst.J,1:inst.T], Bin) #vender o comprar grid
    # @constraint(model, [j in 1:inst.J, t in 1:inst.T], z[j,t]<=inst.f_under*x[j,t])
    # @constraint(model, [j in 1:inst.J, t in 1:inst.T], y[j,t]<=(inst.f_bar)*(1-x[j,t]))
    # @constraint(model, [j in 1:inst.J, t in 1:inst.T], I[j,t]<=1000000*g[j,t])
    # @constraint(model, [j in 1:inst.J, t in 1:inst.T], G[j,t]<=1000000*(1-g[j,t]))

    if solver=="Proportional PEA"
        @constraint(model,[j in 1:inst.J], sum(p[j,t] for t in 1:inst.T)/sum(inst.d_det[j,t] for t in 1:inst.T)==sum(inst.pv_det)/sum(inst.d_det[k,t] for k in 1:inst.J, t in 1:inst.T)) 
    elseif solver=="Time-step Proportional"
        @constraint(model,[j in 1:inst.J, t in 1:inst.T; sum(inst.d_det[:,t])!= 0],p[j,t]==(inst.pv_det[t]/(sum(inst.d_det[:,t])))*(inst.d_det[j,t]))
        @constraint(model,[j in 1:inst.J, t in 1:inst.T; sum(inst.d_det[:,t])== 0],p[j,t]==inst.pv_det[t]/(inst.J)) 
    elseif solver=="Proportional SA"
        # println("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        ########################binary###########################
        # @variable(model, x[1:inst.J,1:inst.T], Bin) #battery set-up charge
        # @variable(model, g[1:inst.J,1:inst.T], Bin) #vender o comprar grid
        # @constraint(model, [j in 1:inst.J, t in 1:inst.T], z[j,t]<=inst.f_under*x[j,t])
        # @constraint(model, [j in 1:inst.J, t in 1:inst.T], y[j,t]<=(inst.f_bar)*(1-x[j,t]))
        # @constraint(model, [j in 1:inst.J, t in 1:inst.T], I[j,t]<=1000000*g[j,t])
        # @constraint(model, [j in 1:inst.J, t in 1:inst.T], G[j,t]<=1000000*(1-g[j,t]))
        @constraint(model,[j in 1:inst.J],(inst.delta*sum(inst.nu[j,t]*inst.d_det[j,t] for t in 1:inst.T)-costs[j])/sum(inst.delta*inst.nu[j,t]*inst.d_det[j,t] for t in 1:inst.T)==(sum(inst.delta*inst.nu[k,t]*inst.d_det[k,t] for t in 1:inst.T, k in 1:inst.J)-sum(costs))/sum(inst.delta*inst.nu[k,t]*inst.d_det[k,t] for t in 1:inst.T, k in 1:inst.J))
    elseif solver=="MMF PEA"
        # costs2=[0.0,0.0,0.18558,0.14993654999999997]
        # @constraint(model,[j in 1:inst.J], costs[j]<=costs2[j])
        r=sum(inst.pv_det)
        pAggreg=zeros(inst.J)
        sort!(dTot, by = x -> x[1])
        if r<sum(inst.d_det)-TOL
            @constraint(model,[j in 1:inst.J],sum(p[j,t] for t in 1:inst.T)<=sum(inst.d_det[j,t] for t in 1:inst.T))
            for j in 1:inst.J
                if j==1 && dTot[j][1]<=((r)/(inst.J))
                    pAggreg[dTot[j][2]]=dTot[j][1]
                elseif j==1 && dTot[j][1]>((r)/(inst.J))
                    pAggreg[dTot[j][2]]=(r)/(inst.J)
                elseif j!=1 && dTot[j][1]<=((r-sum(pAggreg[dTot[i][2]] for i in 1:(j-1)))/(inst.J-j+1))
                    pAggreg[dTot[j][2]]=dTot[j][1]
                else
                    pAggreg[dTot[j][2]]=((r-sum(pAggreg[dTot[i][2]] for i in 1:(j-1)))/(inst.J-j+1))
                end
                @constraint(model, sum(p[dTot[j][2],t] for t in 1:inst.T)==pAggreg[dTot[j][2]])
            end
        else
            @constraint(model, [j in 1:inst.J],sum(p[j,t] for t in 1:inst.T)==sum(inst.d_det[j,t] for t in 1:inst.T)+((r-sum(inst.d_det))/inst.J))
        end
    end  


    @objective(model, Min, sum(costs[j] for j in 1:inst.J))

    # set_attribute(model, "CPXPARAM_TimeLimit", 60*10)
    set_attribute(model, "CPXPARAM_Emphasis_Numerical", 1)
    # set_attribute(model, "CPXPARAM_Preprocessing_Presolve", 0)
    # set_attribute(model,"CPXPARAM_Simplex_Tolerances_Feasibility",1e-8)
    set_silent(model)
    optimize!(model)

    if has_values(model)
        println("Objective : ",round(objective_value(model),digits=3))
        costsAux=value.(costs)
        # yAux=value.(y)
        # zAux=value.(z)
        # iAux=value.(I)
        # pAux=value.(p)
        # sTotAux=value.(s)
        # GAux=value.(G)
        # wAux=zeros(inst.J,inst.T)
        # xAux=zeros(inst.J,inst.T)
        # solTime=round(solve_time(model), digits=2)
        # sol=Solution(sTotAux,iAux,GAux,xAux,wAux,zAux,yAux,pAux,costsAux,true,solTime,inst.id)
        lambdaAux=value.(lambda)
        # lambda=[pAux[j,t]/inst.pv_det[t] for j in 1:inst.J, t in 1:inst.T]
    else
        costsAux=zeros(inst.J)
        # yAux=zeros(inst.J,inst.T)
        # zAux=zeros(inst.J,inst.T)
        # iAux=zeros(inst.J,inst.T)
        # pAux=zeros(inst.J,inst.T)
        # sTotAux=zeros(inst.T)
        # GAux=zeros(inst.J,inst.T)
        # wAux=zeros(inst.J,inst.T)
        lambdaAux=zeros(inst.J,inst.T)
        # solTime=round(solve_time(model), digits=2)  
        # sol=Solution(sTotAux,iAux,GAux,xAux,wAux,zAux,yAux,pAux,costsAux,false,solTime,inst.id)
    end
    
    return sum(costsAux),lambdaAux
end