include("scenario_equity_runtime.jl")
using Dates

function equity_check_inputs(reference,output,manifest)
    historical=equity_read_csv(joinpath(output,"historical_expected_household_results.csv"))
    rows=NamedTuple[]
    for config in eachrow(manifest)
        inst=equity_instance(reference,config)
        tree=equity_tree_data(inst)
        seed=equity_generator_seed(config)
        seed==config.GeneratorSeed || error("Manifest seed mismatch")
        source=historical[(historical.ConfigID .== config.ConfigID).&(historical.Fairness .== "NONE"),:]
        sort!(source,:House)
        benchmark=inst.delta.*[sum(inst.tree.rho[n]*inst.nu[j,tree.times[n]]*inst.d[j,n]
            for n in 1:inst.tree.V) for j in 1:inst.J]
        available=inst.delta*sum(inst.tree.rho.*inst.c_pv)
        expected_demand=inst.delta.*[sum(inst.tree.rho[n]*inst.d[j,n] for n in 1:inst.tree.V) for j in 1:inst.J]
        residual=maximum(abs,benchmark-source.ExpectedBenchmark)
        pv_residual=abs(available-sum(source.ExpectedPV))
        demand_residual=maximum(abs,expected_demand-source.ExpectedDemand)
        passed=all(isapprox.(benchmark,source.ExpectedBenchmark;atol=1e-6,rtol=1e-9)) &&
            all(isapprox.(expected_demand,source.ExpectedDemand;atol=1e-6,rtol=1e-9)) &&
            isapprox(available,sum(source.ExpectedPV);atol=1e-6,rtol=1e-9)
        push!(rows,(ConfigID=String(config.ConfigID),GeneratorSeed=seed,InputBenchmarkResidual=residual,
            InputPVResidual=pv_residual,InputDemandResidual=demand_residual,Passed=passed,JuliaVersion=string(VERSION)))
    end
    df=DataFrame(rows)
    equity_atomic_csv(joinpath(output,"input_validation.csv"),df)
    println("Input replication: ",count(df.Passed),"/",nrow(df)," configurations pass")
    return all(df.Passed)
end

function equity_recover(reference,output)
    config=equity_validation_config(output)
    inst=equity_instance(reference,config)
    snapshots=[joinpath(EQUITY_REPO_ROOT,"results_models",dir,file) for (dir,file) in
        [("conditional_fairness_validation","baseline_before.bin"),
         ("conditional_fairness_validation","baseline_after.bin"),
         ("static_demand_share_validation","existing_policies_before.bin"),
         ("static_demand_share_validation","existing_policies_after.bin")]]
    seen=Dict{Tuple{String,String},String}()
    provenance=NamedTuple[]
    for file in snapshots
        snapshots_dict=open(deserialize,file)
        for policy in SCENARIO_EQUITY_POLICIES
            sol=snapshots_dict[policy]
            signature=equity_digest((p=sol.p,I=sol.I,G=sol.G,z=sol.z,y=sol.y,s=sol.s,costs=sol.costs))
            key=(policy,signature)
            duplicate=haskey(seen,key)
            result=equity_extract(inst,sol,config,policy;source_file=relpath(file,EQUITY_REPO_ROOT))
            if !duplicate
                # Different decision snapshots stay in separate datasets; never count them as independent instances.
                number=count(k->k[1]==policy,keys(seen))+1
                actual_config=number==1 ? config : merge(config,(DatasetID="recovered_validation_snapshot_variant$(number)",))
                directory=joinpath(output,"shards",actual_config.DatasetID,actual_config.ConfigID,policy)
                result=equity_extract(inst,sol,actual_config,policy;source_file=relpath(file,EQUITY_REPO_ROOT))
                equity_save_object(joinpath(directory,"solution.bin"),(instance=equity_portable(inst),
                    solution=sol,config=actual_config,policy=policy,source_file=relpath(file,EQUITY_REPO_ROOT),
                    JuliaVersion=string(VERSION),OptimizationRerun=false))
                equity_write_extraction(directory,result)
                equity_complete_shard(directory)
                seen[key]=directory
            end
            push!(provenance,(SourceFile=relpath(file,EQUITY_REPO_ROOT),Fairness=policy,
                DecisionDigest=signature,Duplicate=duplicate,CanonicalShard=relpath(seen[key],output),
                OptimizationRerun=false,Validated=result.validation.Passed))
        end
    end
    equity_atomic_csv(joinpath(output,"snapshot_recovery_provenance.csv"),DataFrame(provenance))
    println("Recovered ",length(seen)," distinct policy decisions from 20 snapshot records")
