using Test, Serialization, SHA
include(joinpath(@__DIR__,"..","..","codes","scenario_equity_runtime.jl"))

@testset "Equity formulas and validity" begin
    equal=equity_vector_metrics(fill(3.,5))
    @test equal.Jain==1
    @test equal.Gini==0
    @test equal.MaxMin==1
    for x in ([0.,1.,2.],[1.,3.,7.],[1e200,2e200,3e200])
        m=equity_vector_metrics(x)
        @test 1/length(x)-1e-14 <= m.Jain <= 1+1e-14
        @test 0 <= m.Gini <= (length(x)-1)/length(x)+1e-14
    end
    @test ismissing(equity_vector_metrics([0.,1.]).MaxMin)
    @test equity_vector_metrics([0.,1.]).Jain==.5
    @test equity_vector_metrics([0.,1.]).Gini==.5
    @test equity_vector_metrics([1.,4.]).MaxMin==4
    @test equity_vector_metrics([1e-12,1.]).Reason=="zero_or_negligible_minimum"
    @test ismissing(equity_vector_metrics(zeros(3)).Jain)
    @test ismissing(equity_vector_metrics([-1.,3.]).Jain)
    @test ismissing(equity_vector_metrics([-1.,3.]).Gini)
    @test ismissing(equity_vector_metrics([-1.,3.]).MaxMin)
    @test equity_vector_metrics([-1.,3.]).Min==-1
    @test equity_vector_metrics([NaN,1.]).Reason=="nonfinite_outcome"
    @test ismissing(equity_vector_metrics([Inf,1.]).Jain)
end

@testset "Probability-weighted scenario equity differs from ex ante" begin
    probabilities=[.2,.8]
    scenarios=[[9.,1.],[1.,9.]]
    expected=sum(probabilities[i]*scenarios[i] for i in eachindex(probabilities))
    exante=equity_vector_metrics(expected)
    for metric in (:Jain,:Gini,:MaxMin)
        values=[getproperty(equity_vector_metrics(x),metric) for x in scenarios]
        scenario=equity_weighted_metrics(values,probabilities)
        @test !isapprox(getproperty(exante,metric),scenario.ExpectedScenarioEquity)
    end
    partial=equity_weighted_metrics([1.,missing],[.2,.8])
    @test ismissing(partial.ExpectedScenarioEquity)
    @test ismissing(partial.ScenarioStd)
    @test partial.MissingProbabilityMass==.8
    @test partial.ValidContribution==.2
    @test partial.ConditionalValidMean==1
    @test partial.ConditionalValidQ50==1
    @test equity_weighted_metrics([missing,1.],[0.,1.]).ExpectedScenarioEquity==1
    @test_throws ErrorException equity_weighted_metrics([1.,1.],[.2,.2])
    full=equity_weighted_metrics([1.,3.],[.25,.75])
    @test full.ExpectedScenarioEquity==2.5
    @test full.ScenarioStd≈sqrt(.75)
    @test full.ConditionalValidQ50==3
end

reference=equity_reference()
config=equity_validation_config()
inst=equity_instance(reference,config)
snapshots=[joinpath(EQUITY_REPO_ROOT,"results_models",dir,file) for (dir,file) in
    [("conditional_fairness_validation","baseline_before.bin"),
     ("conditional_fairness_validation","baseline_after.bin"),
     ("static_demand_share_validation","existing_policies_before.bin"),
     ("static_demand_share_validation","existing_policies_after.bin")]]

