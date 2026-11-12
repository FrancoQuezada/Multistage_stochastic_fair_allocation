# Diagnostic generator probe only: never calls an optimization routine or writes source files.
include("scenario_equity_runtime.jl")

function probe_without_profile(reference,output)
    # Historical CSVs predate the DemandProfile column. Test the corresponding
    # earlier hash-key convention in an isolated module; do not change active code.
    manifest=equity_read_csv(joinpath(output,"config_manifest.csv"))
    historical=equity_read_csv(joinpath(output,"historical_expected_household_results.csv"))
    rows=NamedTuple[]
    for config in eachrow(manifest)
        seed=equity_generator_seed(config;include_profile=false)
        corrected=merge(NamedTuple(config),(GeneratorSeed=seed,SeedConvention="without_demand_profile"))
        inst=equity_instance(reference,corrected)
        tree=equity_tree_data(inst)
        old=historical[(historical.ConfigID.==config.ConfigID).&(historical.Fairness.=="NONE"),:]
        sort!(old,:House)
        benchmark=inst.delta.*[sum(inst.tree.rho[n]*inst.nu[j,tree.times[n]]*inst.d[j,n]
            for n in 1:inst.tree.V) for j in 1:inst.J]
        pv=inst.delta*sum(inst.tree.rho.*inst.c_pv)
        residual=maximum(abs,benchmark-old.ExpectedBenchmark)
        pv_residual=abs(pv-sum(old.ExpectedPV))
        push!(rows,(ConfigID=String(config.ConfigID),JuliaVersion=string(VERSION),
            SeedConvention="fnv_key_without_demand_profile",GeneratorSeed=seed,
            InputBenchmarkResidual=residual,InputPVResidual=pv_residual,
            Passed=all(isapprox.(benchmark,old.ExpectedBenchmark;atol=1e-6,rtol=1e-9)) &&
                isapprox(pv,sum(old.ExpectedPV);atol=1e-6,rtol=1e-9)))
    end
    frame=DataFrame(rows)
    equity_atomic_csv(joinpath(output,"seed_probe_without_profile_julia_"*replace(string(VERSION),'.'=>'_')*".csv"),frame)
    println("Seed convention without DemandProfile: ",count(frame.Passed),"/",nrow(frame)," pass")
end

reference=equity_reference()
Base.invokelatest(probe_without_profile,reference,EQUITY_DEFAULT_OUTPUT)
