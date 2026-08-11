# =====================================================================================
# Extended abstract-period support and deterministic-base isolation (redesign stage 3).
#
# Included from `tests/oos/runtests.jl` after `structural_catalog_tests.jl`, so this file reuses
# `test_config`, `structural_base_config`, `structural_test_design`, `STRUCTURAL_FIXTURE`,
# `corrupt_manifest`, `TEST_INSTANCE` and `REPO_ROOT`. Numeric factor values remain bounded test
# fixtures only; Stage 12 still owns calibration.
# =====================================================================================

"""A support fixture whose required endpoint is strictly beyond two repository horizons."""
const PERIOD_SUPPORT_FIXTURE = let
    config = structural_base_config(
        evaluation_horizon=50,
        lookahead_horizon=24,
        implementation_step=7,
    )
    profiles = ["morning", "midday", "night"]
    bundle = build_instance_template(config; household_profiles=profiles)
    endpoint = required_period_support_end(config)
    support = build_period_data_support(bundle.template, endpoint)
    provider = RepositoryUncertaintyProvider(bundle.template, support)
    (
        config=config,
        bundle=bundle,
        template=bundle.template,
        endpoint=endpoint,
        support=support,
        provider=provider,
    )
end

"""Resolved activity table of a base template, in household-by-period form."""
function _stage3_template_activity(template::OOSInstanceTemplate)
    activity = falses(template.J, template.T)
    for model in template.demand_models, period in model.active_periods
        activity[model.household, period] = true
    end
    return activity
end

"""All repository-instance fields that an explicit seed override must preserve exactly."""
function _stage3_instance_snapshot(instance)
    tree_fields = Dict(
        String(field) => deepcopy(getfield(instance.tree, field))
        for field in fieldnames(typeof(instance.tree))
    )
    return (
        id=instance.id,
        J=instance.J,
        T=instance.T,
        delta=instance.delta,
        e_c=instance.e_c,
        e_d=instance.e_d,
        s_I=instance.s_I,
        s_min=instance.s_min,
        s_max=instance.s_max,
        f_under=instance.f_under,
        f_bar=instance.f_bar,
        mu=instance.mu,
        beta=instance.beta,
        nu=copy(instance.nu),
        pv_det=copy(instance.pv_det),
        c_pv=copy(instance.c_pv),
        d=copy(instance.d),
        d_det=copy(instance.d_det),
        tree_fields=tree_fields,
    )
end

"""Observed history cut from one already-sampled path."""
_stage3_history(path::OOSPath, period::Int) = ObservedHistory(
    period,
    collect(path.pv[1:period]),
    Matrix(path.demand[:, 1:period]),
)

_stage3_path_signature(path::OOSPath) = (
    path.replication_id,
    path.horizon,
    path.pv,
    path.demand,
)

_stage3_scenario_signature(path::ScenarioPath) = (
    path.first_period,
    path.last_period,
    path.probability,
    path.pv,
    path.demand,
)

_stage3_demand_model_signature(model::OOSHouseholdDemandModel) = (
    model.household,
    model.profile,
    model.active_periods,
    model.avg,
    model.dev,
)

_stage3_demand_model_signatures(models) = [
    _stage3_demand_model_signature(model) for model in models
]

"""Return true when `operation` consumes no values from the current task's default RNG."""
function _stage3_default_rng_untouched(operation::Function)
    Random.seed!(872341)
    expected = rand(UInt64)
    Random.seed!(872341)
    operation()
    observed = rand(UInt64)
    return observed == expected
end

# =====================================================================================
# P0 Centralized period mapping
# =====================================================================================

@testset "P0 centralized abstract-period mapping" begin
    T0 = PERIOD_SUPPORT_FIXTURE.template.T
    endpoint = PERIOD_SUPPORT_FIXTURE.endpoint
    @test endpoint > 2 * T0

    expected = Dict(
        1 => 1,
        T0 => T0,
        T0 + 1 => 1,
        2 * T0 => T0,
        2 * T0 + 1 => 1,
        endpoint => 1 + ((endpoint - 1) % T0),
    )
    for (period, index) in expected
        @test base_period_index(period, T0) == index
    end
    for period in (0, -1, typemin(Int))
        @test_throws ErrorException base_period_index(period, T0)
    end
    for base_horizon in (0, -1, typemin(Int))
        @test_throws ErrorException base_period_index(1, base_horizon)
    end

    @test OOS_PERIOD_MAPPING_NAME == "repository_base_period_repeat"
    @test OOS_PERIOD_MAPPING_VERSION == "base_period_index_v1"
    @test occursin("period", OOS_PERIOD_MAPPING_FORMULA)
    @test occursin("repository_instance_horizon", OOS_PERIOD_MAPPING_FORMULA)
end

# =====================================================================================
# P1 Exact base preservation and multi-cycle extension
# =====================================================================================

@testset "P1 exact base preservation and multi-cycle extension" begin
    fixture = PERIOD_SUPPORT_FIXTURE
    template = fixture.template
    support = fixture.support
    T0 = template.T
    endpoint = fixture.endpoint
    activity = period_demand_activity(support)
    base_activity = _stage3_template_activity(template)

    @test support.repository_instance_horizon == T0
    @test support.required_period_support_end == endpoint
    @test support.materialized_data_end == max(T0, endpoint) == endpoint
    @test support.households == template.J
    @test size(support.nu) == (template.J, endpoint)
    @test length(support.pv_det) == endpoint
    @test size(activity) == (template.J, endpoint)

    # Exact means bit-for-bit equality: extension is copying, not a floating-point transform.
    @test support.nu[:, 1:T0] == template.nu
    @test support.pv_det[1:T0] == template.pv_det
    @test activity[:, 1:T0] == base_activity
    @test [model.profile for model in support.demand_models] ==
          [model.profile for model in template.demand_models]
    @test [model.avg for model in support.demand_models] ==
          [model.avg for model in template.demand_models]
    @test [model.dev for model in support.demand_models] ==
          [model.dev for model in template.demand_models]
    @test fixture.bundle.template.delta == template.delta

    # Exercise every entry across more than two complete cycles, not only boundary examples.
    for period in 1:endpoint
        base = base_period_index(period, T0)
        @test support.nu[:, period] == template.nu[:, base]
        @test support.pv_det[period] == template.pv_det[base]
        @test activity[:, period] == base_activity[:, base]
    end

    # A support request shorter than T0 keeps the complete repository profile and records the
    # requested endpoint separately.
    short = build_period_data_support(template, T0 - 1)
    @test short.required_period_support_end == T0 - 1
    @test short.materialized_data_end == T0
    @test short.nu == template.nu
    @test short.pv_det == template.pv_det
    @test period_demand_activity(short) == base_activity

    summary = period_data_support_summary(support)
    @test summary["repository_instance_horizon"] == T0
    @test summary["required_period_support_end"] == endpoint
    @test summary["materialized_data_end"] == endpoint
    @test summary["period_mapping_name"] == OOS_PERIOD_MAPPING_NAME
    @test summary["period_mapping_version"] == OOS_PERIOD_MAPPING_VERSION
    @test summary["digests"] == period_data_support_digests(support)
    @test all(length(String(value)) == 16 for value in values(summary["digests"]))

    @test_throws ErrorException build_period_data_support(template, 0)
    @test_throws ErrorException build_period_data_support(template, -1)
