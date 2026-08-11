# =====================================================================================
# Structural instance catalog and seed hierarchy (accepted redesign stage 2, with the additive
# deterministic-data and manifest-v2 contract introduced in stage 3).
#
# Included from `tests/oos/runtests.jl`, so it shares that file's helpers (`test_config`,
# `TEST_INSTANCE`, `TEST_OUTPUT`, `REPO_ROOT`) and runs inside the one sanctioned OOS gate.
#
# Every numeric factor level used here is a TEST FIXTURE, never a campaign recommendation: the
# battery scales and uncertainty intensities stay provisional until stage 12 calibrates them.
# =====================================================================================

"""Base campaign configuration for the structural tests: no exports, no blocking gate."""
structural_base_config(; kwargs...) = test_config(;
    fairness_set=[NONE], controller_set=[DETERMINISTIC_RH],
    export_representative_models=false, require_shared_battery_validation=false,
    kwargs...,
)

"""
Small but genuinely complete structural design fixture.

One base instance, `K = 2`, three households, two OOS replications and `h = 6` (so `N_t = 4`)
keeps the factorial catalog at 16 instances and the planned-key tables small enough to assert
exactly.
"""
structural_test_design(; kwargs...) = OOSStructuralDesignConfig(;
    merge(
        Dict{Symbol,Any}(
            :base_instance_files => [TEST_INSTANCE],
            :experiment_seed => 4242,
            :structural_draws_per_cell => 2,
            :battery_scales => battery_scale_map(0.5, 2.0),
            :uncertainty_thetas => uncertainty_theta_map(0.1, 0.4),
            :households => 3,
            :oos_replications => 2,
            :evaluation_horizon => 24,
            :lookahead_horizon => 24,
            :implementation_step => 6,
            :in_sample_stages => 3,
            :in_sample_children => 2,
            :in_sample_periods_per_stage => 8,
        ),
        Dict{Symbol,Any}(kwargs),
    )...
)

# =====================================================================================
# S0 Canonical JSON and the stable digest
# =====================================================================================

@testset "S0 canonical JSON writer, parser and stable digest" begin
    # Object keys are emitted in ascending byte order, never in Dict iteration order.
    document = Dict{String,Any}("zeta" => 1, "alpha" => 2, "mid" => 3)
    rendered = canonical_json(document)
    @test findfirst("alpha", rendered).start < findfirst("mid", rendered).start
    @test findfirst("mid", rendered).start < findfirst("zeta", rendered).start
    # Insertion order must not matter.
    @test canonical_json(Dict{String,Any}("alpha" => 2, "mid" => 3, "zeta" => 1)) == rendered

    # Round trip over every shape the manifest uses.
    payload = Dict{String,Any}(
        "int" => 42, "negative" => -7, "float" => 0.5, "integral_float" => 2.0,
        "bool_true" => true, "bool_false" => false, "nothing" => nothing,
        "string" => "morning", "escaped" => "a\"b\\c\nd\te",
        "empty_vector" => Any[], "empty_object" => Dict{String,Any}(),
        "scalars" => [1, 2, 3], "strings" => ["morning", "midday", "night"],
        "nested" => [Dict{String,Any}("k" => 1), Dict{String,Any}("k" => 2)],
        "deep" => Dict{String,Any}("inner" => Dict{String,Any}("leaf" => [1.5, 2.5])),
    )
    parsed = canonical_json_parse(canonical_json(payload))
    @test parsed["int"] === 42
    @test parsed["negative"] === -7
    @test parsed["float"] === 0.5
    @test parsed["integral_float"] === 2.0
    @test parsed["bool_true"] === true
    @test parsed["bool_false"] === false
    @test parsed["nothing"] === nothing
    @test parsed["escaped"] == "a\"b\\c\nd\te"
    @test parsed["empty_vector"] == Any[]
    @test parsed["empty_object"] == Dict{String,Any}()
    @test parsed["strings"] == ["morning", "midday", "night"]
    @test parsed["deep"]["inner"]["leaf"] == [1.5, 2.5]
    # Re-rendering a parsed document reproduces the bytes: this is what makes the saved manifest
    # verifiable as canonical rather than merely parseable.
    @test canonical_json(parsed) == canonical_json(payload)

    # The digest is a pure function of the bytes and is stable, unlike Base.hash for strings.
    @test oos_stable_digest("abc") == oos_stable_digest("abc")
    @test length(oos_stable_digest("abc")) == 16
    @test oos_stable_digest("abc") != oos_stable_digest("abd")
    # Component encoding is unambiguous: a separator inside a component cannot be confused with
    # a component boundary.
    @test oos_identity_digest(Any["a|b", "c"]) != oos_identity_digest(Any["a", "b|c"])
    @test oos_identity_digest(Any["a", "b"]) != oos_identity_digest(Any["b", "a"])
    @test oos_identity_digest(Any[1, 2]) == oos_identity_digest(Any[1, 2])

    # A non-finite number must be refused rather than silently written as null.
    @test_throws ErrorException canonical_json(Dict{String,Any}("x" => NaN))
    @test_throws ErrorException canonical_json(Dict{String,Any}("x" => Inf))
    # Malformed input must fail loudly instead of guessing.
    @test_throws ErrorException canonical_json_parse("{\"a\": }")
    @test_throws ErrorException canonical_json_parse("{\"a\": 1")
    @test_throws ErrorException canonical_json_parse("{\"a\": 1} trailing")
    @test_throws ErrorException canonical_json_parse("{\"a\": 1, \"a\": 2}")
end

# =====================================================================================
# S1 Structural factor validation
# =====================================================================================

@testset "S1 structural factors and design validation" begin
    # Typed labels, not unchecked strings.
    @test parse_battery_level("LOW_BATTERY") === LOW_BATTERY
    @test parse_battery_level(" high_battery ") === HIGH_BATTERY
    @test parse_demand_regime("heterogeneous") === HETEROGENEOUS
    @test parse_uncertainty_level("LOW_UNCERTAINTY") === LOW_UNCERTAINTY
    @test_throws ErrorException parse_battery_level("MEDIUM_BATTERY")
    @test_throws ErrorException parse_demand_regime("MIXED")
    @test_throws ErrorException parse_demand_regime("mixed2")
    @test_throws ErrorException parse_uncertainty_level("VERY_HIGH")
    # Canonical orders are declared explicitly, not inferred from enum integers.
    @test OOS_BATTERY_LEVEL_ORDER == (LOW_BATTERY, HIGH_BATTERY)
    @test OOS_DEMAND_REGIME_ORDER == (HOMOGENEOUS, HETEROGENEOUS)
    @test OOS_UNCERTAINTY_LEVEL_ORDER == (LOW_UNCERTAINTY, HIGH_UNCERTAINTY)
    @test OOS_STRUCTURAL_DEMAND_PROFILES == ("morning", "midday", "night")

    # A valid explicit design is accepted and its provisional status is recorded.
    design = structural_test_design()
    @test design.structural_draws_per_cell == 2
    @test battery_scale(design, LOW_BATTERY) == 0.5
    @test battery_scale(design, HIGH_BATTERY) == 2.0
    @test uncertainty_theta(design, LOW_UNCERTAINTY) == 0.1
    @test uncertainty_theta(design, HIGH_UNCERTAINTY) == 0.4
    @test design.factor_level_status === OOS_FACTOR_LEVEL_PROVISIONAL
    # The base instance is stored repository-relative, so identifiers are checkout-independent.
    @test design.base_instance_files == ["codes/inst/inst2020/Drahi_1.csv"]
    @test !isabspath(first(design.base_instance_files))
    @test isfile(absolute_base_instance_file(first(design.base_instance_files)))
    @test base_instance_id(first(design.base_instance_files)) == "Drahi_1"

    # K must be positive.
    @test_throws ErrorException structural_test_design(structural_draws_per_cell=0)
    @test_throws ErrorException structural_test_design(structural_draws_per_cell=-1)
    # The base-instance set cannot be empty, nor contain duplicates.
    @test_throws ErrorException structural_test_design(base_instance_files=String[])
    @test_throws ErrorException structural_test_design(
        base_instance_files=[TEST_INSTANCE, TEST_INSTANCE],
    )
    @test_throws ErrorException structural_test_design(
        base_instance_files=[TEST_INSTANCE, "codes/inst/inst2020/Drahi_1.csv"],
    )
    # A missing low or high mapping must be rejected, not silently defaulted.
    @test_throws ErrorException structural_test_design(
        battery_scales=Dict{BatteryLevel,Float64}(LOW_BATTERY => 0.5),
    )
    @test_throws ErrorException structural_test_design(
        battery_scales=Dict{BatteryLevel,Float64}(HIGH_BATTERY => 2.0),
    )
    @test_throws ErrorException structural_test_design(
        uncertainty_thetas=Dict{UncertaintyLevel,Float64}(LOW_UNCERTAINTY => 0.1),
    )
    @test_throws ErrorException structural_test_design(
        uncertainty_thetas=Dict{UncertaintyLevel,Float64}(),
    )
    # Nonfinite numbers are refused everywhere.
    @test_throws ErrorException structural_test_design(battery_scales=battery_scale_map(0.5, NaN))
    @test_throws ErrorException structural_test_design(battery_scales=battery_scale_map(Inf, 2.0))
    @test_throws ErrorException structural_test_design(
        uncertainty_thetas=uncertainty_theta_map(0.1, Inf),
    )
    @test_throws ErrorException structural_test_design(avg_demand=NaN)
    @test_throws ErrorException structural_test_design(dev_demand=Inf)
    @test_throws ErrorException structural_test_design(pv_scale=NaN)
    # Battery scales must be positive and strictly ordered.
    @test_throws ErrorException structural_test_design(battery_scales=battery_scale_map(0.0, 2.0))
    @test_throws ErrorException structural_test_design(battery_scales=battery_scale_map(-1.0, 2.0))
    @test_throws ErrorException structural_test_design(battery_scales=battery_scale_map(2.0, 0.5))
    @test_throws ErrorException structural_test_design(battery_scales=battery_scale_map(1.0, 1.0))
    # Uncertainty must be nonnegative and strictly ordered; theta = 0 is admissible as the low level.
    @test_throws ErrorException structural_test_design(
        uncertainty_thetas=uncertainty_theta_map(-0.1, 0.4),
    )
    @test_throws ErrorException structural_test_design(
        uncertainty_thetas=uncertainty_theta_map(0.4, 0.1),
    )
    @test_throws ErrorException structural_test_design(
        uncertainty_thetas=uncertainty_theta_map(0.2, 0.2),
    )
    @test structural_test_design(
        uncertainty_thetas=uncertainty_theta_map(0.0, 0.3),
    ).uncertainty_thetas[LOW_UNCERTAINTY] == 0.0
    # Remaining guards.
    @test_throws ErrorException structural_test_design(households=1)
    @test_throws ErrorException structural_test_design(oos_replications=0)
    @test_throws ErrorException structural_test_design(repository_demand_profile="  ")
    @test_throws ErrorException structural_test_design(factor_level_status=:CALIBRATED)
    @test_throws ErrorException structural_test_design(factor_level_status=:APPROVED)
    # The stage-1 temporal contract is enforced, not restated.
    @test_throws ErrorException structural_test_design(evaluation_horizon=0)
    @test_throws ErrorException structural_test_design(lookahead_horizon=0)
    @test_throws ErrorException structural_test_design(implementation_step=0)
    @test_throws ErrorException structural_test_design(
        evaluation_horizon=4, implementation_step=6,
    )
    @test_throws ErrorException structural_test_design(
        lookahead_horizon=4, implementation_step=6,
    )
    # A base instance outside the repository has no checkout-independent identifier.
    @test_throws ErrorException structural_test_design(base_instance_files=["/etc/hosts"])
    @test_throws ErrorException normalized_base_instance_file("")

    # The stage-1 temporal helpers apply verbatim to a structural design.
    stepped = structural_test_design(implementation_step=6)
    @test rolling_iteration_starts(stepped) == [1, 7, 13, 19]
    @test rolling_solve_count(stepped) == 4
    @test known_prefix_length(stepped) == 6
    @test final_rolling_iteration_start(stepped) == 19
    @test required_period_support_end(stepped) == 19 + 24 - 1
    @test is_rolling_iteration_start(stepped, 7)
    @test !is_rolling_iteration_start(stepped, 8)

    # Invalid structural-draw indices are rejected by the catalog's own range rule.
    specs = structural_instance_specs(structural_test_design())
    @test all(spec -> 1 <= spec.structural_draw <= 2, specs)
