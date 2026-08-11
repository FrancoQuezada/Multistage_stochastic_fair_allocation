# =====================================================================================
# CR0..CR5  Campaign freeze, operational review and paired analysis (stage 14)
#
# Stage 14's gate is that a pilot's evidence decides whether the confirmatory campaign runs. That
# only means something if the evidence is produced by something that can say NO — so these sets
# check the refusals, not the happy path: an unfrozen code tree, an unpinned solver, a design
# left unbalanced by a rule that aborts in only some cells.
#
# The bounded fixture is deliberately the one that FAILS. At `H = L = 4` this instance has
# windows with zero community demand, so `PEA` aborts in the homogeneous cells and completes in
# the heterogeneous ones — exactly the asymmetry the review has to catch.
#
# These sets run inside `tests/oos/runtests.jl` after `campaign_shard_tests.jl` and reuse its
# `shard_setup`, `shard_campaign` and `merge_oos_shards` helpers.
# =====================================================================================

"""Build one merged bounded campaign and return its directory and manifest path."""
function review_fixture()
    setup = shard_setup()
    ids = [task.task_id for task in setup.tasks]
    directory = mktempdir(prefix="oos_cr_merged_")
    report = merge_oos_shards(shard_campaign(setup, setup.tasks, 1), directory, ids)
    @assert report.merged
    manifest = joinpath(mktempdir(prefix="oos_cr_manifest_"), "structural_manifest.json")
    generate_structural_manifest(setup.base_config, setup.design, manifest;
                                 write_companions=false, verbose=false)
    return (directory=directory, manifest=manifest, setup=setup)
end

@testset "CR0 the freeze is verified, not asserted" begin
    fixture = review_fixture()
    review = review_campaign(fixture.directory, fixture.manifest)

    # The metadata already records both facts; the review's job is to refuse on them rather than
    # let a campaign quote a code version that is not in the history.
    #
    # The fixture is produced from the LIVE tree, whose cleanliness is not the test's to control,
    # so the assertion is on the mechanism in both directions rather than on today's state — it
    # must keep passing once the redesign is committed.
    @test !isempty(review.freeze.code_commit)
    dirty_blocked = any(issue -> occursin("code_dirty", issue), review.blocking)
    @test dirty_blocked == review.freeze.code_dirty

    # Threads are pinned to one per worker because the count changes CPLEX's tie-breaking among
    # equally optimal solutions; unpinned, the same shard differs across machines.
    @test review.freeze.solver_threads != 1
    @test any(issue -> occursin("hilos de solver", issue), review.blocking)
    @test !campaign_review_ready(review)
end

@testset "CR1 an unbalanced design is blocking, not a warning" begin
    fixture = review_fixture()
    review = review_campaign(fixture.directory, fixture.manifest)

    homogeneous = filter(c -> c.demand_regime == "HOMOGENEOUS", review.cells)
    heterogeneous = filter(c -> c.demand_regime == "HETEROGENEOUS", review.cells)
    @test length(homogeneous) == 4 && length(heterogeneous) == 4

    # `PEA` has no denominator when the whole window has zero community demand, which on this
    # instance happens only in the homogeneous regime at this horizon.
    @test all(cell -> "PEA" in cell.aborted_policies, homogeneous)
    @test all(cell -> isempty(cell.aborted_policies), heterogeneous)

    # Aborting EVERYWHERE would merely remove a policy. Aborting in only some cells silently
    # takes every comparison involving it over a different set of cells than the others, so it
    # is reported as its own defect and not folded into the per-cell counts.
    @test any(issue -> occursin("desbalanceado", issue) && occursin("PEA", issue),
              review.blocking)
end

@testset "CR2 a fairness residual is read against its own policy's tolerance" begin
    fixture = review_fixture()
    review = review_campaign(fixture.directory, fixture.manifest)

    # A lexicographic policy legitimately consumes `lex_eps_abs`, so its raw residual sits at
    # ~1.0 next to a physical residual of ~1e-14. Reported as one number that would read as a
    # gross violation; split, it is a policy using the tolerance it declares.
    @test review.numerics.lexicographic_residual > 0.9
    @test review.numerics.non_lexicographic_residual < 1e-6
    @test review.numerics.max_physical_residual < 1e-9

    # And the split must not manufacture a blocker out of the lexicographic allowance.
    @test !any(issue -> occursin("residuo de fairness", issue), review.blocking)
end