end

@testset "P2 period-support builders are pure and defensive" begin
    template = PERIOD_SUPPORT_FIXTURE.template
    endpoint = PERIOD_SUPPORT_FIXTURE.endpoint
    template_nu = copy(template.nu)
    template_pv = copy(template.pv_det)
    template_models = deepcopy(template.demand_models)

    @test _stage3_default_rng_untouched() do
        build_period_data_support(template, endpoint)
    end
    @test template.nu == template_nu
    @test template.pv_det == template_pv
    @test _stage3_demand_model_signatures(template.demand_models) ==
          _stage3_demand_model_signatures(template_models)

    left = build_period_data_support(template, endpoint)
    right = build_period_data_support(template, endpoint)
    @test left !== right
    @test left.nu !== right.nu
    @test left.pv_det !== right.pv_det
    @test left.demand_models !== right.demand_models
    @test left.nu == right.nu
    @test left.pv_det == right.pv_det
    @test period_demand_activity(left) == period_demand_activity(right)
    @test period_data_support_digests(left) == period_data_support_digests(right)

    # Returned activity matrices and constructor inputs are not aliases of stored provider data.
    detached_activity = period_demand_activity(left)
    detached_activity[1, 1] = !detached_activity[1, 1]
    @test detached_activity != period_demand_activity(left)
    provider = RepositoryUncertaintyProvider(template, left)
    old_provider_pv = provider.pv_det[1]
    old_provider_profile = provider.demand_models[1].profile
    old_provider_activity = copy(provider.demand_models[1].active_periods)
    left.pv_det[1] += 123.0
    empty!(left.demand_models[1].active_periods)
    @test provider.pv_det[1] == old_provider_pv
    @test provider.demand_models[1].profile == old_provider_profile
    @test provider.demand_models[1].active_periods == old_provider_activity

    # The public constructor and provider boundary independently reject a forged extended cycle.
    invalid_nu = copy(right.nu)
    invalid_nu[1, template.T + 1] += 1.0
    @test_throws ErrorException OOSPeriodDataSupport(
        right.repository_instance_horizon,
        right.required_period_support_end,
        right.materialized_data_end,
        right.households,
        invalid_nu,
        right.pv_det,
        right.demand_models,
    )
    mutated_price = build_period_data_support(template, endpoint)
    mutated_price.nu[1, template.T + 1] += 1.0
    @test_throws ErrorException RepositoryUncertaintyProvider(template, mutated_price)
    mutated_pv = build_period_data_support(template, endpoint)
    mutated_pv.pv_det[template.T + 1] += 1.0
    @test_throws ErrorException RepositoryUncertaintyProvider(mutated_pv, template.theta)
    mutated_activity = build_period_data_support(template, endpoint)
    first_model = mutated_activity.demand_models[1]
    repeated_period = template.T + 1
    if repeated_period in first_model.active_periods
        deleteat!(first_model.active_periods, findfirst(==(repeated_period), first_model.active_periods))
    else
        push!(first_model.active_periods, repeated_period)
        sort!(first_model.active_periods)
    end
    @test_throws ErrorException RepositoryUncertaintyProvider(template, mutated_activity)

    # Construction order and simulated worker identity are scientific no-ops.
    first_order = withenv("OOS_WORKER_ID" => "1", "OOS_TASK_ORDER" => "forward") do
        a = build_period_data_support(template, endpoint)
        b = build_period_data_support(template, template.T + 1)
        (period_data_support_digests(a), period_data_support_digests(b))
    end
    reverse_order = withenv("OOS_WORKER_ID" => "99", "OOS_TASK_ORDER" => "reverse") do
        b = build_period_data_support(template, template.T + 1)
        a = build_period_data_support(template, endpoint)
        (period_data_support_digests(a), period_data_support_digests(b))
    end
    @test first_order == reverse_order
end

# =====================================================================================
# P3 Provider support through the required endpoint
# =====================================================================================