end

# =====================================================================================
# S2 Catalog cardinality
# =====================================================================================

@testset "S2 catalog cardinality and canonical ordering" begin
    design = structural_test_design()
    specs = structural_instance_specs(design)

    # B x 2 x 2 x 2 x K with B = 1 and K = 2.
    @test length(specs) == 16
    @test expected_structural_instance_count(design) == 16
    @test length(unique([s.paired_base_id for s in specs])) == 8
    @test expected_paired_base_count(design) == 8
    @test length(unique([s.demand_assignment_id for s in specs])) == 4
    @test expected_demand_assignment_count(design) == 4
    @test length(unique([s.structural_instance_id for s in specs])) == 16

    # Planned key tables: 8R OOS-path entries and 8R*N_t conditional-support entries.
    replications = design.oos_replications
    starts = rolling_iteration_starts(design)
    @test length(starts) == 4
    # These are deliberately synthetic records: S2 tests key-table cardinality rather than the
    # repository generator. Schema v2 nevertheless requires a complete finite support summary,
    # so give every DeterministicDataID common price/PV digests and every assignment its own
    # activity digests, exactly as a materialized catalog would.
    fake_summary(spec) = Dict{String,Any}(
        "repository_instance_horizon" => 24,
        "required_period_support_end" => required_period_support_end(design),
        "materialized_data_end" => max(24, required_period_support_end(design)),
        "period_mapping_name" => OOS_PERIOD_MAPPING_NAME,
        "period_mapping_version" => OOS_PERIOD_MAPPING_VERSION,
        "period_mapping_formula" => OOS_PERIOD_MAPPING_FORMULA,
        "price_rows" => spec.households,
        "price_periods" => max(24, required_period_support_end(design)),
        "pv_reference_periods" => max(24, required_period_support_end(design)),
        "demand_model_count" => spec.households,
        "digests" => Dict{String,Any}(
            "base_price_digest" => oos_stable_digest("base-price|$(spec.deterministic_data_id)"),
            "extended_price_digest" =>
                oos_stable_digest("extended-price|$(spec.deterministic_data_id)"),
            "base_pv_reference_digest" =>
                oos_stable_digest("base-pv|$(spec.deterministic_data_id)"),
            "extended_pv_reference_digest" =>
                oos_stable_digest("extended-pv|$(spec.deterministic_data_id)"),
            "base_demand_activity_digest" =>
                oos_stable_digest("base-demand|$(spec.demand_assignment_id)"),
            "demand_activity_digest" =>
                oos_stable_digest("extended-demand|$(spec.demand_assignment_id)"),
        ),
    )
    records = [OOSStructuralInstanceRecord(
        i, s,
        OOSResolvedInstanceParameters(
            "x", 24, 1.0, 0.2, 63.0, 0.2, 4.0, 4.0, 0.95, 0.95, 1.0, 1.0,
        ),
        fake_summary(s),
    ) for (i, s) in enumerate(specs)]
    payload = structural_manifest_payload(design, records)
    @test length(payload["planned_oos_replication_keys"]) == 8 * replications
    @test length(payload["planned_conditional_support_keys"]) ==
          8 * replications * length(starts)

    # Cardinality scales as declared.
    bigger = structural_test_design(structural_draws_per_cell=3)
    @test length(structural_instance_specs(bigger)) == 24
    @test expected_paired_base_count(bigger) == 12
    @test expected_demand_assignment_count(bigger) == 6

    # Canonical order: base instance, draw, regime, uncertainty, battery.
    observed = [(s.base_instance_id, s.structural_draw, s.demand_regime,
                 s.uncertainty_level, s.battery_level) for s in specs]
    expected = [(base_instance_id(file), draw, regime, uncertainty, battery)
                for file in design.base_instance_files
                for draw in 1:design.structural_draws_per_cell
                for regime in OOS_DEMAND_REGIME_ORDER
                for uncertainty in OOS_UNCERTAINTY_LEVEL_ORDER
                for battery in OOS_BATTERY_LEVEL_ORDER]
    @test observed == expected
    # The order does not depend on how the caller listed the base instances.
    @test [s.structural_instance_id for s in
           structural_instance_specs(structural_test_design())] ==
          [s.structural_instance_id for s in specs]

    # Two base instances double the catalog and keep both instances' identifiers distinct.
    two = structural_test_design(base_instance_files=[
        "codes/inst/inst2020/Drahi_2.csv", "codes/inst/inst2020/Drahi_1.csv",
    ])
    @test two.base_instance_files ==
          ["codes/inst/inst2020/Drahi_1.csv", "codes/inst/inst2020/Drahi_2.csv"]
    two_specs = structural_instance_specs(two)
    @test length(two_specs) == 32
    @test length(unique([s.structural_instance_id for s in two_specs])) == 32
    @test length(unique([s.demand_assignment_id for s in two_specs])) == 8
    # Sorted-by-base-instance order: every Drahi_1 record precedes every Drahi_2 record.
    first_ids = [s.base_instance_id for s in two_specs]
    @test first_ids[1:16] == fill("Drahi_1", 16)
    @test first_ids[17:32] == fill("Drahi_2", 16)
end

# =====================================================================================
# S3 Homogeneous assignments
# =====================================================================================

@testset "S3 homogeneous demand assignments" begin
    for seed in (1, 7, 4242, 999_331), households in (2, 3, 5, 6, 7)
        assignment = structural_demand_assignment(households, HOMOGENEOUS, seed)
        @test length(assignment) == households
        @test length(unique(assignment)) == 1
        @test first(assignment) in OOS_STRUCTURAL_DEMAND_PROFILES
        # Repeated generation is identical.
        @test assignment == structural_demand_assignment(households, HOMOGENEOUS, seed)
        counts = validate_structural_assignment(assignment, HOMOGENEOUS, households)
        @test sum(counts) == households
        @test count(>(0), counts) == 1
    end

    # The common profile is seed-determined, and across many seeds every approved profile is
    # reachable — so the rule is a genuine draw from the set, not a hard-coded label.
    selected = unique([first(structural_demand_assignment(4, HOMOGENEOUS, seed))
                       for seed in 1:200])
    @test Set(selected) == Set(OOS_STRUCTURAL_DEMAND_PROFILES)

    # Catalog level: repeated generation selects exactly the same common profile.
    design = structural_test_design()
    first_pass = structural_demand_assignments(design)
    second_pass = structural_demand_assignments(design)
    @test [a.household_profiles for a in first_pass] == [a.household_profiles for a in second_pass]
    @test [a.demand_assignment_id for a in first_pass] ==
          [a.demand_assignment_id for a in second_pass]
    for assignment in first_pass
        if assignment.demand_regime === HOMOGENEOUS
            @test length(unique(assignment.household_profiles)) == 1
        end
    end
    # Different structural draws keep distinct identifiers and seeds even when their profiles
    # happen to coincide.
    homogeneous = [a for a in first_pass if a.demand_regime === HOMOGENEOUS]
    @test length(homogeneous) == 2
    @test homogeneous[1].demand_assignment_id != homogeneous[2].demand_assignment_id
    @test homogeneous[1].assignment_seed != homogeneous[2].assignment_seed
    @test homogeneous[1].structural_draw != homogeneous[2].structural_draw
end

# =====================================================================================
# S4 Heterogeneous assignments
# =====================================================================================