end

function equity_complete_shard(directory)
    names=["solution.bin","scenario_household_results.csv","scenario_equity_metrics.csv",
        "expected_household_results.csv","instance_equity_summary.csv","validation.csv"]
    rows=[(File=name,SHA256=bytes2hex(open(sha256,joinpath(directory,name)))) for name in names]
    equity_atomic_csv(joinpath(directory,"complete.csv"),DataFrame(rows))
end

function equity_shard_complete(directory)
    marker=joinpath(directory,"complete.csv")
    isfile(marker) || return false
    rows=equity_read_csv(marker)
    required=["solution.bin","scenario_household_results.csv","scenario_equity_metrics.csv",
        "expected_household_results.csv","instance_equity_summary.csv","validation.csv"]
    nrow(rows)==length(required) && sort(String.(rows.File))==sort(required) || return false
    for row in eachrow(rows)
        file=joinpath(directory,row.File)
        isfile(file) && bytes2hex(open(sha256,file))==row.SHA256 || return false
    end
    validation=equity_read_csv(joinpath(directory,"validation.csv"))
    return nrow(validation)==1 && first(validation.Passed) && first(validation.DecisionsUnchanged)
end

function equity_set_threads(reference,output)
    cp=reference.CPLEX
    path=abspath(joinpath(output,"cplex_threads_1.prm"))
    env=cp.Env()
    try
        cp.CPXsetintparam(env,cp.CPXPARAM_Threads,1)==0 || error("Cannot set solver threads")
        cp.CPXwriteparam(env,path)==0 || error("Cannot save solver parameters")
        version=unsafe_string(cp.CPXversion(env))
        open(joinpath(output,"solver_environment.txt"),"w") do io
            println(io,"JuliaVersion=",VERSION,"\nCPLEXVersion=",version,"\nThreads=1\nTimeLimit=source_default\nFairnessTolerance=source_default")
        end
    finally
        finalize(env)
    end
    ENV["ILOG_CPLEX_PARAMETER_FILE"]=path
    optimizer=cp.Optimizer()
    try
        reference.JuMP.MOI.get(optimizer,reference.JuMP.MOI.NumberOfThreads())==1 || error("Solver thread limit not applied")
    finally
        finalize(optimizer)
    end
end

function equity_extract_checkpoints(output)
    for (directory,_,files) in walkdir(joinpath(output,"shards"))
        "solution.bin" in files || continue
        equity_shard_complete(directory) && continue
        artifact=open(deserialize,joinpath(directory,"solution.bin"))
        extraction=equity_extract(artifact.instance,artifact.solution,artifact.config,artifact.policy;
            source_file=artifact.source_file)
        equity_write_extraction(directory,extraction)
        equity_complete_shard(directory)
        println("RECONSTRUCT CHECKPOINT ",artifact.config.ConfigID," ",artifact.policy," ",artifact.config.DatasetID)
    end
end

