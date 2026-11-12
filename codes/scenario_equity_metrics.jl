# Additive, solver-independent extraction from repository instances and decisions.
using CSV, DataFrames, Statistics, Serialization, SHA

const SCENARIO_EQUITY_POLICIES = ["NONE", "PEA", "SA", "LEXMMFPEA", "LEXMMFSA"]
const EQUITY_OUTCOME_ATOL = 1e-10
const EQUITY_VALIDATION_ATOL = 1e-6
const EQUITY_VALIDATION_RTOL = 1e-9

function equity_atomic_csv(path, frame)
    mkpath(dirname(path))
    tmp = path * ".tmp.$(getpid())"
    CSV.write(tmp, frame)
    mv(tmp, path; force=true)
end

"""No clipping: negative outcomes invalidate every nonnegative-resource metric."""
function equity_vector_metrics(values; outcome_atol=EQUITY_OUTCOME_ATOL)
    x = Float64.(values)
    isempty(x) && error("Empty household vector")
    finite = all(isfinite, x)
    lo, hi = minimum(x), maximum(x)
    reason = !finite ? "nonfinite_outcome" : lo < 0 ? "negative_outcome" :
        hi <= outcome_atol ? "zero_or_negligible_vector" : "valid"
    base_valid = reason == "valid"
    jain = gini = ratio = missing
    ratio_reason = reason
    if base_valid
        # Scaling avoids overflow; it changes neither metric nor household outcomes.
        q = x ./ hi
        jain = sum(q)^2 / (length(x) * sum(abs2, q))
        gini = sum(abs(a-b) for a in q, b in q) / (2length(x) * sum(q))
        ratio_reason = lo <= outcome_atol ? "zero_or_negligible_minimum" : "valid"
        if ratio_reason == "valid"
            ratio = hi / lo
            if !isfinite(ratio)
                ratio = missing
                ratio_reason = "nonfinite_ratio"
            end
        end
    end
    return (Jain=jain, Gini=gini, MaxMin=ratio, Min=lo, Max=hi, Total=sum(x),
        JainValid=!ismissing(jain), GiniValid=!ismissing(gini), MaxMinValid=!ismissing(ratio),
        MetricValid=base_valid && !ismissing(ratio),
        Reason=reason == "valid" ? ratio_reason : reason,
        NegativeCount=count(<(0), x), ZeroOrNegligibleCount=count(v -> abs(v)<=outcome_atol, x))
end

"""Validate leaf-first paths and recover actual leaf probabilities, without normalization."""
function equity_tree_data(inst)
    tree = inst.tree
    times = zeros(Int, tree.V)
    for n in 1:tree.V
        parent = tree.parents[n]
        0 <= parent < n || error("Invalid parent or cycle at node $n")
        times[n] = parent == 0 ? 1 : times[parent]+1
    end
    probabilities = Float64[]
    node_mass = zeros(tree.V)
    leaves = Int[]
    for path in tree.scenarios
        length(path) == inst.T || error("Incomplete scenario path")
        length(unique(path)) == inst.T || error("Repeated node in scenario path")
        all(n -> 1<=n<=tree.V, path) || error("Invalid scenario node")
        times[path[1]] == inst.T || error("Path must start at terminal leaf")
        tree.parents[path[end]] == 0 || error("Path must end at root")
        all(tree.parents[path[i]] == path[i+1] for i in 1:length(path)-1) || error("Broken path")
        times[reverse(path)] == collect(1:inst.T) || error("Incorrect path time indexing")
        push!(leaves, path[1])
        probability = tree.rho[path[1]]
        isfinite(probability) && probability >= 0 || error("Invalid scenario probability")
        push!(probabilities, probability)
        node_mass[path] .+= probability
    end
    length(unique(leaves)) == length(leaves) || error("Duplicate scenario")
    isapprox(sum(probabilities), 1; atol=1e-10, rtol=0) || error("Probabilities do not sum to one")
    all(isapprox.(node_mass, tree.rho; atol=1e-10, rtol=1e-10)) || error("Leaf/node probability inconsistency")
    return (probabilities=probabilities, times=times)
end