@testset "S4 heterogeneous demand assignments" begin
    for households in (2, 3, 5, 6, 7)
        for seed in (1, 13, 4242, 77_777)
            assignment = structural_demand_assignment(households, HETEROGENEOUS, seed)
            @test length(assignment) == households
            @test all(profile -> profile in OOS_STRUCTURAL_DEMAND_PROFILES, assignment)
            counts = structural_profile_counts(assignment)
            @test sum(counts) == households
            # Maximally balanced: max - min <= 1.
            @test maximum(counts) - minimum(counts) <= 1
            @test validate_structural_assignment(assignment, HETEROGENEOUS, households) == counts
            # Reproducible.
            @test assignment == structural_demand_assignment(households, HETEROGENEOUS, seed)
        end
    end

    # Exact expected multisets of counts.
    @test sort(structural_profile_counts(
        structural_demand_assignment(5, HETEROGENEOUS, 4242))) == [1, 2, 2]
    @test sort(structural_profile_counts(
        structural_demand_assignment(6, HETEROGENEOUS, 4242))) == [2, 2, 2]
    @test sort(structural_profile_counts(
        structural_demand_assignment(7, HETEROGENEOUS, 4242))) == [2, 2, 3]
    @test sort(structural_profile_counts(
        structural_demand_assignment(3, HETEROGENEOUS, 4242))) == [1, 1, 1]
    # Fewer households than profiles: zero counts are unavoidable but the split stays balanced.
    @test sort(structural_profile_counts(
        structural_demand_assignment(2, HETEROGENEOUS, 4242))) == [0, 1, 1]

    # The seed changes the assignment: over many seeds both the composition (which profile gets
    # the remainder) and the household identity permutation vary.
    vectors = unique([structural_demand_assignment(5, HETEROGENEOUS, seed) for seed in 1:60])
    @test length(vectors) > 1
    # A controlled fixture where two seeds give the same counts but a different household order,
    # proving the identity permutation is genuinely seeded and separate from the composition.
    same_counts = Dict{Vector{Int},Vector{Vector{String}}}()
    for seed in 1:400
        assignment = structural_demand_assignment(6, HETEROGENEOUS, seed)
        push!(get!(same_counts, structural_profile_counts(assignment), Vector{String}[]),
              assignment)
    end
    balanced = same_counts[[2, 2, 2]]
    @test length(unique(balanced)) > 1

    # Never an independent per-household `mixed` draw: with 6 households an independent draw
    # would frequently produce an unbalanced composition, and a controlled one never can.
    for seed in 1:300
        counts = structural_profile_counts(structural_demand_assignment(6, HETEROGENEOUS, seed))
        @test counts == [2, 2, 2]
    end
    # The legacy composite labels are not even accepted as structural profiles.
    @test !("mixed" in OOS_STRUCTURAL_DEMAND_PROFILES)
    @test !("alea" in OOS_STRUCTURAL_DEMAND_PROFILES)
    @test_throws ErrorException validate_structural_assignment(
        ["mixed", "mixed", "mixed"], HOMOGENEOUS, 3,
    )
    @test_throws ErrorException validate_structural_assignment(
        ["morning", "morning", "morning"], HETEROGENEOUS, 3,
    )
    @test_throws ErrorException validate_structural_assignment(
        ["morning", "midday"], HETEROGENEOUS, 3,
    )
    @test_throws ErrorException structural_demand_assignment(0, HETEROGENEOUS, 1)
end

# =====================================================================================
# S5 Pairing
# =====================================================================================

@testset "S5 battery pairing and uncertainty separation" begin
    design = structural_test_design()
    specs = structural_instance_specs(design)

    pairs = Dict{String,Vector{OOSStructuralInstanceSpec}}()
    for spec in specs
        push!(get!(pairs, spec.paired_base_id, OOSStructuralInstanceSpec[]), spec)
    end
    @test length(pairs) == 8

    for (pairing, members) in pairs
        @test length(members) == 2
        low = members[findfirst(s -> s.battery_level === LOW_BATTERY, members)]
        high = members[findfirst(s -> s.battery_level === HIGH_BATTERY, members)]

        # Shared: everything that is not the battery.
        @test low.paired_base_id == high.paired_base_id == pairing
        @test low.demand_assignment_id == high.demand_assignment_id
        @test low.assignment_seed == high.assignment_seed
        @test low.household_profiles == high.household_profiles
        @test low.base_instance_id == high.base_instance_id
        @test low.base_instance_file == high.base_instance_file
        @test low.structural_draw == high.structural_draw
        @test low.demand_regime == high.demand_regime
        @test low.uncertainty_level == high.uncertainty_level
        @test low.theta == high.theta
        @test low.repository_instance_seed == high.repository_instance_seed
        @test low.deterministic_data_id == high.deterministic_data_id
        @test low.actual_repository_generator_seed == high.actual_repository_generator_seed
        @test low.households == high.households
        @test low.avg_demand == high.avg_demand
        @test low.dev_demand == high.dev_demand
        @test low.pv_scale == high.pv_scale
        @test low.repository_demand_profile == high.repository_demand_profile

        # The OOS-path and conditional-support seeds are shared, because battery level cannot
        # even be represented in the seed key.
        low_key = oos_path_seed_key(design, low)
        high_key = oos_path_seed_key(design, high)
        @test low_key == high_key
        for replication in 1:design.oos_replications
            @test structural_oos_path_seed(low_key, replication) ==
                  structural_oos_path_seed(high_key, replication)
            for start in rolling_iteration_starts(design)
                @test conditional_support_seed(low_key, replication, start) ==
                      conditional_support_seed(high_key, replication, start)
            end
        end

        # Differ: battery label, scale and full identifier.
        @test low.battery_level !== high.battery_level
        @test low.battery_scale < high.battery_scale
        @test low.structural_instance_id != high.structural_instance_id
    end

    # Uncertainty levels share the household assignment but are different pairs, with different
    # theta and different stochastic streams.
    by_cell = Dict{Tuple{Int,DemandRegime},Vector{OOSStructuralInstanceSpec}}()
    for spec in specs
        if spec.battery_level === LOW_BATTERY
            push!(get!(by_cell, (spec.structural_draw, spec.demand_regime),
                       OOSStructuralInstanceSpec[]), spec)
        end
    end
    for (_, members) in by_cell
        @test length(members) == 2
        low = members[findfirst(s -> s.uncertainty_level === LOW_UNCERTAINTY, members)]
        high = members[findfirst(s -> s.uncertainty_level === HIGH_UNCERTAINTY, members)]
        @test low.demand_assignment_id == high.demand_assignment_id
        @test low.household_profiles == high.household_profiles
        @test low.assignment_seed == high.assignment_seed
        @test low.deterministic_data_id == high.deterministic_data_id
        @test low.actual_repository_generator_seed == high.actual_repository_generator_seed
        @test low.paired_base_id != high.paired_base_id
        @test low.theta < high.theta
        low_key = oos_path_seed_key(design, low)
        high_key = oos_path_seed_key(design, high)
        @test structural_oos_path_seed(low_key, 1) != structural_oos_path_seed(high_key, 1)
        @test conditional_support_seed(low_key, 1, 1) !=
              conditional_support_seed(high_key, 1, 1)
        # The legacy default repository seed still differs because theta is one of its keys. It
        # remains recorded as evidence of the accepted stage-2 confound, while the actual stage-3
        # structural seed above is shared and therefore isolates deterministic repository data.
        @test low.repository_instance_seed != high.repository_instance_seed
    end

    # Each DemandAssignmentID covers exactly 2 battery x 2 uncertainty = 4 structural instances.
    usage = Dict{String,Vector{OOSStructuralInstanceSpec}}()
    for spec in specs
        push!(get!(usage, spec.demand_assignment_id, OOSStructuralInstanceSpec[]), spec)
    end
    for (_, members) in usage
        @test length(members) == 4
        @test length(unique([s.battery_level for s in members])) == 2
        @test length(unique([s.uncertainty_level for s in members])) == 2
        @test length(unique([s.household_profiles for s in members])) == 1
        @test length(unique([s.assignment_seed for s in members])) == 1
    end
end

# =====================================================================================
# S6 Seed hierarchy inclusions and exclusions
# =====================================================================================