function equity_run(reference,output,manifest; allow_nonreplication=false)
    inputs_match=equity_check_inputs(reference,output,manifest)
    if !inputs_match
        allow_nonreplication || error(
            "Original generated inputs are not reproduced with this runtime; see input_validation.csv. No optimization launched. Use run-reproducible for explicitly labeled new inputs.")
        manifest=copy(manifest)
        manifest.DatasetID.= "reproducible_same_numeric_design"
        manifest.Provenance.= "original_inputs_unrecovered_new_reproducible_inputs_same_numeric_design"
        equity_atomic_csv(joinpath(output,"reproducible_config_manifest.csv"),manifest)
        println("New reproducible inputs: these solves are not exact replications of the original results.")
    end
    equity_set_threads(reference,output)
    filters=split(get(ENV,"CONFIG_IDS",""),',')
    selected=isempty(first(filters)) ? manifest : manifest[in.(manifest.ConfigID,Ref(filters)),:]
    policies=String.(split(get(ENV,"FAIRNESS_SET",join(SCENARIO_EQUITY_POLICIES,',')),','))
    all(p->p in SCENARIO_EQUITY_POLICIES,policies) || error("Only original five policies allowed")
    failures_path=joinpath(output,"execution_failures.csv")
    failures=isfile(failures_path) ? equity_read_csv(failures_path) : DataFrame(
        ConfigID=String[],Fairness=String[],DatasetID=String[],ErrorMessage=String[],Timestamp=String[])
    for configrow in eachrow(selected), policy in policies
        config=NamedTuple(configrow)
        directory=joinpath(output,"shards",config.DatasetID,config.ConfigID,policy)
        if equity_shard_complete(directory)
            artifact=open(deserialize,joinpath(directory,"solution.bin"))
            artifact.config==config || error("Configuration changed for completed shard")
            println("SKIP ",config.ConfigID," ",policy," validated complete")
            continue
        end
        mkpath(directory)
        checkpoint=joinpath(directory,"solution.bin")
        println("RUN ",config.ConfigID," ",policy," Sigma=",config.Sigma," J=",config.J)
        flush(stdout)
        try
        if isfile(checkpoint)
            artifact=open(deserialize,checkpoint)
            artifact.config==config || error("Configuration changed for saved solution")
        else
            inst=equity_instance(reference,config)
            result=open(joinpath(directory,"solver.log"),"w") do log
                redirect_stdout(log) do
                    redirect_stderr(log) do
                        Base.invokelatest(reference.solveMulti,inst,policy;
                            sa_fairness_abs_tol=Float64(config.SAFairnessAbsTol))
                    end
                end
            end
            solution=result isa Tuple ? result[1] : result
            solution.status || error("No primal solution: $(config.ConfigID)/$policy")
            artifact=(instance=equity_portable(inst),solution=equity_portable(solution),config=config,
                policy=policy,source_file=relpath(checkpoint,EQUITY_REPO_ROOT),JuliaVersion=string(VERSION),
                OptimizationRerun=true,CompletedAt=string(now()),
                FormulationSourceDigest=equity_digest(read(joinpath(output,"reference_source","multi.jl"))))
            equity_save_object(checkpoint,artifact)
        end
        extraction=equity_extract(artifact.instance,artifact.solution,config,policy;source_file=artifact.source_file)
        equity_write_extraction(directory,extraction)
        equity_complete_shard(directory)
        println("COMPLETE ",config.ConfigID," ",policy," cost residual=",extraction.validation.SolutionCostResidual)
        if nrow(failures)>0
            failures=failures[.!((failures.ConfigID.==config.ConfigID).&(failures.Fairness.==policy).&
                (failures.DatasetID.==config.DatasetID)),:]
        end
        equity_atomic_csv(failures_path,failures)
        flush(stdout)
        catch err
            message=sprint(showerror,err)
            push!(failures,(ConfigID=config.ConfigID,Fairness=policy,DatasetID=config.DatasetID,
                ErrorMessage=message,Timestamp=string(now()));cols=:union)
            equity_atomic_csv(failures_path,failures)
            println(stderr,"FAIL ",config.ConfigID," ",policy," ",message)
            flush(stderr)
            # A system-wide solver/license failure cannot be repaired by submitting more models.
            occursin(r"(?i)license|CPLEX Error 1016|not found|could not load",message) && rethrow()
        end
    end
end