equity_share(value, total) = isfinite(total) && abs(total)>EQUITY_OUTCOME_ATOL ? value/total : missing
equity_digest(object) = bytes2hex(sha256(take!((io=IOBuffer(); serialize(io, object); io))))

function equity_metadata(config, policy)
    fields = (:ConfigID, :RandomInstanceID, :Sigma, :DatasetID, :FormulationID,
        :InstanceFile, :TreeSpec, :NBstage, :Childs, :Periods, :Scenarios, :J,
        :Theta, :Avg_d, :Dev_d, :DemandProfile, :BatteryScale, :PVScale,
        :GeneratorSeed, :ReferenceRevision, :SAFairnessAbsTol, :LexEpsAbs, :Provenance)
    return merge(NamedTuple{fields}(Tuple(getproperty(config, f) for f in fields)), (Fairness=policy,))
end

"""The expectation is missing if any positive-probability scenario is undefined.
ValidContribution is an unnormalized integral, never a substitute for the expectation.
"""
function equity_weighted_metrics(values, probabilities)
    length(values)==length(probabilities) || error("Weight length mismatch")
    all(p -> isfinite(p) && p>=0, probabilities) || error("Invalid weights")
    isapprox(sum(probabilities), 1; atol=1e-10, rtol=0) || error("Weights must sum to one")
    valid = [i for i in eachindex(values) if !ismissing(values[i]) && isfinite(values[i]) && probabilities[i]>0]
    invalid = [i for i in eachindex(values) if (ismissing(values[i]) || !isfinite(values[i])) && probabilities[i]>0]
    mass = sum(probabilities[i] for i in valid; init=0.0)
    missing_mass = sum(probabilities[i] for i in invalid; init=0.0)
    contribution = sum(probabilities[i]*values[i] for i in valid; init=0.0)
    complete = isempty(invalid)
    conditional_mean = mass>0 ? contribution/mass : missing
    conditional_std = mass>0 ? sqrt(sum(probabilities[i]*(values[i]-conditional_mean)^2 for i in valid)/mass) : missing
    ordered = sort(valid; by=i->values[i])
    function quantile_at(q)
        mass>0 || return missing
        cumulative=0.0
        for i in ordered
            cumulative += probabilities[i]
            cumulative + 1e-14 >= q*mass && return values[i]
        end
        return values[ordered[end]]
    end
    return (ExpectedScenarioEquity=complete ? contribution : missing,
        ScenarioStd=complete ? conditional_std : missing,
        ValidProbabilityMass=mass, MissingProbabilityMass=missing_mass,
        ValidContribution=contribution, ConditionalValidMean=conditional_mean,
        ConditionalValidStd=conditional_std,
        ScenarioMin=isempty(valid) ? missing : minimum(values[valid]),
        ScenarioMax=isempty(valid) ? missing : maximum(values[valid]),
        ConditionalValidQ05=quantile_at(.05), ConditionalValidQ25=quantile_at(.25),
        ConditionalValidQ50=quantile_at(.50), ConditionalValidQ75=quantile_at(.75),
        ConditionalValidQ95=quantile_at(.95))
end