@testset "P3 direct provider interfaces reach every support boundary" begin
    fixture = PERIOD_SUPPORT_FIXTURE
    provider = fixture.provider
    T0 = fixture.template.T
    endpoint = fixture.endpoint
    boundaries = (T0, T0 + 1, endpoint)

    @test provider.repository_instance_horizon == T0
    @test provider.required_period_support_end == endpoint
    @test provider.materialized_data_end == endpoint
    @test provider.period_mapping_version == OOS_PERIOD_MAPPING_VERSION
    @test length(provider.pv_det) == endpoint

    legacy_positional = RepositoryUncertaintyProvider(
        fixture.template.J,
        fixture.template.T,
        fixture.template.pv_det,
        fixture.template.theta,
        fixture.template.demand_models,
        OOS_PV_AR_COEFFICIENT,
        OOS_PV_MA_COEFFICIENT,
        true,
    )
    @test legacy_positional.T == fixture.template.T
    @test legacy_positional.required_period_support_end == fixture.template.T
    @test legacy_positional.pv_det == fixture.template.pv_det

    path = sample_oos_path(provider, endpoint, MersenneTwister(3101); replication_id=7)
    @test path.replication_id == 7
    @test path.horizon == endpoint
    @test length(path.pv) == endpoint
    @test size(path.demand) == (provider.J, endpoint)
    @test _stage3_path_signature(path) == _stage3_path_signature(sample_oos_path(
        provider, endpoint, MersenneTwister(3101); replication_id=7,
    ))

    for period in boundaries
        state = filter_pv_state(provider, path.pv[1:period])
        @test state.periods == period
        @test isfinite(pv_from_state(provider, state, period))

        sampled = sample_demand_column(provider, period, MersenneTwister(4100 + period))
        sampled_again = sample_demand_column(provider, period, MersenneTwister(4100 + period))
        @test sampled == sampled_again
        @test length(sampled) == provider.J
        @test length(mean_demand_column(provider, period)) == provider.J

        history = _stage3_history(path, period)
        mean_path = conditional_mean_path(provider, history, period, endpoint)
        @test mean_path.first_period == period
        @test mean_path.last_period == endpoint
        @test length(mean_path.pv) == endpoint - period + 1
        @test size(mean_path.demand) == (provider.J, endpoint - period + 1)

        scenarios = conditional_scenario_paths(
            provider, history, period, endpoint, 2, MersenneTwister(5100 + period),
        )
        repeated = conditional_scenario_paths(
            provider, history, period, endpoint, 2, MersenneTwister(5100 + period),
        )
        @test _stage3_scenario_signature.(scenarios) ==
              _stage3_scenario_signature.(repeated)
        @test length(scenarios) == 2
        @test all(scenario -> scenario.first_period == period, scenarios)
        @test all(scenario -> scenario.last_period == endpoint, scenarios)

        tree = conditional_scenario_tree(
            provider, history, period, endpoint, BranchingSpec([1]),
            MersenneTwister(6100 + period),
        )
        @test tree.first_period == period
        @test tree.last_period == endpoint
        @test minimum(tree.calendar_period) == period
        @test maximum(tree.calendar_period) == endpoint
    end

    @test_throws ErrorException sample_oos_path(
        provider, endpoint + 1, MersenneTwister(1),
    )
    history = _stage3_history(path, T0)
    @test_throws ErrorException conditional_mean_path(provider, history, T0, endpoint + 1)
    @test_throws ErrorException conditional_scenario_paths(
        provider, history, T0, endpoint + 1, 1, MersenneTwister(1),
    )
    @test_throws ErrorException conditional_scenario_tree(
        provider, history, T0, endpoint + 1, BranchingSpec([1]), MersenneTwister(1),
    )
    @test_throws ErrorException pv_from_state(
        provider, PVFilterState(0.0, 0.0, endpoint), endpoint + 1,
    )
    @test_throws ErrorException sample_demand_column(provider, endpoint + 1, MersenneTwister(1))
    @test_throws ErrorException mean_demand_column(provider, endpoint + 1)
end

@testset "P4 provider RNGs are explicit, reproducible and order-independent" begin
    fixture = PERIOD_SUPPORT_FIXTURE
    provider = fixture.provider
    endpoint = fixture.endpoint
    path = sample_oos_path(provider, endpoint, MersenneTwister(7201))
    history = _stage3_history(path, fixture.template.T + 1)

    @test _stage3_default_rng_untouched() do
        sample_oos_path(provider, endpoint, MersenneTwister(7202))
    end
    @test _stage3_default_rng_untouched() do
        conditional_scenario_paths(
            provider, history, history.periods, endpoint, 2, MersenneTwister(7203),
        )
    end
    @test _stage3_default_rng_untouched() do
        conditional_scenario_tree(
            provider, history, history.periods, endpoint, BranchingSpec([1]),
            MersenneTwister(7204),
        )
    end
    @test _stage3_default_rng_untouched() do
        sample_demand_column(provider, endpoint, MersenneTwister(7205))
    end
    @test _stage3_default_rng_untouched() do
        conditional_mean_path(provider, history, history.periods, endpoint)
    end

    forward = let
        realized = sample_oos_path(provider, endpoint, MersenneTwister(7301))
        scenarios = conditional_scenario_paths(
            provider, history, history.periods, endpoint, 2, MersenneTwister(7302),
        )
        demand = sample_demand_column(provider, endpoint, MersenneTwister(7303))
        (realized, scenarios, demand)
    end
    reverse = let
        demand = sample_demand_column(provider, endpoint, MersenneTwister(7303))
        scenarios = conditional_scenario_paths(
            provider, history, history.periods, endpoint, 2, MersenneTwister(7302),
        )
        realized = sample_oos_path(provider, endpoint, MersenneTwister(7301))
        (realized, scenarios, demand)
    end
    @test _stage3_path_signature(forward[1]) == _stage3_path_signature(reverse[1])
    @test _stage3_scenario_signature.(forward[2]) ==
          _stage3_scenario_signature.(reverse[2])
    @test forward[3] == reverse[3]
end

# =====================================================================================
# P5 Legacy generator regression and explicit deterministic-base override
# =====================================================================================

