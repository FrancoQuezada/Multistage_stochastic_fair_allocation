include("structuresMulti.jl")
include("parametersMS.jl")


function build_lex_sa_model(inst::InstanceM)
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
    ##################dual variables##################
    @variable(model,zeta[1:inst.J]) 
    @variable(model,d[1:inst.J,1:inst.J]>=0)
    ################Constraints###################
    @constraint(model, [j in 1:inst.J, n in 1:scenarioTree.V], p[j,n] ==lambda[j,n]*inst.c_pv[n])
    @constraint(model, [t in 1:scenarioTree.V], sum(lambda[:,t]) == 1)
    # @constraint(model, [n in 1:scenarioTree.V], sum(p[j,n] for j in 1:inst.J)==inst.c_pv[n])
    @constraint(model, [n in 1:scenarioTree.V], s[n]<=inst.s_max)
    @constraint(model, [n in 2:scenarioTree.V], s[n]==s[scenarioTree.parents[n]]+inst.delta*inst.e_c*sum(z[j,n] for j in 1:inst.J)-inst.delta*sum(y[j,n] for j in 1:inst.J)/inst.e_d)
    @constraint(model, s[1]==inst.s_I+inst.delta*inst.e_c*sum(z[j,1] for j in 1:inst.J)-inst.delta*sum(y[j,1] for j in 1:inst.J)/inst.e_d)
    @constraint(model, [j in 1:inst.J, n in 1:scenarioTree.V], inst.d[j,n]==p[j,n]+y[j,n]+I[j,n]-z[j,n]-G[j,n])
    @constraint(model, [n in 1:scenarioTree.V ; timePeriods[n]==inst.T],s[n]==inst.s_I)
    @constraint(model,[n in 1:scenarioTree.V], s[n]>=inst.s_min)
    ########################costs###########################
    @expression(model, costs[j in 1:inst.J], (inst.delta)*sum(scenarioTree.rho[n]*(inst.mu*y[j,n] +inst.nu[j,timePeriods[n]]*I[j,n] - inst.beta*G[j,n])  for n in 1:scenarioTree.V)) 
    @constraint(model, [j in 1:inst.J], costs[j]>=0)
    ########################Lexico Constraints##############
    savings_rhs=[(inst.delta) * sum(scenarioTree.rho[t] * inst.nu[j,timePeriods[t]] * inst.d[j,t] for t in 1:scenarioTree.V) for j in 1:inst.J]
    for n in 1:inst.J, j in 1:inst.J
        @constraint(model, zeta[n]-d[n,j] <= savings_rhs[j] - costs[j])
    end
    set_silent(model)
    return (model=model, s=s, I=I, G=G, battery_mode=battery_mode, z=z, y=y, p=p, costs=costs, zeta=zeta, d=d)
end 

function lexico(inst::InstanceM)
    """
    Algorithm lexicographic in paper
    """
    println("##########################################################")
    println("Lexicographic Algorithm")
    ω=zeros(inst.J) #initialize omega
    x_sol=SolutionM() #initial empty solution
    total_solve_time=0.0
    total_run_time=0.0
    persistent=build_lex_sa_model(inst)
    model=persistent.model
    lex_eps_abs=TOL
    for k in 1:inst.J
        @objective(model, Max, k * persistent.zeta[k] - sum(persistent.d[k,j] for j in 1:inst.J))
        t_start=time()
        optimize!(model)
        term=termination_status(model)
        pstat=primal_status(model)
        step_run_time=time()-t_start
        step_time=round(solve_time(model), digits=2)
        total_solve_time+=step_time
        total_run_time+=step_run_time
        if !has_values(model)
            println("Lex step ", k, " failed: term=", term, ", primal=", pstat, ", time=", step_time)
            x_sol.costs=fill(Inf,inst.J)
            x_sol.y=zeros(inst.J,inst.tree.V)
            x_sol.z=zeros(inst.J,inst.tree.V)
            x_sol.I=zeros(inst.J,inst.tree.V)
            x_sol.p=zeros(inst.J,inst.tree.V)
            x_sol.s=zeros(inst.tree.V)
            x_sol.G=zeros(inst.J,inst.tree.V)
            x_sol.w=zeros(inst.J,inst.T)
            x_sol.battery_mode=zeros(inst.tree.V)
            x_sol.time=step_time
            x_sol.run_time=step_run_time
            x_sol.status=false
            x_sol.id=inst.id
            println("Lexicographic algorithm stopped at step ", k, " (no solution values).")
            break
        end
        println("Lex step ", k, " objective: ", round(objective_value(model),digits=3), " (", term, ")")
        x_sol.costs=value.(persistent.costs)
        x_sol.y=value.(persistent.y)
        x_sol.z=value.(persistent.z)
        x_sol.I=value.(persistent.I)
        x_sol.p=value.(persistent.p)
        x_sol.s=value.(persistent.s)
        x_sol.G=value.(persistent.G)
        x_sol.w=zeros(inst.J,inst.T)
        x_sol.battery_mode=collect(value.(persistent.battery_mode))
        x_sol.time=step_time
        x_sol.run_time=step_run_time
        x_sol.status=true
        x_sol.id=inst.id
        ω[k]=objective_value(model)
        @constraint(model, k * persistent.zeta[k] - sum(persistent.d[k,j] for j in 1:inst.J) >= ω[k] - lex_eps_abs)
    end
    x_sol.time=round(total_solve_time, digits=2)
    x_sol.run_time=total_run_time
    println("end")
    println("##########################################################")
    # println([(inst.delta)*sum(inst.nu[j,t]*inst.d[j,t] for t in 1:inst.T) for j in 1:inst.J]) #for debug
    return x_sol    
end

lexico_mmf_sa(inst::InstanceM)=lexico(inst)