function equity_extract(inst, sol, config, policy; source_file="", validate=true)
    policy in SCENARIO_EQUITY_POLICIES || error("Outside five-policy experiment")
    sol.status || error("No primal solution")
    (inst.J==config.J && inst.tree.S==config.NBstage && inst.tree.C==config.Childs &&
        inst.tree.T==config.Periods && length(inst.tree.scenarios)==config.Scenarios) ||
        error("Instance/scenario metadata mismatch")
    before = equity_digest(sol)
    tree_data = equity_tree_data(inst)
    probabilities, times = tree_data.probabilities, tree_data.times
    J, W = inst.J, length(probabilities)
    all(size(getproperty(sol,f))==(J,inst.tree.V) for f in (:p,:I,:G,:z,:y)) || error("Decision shape mismatch")
    all(all(isfinite, getproperty(sol,f)) for f in (:p,:I,:G,:z,:y,:costs)) || error("Nonfinite decisions")
    meta = merge(equity_metadata(config, policy), (Delta=inst.delta, SourceFile=source_file, Status=true))
    pv, demand, imports, exports, charge, discharge = (zeros(J,W) for _ in 1:6)
    benchmark, cost = zeros(J,W), zeros(J,W)
    household_rows, metric_rows, expected_rows, instance_rows = (NamedTuple[] for _ in 1:4)
    for (w,path) in enumerate(inst.tree.scenarios)
        for j in 1:J
            pv[j,w] = inst.delta*sum(sol.p[j,n] for n in path)
            demand[j,w] = inst.delta*sum(inst.d[j,n] for n in path)
            imports[j,w] = inst.delta*sum(sol.I[j,n] for n in path)
            exports[j,w] = inst.delta*sum(sol.G[j,n] for n in path)
            charge[j,w] = inst.delta*sum(sol.z[j,n] for n in path)
            discharge[j,w] = inst.delta*sum(sol.y[j,n] for n in path)
            benchmark[j,w] = inst.delta*sum(inst.nu[j,times[n]]*inst.d[j,n] for n in path)
            cost[j,w] = inst.delta*sum(inst.mu*sol.y[j,n]+inst.nu[j,times[n]]*sol.I[j,n]-inst.beta*sol.G[j,n] for n in path)
        end
        savings = benchmark[:,w]-cost[:,w]
        pm, sm = equity_vector_metrics(pv[:,w]), equity_vector_metrics(savings)
        scenmeta = merge(meta, (Scenario=w, ScenarioProbability=probabilities[w], LeafNode=path[1]))
        for j in 1:J
            push!(household_rows, merge(scenmeta, (House=j, ScenarioPVAllocation=pv[j,w],
                ScenarioDemand=demand[j,w], ScenarioGridImport=imports[j,w], ScenarioGridExport=exports[j,w],
                ScenarioBatteryCharge=charge[j,w], ScenarioBatteryDischarge=discharge[j,w],
                ScenarioAllGridBenchmark=benchmark[j,w], ScenarioOperatingCost=cost[j,w],
                ScenarioSavings=savings[j], ScenarioPVShare=equity_share(pv[j,w],sum(pv[:,w])),
                ScenarioSavingsShare=equity_share(savings[j],sum(savings)))))
        end
        push!(metric_rows, merge(scenmeta, (PVJain=pm.Jain, PVGini=pm.Gini, PVMaxMin=pm.MaxMin,
            SavingsJain=sm.Jain, SavingsGini=sm.Gini, SavingsMaxMin=sm.MaxMin,
            PVMin=pm.Min, PVMax=pm.Max, SavingsMin=sm.Min, SavingsMax=sm.Max,
            TotalPVAllocation=pm.Total, TotalSavings=sm.Total, PVMetricValid=pm.MetricValid,
            SavingsMetricValid=sm.MetricValid, PVJainValid=pm.JainValid, PVGiniValid=pm.GiniValid,
            PVMaxMinValid=pm.MaxMinValid, SavingsJainValid=sm.JainValid,
            SavingsGiniValid=sm.GiniValid, SavingsMaxMinValid=sm.MaxMinValid,
            PVValidityReason=pm.Reason, SavingsValidityReason=sm.Reason,
            MetricValidityReason="PV:"*pm.Reason*";Savings:"*sm.Reason,
            SavingsNegativeCount=sm.NegativeCount, OutcomeAbsoluteTolerance=EQUITY_OUTCOME_ATOL)))
    end
    epv, eb, ek = pv*probabilities, benchmark*probabilities, cost*probabilities
    es = eb-ek
    for j in 1:J
        push!(expected_rows, merge(meta, (House=j, ExpectedPV=epv[j], ExpectedSavings=es[j],
            ExpectedBenchmark=eb[j], ExpectedOperatingCost=ek[j], ExpectedCost=ek[j],
            PVReceivedExpected=epv[j], CostExpected=ek[j], AllGridExpectedCost=eb[j], Savings=es[j])))
    end
    for (resource,vector) in (("PV",epv),("Savings",es))
        expected_metrics = equity_vector_metrics(vector)
        for metric in (:Jain,:Gini,:MaxMin)
            column = Symbol(resource, metric)
            values = [getproperty(r,column) for r in metric_rows]
            weighted = equity_weighted_metrics(values, probabilities)
            exante = getproperty(expected_metrics, metric)
            scenario_expected = weighted.ExpectedScenarioEquity
            push!(instance_rows, merge(meta, (Resource=resource, Metric=String(metric),
                EquityOfExpectedOutcomes=exante,
                ExpectedOutcomeValidityReason=expected_metrics.Reason,
                ExAnteMinusScenarioMean=ismissing(exante)||ismissing(scenario_expected) ? missing : exante-scenario_expected), weighted))
        end
    end
    residuals = equity_validate_extraction(inst,sol,tree_data,pv,epv,eb,ek,es; check=validate)
    fairness_residual = missing
    if policy=="PEA"
        target=[sum(probabilities[w] * inst.delta * sum(inst.c_pv[n] for n in path) *
            sum(inst.d[j,n] for n in path)/sum(inst.d[k,n] for k in 1:J,n in path)
            for (w,path) in enumerate(inst.tree.scenarios)) for j in 1:J]
        fairness_residual=maximum(abs,epv-target)
        validate && fairness_residual>1e-6 && error("PEA expectation constraint failed")
    elseif policy=="SA"
        # Match the source's TOL=1 denominator floor in both RHS occurrences.
        # Generated experimental benchmarks are all far above that floor.
        target=[sum(probabilities[w]*benchmark[j,w]/max(1.,sum(benchmark[:,w]))*
            (max(1.,sum(benchmark[:,w]))-sum(cost[:,w])) for w in 1:W) for j in 1:J]
        fairness_residual=maximum(abs,es-target)
        validate && fairness_residual>config.SAFairnessAbsTol+1e-6 && error("SA expectation constraint failed")
    end
    before==equity_digest(sol) || error("Extraction changed solution decisions")
    return (households=DataFrame(household_rows), metrics=DataFrame(metric_rows),
        expected=DataFrame(expected_rows), instances=DataFrame(instance_rows),
        validation=merge(residuals,(FairnessResidual=fairness_residual,
            DecisionDigest=before, DecisionsUnchanged=true)))