@testset "P5 legacy generateInstance default and explicit-nothing regression" begin
    stages, children, periods = 3, 2, 8
    households = 3
    theta, avg, dev = 0.2, 1.5, 0.1
    profile = "mixed"
    legacy_seed = deterministic_seed(
        stages, children, periods, households, TEST_INSTANCE, theta, avg, dev;
        demand_profile=profile,
    )

    legacy = generateInstance(
        stages, children, periods, households, TEST_INSTANCE, theta, avg, dev;
        demand_profile=profile,
    )
    explicit_nothing = generateInstance(
        stages, children, periods, households, TEST_INSTANCE, theta, avg, dev;
        demand_profile=profile, repository_seed_override=nothing,
    )
    explicit_legacy_seed = generateInstance(
        stages, children, periods, households, TEST_INSTANCE, theta, avg, dev;
        demand_profile=profile, repository_seed_override=legacy_seed,
    )
    legacy_snapshot = _stage3_instance_snapshot(legacy)
    @test _stage3_instance_snapshot(explicit_nothing) == legacy_snapshot
    @test _stage3_instance_snapshot(explicit_legacy_seed) == legacy_snapshot

    config = structural_base_config(theta=theta, avg_demand=avg, dev_demand=dev)
    default_bundle = build_instance_template(config)
    nothing_bundle = build_instance_template(config; repository_seed_override=nothing)
    override_bundle = build_instance_template(config; repository_seed_override=legacy_seed)
    @test propertynames(default_bundle) == (:template, :in_sample_tree, :instance)
    @test propertynames(nothing_bundle) == (:template, :in_sample_tree, :instance)
    @test override_bundle.actual_repository_generator_seed == legacy_seed
    @test default_bundle.template.nu == nothing_bundle.template.nu == override_bundle.template.nu
    @test default_bundle.template.pv_det ==
          nothing_bundle.template.pv_det == override_bundle.template.pv_det
    @test default_bundle.template.id == nothing_bundle.template.id == override_bundle.template.id

    @test_throws ErrorException generateInstance(
        stages, children, periods, households, TEST_INSTANCE, theta, avg, dev;
        demand_profile=profile, repository_seed_override=0,
    )
    @test_throws ErrorException generateInstance(
        stages, children, periods, households, TEST_INSTANCE, theta, avg, dev;
        demand_profile=profile, repository_seed_override=-1,
    )

    # The verified legacy side effect remains exact: the call resets and consumes the current
    # task's default RNG, independent of its incoming state, and leaves that stream advanced.
    Random.seed!(101)
    generateInstance(
        stages, children, periods, households, TEST_INSTANCE, theta, avg, dev;
        demand_profile=profile,
    )
    post_legacy = rand(UInt64)
    Random.seed!(202)
    generateInstance(
        stages, children, periods, households, TEST_INSTANCE, theta, avg, dev;
        demand_profile=profile, repository_seed_override=nothing,
    )
    post_nothing = rand(UInt64)
    @test post_legacy == post_nothing

    Random.seed!(303)
    untouched_next = rand(UInt64)
    Random.seed!(303)
    generateInstance(
        stages, children, periods, households, TEST_INSTANCE, theta, avg, dev;
        demand_profile=profile,
    )
    @test rand(UInt64) != untouched_next

    # An unrelated explicit RNG object is not consulted or mutated by the legacy generator.
    explicit_rng = MersenneTwister(404)
    explicit_reference = MersenneTwister(404)
    generateInstance(
        stages, children, periods, households, TEST_INSTANCE, theta, avg, dev;
        demand_profile=profile,
    )
    @test rand(explicit_rng, UInt64, 8) == rand(explicit_reference, UInt64, 8)

    # With one explicit repository seed, theta changes the stochastic PV law but no deterministic
    # price/reference/physical field. This is the narrow Stage-3 isolation mechanism.
    shared_seed = oos_stream_seed(4242, "stage3_test_repository_base", "Drahi_1", 1)
    low = generateInstance(
        stages, children, periods, households, TEST_INSTANCE, 0.1, avg, dev;
        demand_profile=profile, repository_seed_override=shared_seed,
    )
    high = generateInstance(
        stages, children, periods, households, TEST_INSTANCE, 0.4, avg, dev;
        demand_profile=profile, repository_seed_override=shared_seed,
    )
    @test low.nu == high.nu
    @test low.pv_det == high.pv_det
    @test low.J == high.J
    @test low.T == high.T
    @test low.delta == high.delta
    @test low.e_c == high.e_c
    @test low.e_d == high.e_d
    @test low.s_I == high.s_I
    @test low.s_min == high.s_min
    @test low.s_max == high.s_max
    @test low.f_under == high.f_under
    @test low.f_bar == high.f_bar
    @test low.mu == high.mu
    @test low.beta == high.beta
    @test low.c_pv != high.c_pv
end

# =====================================================================================
# P6 Deterministic-base and experimental-factor isolation
# =====================================================================================

_stage3_base_data_signature(materialized) = (
    materialized.template.nu,
    materialized.template.pv_det,
    materialized.period_data_support.repository_instance_horizon,
    materialized.period_data_support.required_period_support_end,
    materialized.period_data_support.materialized_data_end,
    materialized.period_data_support.period_mapping_name,
    materialized.period_data_support.period_mapping_version,
    materialized.period_data_support.period_mapping_formula,
    materialized.period_data_support.nu,
    materialized.period_data_support.pv_det,
)

_stage3_full_physical_signature(template::OOSInstanceTemplate) = (
    template.J,
    template.T,
    template.delta,
    template.e_c,
    template.e_d,
    template.s_I,
    template.s_min,
    template.s_max,
    template.f_under,
    template.f_bar,
    template.mu,
    template.beta,
)

_stage3_nonbattery_physical_signature(template::OOSInstanceTemplate) = (
    template.J,
    template.T,
    template.delta,
    template.e_c,
    template.e_d,
    template.s_I,
    template.s_min,
    template.mu,
    template.beta,
)

_stage3_battery_signature(template::OOSInstanceTemplate) = (
    template.s_min,
    template.s_max,
    template.s_I,
    template.f_under,
    template.f_bar,
)

function _stage3_materialized_by_id(base, design, records)
    endpoint = required_period_support_end(design)
    return Dict(
        record.spec.structural_instance_id => materialize_structural_instance(
            base, record.spec; required_period_support_end=endpoint,
        )
        for record in records
    )
end