"""Record reused versus solved decisions and verify identical policy inputs."""
function equity_checkpoint_provenance(output)
    rows=NamedTuple[]
    instances=Dict{Tuple{String,String},String}()
    for (directory,_,files) in walkdir(joinpath(output,"shards"))
        "complete.csv" in files && equity_shard_complete(directory) || continue
        artifact=open(deserialize,joinpath(directory,"solution.bin"))
        config=artifact.config
        inst=artifact.instance
        (inst.J==config.J && inst.tree.S==config.NBstage && inst.tree.C==config.Childs &&
            inst.tree.T==config.Periods && length(inst.tree.scenarios)==config.Scenarios) ||
            error("Checkpoint instance/scenario metadata mismatch: $directory")
        instance_digest=equity_digest(artifact.instance)
        key=(String(config.DatasetID),String(config.ConfigID))
        get(instances,key,instance_digest)==instance_digest ||
            error("Different generated instances across policies: $key")
        instances[key]=instance_digest
        validation=first(eachrow(equity_read_csv(joinpath(directory,"validation.csv"))))
        equity_digest(artifact.solution)==validation.DecisionDigest ||
            error("Saved decisions do not match extraction validation: $directory")
        if hasproperty(artifact,:FormulationSourceDigest)
            artifact.FormulationSourceDigest==equity_digest(read(joinpath(output,"reference_source","multi.jl"))) ||
                error("Saved formulation digest differs: $directory")
        end
        push!(rows,(DatasetID=String(config.DatasetID),ConfigID=String(config.ConfigID),
            RandomInstanceID=String(config.RandomInstanceID),Sigma=config.Sigma,Fairness=String(artifact.policy),
            OptimizationRerun=artifact.OptimizationRerun,
            ExecutionKind=artifact.OptimizationRerun ? "optimization_rerun" : "saved_solution_recovery",
            JuliaVersion=artifact.JuliaVersion,GeneratorSeed=config.GeneratorSeed,
            InstanceFile=String(config.InstanceFile),InstanceSHA256=String(config.InstanceSHA256),
            GeneratedInstanceDigest=instance_digest,IdenticalInputsAcrossPolicies=true,
            DecisionDigest=String(validation.DecisionDigest),
            SolutionFileSHA256=bytes2hex(open(sha256,joinpath(directory,"solution.bin"))),
            SourceFile=String(artifact.source_file),ReferenceRevision=String(config.ReferenceRevision),
            FormulationID=String(config.FormulationID),
            CompletedAt=hasproperty(artifact,:CompletedAt) ? artifact.CompletedAt : missing,
            SourceReportedSolverTimeSeconds=hasproperty(artifact.solution,:time) ? artifact.solution.time : missing,
            SourceReportedPolicyTimeSeconds=hasproperty(artifact.solution,:run_time) ? artifact.solution.run_time : missing,
            VerifiedSolverThreads=artifact.OptimizationRerun ? 1 : missing))
    end
    frame=DataFrame(rows)
    sort!(frame,[:DatasetID,:ConfigID,:Fairness])
    equity_atomic_csv(joinpath(output,"optimization_provenance.csv"),frame)
    println("Verified checkpoint provenance for ",nrow(frame)," policy solutions and ",length(instances)," generated inputs")
end

function equity_solver_parameters(reference,output,manifest)
    cp=reference.CPLEX
    env=cp.Env()
    rows=NamedTuple[]
    try
        cp.CPXsetintparam(env,cp.CPXPARAM_Threads,1)==0 || error("Cannot set verified thread count")
        for name in (:CPXPARAM_Threads,:CPXPARAM_LPMethod,:CPXPARAM_Preprocessing_Presolve,:CPXPARAM_RandomSeed)
            value=Ref{Cint}()
            cp.CPXgetintparam(env,getproperty(cp,name),value)==0 || error("Cannot read $name")
            push!(rows,(Parameter=String(name),Value=string(value[]),Scope="installed_CPLEX_environment",
                Provenance=name==:CPXPARAM_Threads ? "explicit_worker_setting" : "installed_default"))
        end
        for name in (:CPXPARAM_Simplex_Tolerances_Feasibility,:CPXPARAM_Simplex_Tolerances_Optimality,
            :CPXPARAM_Barrier_ConvergeTol,:CPXPARAM_TimeLimit)
            value=Ref{Cdouble}()
            cp.CPXgetdblparam(env,getproperty(cp,name),value)==0 || error("Cannot read $name")
            push!(rows,(Parameter=String(name),Value=string(value[]),Scope="installed_CPLEX_environment",
                Provenance="installed_default; cost_models_override_TimeLimit_to_3600_seconds"))
        end
        for (name,value,scope) in (("CostModelTimeLimitSeconds",3600,"NONE_PEA_SA_LEXMMFPEA_final_cost_stage"),
            ("SAFairnessAbsTol",only(unique(manifest.SAFairnessAbsTol)),"SA_constraints"),
            ("LexEpsAbs",only(unique(manifest.LexEpsAbs)),"LEXMMFPEA_and_LEXMMFSA"))
            push!(rows,(Parameter=name,Value=string(value),Scope=scope,Provenance="pinned_source_and_config_manifest"))
        end
    finally
        finalize(env)
    end
    equity_atomic_csv(joinpath(output,"solver_parameters.csv"),DataFrame(rows))
    println("Recorded installed solver defaults and source/manifest overrides; no optimization launched")