end

function equity_validate_extraction(inst,sol,tree_data,pv,epv,eb,ek,es;check=true)
    nodes, times = 1:inst.tree.V, tree_data.times
    rho = inst.tree.rho
    reference_pv = inst.delta .* [sum(rho[n]*sol.p[j,n] for n in nodes) for j in 1:inst.J]
    reference_benchmark = inst.delta .* [sum(rho[n]*inst.nu[j,times[n]]*inst.d[j,n] for n in nodes) for j in 1:inst.J]
    reference_cost = inst.delta .* [sum(rho[n]*(inst.mu*sol.y[j,n]+inst.nu[j,times[n]]*sol.I[j,n]-inst.beta*sol.G[j,n]) for n in nodes) for j in 1:inst.J]
    close(a,b) = all(isapprox.(a,b;atol=EQUITY_VALIDATION_ATOL,rtol=EQUITY_VALIDATION_RTOL))
    if check
        close(epv, reference_pv) || error("Expected PV mismatch")
        close(eb, reference_benchmark) || error("Expected benchmark mismatch")
        close(ek, reference_cost) || error("Expected operating cost mismatch")
        close(ek, sol.costs) || error("Solution household cost mismatch")
        close(es, reference_benchmark-sol.costs) || error("Expected savings mismatch")
    end
    available = [inst.delta*sum(inst.c_pv[n] for n in path) for path in inst.tree.scenarios]
    scenario_totals = vec(sum(pv;dims=1))
    check && !close(scenario_totals,available) && error("Scenario PV conservation failed")
    node_pv = vec(sum(sol.p;dims=1))
    balance = inst.d-sol.p-sol.y-sol.I+sol.z+sol.G
    soc_residual = [sol.s[n]-(inst.tree.parents[n]==0 ? inst.s_I : sol.s[inst.tree.parents[n]])-
        inst.delta*inst.e_c*sum(sol.z[:,n])+inst.delta/inst.e_d*sum(sol.y[:,n]) for n in nodes]
    tol = EQUITY_VALIDATION_ATOL
    if check
        close(node_pv,inst.c_pv) || error("Node PV conservation failed")
        maximum(abs,balance)<=tol || error("Node energy balance failed")
        maximum(abs,soc_residual)<=tol || error("Battery state transition failed")
        minimum(sol.s)>=inst.s_min-tol && maximum(sol.s)<=inst.s_max+tol || error("SOC bounds failed")
        all(abs(sol.s[n]-inst.s_I)<=tol for n in nodes if times[n]==inst.T) || error("Terminal SOC failed")
        maximum(sum(sol.z;dims=1))<=inst.f_under+tol || error("Charge rate failed")
        maximum(sum(sol.y;dims=1))<=inst.f_bar+tol || error("Discharge rate failed")
        all(minimum(getproperty(sol,f))>=-tol for f in (:p,:I,:G,:y,:z)) || error("Negative decisions")
    end
    return (ExpectedPVResidual=maximum(abs,epv-reference_pv),
        ExpectedBenchmarkResidual=maximum(abs,eb-reference_benchmark),
        ExpectedSavingsResidual=maximum(abs,es-(reference_benchmark-sol.costs)),
        SolutionCostResidual=maximum(abs,ek-sol.costs),
        ScenarioPVConservationResidual=maximum(abs,scenario_totals-available),
        NodeBalanceResidual=maximum(abs,balance), SOCTransitionResidual=maximum(abs,soc_residual),
        ProbabilitySum=sum(tree_data.probabilities), PathsValid=true, Passed=check)
