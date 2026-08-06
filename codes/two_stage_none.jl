function twoS_none(inst::Instance; lambdaS=zeros(inst.J, inst.T), EEV::Bool=false)
    model = Model(CPLEX.Optimizer)

    @variable(model, inst.s_min <= s[1:inst.T, 1:inst.Omega] <= inst.s_max)
    @variable(model, I[1:inst.J, 1:inst.T, 1:inst.Omega] >= 0)
    @variable(model, G[1:inst.J, 1:inst.T, 1:inst.Omega] >= 0)
    @variable(model, z[1:inst.J, 1:inst.T, 1:inst.Omega] >= 0)
    @variable(model, y[1:inst.J, 1:inst.T, 1:inst.Omega] >= 0)
    @variable(model, p[1:inst.J, 1:inst.T, 1:inst.Omega] >= 0)
    @variable(model, lambda[1:inst.J, 1:inst.T] >= 0)
    @variable(model, battery_mode[1:inst.T, 1:inst.Omega], Bin)

    if EEV
        fix.(lambda, lambdaS; force=true)
    end

    @constraint(model, [j in 1:inst.J, t in 1:inst.T, o in 1:inst.Omega], p[j, t, o] == lambda[j, t] * inst.c_pv[t, o])
    @constraint(model, [t in 1:inst.T], sum(lambda[:, t]) == 1)
    @constraint(model, [t in 2:inst.T, o in 1:inst.Omega], s[t, o] == s[t - 1, o] + inst.delta * inst.e_c * sum(z[j, t, o] for j in 1:inst.J) - inst.delta * sum(y[j, t, o] for j in 1:inst.J) / inst.e_d)
    @constraint(model, [o in 1:inst.Omega], s[1, o] == inst.s_I + inst.delta * inst.e_c * sum(z[j, 1, o] for j in 1:inst.J) - inst.delta * sum(y[j, 1, o] for j in 1:inst.J) / inst.e_d)
    @constraint(model, battery_discharge_mode[t in 1:inst.T, o in 1:inst.Omega],
        sum(y[j, t, o] for j in 1:inst.J) <= inst.f_bar * (1 - battery_mode[t, o]))
    @constraint(model, battery_charge_mode[t in 1:inst.T, o in 1:inst.Omega],
        sum(z[j, t, o] for j in 1:inst.J) <= inst.f_under * battery_mode[t, o])
    @constraint(model, [j in 1:inst.J, t in 1:inst.T, o in 1:inst.Omega], inst.d[j, t, o] == p[j, t, o] + y[j, t, o] + I[j, t, o] - z[j, t, o] - G[j, t, o])
    @constraint(model, [o in 1:inst.Omega], s[inst.T, o] == inst.s_I)

    @expression(model, costs[j in 1:inst.J], inst.delta * sum((inst.mu * y[j, t, o] + inst.nu[j, t] * I[j, t, o] - inst.beta * G[j, t, o]) * inst.rho[o] for t in 1:inst.T, o in 1:inst.Omega))

    @objective(model, Min, sum(costs[j] for j in 1:inst.J))
    set_attribute(model, "CPXPARAM_TimeLimit", 60 * 60)
    set_silent(model)
    optimize!(model)

    if has_values(model)
        return Solution(
            value.(s),
            value.(I),
            value.(G),
            value.(battery_mode),
            zeros(inst.J, inst.T, inst.Omega),
            value.(z),
            value.(y),
            value.(p),
            value.(lambda),
            value.(costs),
            termination_status(model) == OPTIMAL,
            round(solve_time(model), digits=2),
            inst.id,
        )
    end

    return Solution(
        zeros(inst.T, inst.Omega),
        zeros(inst.J, inst.T, inst.Omega),
        zeros(inst.J, inst.T, inst.Omega),
        zeros(inst.T, inst.Omega),
        zeros(inst.J, inst.T, inst.Omega),
        zeros(inst.J, inst.T, inst.Omega),
        zeros(inst.J, inst.T, inst.Omega),
        zeros(inst.J, inst.T, inst.Omega),
        zeros(inst.J, inst.T),
        fill(Inf, inst.J),
        false,
        round(solve_time(model), digits=2),
        inst.id,
    )
end