end

function equity_merge(output,manifest)
    shardroot=joinpath(output,"shards")
    directories=String[]
    if isdir(shardroot)
        for (dir,_,files) in walkdir(shardroot)
            "complete.csv" in files && equity_shard_complete(dir) && push!(directories,dir)
        end
    end
    sort!(directories)
    expected=equity_read_csv(joinpath(output,"historical_expected_household_results.csv"))
    instances=DataFrame()
    validations=DataFrame()
    completed=Dict{Tuple{String,String},String}()
    for directory in directories
        append!(expected,equity_read_csv(joinpath(directory,"expected_household_results.csv"));cols=:union)
        frame=equity_read_csv(joinpath(directory,"instance_equity_summary.csv"))
        append!(instances,frame;cols=:union)
        v=equity_read_csv(joinpath(directory,"validation.csv"))
        v.ConfigID=fill(first(frame.ConfigID),nrow(v))
        v.Fairness=fill(first(frame.Fairness),nrow(v))
        v.DatasetID=fill(first(frame.DatasetID),nrow(v))
        append!(validations,v;cols=:union)
        if first(frame.DatasetID)=="manuscript_design_rerun"
            completed[(String(first(frame.ConfigID)),String(first(frame.Fairness)))]=String(first(frame.DatasetID))
        end
    end
    equity_atomic_csv(joinpath(output,"expected_household_results.csv"),expected)
    equity_atomic_csv(joinpath(output,"instance_equity_summary.csv"),instances)
    equity_atomic_csv(joinpath(output,"validation_results.csv"),validations)
    nrow(instances)>0 && equity_atomic_csv(joinpath(output,"equity_summary.csv"),equity_summary(instances))
    # Stream large household/scenario CSVs instead of materializing every scenario in memory.
    for name in ["scenario_household_results.csv","scenario_equity_metrics.csv"]
        temporary=joinpath(output,name*".tmp")
        open(temporary,"w") do destination
            header=nothing
            for directory in directories
                open(joinpath(directory,name)) do source
                    current=readline(source)
                    if header===nothing
                        header=current
                        println(destination,header)
                    else
                        current==header || error("Inconsistent shard schema")
                    end
                    while !eof(source)
                        write(destination,read(source,1024*1024))
                    end
                end
            end
        end
        mv(temporary,joinpath(output,name);force=true)
    end
    status=DataFrame([(ConfigID=String(config.ConfigID),Sigma=config.Sigma,Fairness=policy,
        Complete=haskey(completed,(String(config.ConfigID),policy)),
        ActualDatasetID=get(completed,(String(config.ConfigID),policy),"unavailable"),
        OriginalInputsReproduced=get(completed,(String(config.ConfigID),policy),"")=="manuscript_design_rerun",
        ExecutionStatus=haskey(completed,(String(config.ConfigID),policy)) ?
            "rerun_validated_"*completed[(String(config.ConfigID),policy)] : "pending_original_seed_rerun")
        for config in eachrow(manifest) for policy in SCENARIO_EQUITY_POLICIES])
    equity_atomic_csv(joinpath(output,"execution_status.csv"),status)
    # Historical outputs remain the table reproduction reference; differences in new optimal
    # household allocations are measured separately because LP optima need not be unique.
    comparisons=NamedTuple[]
    historical=expected[expected.DatasetID .== "historical_expected_only",:]
    reruns=expected[in.(expected.DatasetID,Ref(["manuscript_design_rerun","reproducible_same_numeric_design"])),:]
    for group in groupby(reruns,[:DatasetID,:ConfigID,:Fairness])
        old=historical[(historical.ConfigID .== first(group.ConfigID)).&(historical.Fairness .== first(group.Fairness)),:]
        sort!(group,:House)
        sort!(old,:House)
        for resource in ("PV","Savings"), metric in (:Jain,:Gini,:MaxMin)
            col=Symbol("Expected",resource)
            a=getproperty(equity_vector_metrics(Float64.(old[!,col])),metric)
            b=getproperty(equity_vector_metrics(Float64.(group[!,col])),metric)
            push!(comparisons,(DatasetID=String(first(group.DatasetID)),ConfigID=String(first(group.ConfigID)),Sigma=first(group.Sigma),
                Fairness=String(first(group.Fairness)),Resource=resource,Metric=String(metric),
                HistoricalValue=a,RerunValue=b,AbsoluteDifference=ismissing(a)||ismissing(b) ? missing : abs(a-b),
                ExpectedCostDifference=sum(group.ExpectedOperatingCost)-sum(old.ExpectedOperatingCost)))
        end
    end
    equity_atomic_csv(joinpath(output,"rerun_historical_comparison.csv"),DataFrame(comparisons))
    published=equity_read_csv(joinpath(output,"manuscript_comparison.csv"))
    table_rows=NamedTuple[]
    for group in groupby(instances,[:DatasetID,:Sigma,:Fairness,:Resource,:Metric])
        firstrow=first(eachrow(group))
        startswith(firstrow.DatasetID,"recovered_") && continue
        match=published[(published.Sigma.==firstrow.Sigma).&(published.Fairness.==firstrow.Fairness).&
            (published.Resource.==firstrow.Resource).&(published.Metric.==firstrow.Metric),:]
        manuscript_value=first(match.ManuscriptValue)
        valid=collect(skipmissing(group.EquityOfExpectedOutcomes))
        recomputed=isempty(valid) ? missing : mean(valid)
        difference=ismissing(recomputed) ? missing : abs(recomputed-manuscript_value)
        replicated=firstrow.DatasetID=="manuscript_design_rerun"
        push!(table_rows,(DatasetID=String(firstrow.DatasetID),Sigma=firstrow.Sigma,
            Fairness=String(firstrow.Fairness),Resource=String(firstrow.Resource),Metric=String(firstrow.Metric),
            ManuscriptValue=manuscript_value,RecomputedValue=recomputed,AbsoluteDifference=difference,
            RelativeDifference=ismissing(difference)||manuscript_value==0 ? missing : difference/abs(manuscript_value),
            ValidationStatus=!replicated ? "NOT_EXACT_REPLICATION_INPUT_MISMATCH" :
                (ismissing(difference) ? "UNDEFINED" : difference<=.005+1e-10 ? "PASS_ROUNDING" : "DIFFERENT_RERUN_OPTIMUM"),
            NumInstances=nrow(group),NumValidInstances=length(valid),
            Aggregation="conditional_valid_instance_mean_reported_with_counts"))
    end
    equity_atomic_csv(joinpath(output,"rerun_manuscript_comparison.csv"),DataFrame(table_rows))
    println("Merged ",length(directories)," validated shards; manuscript reruns ",length(completed),"/",nrow(status))