end

function equity_summary(instances)
    rows=NamedTuple[]
    for group in groupby(instances,[:DatasetID,:Sigma,:Fairness,:Resource])
        firstrow=first(eachrow(group))
        row=Dict{Symbol,Any}(f=>getproperty(firstrow,f) for f in (:DatasetID,:Sigma,:Fairness,:Resource))
        row[:NumInstances]=length(unique(group.ConfigID))
        row[:NumScenarios]=sum(first(g.Scenarios) for g in groupby(group,:ConfigID))
        row[:InstanceWeighting]="equal_configuration_weight; scenarios_use_leaf_probability"
        for metric in ("Jain","Gini","MaxMin")
            sub=group[group.Metric .== metric,:]
            for column in (:EquityOfExpectedOutcomes,:ExpectedScenarioEquity,:ScenarioStd,
                :ScenarioMin,:ScenarioMax,:ConditionalValidQ05,:ConditionalValidQ25,:ConditionalValidQ50,
                :ConditionalValidQ75,:ConditionalValidQ95,:ValidProbabilityMass,:MissingProbabilityMass,
                :ValidContribution,:ConditionalValidMean,:ConditionalValidStd,:ExAnteMinusScenarioMean)
                v=sub[!,column]
                complete=all(!ismissing(x) for x in v)
                row[Symbol(metric,"_",column,"_MeanAcrossInstances")]=complete ? mean(v) : missing
                if column in (:EquityOfExpectedOutcomes,:ExpectedScenarioEquity)
                    row[Symbol(metric,"_",column,"_StdAcrossInstances")]=complete && length(v)>1 ? std(v) : missing
                    row[Symbol(metric,"_",column,"_ValidInstances")]=count(!ismissing,v)
                    # Explicit conditional descriptive statistic, not a full expectation.
                    valid=collect(skipmissing(v))
                    row[Symbol(metric,"_",column,"_ConditionalValidInstanceMean")]=isempty(valid) ? missing : mean(valid)
                end
            end
            row[Symbol(metric,"_ScenarioGlobalMin")]=all(ismissing,sub.ScenarioMin) ? missing : minimum(skipmissing(sub.ScenarioMin))
            row[Symbol(metric,"_ScenarioGlobalMax")]=all(ismissing,sub.ScenarioMax) ? missing : maximum(skipmissing(sub.ScenarioMax))
        end
        push!(rows,(;row...))
    end
    frame=DataFrame(rows)
    front=[:DatasetID,:Sigma,:Fairness,:Resource,:NumInstances,:NumScenarios,:InstanceWeighting]
    select!(frame,vcat(front,sort(setdiff(Symbol.(names(frame)),front))))
    sort!(frame,[:DatasetID,:Sigma,:Fairness,:Resource])
    return frame
end