@testset "P6 uncertainty and factor isolation over the bounded catalog" begin
    design = STRUCTURAL_FIXTURE.design
    base = STRUCTURAL_FIXTURE.base
    records = STRUCTURAL_FIXTURE.records
    @test length(records) == 16
    @test expected_deterministic_data_count(design) == 2
    @test length(unique(record.spec.deterministic_data_id for record in records)) == 2
    @test all(
        count(other -> other.spec.deterministic_data_id == record.spec.deterministic_data_id,
              records) == 8
        for record in records
    )

    materialized = _stage3_materialized_by_id(base, design, records)

    # Every low/high uncertainty pair keeps every non-uncertainty input exactly fixed.
    uncertainty_groups = Dict{Tuple{Int,DemandRegime,BatteryLevel},Vector{Any}}()
    for record in records
        key = (record.spec.structural_draw, record.spec.demand_regime,
               record.spec.battery_level)
        push!(get!(uncertainty_groups, key, Any[]), record)
    end
    @test length(uncertainty_groups) == 8
    for members in values(uncertainty_groups)
        @test length(members) == 2
        low_record = only(filter(
            record -> record.spec.uncertainty_level === LOW_UNCERTAINTY, members,
        ))
        high_record = only(filter(
            record -> record.spec.uncertainty_level === HIGH_UNCERTAINTY, members,
        ))
        low_spec, high_spec = low_record.spec, high_record.spec
        low = materialized[low_spec.structural_instance_id]
        high = materialized[high_spec.structural_instance_id]

        @test low_spec.uncertainty_level !== high_spec.uncertainty_level
        @test low_spec.theta < high_spec.theta
        @test low_spec.deterministic_data_id == high_spec.deterministic_data_id
        @test low_spec.actual_repository_generator_seed ==
              high_spec.actual_repository_generator_seed
        @test low_spec.repository_instance_seed != high_spec.repository_instance_seed
        @test low_spec.demand_assignment_id == high_spec.demand_assignment_id
        @test low_spec.household_profiles == high_spec.household_profiles
        @test low_spec.households == high_spec.households
        @test low_spec.avg_demand == high_spec.avg_demand
        @test low_spec.dev_demand == high_spec.dev_demand
        @test low_spec.pv_scale == high_spec.pv_scale
        @test low.actual_repository_generator_seed == high.actual_repository_generator_seed
        @test _stage3_base_data_signature(low) == _stage3_base_data_signature(high)
        @test _stage3_full_physical_signature(low.template) ==
              _stage3_full_physical_signature(high.template)
        @test _stage3_demand_model_signatures(low.period_data_support.demand_models) ==
              _stage3_demand_model_signatures(high.period_data_support.demand_models)
        @test period_demand_activity(low.period_data_support) ==
              period_demand_activity(high.period_data_support)
        @test period_data_support_digests(low.period_data_support) ==
              period_data_support_digests(high.period_data_support)

        low_key = oos_path_seed_key(design, low_spec)
        high_key = oos_path_seed_key(design, high_spec)
        @test structural_oos_path_seed(low_key, 1) != structural_oos_path_seed(high_key, 1)
        @test conditional_support_seed(low_key, 1, first(rolling_iteration_starts(design))) !=
              conditional_support_seed(high_key, 1, first(rolling_iteration_starts(design)))

        # A fixed import probe has exactly the same price contribution. Therefore a later cost
        # comparison cannot contain a deterministic price-matrix change between theta levels.
        imports = reshape(
            Float64.(1:(low.template.J * low.template.T)),
            low.template.J,
            low.template.T,
        )
        @test sum(low.template.nu .* imports) == sum(high.template.nu .* imports)
    end

    # Battery changes only the approved resolved battery vector.
    battery_groups = Dict{Tuple{Int,DemandRegime,UncertaintyLevel},Vector{Any}}()
    for record in records
        key = (record.spec.structural_draw, record.spec.demand_regime,
               record.spec.uncertainty_level)
        push!(get!(battery_groups, key, Any[]), record)
    end
    for members in values(battery_groups)
        low_record = only(filter(r -> r.spec.battery_level === LOW_BATTERY, members))
        high_record = only(filter(r -> r.spec.battery_level === HIGH_BATTERY, members))
        low = materialized[low_record.spec.structural_instance_id]
        high = materialized[high_record.spec.structural_instance_id]
        @test low_record.spec.deterministic_data_id == high_record.spec.deterministic_data_id
        @test low_record.spec.actual_repository_generator_seed ==
              high_record.spec.actual_repository_generator_seed
        @test _stage3_base_data_signature(low) == _stage3_base_data_signature(high)
        @test _stage3_nonbattery_physical_signature(low.template) ==
              _stage3_nonbattery_physical_signature(high.template)
        @test _stage3_battery_signature(low.template) != _stage3_battery_signature(high.template)
        @test period_demand_activity(low.period_data_support) ==
              period_demand_activity(high.period_data_support)
    end

    # Demand regime changes only the controlled assignment and the process induced by it.
    regime_groups = Dict{Tuple{Int,BatteryLevel,UncertaintyLevel},Vector{Any}}()
    for record in records
        key = (record.spec.structural_draw, record.spec.battery_level,
               record.spec.uncertainty_level)
        push!(get!(regime_groups, key, Any[]), record)
    end
    for members in values(regime_groups)
        homogeneous_record = only(filter(r -> r.spec.demand_regime === HOMOGENEOUS, members))
        heterogeneous_record = only(filter(r -> r.spec.demand_regime === HETEROGENEOUS, members))
        homogeneous = materialized[homogeneous_record.spec.structural_instance_id]
        heterogeneous = materialized[heterogeneous_record.spec.structural_instance_id]
        @test homogeneous_record.spec.deterministic_data_id ==
              heterogeneous_record.spec.deterministic_data_id
        @test homogeneous_record.spec.actual_repository_generator_seed ==
              heterogeneous_record.spec.actual_repository_generator_seed
        @test homogeneous_record.spec.demand_assignment_id !=
              heterogeneous_record.spec.demand_assignment_id
        @test homogeneous_record.spec.household_profiles !=
              heterogeneous_record.spec.household_profiles
        @test _stage3_base_data_signature(homogeneous) ==
              _stage3_base_data_signature(heterogeneous)
        @test _stage3_full_physical_signature(homogeneous.template) ==
              _stage3_full_physical_signature(heterogeneous.template)
        @test period_demand_activity(homogeneous.period_data_support) !=
              period_demand_activity(heterogeneous.period_data_support)
    end

    # Structural draw is the only experimental-design axis admitted into this key.
    data_ids_by_draw = Dict(
        draw => unique(record.spec.deterministic_data_id for record in records
                       if record.spec.structural_draw == draw)
        for draw in 1:design.structural_draws_per_cell
    )
    seeds_by_draw = Dict(
        draw => unique(record.spec.actual_repository_generator_seed for record in records
                       if record.spec.structural_draw == draw)
        for draw in 1:design.structural_draws_per_cell
    )
    @test all(length(ids) == 1 for ids in values(data_ids_by_draw))
    @test all(length(seeds) == 1 for seeds in values(seeds_by_draw))
    @test only(data_ids_by_draw[1]) != only(data_ids_by_draw[2])
    @test only(seeds_by_draw[1]) != only(seeds_by_draw[2])

    for forbidden in (
        :battery_level, :battery_scale, :demand_regime, :demand_assignment_id,
        :uncertainty_level, :theta, :oos_replication, :rolling_start, :controller,
        :fairness_policy, :solver_phase, :worker, :retry, :execution_order,
    )
        @test !(forbidden in fieldnames(OOSDeterministicBaseKey))
        @test String(forbidden) in OOS_DETERMINISTIC_BASE_EXCLUDED_KEYS
    end
end