@testset "S6 seed hierarchy inclusions and exclusions" begin
    design = structural_test_design()

    # --- assignment seed ---------------------------------------------------------------
    base = structural_assignment_seed(design, "Drahi_1", HETEROGENEOUS, 1)
    @test base == structural_assignment_seed(design, "Drahi_1", HETEROGENEOUS, 1)
    # Each relevant key moves the stream.
    @test base != structural_assignment_seed(
        structural_test_design(experiment_seed=999), "Drahi_1", HETEROGENEOUS, 1)
    @test base != structural_assignment_seed(design, "Drahi_2", HETEROGENEOUS, 1)
    @test base != structural_assignment_seed(design, "Drahi_1", HOMOGENEOUS, 1)
    @test base != structural_assignment_seed(design, "Drahi_1", HETEROGENEOUS, 2)
    # Battery and uncertainty cannot enter: the function has no parameter for them, and the
    # catalog gives one seed per (base, regime, draw).
    specs = structural_instance_specs(design)
    for cell in unique([(s.base_instance_id, s.demand_regime, s.structural_draw) for s in specs])
        seeds = unique([s.assignment_seed for s in specs
                        if (s.base_instance_id, s.demand_regime, s.structural_draw) == cell])
        @test length(seeds) == 1
    end

    # --- OOS-path seed -----------------------------------------------------------------
    key = OOSPathSeedKey(4242, "Drahi_1", "DA-x", HETEROGENEOUS, 1, LOW_UNCERTAINTY)
    @test structural_oos_path_seed(key, 1) == structural_oos_path_seed(key, 1)
    @test structural_oos_path_seed(key, 1) != structural_oos_path_seed(key, 2)
    @test structural_oos_path_seed(key, 1) != structural_oos_path_seed(
        OOSPathSeedKey(9999, "Drahi_1", "DA-x", HETEROGENEOUS, 1, LOW_UNCERTAINTY), 1)
    @test structural_oos_path_seed(key, 1) != structural_oos_path_seed(
        OOSPathSeedKey(4242, "Drahi_2", "DA-x", HETEROGENEOUS, 1, LOW_UNCERTAINTY), 1)
    @test structural_oos_path_seed(key, 1) != structural_oos_path_seed(
        OOSPathSeedKey(4242, "Drahi_1", "DA-y", HETEROGENEOUS, 1, LOW_UNCERTAINTY), 1)
    @test structural_oos_path_seed(key, 1) != structural_oos_path_seed(
        OOSPathSeedKey(4242, "Drahi_1", "DA-x", HOMOGENEOUS, 1, LOW_UNCERTAINTY), 1)
    @test structural_oos_path_seed(key, 1) != structural_oos_path_seed(
        OOSPathSeedKey(4242, "Drahi_1", "DA-x", HETEROGENEOUS, 2, LOW_UNCERTAINTY), 1)
    @test structural_oos_path_seed(key, 1) != structural_oos_path_seed(
        OOSPathSeedKey(4242, "Drahi_1", "DA-x", HETEROGENEOUS, 1, HIGH_UNCERTAINTY), 1)
    # The key type structurally cannot carry battery level, controller, fairness, worker or order.
    @test !(:battery_level in fieldnames(OOSPathSeedKey))
    @test !(:battery_scale in fieldnames(OOSPathSeedKey))
    @test !(:theta in fieldnames(OOSPathSeedKey))
    @test !(:controller in fieldnames(OOSPathSeedKey))
    @test !(:fairness in fieldnames(OOSPathSeedKey))
    @test !(:worker in fieldnames(OOSPathSeedKey))
    @test !(:rolling_start in fieldnames(OOSPathSeedKey))

    # --- conditional-support seed ------------------------------------------------------
    @test conditional_support_seed(key, 1, 1) == conditional_support_seed(key, 1, 1)
    starts = rolling_iteration_starts(design)
    support = [conditional_support_seed(key, 1, start) for start in starts]
    @test length(unique(support)) == length(starts)      # differs across rolling starts
    @test conditional_support_seed(key, 1, 1) != conditional_support_seed(key, 2, 1)
    @test conditional_support_seed(key, 1, 1) != structural_oos_path_seed(key, 1)
    @test_throws ErrorException conditional_support_seed(key, 1, 0)

    # --- stream separation -------------------------------------------------------------
    # The three new streams are distinct from each other and from every legacy stream, so no
    # hierarchy can consume another's numbers.
    names = [OOS_STRUCTURAL_ASSIGNMENT_STREAM, OOS_STRUCTURAL_PATH_STREAM,
             OOS_CONDITIONAL_SUPPORT_STREAM, "oos_path", "lookahead", "in_sample",
             "demand_profiles"]
    @test length(unique(names)) == length(names)
    @test oos_stream_seed(4242, OOS_STRUCTURAL_PATH_STREAM, 1) !=
          oos_stream_seed(4242, "oos_path", 1)

    # --- RNGs are usable and reproducible ----------------------------------------------
    @test rand(structural_assignment_rng(design, "Drahi_1", HETEROGENEOUS, 1), 5) ==
          rand(structural_assignment_rng(design, "Drahi_1", HETEROGENEOUS, 1), 5)
    @test rand(structural_oos_path_rng(key, 1), 5) == rand(structural_oos_path_rng(key, 1), 5)
    @test rand(conditional_support_rng(key, 1, 7), 5) ==
          rand(conditional_support_rng(key, 1, 7), 5)

    # --- repository generator seed -----------------------------------------------------
    # Recorded under its own name and equal to the repository's own deterministic_seed.
    file = first(design.base_instance_files)
    @test repository_instance_seed(design, file, 0.1) == deterministic_seed(
        design.in_sample_stages, design.in_sample_children, design.in_sample_periods_per_stage,
        design.households, absolute_base_instance_file(file), 0.1,
        design.avg_demand, design.dev_demand;
        demand_profile=design.repository_demand_profile,
    )
    # It excludes battery scale and pv_scale, and is not any of the three new seeds.
    @test repository_instance_seed(design, file, 0.1) ==
          repository_instance_seed(structural_test_design(
              battery_scales=battery_scale_map(0.9, 9.0)), file, 0.1)
    @test repository_instance_seed(design, file, 0.1) !=
          repository_instance_seed(design, file, 0.4)
    @test repository_instance_seed(design, file, 0.1) !=
          structural_assignment_seed(design, "Drahi_1", HOMOGENEOUS, 1)

    # --- actual deterministic-base repository seed ------------------------------------
    deterministic_key = deterministic_base_key(design, file, 1)
    @test deterministic_data_id(deterministic_key) == deterministic_data_id(design, file, 1)
    @test startswith(deterministic_data_id(deterministic_key), "DD-Drahi_1-d1-")
    @test actual_repository_generator_seed(deterministic_key) ==
          actual_repository_generator_seed(design, file, 1)
    @test actual_repository_generator_seed(design, file, 1) !=
          actual_repository_generator_seed(design, file, 2)
    @test actual_repository_generator_seed(design, file, 1) !=
          actual_repository_generator_seed(structural_test_design(experiment_seed=999), file, 1)
    # No uncertainty, battery, demand-regime or operational field can be represented by the key.
    for forbidden in (:battery_level, :battery_scale, :demand_regime, :demand_assignment_id,
                      :uncertainty_level, :theta, :controller, :fairness_policy, :worker,
                      :retry, :execution_order)
        @test !(forbidden in fieldnames(OOSDeterministicBaseKey))
    end
end

# =====================================================================================
# S7 Manifest structure, identity and reproducibility
# =====================================================================================

"""Materialize a bounded structural catalog once and reuse it across the manifest tests."""
const STRUCTURAL_FIXTURE = let
    design = structural_test_design()
    base = structural_base_config()
    records = build_structural_catalog(base, design; verbose=false)
    (design=design, base=base, records=records,
     document=structural_manifest_document(design, records))
end

@testset "S7 manifest structure, identity and byte reproducibility" begin
    document = STRUCTURAL_FIXTURE.document
    design = STRUCTURAL_FIXTURE.design

    # Its own schema version; the results schema is untouched by this standalone artefact. The
    # two are INDEPENDENT contracts — the manifest is still v2 while the results schema moved to
    # v3 in stage 10 — which is exactly what this pair of assertions exists to pin.
    @test document["design"]["structural_manifest_schema_version"] ==
          OOS_STRUCTURAL_MANIFEST_SCHEMA_VERSION == 2
    @test OOS_OUTPUT_SCHEMA_VERSION == 3
    @test OOS_STRUCTURAL_MANIFEST_SCHEMA_VERSION != OOS_OUTPUT_SCHEMA_VERSION

    # Design metadata records everything stage 2 requires.
    metadata = document["design"]
    for key in ("experiment_seed", "factor_level_status", "base_instance_files",
                "structural_draws_per_cell", "expected_structural_instance_count",
                "actual_structural_instance_count", "battery_level_scales",
                "uncertainty_level_thetas", "demand_regimes", "households", "avg_demand",
                "dev_demand", "pv_scale", "evaluation_horizon", "implementation_step",
                "rolling_iteration_starts", "oos_replication_count", "canonical_ordering",
                "expected_deterministic_data_count", "actual_deterministic_data_count",
                "repository_instance_horizon", "required_period_support_end",
                "materialized_data_end", "period_mapping_name", "period_mapping_version",
                "period_mapping_formula", "deterministic_base_isolation_status", "stage3_ready")
        @test haskey(metadata, key)
    end
    @test metadata["factor_level_status"] == "PROVISIONAL_UNCALIBRATED"
    # Stage 13 connected the manifest to the campaign runner; the flag records that.
    @test metadata["consumed_by_active_simulator"] === true
    @test metadata["expected_structural_instance_count"] == 16
    @test metadata["actual_structural_instance_count"] == 16
    @test metadata["expected_deterministic_data_count"] == 2
    @test metadata["actual_deterministic_data_count"] == 2
    @test metadata["repository_instance_horizon"] == 24
    @test metadata["required_period_support_end"] == required_period_support_end(design) == 42
    @test metadata["materialized_data_end"] == 42
    @test metadata["period_mapping_name"] == OOS_PERIOD_MAPPING_NAME
    @test metadata["period_mapping_version"] == OOS_PERIOD_MAPPING_VERSION
    @test metadata["period_mapping_formula"] == OOS_PERIOD_MAPPING_FORMULA
    @test metadata["deterministic_base_isolation_status"] == "passed"
    @test metadata["stage3_ready"] === true
    @test metadata["canonical_ordering"] == OOS_STRUCTURAL_CANONICAL_ORDERING
    @test metadata["battery_level_scales"] == Dict{String,Any}(
        "LOW_BATTERY" => 0.5, "HIGH_BATTERY" => 2.0)
    @test metadata["uncertainty_level_thetas"] == Dict{String,Any}(
        "LOW_UNCERTAINTY" => 0.1, "HIGH_UNCERTAINTY" => 0.4)
    @test metadata["rolling_iteration_starts"] == rolling_iteration_starts(design)

    # Seed contract: every stream, its algorithm, its inclusions and its exclusions.
    streams = Dict(entry["stream"] => entry for entry in document["seed_contract"])
    for stream in (OOS_STRUCTURAL_ASSIGNMENT_STREAM, OOS_STRUCTURAL_PATH_STREAM,
                   OOS_CONDITIONAL_SUPPORT_STREAM, OOS_DETERMINISTIC_BASE_STREAM,
                   "repository_instance_seed",
                   "oos_path", "lookahead", "in_sample", "demand_profiles")
        @test haskey(streams, stream)
        @test haskey(streams[stream], "included_keys")
        @test haskey(streams[stream], "excluded_keys")
        @test haskey(streams[stream], "seed_algorithm")
    end
    for stream in (OOS_STRUCTURAL_ASSIGNMENT_STREAM, OOS_STRUCTURAL_PATH_STREAM,
                   OOS_CONDITIONAL_SUPPORT_STREAM)
        included = streams[stream]["included_keys"]
        for forbidden in ("controller", "fairness_policy", "solver_phase", "worker",
                          "execution_order", "battery_level")
            @test !(forbidden in included)
            @test forbidden in streams[stream]["excluded_keys"]
        end
    end
    # The still-active look-ahead stream is recorded truthfully, controller included: removing it
    # is stage 5, and the manifest must not pretend otherwise.
    @test "controller" in streams["lookahead"]["included_keys"]
    @test streams["lookahead"]["status"] == "legacy_active"
    @test streams[OOS_STRUCTURAL_PATH_STREAM]["status"] == "stage2_contract"
    # The repository generator seed keeps its own name and is never relabelled.
    @test streams["repository_instance_seed"]["status"] ==
          "legacy_default_active_outside_structural_materializer"
    @test "theta" in streams["repository_instance_seed"]["included_keys"]
    @test "battery_scale" in streams["repository_instance_seed"]["excluded_keys"]
    @test streams[OOS_DETERMINISTIC_BASE_STREAM]["status"] ==
          "stage3_active_structural_materializer"
    @test streams[OOS_DETERMINISTIC_BASE_STREAM]["included_keys"] ==
          OOS_DETERMINISTIC_BASE_INCLUDED_KEYS
    @test streams[OOS_DETERMINISTIC_BASE_STREAM]["excluded_keys"] ==
          OOS_DETERMINISTIC_BASE_EXCLUDED_KEYS
    @test !("theta" in streams[OOS_DETERMINISTIC_BASE_STREAM]["included_keys"])

    # One deterministic repository-data block per base instance x structural draw. Every block
    # is referenced by all eight battery x regime x uncertainty variants and carries finite,
    # stable digests for the base and extended period support.
    deterministic_blocks = document["deterministic_data_blocks"]
    @test length(deterministic_blocks) == 2
    @test length(unique([b["deterministic_data_id"] for b in deterministic_blocks])) == 2
    for block in deterministic_blocks
        @test block["included_seed_keys"] == OOS_DETERMINISTIC_BASE_INCLUDED_KEYS
        @test block["excluded_seed_keys"] == OOS_DETERMINISTIC_BASE_EXCLUDED_KEYS
        @test block["required_period_support_end"] == required_period_support_end(design)
        @test block["materialized_data_end"] == required_period_support_end(design)
        @test length(block["demand_activity_digests"]) == 2
        for key in ("base_price_digest", "extended_price_digest",
                    "base_pv_reference_digest", "extended_pv_reference_digest",
                    "demand_activity_digest")
            @test length(block[key]) == 16
        end
        @test count(row -> row["deterministic_data_id"] == block["deterministic_data_id"],
                    document["structural_instances"]) == 8
    end

    # Demand assignments recorded once each, with counts.
    assignments = document["demand_assignments"]
    @test length(assignments) == 4
    @test length(unique([a["demand_assignment_id"] for a in assignments])) == 4
    for entry in assignments
        @test entry["profile_count_labels"] == collect(OOS_STRUCTURAL_DEMAND_PROFILES)
        @test sum(entry["profile_counts"]) == design.households
        @test haskey(entry, "assignment_seed")
        @test haskey(entry, "deterministic_data_id")
        @test haskey(entry, "base_demand_activity_digest")
        @test haskey(entry, "demand_activity_digest")
    end

    # Structural instances: ordinals in canonical order and resolved parameters present.
    rows = document["structural_instances"]
    @test length(rows) == 16
    @test [row["manifest_ordinal"] for row in rows] == collect(1:16)
    for row in rows
        for key in ("resolved_s_min", "resolved_s_max", "resolved_s_I", "resolved_f_under",
                    "resolved_f_bar", "resolved_mu", "resolved_beta", "deterministic_data_id",
                    "legacy_default_repository_instance_seed",
                    "actual_repository_generator_seed", "repository_instance_horizon",
                    "required_period_support_end", "materialized_data_end",
                    "base_price_digest", "extended_price_digest", "base_pv_reference_digest",
                    "extended_pv_reference_digest", "base_demand_activity_digest",
                    "demand_activity_digest", "instance_period_length_delta")
            @test haskey(row, key)
        end
    end

    # Planned key tables are not duplicated by battery level.
    @test length(document["planned_oos_replication_keys"]) == 8 * design.oos_replications
    @test all(row -> !haskey(row, "battery_level"), document["planned_oos_replication_keys"])
    @test all(row -> !haskey(row, "battery_level"),
              document["planned_conditional_support_keys"])
    @test length(document["planned_conditional_support_keys"]) ==
          8 * design.oos_replications * rolling_solve_count(design)

    # Manifest identity: digest of the canonical payload, excluding the digest field.
    @test startswith(document["manifest_id"], "MF-")
    @test document["manifest_id"] == structural_manifest_id(document)
    without = Dict{String,Any}(document)
    delete!(without, "manifest_id")
    @test document["manifest_id"] == string("MF-", oos_stable_digest(canonical_json(without)))

    # No clock-time, calendar, timestamp or machine-dependent field anywhere in the payload.
    for key in _collect_keys(document)
        lowered = lowercase(key)
        for fragment in OOS_MANIFEST_FORBIDDEN_KEY_FRAGMENTS
            @test !occursin(fragment, lowered)
        end
    end
    rendered = structural_manifest_text(document)
    @test !occursin("PERIOD_DURATION", rendered)
    @test !occursin("\"pv_scale_minutes\"", rendered)
    # The instance period length is recorded WITHOUT a clock unit.
    @test document["structural_instances"][1]["instance_period_length_delta"] == 1.0

    # Rebuilding from the same logical inputs reproduces the bytes exactly, in this process.
    rebuilt = structural_manifest_document(
        structural_test_design(),
        build_structural_catalog(structural_base_config(), structural_test_design();
                                verbose=false),
    )
    @test structural_manifest_text(rebuilt) == rendered
    @test rebuilt["manifest_id"] == document["manifest_id"]

    # Controller order, fairness order, solver threads and warm starts are outside the design and
    # cannot touch the manifest.
    for variant in (
        structural_base_config(controller_set=[MULTISTAGE_RH, TWO_STAGE_RH, DETERMINISTIC_RH]),
        structural_base_config(fairness_set=[LEXMMFSA, SA, NONE]),
        structural_base_config(solver_threads=4),
        structural_base_config(use_warm_starts=true),
        structural_base_config(output_directory=mktempdir(; prefix="oos_structural_alt_")),
    )
        alternative = structural_manifest_document(
            structural_test_design(),
            build_structural_catalog(variant, structural_test_design(); verbose=false),
        )
        @test alternative["manifest_id"] == document["manifest_id"]
        @test structural_manifest_text(alternative) == rendered
    end

    # A changed design DOES change the manifest identity.
    for changed in (structural_test_design(experiment_seed=999),
                    structural_test_design(structural_draws_per_cell=1),
                    structural_test_design(battery_scales=battery_scale_map(0.5, 3.0)),
                    structural_test_design(implementation_step=4))
        other = structural_manifest_document(
            changed, build_structural_catalog(structural_base_config(), changed; verbose=false),
        )
        @test other["manifest_id"] != document["manifest_id"]
    end
