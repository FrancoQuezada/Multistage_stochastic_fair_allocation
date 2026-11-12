include("scenario_equity_metrics.jl")

const EQUITY_REPO_ROOT = normpath(joinpath(@__DIR__, ".."))
const EQUITY_DEFAULT_OUTPUT = abspath(get(ENV,"SCENARIO_EQUITY_DIR",
    joinpath(EQUITY_REPO_ROOT,"results_models","scenario_equity")))

function equity_reference(output=EQUITY_DEFAULT_OUTPUT)
    manifest=equity_read_csv(joinpath(output,"config_manifest.csv"))
    revision=String(first(manifest.ReferenceRevision))
    for name in ["multi.jl","structuresMulti.jl","parametersMS.jl","epp.jl",
        "mmf_pea.jl","mmf_sa.jl","conditional_fairness.jl","static_demand_share.jl"]
        expected=read(Cmd(["git","-C",EQUITY_REPO_ROOT,"show",revision*":codes/"*name]))
        read(joinpath(output,"reference_source",name))==expected || error("Reference source changed: $name")
    end
    reference = Module(:ScenarioEquityReference)
    Core.eval(reference, :(include(path::AbstractString) = Base.include($reference,path)))
    Base.include(reference, joinpath(output,"reference_source","multi.jl"))
    # Explicit seeds recover the pre-DemandProfile generator contract. The random
    # draw sequence and all physical/model code remain those of the pinned source.
    Core.eval(reference,quote
        const SCENARIO_EQUITY_SEED_OVERRIDE=Ref{Union{Nothing,Int}}(nothing)
        function deterministic_seed(S::Int64,C::Int64,P::Int64,J::Int64,file::String,
            theta::Float64,avg::Float64,dev::Float64;demand_profile::String="mixed")
            SCENARIO_EQUITY_SEED_OVERRIDE[]===nothing || return SCENARIO_EQUITY_SEED_OVERRIDE[]
            key=string(basename(file),"|",S,"|",C,"|",P,"|",J,"|",repr(theta),"|",repr(avg),"|",repr(dev),"|",demand_profile)
            acc=UInt(1469598103934665603)
            for b in codeunits(key)
                acc=(acc ⊻ UInt(b))*UInt(1099511628211)
            end
            return Int(mod(acc,UInt(2^31-1)))+1
        end
    end)
    return reference
end

function equity_generator_seed(config;include_profile=nothing)
    profile=include_profile===nothing ? (!hasproperty(config,:SeedConvention) ||
        config.SeedConvention!="without_demand_profile") : include_profile
    tokens=[String(config.InstanceFile),string(config.NBstage),string(config.Childs),string(config.Periods),
        string(config.J),repr(Float64(config.Theta)),repr(Float64(config.Avg_d)),repr(Float64(config.Dev_d))]
    profile && push!(tokens,String(config.DemandProfile))
    acc=UInt(1469598103934665603)
    for b in codeunits(join(tokens,'|'))
        acc=(acc ⊻ UInt(b))*UInt(1099511628211)
    end
    return Int(mod(acc,UInt(2^31-1)))+1
end

function equity_read_csv(path)
    return CSV.read(path, DataFrame; types=(i,name)->String(name) in
        ["ConfigID","RandomInstanceID","DatasetID","FormulationID","InstanceFile","InstFolder",
         "TreeSpec","DemandProfile","ReferenceRevision","Provenance","Fairness","Resource","Metric"] ? String : nothing)
end

function equity_instance(reference, config)
    file=joinpath(EQUITY_REPO_ROOT,String(config.InstFolder),String(config.InstanceFile))
    bytes2hex(open(sha256,file))==config.InstanceSHA256 || error("Input file changed: $file")
    Base.invokelatest(()->reference.SCENARIO_EQUITY_SEED_OVERRIDE[]=Int(config.GeneratorSeed))
    try
    inst=Base.invokelatest(() -> reference.generateInstance(
        Int(config.NBstage),Int(config.Childs),Int(config.Periods),Int(config.J),
        file,
        Float64(config.Theta),Float64(config.Avg_d),Float64(config.Dev_d);
        pv_scale=Float64(config.PVScale),demand_profile=String(config.DemandProfile)))
    Base.invokelatest(()->reference.scaleInstance!(inst;battery_scale=Float64(config.BatteryScale)))
    return inst
    finally
        Base.invokelatest(()->reference.SCENARIO_EQUITY_SEED_OVERRIDE[]=nothing)
    end
end

function equity_validation_config(output=EQUITY_DEFAULT_OUTPUT)
    firstrow=NamedTuple(first(eachrow(equity_read_csv(joinpath(output,"config_manifest.csv")))))
    seed_reference=equity_reference(output)
    seed=Base.invokelatest(() -> seed_reference.deterministic_seed(3,2,8,5,"Drahi_1.csv",.2,100.,10.))
    return merge(firstrow,(ConfigID="V001",RandomInstanceID="Drahi_1",NBstage=3,Childs=2,Periods=8,
        Scenarios=4,J=5,Theta=.2,Sigma=.2,Dev_d=10.,TreeSpec="3:2:8",GeneratorSeed=seed,SeedConvention="with_demand_profile",
        SAFairnessAbsTol=1.0, DatasetID="recovered_validation_snapshot",
        Provenance="saved_decisions_recovered_without_optimization"))
end

function equity_portable(object)
    pairs = [field => (field==:tree ? equity_portable(getproperty(object,field)) :
        deepcopy(getproperty(object,field))) for field in fieldnames(typeof(object))]
    return (;pairs...)
end

function equity_save_object(path,object)
    mkpath(dirname(path))
    temp=path*".tmp.$(getpid())"
    open(io->serialize(io,object),temp,"w")
    mv(temp,path;force=true)
end

function equity_write_extraction(directory,result)
    mkpath(directory)
    for (name,frame) in (("scenario_household_results",result.households),("scenario_equity_metrics",result.metrics),
        ("expected_household_results",result.expected),("instance_equity_summary",result.instances))
        equity_atomic_csv(joinpath(directory,name*".csv"),frame)
    end
    equity_atomic_csv(joinpath(directory,"validation.csv"),DataFrame([result.validation]))
end