@testset "P7 deterministic data ignore controller, fairness, threads, worker and order" begin
    design = STRUCTURAL_FIXTURE.design
    records = STRUCTURAL_FIXTURE.records[1:4]
    forward_base = test_config(
        controller_set=[DETERMINISTIC_RH, TWO_STAGE_RH, MULTISTAGE_RH],
        fairness_set=[NONE, PEA, SA],
        solver_threads=1,
        export_representative_models=false,
        require_shared_battery_validation=false,
    )
    reverse_base = test_config(
        controller_set=[MULTISTAGE_RH, TWO_STAGE_RH, DETERMINISTIC_RH],
        fairness_set=[SA, PEA, NONE],
        solver_threads=4,
        export_representative_models=false,
        require_shared_battery_validation=false,
    )

    function materialize_signatures(base, ordered_records, worker, order_label)
        return withenv("OOS_WORKER_ID" => worker, "OOS_TASK_ORDER" => order_label) do
            Dict(
                record.spec.structural_instance_id => begin
                    item = materialize_structural_instance(
                        base,
                        record.spec;
                        required_period_support_end=required_period_support_end(design),
                    )
                    (
                        item.actual_repository_generator_seed,
                        record.spec.deterministic_data_id,
                        _stage3_base_data_signature(item),
                        period_data_support_digests(item.period_data_support),
                    )
                end
                for record in ordered_records
            )
        end
    end

    forward = materialize_signatures(forward_base, records, "1", "forward")
    reversed_result = materialize_signatures(
        reverse_base, Base.reverse(records), "77", "reverse",
    )
    @test forward == reversed_result

    file = first(design.base_instance_files)
    reference_id = deterministic_data_id(design, file, 1)
    reference_seed = actual_repository_generator_seed(design, file, 1)
    @test deterministic_data_id(
        structural_test_design(battery_scales=battery_scale_map(0.7, 3.0)), file, 1,
    ) == reference_id
    @test deterministic_data_id(
        structural_test_design(uncertainty_thetas=uncertainty_theta_map(0.05, 0.8)), file, 1,
    ) == reference_id
    @test actual_repository_generator_seed(
        structural_test_design(battery_scales=battery_scale_map(0.7, 3.0)), file, 1,
    ) == reference_seed
    @test actual_repository_generator_seed(
        structural_test_design(uncertainty_thetas=uncertainty_theta_map(0.05, 0.8)), file, 1,
    ) == reference_seed
end

# =====================================================================================
# P8 Reentrancy, input nonmutation and production-source guards
# =====================================================================================

@testset "P8 period support and providers have no hidden mutable scientific state" begin
    fixture = PERIOD_SUPPORT_FIXTURE
    support = fixture.support
    provider = fixture.provider
    endpoint = fixture.endpoint
    provider_pv = copy(provider.pv_det)
    provider_models = deepcopy(provider.demand_models)
    support_nu = copy(support.nu)
    support_pv = copy(support.pv_det)
    support_models = deepcopy(support.demand_models)

    path = sample_oos_path(provider, endpoint, MersenneTwister(8101))
    history = _stage3_history(path, fixture.template.T + 1)
    history_pv = copy(history.pv)
    history_demand = copy(history.demand)
    conditional_mean_path(provider, history, history.periods, endpoint)
    conditional_scenario_paths(
        provider, history, history.periods, endpoint, 2, MersenneTwister(8102),
    )
    conditional_scenario_tree(
        provider, history, history.periods, endpoint, BranchingSpec([1]),
        MersenneTwister(8103),
    )
    sample_demand_column(provider, endpoint, MersenneTwister(8104))
    mean_demand_column(provider, endpoint)
    filter_pv_state(provider, history.pv)

    @test provider.pv_det == provider_pv
    @test _stage3_demand_model_signatures(provider.demand_models) ==
          _stage3_demand_model_signatures(provider_models)
    @test support.nu == support_nu
    @test support.pv_det == support_pv
    @test _stage3_demand_model_signatures(support.demand_models) ==
          _stage3_demand_model_signatures(support_models)
    @test history.pv == history_pv
    @test history.demand == history_demand

    support_source = read(
        joinpath(REPO_ROOT, "codes", "oos_experiment", "period_support.jl"), String,
    )
    provider_source = read(
        joinpath(REPO_ROOT, "codes", "oos_experiment", "uncertainty_provider.jl"), String,
    )
    catalog_source = read(
        joinpath(REPO_ROOT, "codes", "oos_experiment", "structural_catalog.jl"), String,
    )
    for source in (support_source, provider_source)
        @test !occursin("Random.seed!", source)
        @test !occursin(r"(?m)^\s*global\s+", source)
        @test !occursin(r"(?mi)^\s*const\s+\w*(cache|rng)\w*\s*=", source)
        @test !occursin(r"\b(myid|workers|nworkers|addprocs|Threads\.@spawn)\s*\(", source)
    end

    # Every production random draw in the pure/provider/catalog layers names an explicit RNG.
    for (path_name, source) in (
        ("period_support.jl", support_source),
        ("uncertainty_provider.jl", provider_source),
        ("structural_catalog.jl", catalog_source),
    )
        random_lines = [line for line in split(source, '\n') if occursin(r"\brand\s*\(", line)]
        for line in random_lines
            @test occursin(r"\brand\s*\(\s*rng\b", line)
        end
        path_name == "period_support.jl" && @test isempty(random_lines)
    end

    # The only legacy activity helper delegates to the centralized mapping; it does not retain
    # its former local `mod1(period, 24)` implementation.
    start = first(findfirst("function demand_active_periods", provider_source))
    stop = first(findnext("function assign_demand_models", provider_source, start))
    demand_helper = provider_source[start:prevind(provider_source, stop)]
    @test occursin("base_period_index", demand_helper)
    @test !occursin("mod1", demand_helper)
    @test !occursin(r"%\s*24", demand_helper)

    # The canonical mapping owns the one repetition operation in the Stage-3 data layer.
    @test count(occursin("mod1", line) for line in split(support_source, '\n')) == 1
    @test occursin("return mod1(period, base_horizon)", support_source)
end

# =====================================================================================
# P9 Manifest-v2 validation and adversarial corruption
# =====================================================================================