end

# =====================================================================================
# S8 Physical materialization
# =====================================================================================

@testset "S8 structural materialization and resolved battery parameters" begin
    design = STRUCTURAL_FIXTURE.design
    base = STRUCTURAL_FIXTURE.base
    records = STRUCTURAL_FIXTURE.records
    support_end = required_period_support_end(design)
    @test length(records) == 16

    for record in records
        spec = record.spec
        materialized = materialize_structural_instance(
            base, spec; required_period_support_end=support_end,
        )
        template = materialized.template

        # The template is the one the existing physical-model builder consumes.
        @test template isa OOSInstanceTemplate
        @test template.J == spec.households
        @test template.theta == spec.theta

        # Stored battery parameters match the approved pipeline exactly.
        @test record.resolved.s_min == template.s_min
        @test record.resolved.s_max == template.s_max
        @test record.resolved.s_I == template.s_I
        @test record.resolved.f_under == template.f_under
        @test record.resolved.f_bar == template.f_bar
        @test record.resolved.delta == template.delta
        @test record.resolved.repository_instance_horizon == template.T
        @test record.resolved.repository_instance_id == template.id
        @test record.resolved.mu == template.mu
        @test record.resolved.beta == template.beta
        @test materialized.actual_repository_generator_seed ==
              spec.actual_repository_generator_seed
        @test materialized.period_data_support.required_period_support_end == support_end
        @test materialized.period_data_support.materialized_data_end == support_end
        @test materialized.period_data_support_summary == record.period_data_support_summary

        # Household profiles come from the catalog and are never re-sampled.
        @test [model.profile for model in template.demand_models] == spec.household_profiles
        for (index, model) in enumerate(template.demand_models)
            @test model.household == index
            @test model.avg == spec.avg_demand
            @test model.dev == spec.dev_demand
            @test model.active_periods ==
                  demand_active_periods(spec.household_profiles[index], template.T)
        end
        # Rematerializing gives the identical profiles: no hidden randomness.
        @test [m.profile for m in
               materialize_structural_instance(
                   base, spec; required_period_support_end=support_end,
               ).template.demand_models] ==
              spec.household_profiles

        # The legacy in-sample tree stays labelled as such.
        @test materialized.legacy_in_sample_tree isa Tree
        # The derived configuration carries the structural factor levels.
        @test materialized.config.battery_scale == spec.battery_scale
        @test materialized.config.theta == spec.theta
        @test materialized.config.demand_profile == spec.repository_demand_profile
    end

    # Battery pairs: identical non-battery physics, correctly scaled battery physics.
    pairs = Dict{String,Vector{OOSStructuralInstanceRecord}}()
    for record in records
        push!(get!(pairs, record.spec.paired_base_id, OOSStructuralInstanceRecord[]), record)
    end
    for (_, members) in pairs
        low = members[findfirst(r -> r.spec.battery_level === LOW_BATTERY, members)]
        high = members[findfirst(r -> r.spec.battery_level === HIGH_BATTERY, members)]
        # `scaleInstance!` scales s_max, f_under and f_bar; it leaves s_min and s_I alone.
        @test low.resolved.s_min == high.resolved.s_min
        @test low.resolved.s_I == high.resolved.s_I
        @test low.resolved.e_c == high.resolved.e_c
        @test low.resolved.e_d == high.resolved.e_d
        @test low.resolved.mu == high.resolved.mu
        @test low.resolved.beta == high.resolved.beta
        @test low.resolved.delta == high.resolved.delta
        @test low.resolved.repository_instance_horizon == high.resolved.repository_instance_horizon
        @test low.spec.deterministic_data_id == high.spec.deterministic_data_id
        @test low.spec.actual_repository_generator_seed ==
              high.spec.actual_repository_generator_seed
        @test low.period_data_support_summary == high.period_data_support_summary
        @test low.resolved.s_max < high.resolved.s_max
        @test low.resolved.f_under < high.resolved.f_under
        @test low.resolved.f_bar < high.resolved.f_bar
        # Exactly the repository's own scaling rule, not a reinterpretation of it.
        @test high.resolved.s_max == 63.0 * high.spec.battery_scale
        @test high.resolved.f_under == 4.0 * high.spec.battery_scale * 4
        @test high.resolved.f_bar == 4.0 * high.spec.battery_scale * 4
    end

    # Prices and deterministic PV references are shared both inside a battery pair and across
    # uncertainty levels. The theta-dependent legacy seed remains in the spec only as audit data;
    # the actual structural generator seed is uncertainty-independent.
    materialized_by_id = Dict(
        r.spec.structural_instance_id => materialize_structural_instance(
            base, r.spec; required_period_support_end=support_end,
        )
        for r in records if r.spec.structural_draw == 1 && r.spec.demand_regime === HOMOGENEOUS
    )
    grouped = Dict{String,Vector{String}}()
    for record in records
        (record.spec.structural_draw == 1 && record.spec.demand_regime === HOMOGENEOUS) || continue
        push!(get!(grouped, record.spec.paired_base_id, String[]),
              record.spec.structural_instance_id)
    end
    pair_ids = sort(collect(keys(grouped)))
    @test length(pair_ids) == 2
    for pairing in pair_ids
        members = grouped[pairing]
        @test materialized_by_id[members[1]].template.nu ==
              materialized_by_id[members[2]].template.nu
        @test materialized_by_id[members[1]].template.pv_det ==
              materialized_by_id[members[2]].template.pv_det
        @test materialized_by_id[members[1]].period_data_support_summary ==
              materialized_by_id[members[2]].period_data_support_summary
    end
    low_uncertainty = materialized_by_id[grouped[pair_ids[1]][1]]
    high_uncertainty = materialized_by_id[grouped[pair_ids[2]][1]]
    @test low_uncertainty.template.nu == high_uncertainty.template.nu
    @test low_uncertainty.template.pv_det == high_uncertainty.template.pv_det
    @test low_uncertainty.period_data_support_summary ==
          high_uncertainty.period_data_support_summary

    # A spec rebuilt from a manifest row rematerializes to the same physics.
    row = STRUCTURAL_FIXTURE.document["structural_instances"][1]
    round_tripped = _spec_from_payload(canonical_json_parse(canonical_json(row)))
    @test round_tripped.structural_instance_id == records[1].spec.structural_instance_id
    @test round_tripped.household_profiles == records[1].spec.household_profiles
    rebuilt = materialize_structural_instance(
        base, round_tripped; required_period_support_end=support_end,
    )
    @test rebuilt.resolved.s_max == records[1].resolved.s_max
    @test rebuilt.resolved.f_under == records[1].resolved.f_under
    @test rebuilt.resolved.f_bar == records[1].resolved.f_bar
    @test rebuilt.resolved.s_min == records[1].resolved.s_min
    @test rebuilt.resolved.s_I == records[1].resolved.s_I
    @test rebuilt.resolved.mu == records[1].resolved.mu
    @test rebuilt.resolved.beta == records[1].resolved.beta
    @test rebuilt.period_data_support_summary == records[1].period_data_support_summary