@testset "CR3 costs are reported crossed with every design dimension" begin
    fixture = review_fixture()
    write_campaign_analysis(fixture.directory, fixture.manifest)
    costs = CSV.read(joinpath(fixture.directory, "campaign_cost_by_cell.csv"), DataFrame)

    # Plan section 7 names these explicitly. Pooling any of them away is the failure mode.
    for column in ("Controller", "Fairness", "Resource", "ObjectiveCriterion", "BatteryLevel",
                   "DemandRegime", "UncertaintyLevel", "ImplementationStep", "StructuralDraw")
        @test column in names(costs)
    end
    @test all(row -> row.ObjectiveCriterion == OOS_OBJECTIVE_CRITERION, eachrow(costs))

    # One row per (cell, controller, policy) that has completed runs — never a pooled row that
    # has already averaged a factor away.
    cell_keys = [(r.StructuralInstanceID, r.Controller, r.Fairness) for r in eachrow(costs)]
    @test length(unique(cell_keys)) == length(cell_keys)
    @test length(unique(costs.BatteryLevel)) == 2
    @test length(unique(costs.DemandRegime)) == 2
    @test length(unique(costs.UncertaintyLevel)) == 2
    # `PEA` aborted in the homogeneous cells, so it appears in fewer cells than the others.
    pea_cells = length(unique(filter(r -> r.Fairness == "PEA", costs).StructuralInstanceID))
    none_cells = length(unique(filter(r -> r.Fairness == "NONE", costs).StructuralInstanceID))
    @test pea_cells < none_cells
end

@testset "CR4 the paired effect is differenced inside the cell, then averaged" begin
    fixture = review_fixture()
    write_campaign_analysis(fixture.directory, fixture.manifest)
    paired = CSV.read(joinpath(fixture.directory, "campaign_paired_by_cell.csv"), DataFrame)
    replications = CSV.read(joinpath(fixture.directory, "replication_summary.csv"), DataFrame)

    row = first(filter(r -> r.Fairness == "NONE" &&
                            r.Baseline == "DETERMINISTIC_RH" &&
                            r.Comparison == "MULTISTAGE_RH", paired))
    cell = row.StructuralInstanceID
    matching = filter(
        r -> String(r.StructuralInstanceID) == cell && String(r.Fairness) == "NONE" &&
             r.CompletionStatus == "completed",
        replications,
    )
    costs = Dict(
        (String(r.Controller), Int(r.Replication)) => Float64(r.TotalOperatingCost)
        for r in eachrow(matching))
    ids = sort(unique(Int.(matching.Replication)))
    differences = [costs[("MULTISTAGE_RH", i)] - costs[("DETERMINISTIC_RH", i)] for i in ids]

    @test row.PairedObservations == length(differences)
    @test isapprox(row.MeanDifference, sum(differences) / length(differences); atol=1e-9)

    # The mean of the differences equals the difference of the means, so the mean alone cannot
    # tell the two orderings apart. The STANDARD ERROR can: the paired one is built from the
    # differences and is smaller than the unpaired one exactly when the trajectories are the
    # common factor the design pairs on. This is the assertion that the pairing is real.
    n = length(differences)
    mean_difference = sum(differences) / n
    paired_sd = sqrt(sum((d - mean_difference)^2 for d in differences) / (n - 1))
    @test isapprox(row.StdDifference, paired_sd; atol=1e-9)
    @test isapprox(row.StandardError, paired_sd / sqrt(n); atol=1e-9)

    # The spread an UNPAIRED analysis would report, from the two groups treated as independent.
    # Asserting an inequality between them would be a claim about this fixture's covariance, so
    # the check is exact instead: whenever the two figures differ, the reported one must be the
    # paired figure.
    base = [costs[("DETERMINISTIC_RH", i)] for i in ids]
    comparison = [costs[("MULTISTAGE_RH", i)] for i in ids]
    unpaired = sqrt(
        (sum((x - sum(base) / n)^2 for x in base) +
         sum((x - sum(comparison) / n)^2 for x in comparison)) / (n - 1))
    if !isapprox(paired_sd, unpaired; atol=1e-9)
        @test !isapprox(row.StdDifference, unpaired; atol=1e-9)
    end
end

@testset "CR5 the merge refuses to call a blocked review ready" begin
    fixture = review_fixture()
    review = review_campaign(fixture.directory, fixture.manifest)
    # The dataset is well-formed AND unfit at the same time. That pair of verdicts is the whole
    # point of keeping the review separate from the schema validator: a campaign that passed
    # validation would otherwise look ready to scale up.
    @test isempty(blocking_issues(validate_output_directory(fixture.directory)))
    @test !campaign_review_ready(review)
    @test !isempty(review.blocking)
end