@testset "P9 manifest v2 records and enforces the Stage-3 data contract" begin
    document = STRUCTURAL_FIXTURE.document
    base = STRUCTURAL_FIXTURE.base
    design = document["design"]

    @test design["structural_manifest_schema_version"] ==
          OOS_STRUCTURAL_MANIFEST_SCHEMA_VERSION == 2
    @test design["stage3_ready"] === true
    @test design["deterministic_base_isolation_status"] == "passed"
    @test design["repository_instance_horizon"] == first(
        record.resolved.repository_instance_horizon for record in STRUCTURAL_FIXTURE.records
    )
    @test design["required_period_support_end"] ==
          required_period_support_end(STRUCTURAL_FIXTURE.design)
    @test design["materialized_data_end"] == max(
        design["repository_instance_horizon"], design["required_period_support_end"],
    )
    @test design["period_mapping_name"] == OOS_PERIOD_MAPPING_NAME
    @test design["period_mapping_version"] == OOS_PERIOD_MAPPING_VERSION
    @test design["period_mapping_formula"] == OOS_PERIOD_MAPPING_FORMULA

    blocks = document["deterministic_data_blocks"]
    @test length(blocks) == expected_deterministic_data_count(STRUCTURAL_FIXTURE.design) == 2
    @test all(block -> length(block["deterministic_data_id"]) > 3, blocks)
    @test all(block -> block["included_seed_keys"] == OOS_DETERMINISTIC_BASE_INCLUDED_KEYS,
              blocks)
    @test all(block -> block["excluded_seed_keys"] == OOS_DETERMINISTIC_BASE_EXCLUDED_KEYS,
              blocks)
    @test all(block -> length(block["demand_activity_digests"]) == 2, blocks)
    @test all(block -> all(
        length(String(block[field])) == 16 for field in (
            "base_price_digest", "extended_price_digest", "base_pv_reference_digest",
            "extended_pv_reference_digest", "demand_activity_digest",
        )
    ), blocks)

    pristine = validate_structural_manifest_document(document)
    @test pristine.passed
    @test isempty(structural_blocking_issues(pristine))

    # Returned documents own their nested vectors: corrupting one cannot mutate module constants,
    # the design/records, or legitimize a later manifest generated in the same process.
    fresh_before = structural_manifest_document(
        STRUCTURAL_FIXTURE.design, STRUCTURAL_FIXTURE.records,
    )
    fresh_bytes = structural_manifest_text(fresh_before)
    push!(fresh_before["seed_contract"][1]["included_keys"], "worker")
    push!(fresh_before["design"]["canonical_ordering"], "worker")
    push!(fresh_before["structural_instances"][1]["household_profiles"], "morning")
    fresh_after = structural_manifest_document(
        STRUCTURAL_FIXTURE.design, STRUCTURAL_FIXTURE.records,
    )
    @test structural_manifest_text(fresh_after) == fresh_bytes
    @test !("worker" in OOS_SEED_CONTRACT[1]["included_keys"])
    @test OOS_STRUCTURAL_CANONICAL_ORDERING == [
        "normalized_base_instance_id", "structural_draw", "demand_regime",
        "uncertainty_level", "battery_level",
    ]
    rematerialized = validate_structural_manifest_document(
        document; base_config=base, rematerialize=true, rematerialize_limit=2,
    )
    @test rematerialized.passed
    @test rematerialized.counts["rematerialized"] == 2

    function require_rejected(corrupted; kwargs...)
        report = validate_structural_manifest_document(corrupted; kwargs...)
        @test !report.passed
        @test !isempty(structural_blocking_issues(report))
        return report
    end

    # Schema-v1 remains recognizable but can never be silently treated as Stage-3-ready.
    v1 = corrupt_manifest(document, d ->
        d["design"]["structural_manifest_schema_version"] = 1)
    v1_report = require_rejected(v1)
    @test any(
        issue -> occursin("regenerate as schema v2", issue.detail),
        structural_blocking_issues(v1_report),
    )

    # Wrong centralized mapping / base-period index contract.
    require_rejected(corrupt_manifest(document, d ->
        d["deterministic_data_blocks"][1]["period_mapping_formula"] =
            "1 + (period mod repository_instance_horizon)"))

    # Altered extended price and PV references.
    require_rejected(corrupt_manifest(document, d ->
        d["structural_instances"][1]["extended_price_digest"] = "0000000000000000"))
    require_rejected(corrupt_manifest(document, d ->
        d["structural_instances"][1]["extended_pv_reference_digest"] =
            "1111111111111111"))

    # Altered demand activity and a missing final materialized support period.
    require_rejected(corrupt_manifest(document, d ->
        d["demand_assignments"][1]["demand_activity_digest"] = "2222222222222222"))
    require_rejected(corrupt_manifest(document, d ->
        d["structural_instances"][1]["materialized_data_end"] -= 1))

    # Both theta-dependent and battery-dependent actual repository seeds are forbidden.
    require_rejected(corrupt_manifest(document, d -> begin
        row = only(filter(
            r -> r["uncertainty_level"] == "HIGH_UNCERTAINTY" &&
                 r["battery_level"] == "LOW_BATTERY" && r["structural_draw"] == 1 &&
                 r["demand_regime"] == "HOMOGENEOUS",
            d["structural_instances"],
        ))
        row["actual_repository_generator_seed"] += 1
    end))
    require_rejected(corrupt_manifest(document, d -> begin
        row = only(filter(
            r -> r["battery_level"] == "HIGH_BATTERY" &&
                 r["uncertainty_level"] == "LOW_UNCERTAINTY" &&
                 r["structural_draw"] == 1 && r["demand_regime"] == "HOMOGENEOUS",
            d["structural_instances"],
        ))
        row["actual_repository_generator_seed"] += 1
    end))

    # A price split introduced only in HIGH_UNCERTAINTY must be rejected.
    require_rejected(corrupt_manifest(document, d -> begin
        row = only(filter(
            r -> r["uncertainty_level"] == "HIGH_UNCERTAINTY" &&
                 r["battery_level"] == "LOW_BATTERY" && r["structural_draw"] == 1 &&
                 r["demand_regime"] == "HETEROGENEOUS",
            d["structural_instances"],
        ))
        row["base_price_digest"] = "3333333333333333"
    end))

    # A block-level deterministic digest and the temporal endpoint are independently guarded.
    require_rejected(corrupt_manifest(document, d ->
        d["deterministic_data_blocks"][1]["extended_price_digest"] =
            "4444444444444444"))
    require_rejected(corrupt_manifest(document, d ->
        d["design"]["required_period_support_end"] += 1))

    # Even a self-consistent forged digest is caught by independent rematerialization.
    forged = corrupt_manifest(document, d -> begin
        identifier = d["deterministic_data_blocks"][1]["deterministic_data_id"]
        forged_digest = "5555555555555555"
        d["deterministic_data_blocks"][1]["extended_price_digest"] = forged_digest
        for row in d["structural_instances"]
            row["deterministic_data_id"] == identifier || continue
            row["extended_price_digest"] = forged_digest
        end
    end)
    require_rejected(
        forged; base_config=base, rematerialize=true, rematerialize_limit=1,
    )

    # Duplicate activity entries cannot stand in for exhaustive assignment coverage, even when
    # the aggregate and top-level ManifestID are recomputed consistently.
    duplicate_activity = corrupt_manifest(document, d -> begin
        block = d["deterministic_data_blocks"][1]
        block["demand_activity_digests"][2] = canonical_json_parse(
            canonical_json(block["demand_activity_digests"][1]),
        )
        block["demand_activity_digest"] = oos_stable_digest(
            canonical_json(block["demand_activity_digests"]),
        )
    end)
    require_rejected(
        duplicate_activity; base_config=base, rematerialize=true, rematerialize_limit=1,
    )

    # Planned Stage-2 seeds are scientific values, not merely distinct labels. A forged seed
    # must fail even when the payload digest is refreshed and every structural row is
    # rematerialized successfully.
    forged_oos_seed = corrupt_manifest(document, d ->
        d["planned_oos_replication_keys"][1]["oos_path_seed"] += 1)
    require_rejected(
        forged_oos_seed; base_config=base, rematerialize=true,
    )
    forged_support_seed = corrupt_manifest(document, d ->
        d["planned_conditional_support_keys"][1]["conditional_support_seed"] += 1)
    require_rejected(
        forged_support_seed; base_config=base, rematerialize=true,
    )

    # Design metadata is part of the same scientific contract as the rows and deterministic
    # blocks. Self-consistent row rematerialization must not legitimize a contradictory design
    # header or a noncanonical rolling-start vector.
    require_rejected(
        corrupt_manifest(document, d -> d["design"]["avg_demand"] += 0.25);
        base_config=base, rematerialize=true,
    )
    require_rejected(
        corrupt_manifest(document, d ->
            d["design"]["battery_level_scales"]["LOW_BATTERY"] += 0.125);
        base_config=base, rematerialize=true,
    )
    require_rejected(
        corrupt_manifest(document, d ->
            d["design"]["uncertainty_level_thetas"]["LOW_UNCERTAINTY"] += 0.025);
        base_config=base, rematerialize=true,
    )
    require_rejected(
        corrupt_manifest(document, d ->
            reverse!(d["design"]["rolling_iteration_starts"]));
        base_config=base, rematerialize=true,
    )

    # The seed-contract table is an exact schema: dictionary indexing must not allow a duplicate
    # stream to shadow another entry, and unknown extra streams are not silently accepted.
    duplicate_seed_stream = corrupt_manifest(document, d -> push!(
        d["seed_contract"],
        canonical_json_parse(canonical_json(d["seed_contract"][1])),
    ))
    require_rejected(
        duplicate_seed_stream; base_config=base, rematerialize=true,
    )
    extra_seed_stream = corrupt_manifest(document, d -> begin
        extra = canonical_json_parse(canonical_json(d["seed_contract"][1]))
        extra["stream"] = "unexpected_stage3_stream"
        push!(d["seed_contract"], extra)
    end)
    require_rejected(
        extra_seed_stream; base_config=base, rematerialize=true,
    )

    # A wrong ManifestID fails even when every payload field remains parseable.
    require_rejected(corrupt_manifest(
        document, d -> d["manifest_id"] = "MF-0000000000000000";
        refresh_digest=false,
    ))