@testset "Saved stochastic decisions: paths, expectations, costs, conservation" begin
    tree=equity_tree_data(inst)
    @test sum(tree.probabilities)≈1
    @test length(tree.probabilities)==4
    @test all(length(path)==24 for path in inst.tree.scenarios)
    for path in inst.tree.scenarios
        @test all(inst.tree.parents[path[i]]==path[i+1] for i in 1:23)
    end
    for file in snapshots, policy in SCENARIO_EQUITY_POLICIES
        sol=open(deserialize,file)[policy]
        before=equity_digest(sol)
        result=equity_extract(inst,sol,config,policy;source_file=file)
        @test result.validation.Passed
        @test before==equity_digest(sol)
        @test nrow(result.households)==20
        @test nrow(result.expected)==5
        @test maximum(abs,result.expected.ExpectedOperatingCost-sol.costs)<1e-6
        @test maximum(abs,result.expected.ExpectedSavings-
            (result.expected.ExpectedBenchmark-sol.costs))<1e-6
        for j in 1:inst.J
            household=result.households[result.households.House.==j,:]
            @test sum(household.ScenarioProbability.*household.ScenarioPVAllocation)≈result.expected.ExpectedPV[j]
            @test sum(household.ScenarioProbability.*household.ScenarioSavings)≈result.expected.ExpectedSavings[j]
            @test sum(household.ScenarioProbability.*household.ScenarioOperatingCost)≈sol.costs[j]
        end
        @test all(1/inst.J-1e-12<=x<=1+1e-12 for x in skipmissing(result.metrics.PVJain))
        @test all(0<=x<=1-1/inst.J+1e-12 for x in skipmissing(result.metrics.PVGini))
        # A nonunit time step must scale energy and economics, preserving metrics.
        half=deepcopy(inst)
        half.delta=.5
        # Decisions no longer meet physical SOC equations under a changed timestep;
        # this test only compares arithmetic and therefore disables physical validation.
        solhalf=merge(sol,(costs=sol.costs*.5,))
        scaled=equity_extract(half,solhalf,config,policy;validate=false)
        @test scaled.expected.ExpectedPV≈result.expected.ExpectedPV*.5
        @test scaled.expected.ExpectedSavings≈result.expected.ExpectedSavings*.5
    end
    broken=deepcopy(inst)
    broken.tree.rho[broken.tree.scenarios[1][1]]=.3
    @test_throws ErrorException equity_tree_data(broken)
    # A real branching tree with deliberately unequal leaf probabilities exercises
    # extraction itself, including the equivalence between leaf and node weights.
    unequal=deepcopy(inst)
    weights=[.1,.2,.3,.4]
    unequal.tree.rho.=0
    for (w,path) in enumerate(unequal.tree.scenarios)
        unequal.tree.rho[path].+=weights[w]
    end
    snapshot=open(deserialize,first(snapshots))["NONE"]
    times=equity_tree_data(unequal).times
    costs=[unequal.delta*sum(unequal.tree.rho[n]*(unequal.mu*snapshot.y[j,n]+
        unequal.nu[j,times[n]]*snapshot.I[j,n]-unequal.beta*snapshot.G[j,n])
        for n in 1:unequal.tree.V) for j in 1:unequal.J]
    extracted=equity_extract(unequal,merge(snapshot,(costs=costs,)),config,"NONE")
    @test extracted.validation.Passed
    @test extracted.metrics.ScenarioProbability==weights
    @test extracted.expected.ExpectedPV≈
        unequal.delta.*[sum(unequal.tree.rho[n]*snapshot.p[j,n] for n in 1:unequal.tree.V) for j in 1:unequal.J]
    # Two independent configurations have equal weight after their separate
    # probability-weighted scenario aggregation, regardless of scenario count.
    other=deepcopy(extracted.instances)
    other.ConfigID.= "V002"
    other.Scenarios.=8
    summary=equity_summary(vcat(extracted.instances,other))
    @test all(summary.NumInstances.==2)
    @test all(summary.NumScenarios.==12)
    pv_summary=summary[summary.Resource.=="PV",:]
    instance_jain=extracted.instances[(extracted.instances.Resource.=="PV").&(extracted.instances.Metric.=="Jain"),:]
    @test first(pv_summary.Jain_ExpectedScenarioEquity_MeanAcrossInstances)≈first(instance_jain.ExpectedScenarioEquity)
end

@testset "Historical files are preserved" begin
    hashes=equity_read_csv(joinpath(EQUITY_DEFAULT_OUTPUT,"historical_file_hashes.csv"))
    for row in eachrow(hashes)
        @test bytes2hex(open(sha256,joinpath(EQUITY_REPO_ROOT,row.Path)))==row.SHA256
    end
end

@testset "Recovered historical seed convention" begin
    manifest=equity_read_csv(joinpath(EQUITY_DEFAULT_OUTPUT,"config_manifest.csv"))
    probes=equity_read_csv(joinpath(EQUITY_DEFAULT_OUTPUT,"seed_probe_without_profile_julia_1_12_6.csv"))
    @test nrow(probes)==80
    @test all(probes.Passed)
    for row in eachrow(manifest)
        @test equity_generator_seed(row)==row.GeneratorSeed
    end
    @test equity_generator_seed(config)==config.GeneratorSeed
    @test equity_generator_seed(first(eachrow(manifest));include_profile=true)!=first(manifest.GeneratorSeed)
end

println("Scenario equity validation passed; no optimization was needed for these tests.")