end

# =====================================================================================
# S9 Manifest validation and corruption rejection
# =====================================================================================

"""Deep-copy a document, mutate it, and restore a consistent digest unless asked otherwise."""
function corrupt_manifest(document::AbstractDict, mutate!::Function; refresh_digest::Bool=true)
    copied = canonical_json_parse(canonical_json(document))
    mutate!(copied)
    if refresh_digest
        copied["manifest_id"] = structural_manifest_id(copied)
    end
    return copied
end

structural_details(report) = join([issue.detail for issue in report.issues], " || ")

@testset "S9 manifest validation and corruption rejection" begin
    document = STRUCTURAL_FIXTURE.document
    base = STRUCTURAL_FIXTURE.base

    # The pristine manifest passes, including the physical re-check.
    pristine = validate_structural_manifest_document(document)
    @test pristine.passed
    @test isempty(structural_blocking_issues(pristine))
    @test pristine.counts["structural_instances"] == 16
    @test pristine.counts["paired_bases"] == 8
    @test pristine.counts["demand_assignments"] == 4
    @test pristine.counts["deterministic_data_blocks"] == 2

    physical = validate_structural_manifest_document(
        document; base_config=base, rematerialize=true,
    )
    @test physical.passed
    @test physical.counts["rematerialized"] == 16

    # Schema v1 is recognized explicitly as an accepted stage-2 artefact, but cannot be treated
    # as stage-3 ready because it has neither deterministic isolation nor extended support proof.
    schema_v1 = corrupt_manifest(document, d -> begin
        d["design"]["structural_manifest_schema_version"] = 1
    end)
    report = validate_structural_manifest_document(schema_v1)
    @test !report.passed
    @test occursin("schema v2", structural_details(report))

    # --- 1 duplicate structural IDs -----------------------------------------------------
    report = validate_structural_manifest_document(corrupt_manifest(document, d -> begin
        d["structural_instances"][2]["structural_instance_id"] =
            d["structural_instances"][1]["structural_instance_id"]
    end))
    @test !report.passed
    @test occursin("duplicado", structural_details(report))

    # --- 2 missing battery partner ------------------------------------------------------
    report = validate_structural_manifest_document(corrupt_manifest(document, d -> begin
        d["structural_instances"][2]["paired_base_id"] = "PB-orphan"
    end))
    @test !report.passed
    @test occursin("debe aparecer exactamente 2", structural_details(report))

    # A pair covering the same battery level twice is also rejected.
    report = validate_structural_manifest_document(corrupt_manifest(document, d -> begin
        d["structural_instances"][2]["battery_level"] = "LOW_BATTERY"
    end))
    @test !report.passed

    # --- 3 altered demand assignment ----------------------------------------------------
    # Flip every label to a different one, so the corruption is genuinely a change whatever the
    # fixture's assignment happens to be. (Writing a literal vector here would silently become a
    # no-op the day the fixture's seed produces that same vector.)
    report = validate_structural_manifest_document(corrupt_manifest(document, d -> begin
        row = d["structural_instances"][1]
        row["household_profiles"] =
            [profile == "morning" ? "night" : "morning" for profile in row["household_profiles"]]
    end))
    @test !report.passed
    @test occursin("no reproduce los perfiles", structural_details(report))

    # An assignment referenced but absent is rejected.
    report = validate_structural_manifest_document(corrupt_manifest(document, d -> begin
        d["structural_instances"][1]["demand_assignment_id"] = "DA-ghost"
    end))
    @test !report.passed
    @test occursin("inexistente", structural_details(report))

    # --- 4 invalid heterogeneous count --------------------------------------------------
    report = validate_structural_manifest_document(corrupt_manifest(document, d -> begin
        index = findfirst(a -> a["demand_regime"] == "HETEROGENEOUS", d["demand_assignments"])
        entry = d["demand_assignments"][index]
        entry["household_profiles"] = ["morning", "morning", "morning"]
        entry["profile_counts"] = [3, 0, 0]
    end))
    @test !report.passed
    @test occursin("difieren en más de uno", structural_details(report))

    # A homogeneous assignment using several profiles is rejected too.
    report = validate_structural_manifest_document(corrupt_manifest(document, d -> begin
        index = findfirst(a -> a["demand_regime"] == "HOMOGENEOUS", d["demand_assignments"])
        entry = d["demand_assignments"][index]
        entry["household_profiles"] = ["morning", "midday", "night"]
        entry["profile_counts"] = [1, 1, 1]
    end))
    @test !report.passed
    @test occursin("varios perfiles", structural_details(report))

    # Inconsistent recorded counts are rejected.
    report = validate_structural_manifest_document(corrupt_manifest(document, d -> begin
        d["demand_assignments"][1]["profile_counts"] = [99, 0, 0]
    end))
    @test !report.passed
    @test occursin("profile_counts inconsistente", structural_details(report))

    # --- 5 battery-dependent OOS or support seed ---------------------------------------
    report = validate_structural_manifest_document(corrupt_manifest(document, d -> begin
        d["planned_oos_replication_keys"][1]["battery_level"] = "LOW_BATTERY"
    end))
    @test !report.passed
    @test occursin("battery_level", structural_details(report))

    report = validate_structural_manifest_document(corrupt_manifest(document, d -> begin
        d["planned_conditional_support_keys"][1]["battery_level"] = "HIGH_BATTERY"
    end))
    @test !report.passed
    @test occursin("battery_level", structural_details(report))

    # Duplicating the OOS key per battery level breaks the declared cardinality.
    report = validate_structural_manifest_document(corrupt_manifest(document, d -> begin
        push!(d["planned_oos_replication_keys"],
              canonical_json_parse(canonical_json(d["planned_oos_replication_keys"][1])))
    end))
    @test !report.passed

    # A seed contract that lists an operational key as included is rejected.
    report = validate_structural_manifest_document(corrupt_manifest(document, d -> begin
        index = findfirst(e -> e["stream"] == OOS_STRUCTURAL_PATH_STREAM, d["seed_contract"])
        push!(d["seed_contract"][index]["included_keys"], "controller")
    end))
    @test !report.passed
    @test occursin("controller", structural_details(report))

    # The active deterministic-base stream must retain its exact theta-free inclusion set.
    report = validate_structural_manifest_document(corrupt_manifest(document, d -> begin
        index = findfirst(e -> e["stream"] == OOS_DETERMINISTIC_BASE_STREAM,
                          d["seed_contract"])
        push!(d["seed_contract"][index]["included_keys"], "theta")
    end))
    @test !report.passed
    @test occursin("theta", structural_details(report))

    # Support seeds must differ across rolling starts.
    report = validate_structural_manifest_document(corrupt_manifest(document, d -> begin
        rows = d["planned_conditional_support_keys"]
        rows[2]["conditional_support_seed"] = rows[1]["conditional_support_seed"]
        rows[2]["paired_base_id"] = rows[1]["paired_base_id"]
        rows[2]["oos_replication"] = rows[1]["oos_replication"]
    end))
    @test !report.passed
    @test occursin("semilla de soporte", structural_details(report))

    # An assignment seed that varies with battery or uncertainty is rejected.
    report = validate_structural_manifest_document(corrupt_manifest(document, d -> begin
        d["structural_instances"][2]["assignment_seed"] =
            d["structural_instances"][2]["assignment_seed"] + 1
    end))
    @test !report.passed

    # --- 6 incorrect physical parameter -------------------------------------------------
    report = validate_structural_manifest_document(
        corrupt_manifest(document, d -> begin
            d["structural_instances"][1]["resolved_s_max"] = 1234.5
        end);
        base_config=base, rematerialize=true, rematerialize_limit=2,
    )
    @test !report.passed
    @test occursin("al rematerializar", structural_details(report))

    # A battery pair whose shared physics disagree is rejected without rematerializing.
    report = validate_structural_manifest_document(corrupt_manifest(document, d -> begin
        d["structural_instances"][1]["resolved_s_min"] = 9.0
    end))
    @test !report.passed
    @test occursin("resolved_s_min", structural_details(report))

    # Deterministic-data identity, seed, endpoints and digests are independently validated.
    report = validate_structural_manifest_document(corrupt_manifest(document, d -> begin
        d["deterministic_data_blocks"][1]["actual_repository_generator_seed"] += 1
    end))
    @test !report.passed
    @test occursin("semilla real", structural_details(report))

    report = validate_structural_manifest_document(corrupt_manifest(document, d -> begin
        d["deterministic_data_blocks"][1]["required_period_support_end"] -= 1
    end))
    @test !report.passed
    @test occursin("required_period_support_end", structural_details(report))

    report = validate_structural_manifest_document(corrupt_manifest(document, d -> begin
        d["structural_instances"][1]["extended_price_digest"] = "0000000000000000"
    end))
    @test !report.passed
    @test occursin("extended_price_digest", structural_details(report))

    # Uncertainty may change theta and future stochastic streams, but not deterministic inputs.
    report = validate_structural_manifest_document(corrupt_manifest(document, d -> begin
        rows = d["structural_instances"]
        low = findfirst(row -> row["structural_draw"] == 1 &&
                                row["demand_regime"] == "HOMOGENEOUS" &&
                                row["battery_level"] == "LOW_BATTERY" &&
                                row["uncertainty_level"] == "LOW_UNCERTAINTY", rows)
        rows[low]["base_price_digest"] = "1111111111111111"
    end))
    @test !report.passed
    @test occursin("base_price_digest", structural_details(report))

    # --- 7 incorrect manifest digest ----------------------------------------------------
    report = validate_structural_manifest_document(
        corrupt_manifest(document, d -> begin
            d["manifest_id"] = "MF-0000000000000000"
        end; refresh_digest=false),
    )
    @test !report.passed
    @test occursin("digest recomputado", structural_details(report))

    # Any silent content edit is caught by the digest as well.
    report = validate_structural_manifest_document(
        corrupt_manifest(document, d -> begin
            d["design"]["avg_demand"] = 123.0
        end; refresh_digest=false),
    )
    @test !report.passed
    @test occursin("digest recomputado", structural_details(report))

    # --- 8 incorrect expected row count -------------------------------------------------
    report = validate_structural_manifest_document(corrupt_manifest(document, d -> begin
        d["design"]["expected_structural_instance_count"] = 99
    end))
    @test !report.passed
    @test occursin("expected_structural_instance_count", structural_details(report))

    report = validate_structural_manifest_document(corrupt_manifest(document, d -> begin
        pop!(d["structural_instances"])
    end))
    @test !report.passed

    report = validate_structural_manifest_document(corrupt_manifest(document, d -> begin
        d["design"]["actual_structural_instance_count"] = 15
    end))
    @test !report.passed

    # --- other required invariants ------------------------------------------------------
    # A structural draw outside 1:K.
    report = validate_structural_manifest_document(corrupt_manifest(document, d -> begin
        d["structural_instances"][1]["structural_draw"] = 9
    end))
    @test !report.passed
    @test occursin("fuera de 1:", structural_details(report))

    # A wrong schema version must not be read silently.
    report = validate_structural_manifest_document(corrupt_manifest(document, d -> begin
        d["design"]["structural_manifest_schema_version"] = 99
    end))
    @test !report.passed
    @test occursin("esquema", structural_details(report))

    # Factor levels must stay declared provisional until stage 12.
    report = validate_structural_manifest_document(corrupt_manifest(document, d -> begin
        d["design"]["factor_level_status"] = "CALIBRATED"
    end))
    @test !report.passed
    @test occursin("factor_level_status", structural_details(report))

    # Since stage 13 the manifest IS consumed, so a document denying it is now the corrupt one.
    report = validate_structural_manifest_document(corrupt_manifest(document, d -> begin
        d["design"]["consumed_by_active_simulator"] = false
    end))
    @test !report.passed
    @test occursin("consumed_by_active_simulator", structural_details(report))

    # A clock-time or machine-dependent key anywhere in the payload is rejected.
    for (key, value) in (("period_duration_minutes", 15), ("profile_cycle", 24),
                         ("generated_at", "now"), ("hostname", "somewhere"))
        report = validate_structural_manifest_document(corrupt_manifest(document, d -> begin
            d["design"][key] = value
        end))
        @test !report.passed
    end

    # A missing section fails immediately rather than half-validating.
    for section in ("design", "seed_contract", "deterministic_data_blocks",
                    "demand_assignments", "structural_instances",
                    "planned_oos_replication_keys", "planned_conditional_support_keys",
                    "manifest_id")
        report = validate_structural_manifest_document(
            corrupt_manifest(document, d -> delete!(d, section); refresh_digest=false),
        )
        @test !report.passed
    end

    # enforce_structural_manifest! raises on a failing report and returns a passing one.
    @test enforce_structural_manifest!(pristine) === pristine
    @test_throws ErrorException enforce_structural_manifest!(
        validate_structural_manifest_document(corrupt_manifest(document, d -> begin
            d["design"]["expected_structural_instance_count"] = 99
        end)),
    )