end

# =====================================================================================
# P10 Cross-process byte and scientific-input reproducibility
# =====================================================================================

@testset "P10 manifest v2 is byte-reproducible across independent processes" begin
    script_directory = mktempdir(; prefix="oos_stage3_manifest_script_")
    script = joinpath(script_directory, "generate_stage3_fixture.jl")
    write(script, """
    const REPO_ROOT = $(repr(REPO_ROOT))
    include(joinpath(REPO_ROOT, "codes", "oos_experiment", "oos_experiment.jl"))
    reversed = ARGS[2] == "reverse"
    design = OOSStructuralDesignConfig(
        base_instance_files=[$(repr(TEST_INSTANCE))],
        experiment_seed=4242, structural_draws_per_cell=1,
        battery_scales=battery_scale_map(0.5, 2.0),
        uncertainty_thetas=uncertainty_theta_map(0.1, 0.4),
        households=3, oos_replications=1,
        evaluation_horizon=24, lookahead_horizon=24, implementation_step=12,
        in_sample_stages=3, in_sample_children=2, in_sample_periods_per_stage=8,
    )
    controllers = reversed ?
        [MULTISTAGE_RH, TWO_STAGE_RH, DETERMINISTIC_RH] :
        [DETERMINISTIC_RH, TWO_STAGE_RH, MULTISTAGE_RH]
    policies = reversed ? [SA, PEA, NONE] : [NONE, PEA, SA]
    base = OOSExperimentConfig(
        experiment_seed=4242, oos_replications=1,
        controller_set=controllers, fairness_set=policies,
        solver_threads=reversed ? 4 : 1,
        formulation_id="stage3_cross_process", export_representative_models=false,
        require_shared_battery_validation=false,
        output_directory=ARGS[1], instance_file=$(repr(TEST_INSTANCE)), households=3,
    )
    generate_structural_manifest(
        base, design, joinpath(ARGS[1], "structural_instance_manifest.json");
        write_companions=false, verbose=false,
    )
    """)

    outputs = String[]
    for (index, order) in enumerate(("forward", "reverse"))
        output = mktempdir(; prefix="oos_stage3_process_$(index)_")
        command = Cmd([
            first(Base.julia_cmd()), "--project=$(REPO_ROOT)", "--startup-file=no",
            script, output, order,
        ])
        process = withenv(
            "OOS_WORKER_ID" => string(40 + index),
            "OOS_TASK_ORDER" => order,
        ) do
            run(ignorestatus(command))
        end
        @test process.exitcode == 0
        push!(outputs, joinpath(output, "structural_instance_manifest.json"))
    end
    @test all(isfile, outputs)
    bytes = read.(outputs, String)
    @test bytes[1] == bytes[2]

    documents = canonical_json_parse.(bytes)
    @test documents[1]["manifest_id"] == documents[2]["manifest_id"]
    for section in ("deterministic_data_blocks", "structural_instances",
                    "demand_assignments", "planned_oos_replication_keys",
                    "planned_conditional_support_keys")
        @test documents[1][section] == documents[2][section]
    end
    @test [block["deterministic_data_id"]
           for block in documents[1]["deterministic_data_blocks"]] ==
          [block["deterministic_data_id"]
           for block in documents[2]["deterministic_data_blocks"]]
    @test [block["actual_repository_generator_seed"]
           for block in documents[1]["deterministic_data_blocks"]] ==
          [block["actual_repository_generator_seed"]
           for block in documents[2]["deterministic_data_blocks"]]
    @test [block["extended_price_digest"]
           for block in documents[1]["deterministic_data_blocks"]] ==
          [block["extended_price_digest"]
           for block in documents[2]["deterministic_data_blocks"]]
    @test [block["extended_pv_reference_digest"]
           for block in documents[1]["deterministic_data_blocks"]] ==
          [block["extended_pv_reference_digest"]
           for block in documents[2]["deterministic_data_blocks"]]
end