end

if abspath(PROGRAM_FILE)==@__FILE__
    output=abspath(get(ENV,"SCENARIO_EQUITY_DIR",EQUITY_DEFAULT_OUTPUT))
    manifest=equity_read_csv(joinpath(output,"config_manifest.csv"))
    command=isempty(ARGS) ? "recover" : first(ARGS)
    if command=="provenance"
        Base.invokelatest(equity_checkpoint_provenance,output)
    elseif command=="extract-checkpoints"
        Base.invokelatest(equity_extract_checkpoints,output)
        Base.invokelatest(equity_merge,output,manifest)
    elseif command=="merge"
        Base.invokelatest(equity_merge,output,manifest)
    else
        reference=equity_reference(output)
        if command=="check-inputs"
            Base.invokelatest(equity_check_inputs,reference,output,manifest) || exit(2)
        elseif command=="parameters"
            Base.invokelatest(equity_solver_parameters,reference,output,manifest)
        elseif command=="recover"
            Base.invokelatest(equity_recover,reference,output)
            Base.invokelatest(equity_merge,output,manifest)
        elseif command in ("run","run-reproducible")
            try
                Base.invokelatest(equity_run,reference,output,manifest;allow_nonreplication=command=="run-reproducible")
            finally
                Base.invokelatest(equity_merge,output,manifest)
            end
        else
            error("Use recover, check-inputs, parameters, run, run-reproducible, extract-checkpoints, provenance, or merge")
        end
    end
end