end

# =====================================================================================
# S10 Generation, idempotence and cross-process byte reproducibility
# =====================================================================================

@testset "S10 manifest generation, idempotence and cross-process reproducibility" begin
    design = STRUCTURAL_FIXTURE.design
    base = STRUCTURAL_FIXTURE.base
    directory = mktempdir(; prefix="oos_structural_manifest_")
    path = joinpath(directory, OOS_STRUCTURAL_MANIFEST_FILES.manifest)

    result = generate_structural_manifest(base, design, path; verbose=false)
    @test result.status == "created"
    @test result.written
    @test isfile(path)
    @test result.structural_instances == 16
    @test result.paired_bases == 8
    @test result.demand_assignments == 4
    @test result.deterministic_data_blocks == 2
    @test result.planned_oos_keys == 8 * design.oos_replications
    @test result.planned_support_keys == 8 * design.oos_replications * rolling_solve_count(design)
    @test result.manifest_id == STRUCTURAL_FIXTURE.document["manifest_id"]
    # Companions: a normalized CSV and an explicitly NONCANONICAL provenance report.
    @test length(result.companion_files) == 2
    @test all(isfile, result.companion_files)
    csv_path = joinpath(directory, OOS_STRUCTURAL_MANIFEST_FILES.instances)
    frame = CSV.read(csv_path, DataFrame)
    @test nrow(frame) == 16
    @test frame.ManifestOrdinal == collect(1:16)
    @test length(unique(frame.StructuralInstanceID)) == 16
    @test length(unique(frame.PairedBaseID)) == 8
    @test length(unique(frame.DeterministicDataID)) == 2
    @test all(frame.RequiredPeriodSupportEnd .== required_period_support_end(design))
    @test all(frame.MaterializedDataEnd .== required_period_support_end(design))
    @test all(length.(frame.BasePriceDigest) .== 16)
    @test all(length.(frame.ExtendedPriceDigest) .== 16)
    # Provenance holds the machine-dependent facts the canonical payload must not.
    provenance = read(joinpath(directory, OOS_STRUCTURAL_MANIFEST_FILES.provenance), String)
    @test occursin("NO CANÓNICO", provenance)
    @test occursin(result.manifest_id, provenance)
    saved = read(path, String)
    @test !occursin(string(Sys.MACHINE), saved)
    @test !occursin(abspath(directory), saved)

    # The saved file validates standalone, from disk, including the physical re-check.
    from_disk = validate_structural_manifest(path; base_config=base, rematerialize=true)
    @test from_disk.passed
    @test from_disk.manifest_id == result.manifest_id
    @test from_disk.counts["rematerialized"] == 16

    # Idempotence: identical content is a no-op.
    again = generate_structural_manifest(base, design, path; verbose=false)
    @test again.status == "unchanged"
    @test !again.written
    @test read(path, String) == saved

    # Conflicting content must fail rather than be silently replaced.
    conflicting = structural_test_design(battery_scales=battery_scale_map(0.5, 3.0))
    @test_throws ErrorException generate_structural_manifest(base, conflicting, path;
                                                            verbose=false)
    @test read(path, String) == saved
    # ... and succeed only with an explicit overwrite.
    overwritten = generate_structural_manifest(base, conflicting, path;
                                               overwrite=true, verbose=false)
    @test overwritten.status == "overwritten"
    @test overwritten.manifest_id != result.manifest_id
    @test read(path, String) != saved

    # A hand-edited file that still parses must not pass: its bytes would not reproduce.
    tampered_directory = mktempdir(; prefix="oos_structural_tampered_")
    tampered = joinpath(tampered_directory, OOS_STRUCTURAL_MANIFEST_FILES.manifest)
    write(tampered, replace(saved, "\n  \"manifest_id\"" => "\n\n  \"manifest_id\""))
    @test !validate_structural_manifest(tampered).passed
    @test_throws ErrorException validate_structural_manifest(
        joinpath(tampered_directory, "does_not_exist.json"),
    )

    # --- cross-process byte reproducibility --------------------------------------------
    # Two independent Julia processes, neither of them this one, must produce identical bytes,
    # the same ManifestID, the same structural identifiers, seeds and household assignments.
    script_directory = mktempdir(; prefix="oos_structural_script_")
    script = joinpath(script_directory, "generate_fixture_manifest.jl")
    write(script, """
    const REPO_ROOT = $(repr(REPO_ROOT))
    include(joinpath(REPO_ROOT, "codes", "oos_experiment", "oos_experiment.jl"))
    design = OOSStructuralDesignConfig(
        base_instance_files=[$(repr(TEST_INSTANCE))],
        experiment_seed=4242, structural_draws_per_cell=1,
        battery_scales=battery_scale_map(0.5, 2.0),
        uncertainty_thetas=uncertainty_theta_map(0.1, 0.4),
        households=3, oos_replications=1,
        evaluation_horizon=24, lookahead_horizon=24, implementation_step=12,
        in_sample_stages=3, in_sample_children=2, in_sample_periods_per_stage=8,
    )
    base = OOSExperimentConfig(
        experiment_seed=4242, oos_replications=1,
        controller_set=[DETERMINISTIC_RH], fairness_set=[NONE],
        formulation_id="structural_cross_process", export_representative_models=false,
        require_shared_battery_validation=false,
        output_directory=ARGS[1], instance_file=$(repr(TEST_INSTANCE)), households=3,
    )
    result = generate_structural_manifest(
        base, design, joinpath(ARGS[1], "structural_instance_manifest.json");
        write_companions=false, verbose=false,
    )
    println("MANIFEST_ID=", result.manifest_id)
    """)

    outputs = String[]
    for replicate in 1:2
        output = mktempdir(; prefix="oos_structural_process_$(replicate)_")
        command = Cmd([
            first(Base.julia_cmd()), "--project=$(REPO_ROOT)", "--startup-file=no",
            script, output,
        ])
        process = run(ignorestatus(command))
        @test process.exitcode == 0
        push!(outputs, joinpath(output, "structural_instance_manifest.json"))
    end
    @test all(isfile, outputs)
    first_bytes = read(outputs[1], String)
    second_bytes = read(outputs[2], String)
    @test first_bytes == second_bytes
    @test oos_stable_digest(first_bytes) == oos_stable_digest(second_bytes)

    parsed_first = canonical_json_parse(first_bytes)
    parsed_second = canonical_json_parse(second_bytes)
    @test parsed_first["manifest_id"] == parsed_second["manifest_id"]
    @test [row["structural_instance_id"] for row in parsed_first["structural_instances"]] ==
          [row["structural_instance_id"] for row in parsed_second["structural_instances"]]
    @test [row["assignment_seed"] for row in parsed_first["structural_instances"]] ==
          [row["assignment_seed"] for row in parsed_second["structural_instances"]]
    @test [row["deterministic_data_id"] for row in parsed_first["structural_instances"]] ==
          [row["deterministic_data_id"] for row in parsed_second["structural_instances"]]
    @test [row["actual_repository_generator_seed"]
           for row in parsed_first["structural_instances"]] ==
          [row["actual_repository_generator_seed"]
           for row in parsed_second["structural_instances"]]
    @test [row["extended_price_digest"] for row in parsed_first["structural_instances"]] ==
          [row["extended_price_digest"] for row in parsed_second["structural_instances"]]
    @test [row["demand_activity_digest"] for row in parsed_first["structural_instances"]] ==
          [row["demand_activity_digest"] for row in parsed_second["structural_instances"]]
    @test [row["household_profiles"] for row in parsed_first["structural_instances"]] ==
          [row["household_profiles"] for row in parsed_second["structural_instances"]]
    @test [row["oos_path_seed"] for row in parsed_first["planned_oos_replication_keys"]] ==
          [row["oos_path_seed"] for row in parsed_second["planned_oos_replication_keys"]]
    @test [row["conditional_support_seed"]
           for row in parsed_first["planned_conditional_support_keys"]] ==
          [row["conditional_support_seed"]
           for row in parsed_second["planned_conditional_support_keys"]]
    # 1 base x 2 x 2 x 2 x 1 draw = 8 instances; h = 12 gives two rolling starts.
    @test length(parsed_first["structural_instances"]) == 8
    @test length(parsed_first["deterministic_data_blocks"]) == 1
    @test length(parsed_first["planned_oos_replication_keys"]) == 4
    @test length(parsed_first["planned_conditional_support_keys"]) == 8
    @test parsed_first["deterministic_data_blocks"] ==
          parsed_second["deterministic_data_blocks"]
    # And this process agrees with both of them.
    in_process_directory = mktempdir(; prefix="oos_structural_in_process_")
    cross_design = structural_test_design(
        structural_draws_per_cell=1, oos_replications=1, implementation_step=12,
    )
    cross_result = generate_structural_manifest(
        structural_base_config(
            formulation_id="structural_cross_process", output_directory=in_process_directory,
        ),
        cross_design,
        joinpath(in_process_directory, "structural_instance_manifest.json");
        write_companions=false, verbose=false,
    )
    @test cross_result.manifest_id == parsed_first["manifest_id"]
    @test read(joinpath(in_process_directory, "structural_instance_manifest.json"), String) ==
          first_bytes
end

# =====================================================================================
# S11 Stage-2/3 non-goal gate: the active simulator is untouched
# =====================================================================================

@testset "S11 the structural catalog and data support do not change the active simulator" begin
    # The legacy template path is byte-identical: same draw, same stream, same metadata.
    config = test_config(fairness_set=[NONE], controller_set=[DETERMINISTIC_RH])
    bundle = build_instance_template(config)
    expected_models = assign_demand_models(
        config.households, bundle.template.T, config.avg_demand, config.dev_demand,
        config.demand_profile, demand_profile_rng(config),
    )
    @test [m.profile for m in bundle.template.demand_models] ==
          [m.profile for m in expected_models]
    @test [m.active_periods for m in bundle.template.demand_models] ==
          [m.active_periods for m in expected_models]
    # The structural marker appears ONLY on the structural path.
    @test !haskey(bundle.template.metadata, "household_profile_source")
    structural = build_instance_template(config; household_profiles=["morning", "midday", "night"])
    @test structural.template.metadata["household_profile_source"] ==
          "structural_catalog_fixed_assignment"
    @test [m.profile for m in structural.template.demand_models] ==
          ["morning", "midday", "night"]
    @test_throws ErrorException build_instance_template(config; household_profiles=["morning"])

    # MIGRATED IN STAGE 5. The stage-2 version asserted that the controller was still part of the
    # look-ahead key and noted that removing it was stage 5. That happened: `lookahead_rng` and
    # its `lookahead` stream are gone, replaced by `lookahead_support_rng` over a key that CANNOT
    # carry the controller. The claim this block defends — that the structural catalog does not
    # disturb the active streams — is unchanged.
    @test oos_path_rng(config, 3) ==
          MersenneTwister(oos_stream_seed(config.experiment_seed, "oos_path", 3))
    @test !isdefined(@__MODULE__, :lookahead_rng)
    @test lookahead_support_rng(config, 3, 5) == MersenneTwister(
        oos_stream_seed(config.experiment_seed, OOS_LOOKAHEAD_SUPPORT_STREAM, 3, 5))
    # The controller cannot enter this key: the three methods share one support per rolling start.
    @test lookahead_support_rng(config, 3, 5) == lookahead_support_rng(config, 3, 5)
    @test lookahead_support_rng(config, 3, 5) != lookahead_support_rng(config, 3, 6)
    @test lookahead_support_rng(config, 3, 5) != lookahead_support_rng(config, 4, 5)
    # The legacy and structural conditional-support streams stay separate, exactly as the legacy
    # `oos_path` stream stays separate from `structural_oos_path`.
    @test OOS_LOOKAHEAD_SUPPORT_STREAM != OOS_CONDITIONAL_SUPPORT_STREAM
    @test in_sample_rng(config) ==
          MersenneTwister(oos_stream_seed(config.experiment_seed, "in_sample"))
    @test demand_profile_rng(config) ==
          MersenneTwister(oos_stream_seed(config.experiment_seed, "demand_profiles"))

    # MIGRATED IN STAGE 4. The claim this test defends is unchanged — the structural catalog and
    # the manifest are still invisible to the active simulator — but the simulator itself now
    # runs the stage-4 moving window, so the run is checked against the temporal contract rather
    # than against the repository horizon.
    common = build_common_objects(config; verbose=false)
    template = common.template
    path = common.oos_paths[1]
    cache = cache_lookahead_trees(common.provider, common.context, path)
    for t in (1, 5, 24)
        @test cache[(t, DETERMINISTIC_RH)].first_period == t
        @test cache[(t, DETERMINISTIC_RH)].last_period == t + config.lookahead_horizon - 1
    end
    run = simulate_configuration(
        common.context, path, cache, DETERMINISTIC_RH, NONE, common.static_shares,
    )
    @test run.completed
    @test run.periods_completed == rolling_solve_count(config)
    # No terminal requirement on the realized trajectory: the target binds at each window end.
    @test all(r.validation.residuals.terminal == 0.0 for r in run.records)
    @test template.s_min <= last(run.records).soc_after <= template.s_max
    for record in run.records
        @test record.validation.valid
    end

    # The stage-1 temporal contract is intact, and stage 4 wired it into the simulator.
    @test config.evaluation_horizon == OOS_DEFAULT_EVALUATION_HORIZON
    @test rolling_solve_count(config) == 24
    @test implementation_block(config, 10) == 10:10
    document = experiment_config_dictionary(config, template)
    @test haskey(document, "temporal_structure")
    @test occursin("wired_rolling_blocks",
                   document["temporal_structure"]["contract_status"])
    # No structural section leaked into the campaign metadata, and the results schema is untouched.
    @test !haskey(document, "structural_structure")
    @test !haskey(document, "structural_instance_id")
    @test !haskey(document, "temporal_structure") == false          # stage 1's section stays
    @test !haskey(document, "structural_manifest_schema_version")
    @test document["output_schema_version"] == OOS_OUTPUT_SCHEMA_VERSION == 3
    # The two schema versions are independent contracts and now differ numerically: the manifest
    # moved v1 -> v2 in stage 3, the results schema v2 -> v3 in stage 10, and neither bump
    # dragged the other along.
    @test OOS_STRUCTURAL_MANIFEST_SCHEMA_VERSION == 2
    @test OOS_OUTPUT_SCHEMA_VERSION == 3
    # The downstream results reader must NOT have been taught to require a structural manifest,
    # or every pre-existing result directory would start failing.
    @test !(OOS_STRUCTURAL_MANIFEST_FILES.manifest in keys(OOS_REQUIRED_COLUMNS))
    reader_source = read(
        joinpath(REPO_ROOT, "codes", "oos_experiment", "output_schema.jl"), String,
    )
    @test !occursin("structural_instance_manifest", reader_source)
    # MIGRATED IN STAGE 10. `StructuralInstanceID` is now a legitimate RESULT COLUMN, so the
    # reader necessarily mentions it. The claim this line defended is unchanged and is the one
    # above: the reader must not require the structural MANIFEST FILE, or every pre-existing
    # result directory would start failing. A degenerate identifier is written on the
    # single-instance path precisely so the column exists without the manifest.
    @test "StructuralInstanceID" in OOS_REQUIRED_COLUMNS["run_identity.csv"]
    @test !occursin("OOSStructuralDesignConfig", reader_source)
    @test !occursin("build_structural_catalog", reader_source)

    # The catalog is reachable only through its own entry points, never from the simulator loop.
    for file in ("simulator.jl", "controllers.jl", "lookahead_tree.jl", "uncertainty_provider.jl",
                 "physical_model.jl", "metrics.jl", "fairness_rules.jl")
        source = read(joinpath(REPO_ROOT, "codes", "oos_experiment", file), String)
        @test !occursin("build_structural_catalog", source)
        @test !occursin("structural_instance_specs", source)
        @test !occursin("OOSStructuralDesignConfig", source)
        @test !occursin("structural_oos_path_seed", source)
        @test !occursin("conditional_support_seed", source)
    end
    # `simulator.jl` may only reference the one additive hook the catalog needs.
    simulator_source = read(
        joinpath(REPO_ROOT, "codes", "oos_experiment", "simulator.jl"), String,
    )
    @test occursin("structural_demand_models", simulator_source)
end
