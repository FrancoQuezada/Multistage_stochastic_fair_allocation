# Scenario equity analysis

Audit and execution date: 2026-10-09 (Europe/Paris). 400/400 target policy configurations have validated scenario analyses; 400 pass all available archived input checks.

The historical household file reproduces **all 60 entries** in manuscript Tables 5 and 6 within the two-decimal rounding interval. Full original scenario decisions were not retained. The historical seed convention was recovered: its hash omits the later DemandProfile field. With Julia 1.12.6, this convention reproduces every recorded household demand and all-grid benchmark and every community PV total in all 80 configurations. The main reruns use these reconstructed inputs and the earlier continuous-battery formulation. Original optimal decisions, the original source revision, and all solver overrides remain unrecorded, so original scenario allocations cannot be certified as exact copies.

## Repository audit and provenance

The audit examined the full repository, active and archived Julia sources, shell runners, manuscript PDF, all results directories, ZIP contents, CSV headers, serialized snapshots, manifests, and git history. No applicable `AGENTS.md` was present in the repository or its ancestors. The initial working tree had only these user-owned untracked paths:

```
?? Equity_plots.png
?? Outout_oos_campaign.txt
?? results_oos/campaign/merged_partial/
```

Base working-tree revision: `a8871e94633f1899b77e23ff032ef8a0260d29c1`. Historical reference formulation: `c8e7a25b88cdae026bff575f92edf19a114d949e` (earliest tracked import). The exact commit and package versions used for the original runs were not recorded. The current formulation was changed by commit `0a751cf44aa17f7dab0bf5a6a653888bdd16db21`, introducing shared battery direction binaries; the primary reruns therefore load untouched copies of the earlier **continuous-battery** formulation from `reference_source/`. The OOS model adds additional rules and is excluded from this experiment.

`historical_file_hashes.csv` records 6,481 pre-existing files; `results_inventory.csv` records all historical result artifacts, sizes, checksums, CSV schemas, and archive members. Preservation check: **True**; changed historical files: `[]`. `analysis_source_hashes.txt` pins the additive scripts and tests, since they remain uncommitted working-tree additions.

### Result sources and recovery classification

| Source | Contents | Recovery disposition |
| --- | --- | --- |
| `results_models/fairness_ALL_report_by_house_1024.csv` | 3,000 household expectations/extrema, 400 policy configurations | Expected outcomes reused; original joint scenarios require decisions that are missing (C) |
| `results_models/fairness_ALL_report_1024.csv` | 400 community summaries | Reproduces metadata; cannot reconstruct joint household scenarios |
| `results_models/fairness_ALL_report.csv`, `fairness_ALL_report_by_house.csv` | 1,200 summaries / 9,000 household rows over three trees; include the 1,024-scenario subset | Smaller-tree results outside the manuscript equity tables; no extra reruns |
| `archive_legacy/results/all_grid_expected_costs_S6_C4_P4.csv`, `expected_demand_by_house_S6_C4_P4.csv` | 600 expected benchmarks/demands each | Explain historical table enrichment; not raw instances |
| `results_models/fairness_comparison/consolidated/all_fairness_summary.csv`, `all_fairness_by_house.csv` | 232 summaries / 1,160 expected household rows | Different sampled files and policies; trees `2:2:12;6:4:4`, J=5, Theta=0.2; not manuscript table provenance |
| `results_models/fairness_comparison_smoke/consolidated/` | 16 summaries / 80 expected household rows | Different smoke design; expected outcomes only |
| `results_models/fairness_comparison.zip` | Copies of comparison CSVs/logs | No additional saved solutions |
| `results_models/conditional_fairness_validation/baseline_before.bin`, `baseline_after.bin` | Full p/I/G/z/y/s/cost arrays, all five policies, S=3,C=2,P=8,J=5,Theta=0.2,Drahi_1 | Recoverable (B), physical/economic identities verified |
| `results_models/static_demand_share_validation/existing_policies_before.bin`, `existing_policies_after.bin` | Overlapping snapshots with more policy labels | Original five policies recoverable (B), remaining labels excluded |
| `results_heuristics/`, `results_decomposicion/`, `results_sensitivity/`, `results_sensitivity_old/`, archived results | Expected values, extrema, diagnostics, plots and logs | No full decisions for the original equity ensemble |
| `results_oos/`, `results_oos_timing_probe/` | Realized rolling-horizon actions, replications, LP/MPS model exports | Excluded: OOS paths are not stochastic scenarios; model files do not contain solutions |

Category A (complete original in-sample scenario outputs): **none**. Category B: **five distinct policy solutions** recovered from 20 overlapping snapshot records, with 15 duplicates excluded. Category C for the manuscript design: **400 original policy solutions** lack decisions. The 20 snapshot records were individually checked before deduplication. No aggregate equity metric or marginal extrema were inverted.

## Experimental design, input reconstruction and provenance limits

The actual table source fixes ten files `Drahi_1.csv` through `Drahi_10.csv`, J in {5,10}, Theta in {0.2,0.6}, mean demand 100, demand standard deviation in {10,20}, and tree S:C:P=`6:4:4`. There are 24 time periods, 5,460 nodes and 1,024 leaves. This yields 80 configurations and 400 policy results: 40 configurations per uncertainty level per policy. Configurations, including all four J/demand-deviation variants per base file, receive equal weight; scenarios first receive their actual leaf probabilities. The ten base files are not 40 independent base days.

Policies are exactly `NONE` (NF), `PEA`, `SA`, `LEXMMFPEA` (MM PEA), `LEXMMFSA` (MM SA). The unmodified source implements expected-cost minimization for NONE/PEA/SA, lexicographic expected PV target LPs followed by a cost solve for MM PEA, and sequential lexicographic expected savings maximization for MM SA. No conditional policies or rolling-horizon controllers are included.

The manuscript's sigma is the generator's **Theta**: `pv_ms` uses `Normal(0,theta)` for PV innovations in the ARMA(1,1) recursion with coefficients 0.8 and 0.2. Demand uncertainty separately uses `Dev_d`. The source describes normal demand around 100 with deviation 10/20 and repairs demand where needed for PEA feasibility; this differs from the manuscript prose describing uniform demand from 4 to 9.2. The analysis follows the source data and does not rewrite the manuscript.

The current tracked deterministic seed formula adds DemandProfile to a 64-bit FNV-style hash. The reconstructed historical key is `InstanceFile|NBstage|Childs|Periods|J|Theta|Avg_d|Dev_d`, **without DemandProfile**, modulo `2^31-1`, plus one. The historical CSVs lack the later DemandProfile column, which motivated this diagnostic rather than a brute-force search. Agreement of all available input checks within the documented numerical tolerance supports the recovered convention. Seeds and input file SHA256 values are recorded in `config_manifest.csv`; the earlier failed seed convention is retained in `config_manifest_with_profile_seed.csv` and the supplementary manifest. A scoped seed override supplies the recovered seed to the unmodified generator's draw sequence; no optimization equations or source files are changed. Theta remains part of the seed, so changing sigma also changes price draws and household profile assignment under the historical source contract.

Initial probes using the **tracked, later hash containing DemandProfile** failed before optimization:

- Julia 1.12.6: 0/80 inputs match; maximum benchmark residual 395439.670125; maximum total-PV residual 1720.211614.
- Julia 1.8.1: 0/80 inputs match; maximum benchmark residual 395439.670125; maximum total-PV residual 1720.211614.

The missing historical seed field explains the discrepancy:

- Seed hash without DemandProfile, Julia 1.12.6: 80/80 historical benchmark/PV checks pass.
- Seed hash without DemandProfile, Julia 1.8.1: 10/80 historical benchmark/PV checks pass.

The final input gate checks every household expected demand, every household all-grid benchmark, and the community expected PV total. It passes **80/80** configurations. Julia 1.12.6 uses the existing repository environment. The supplementary Julia 1.8.1 compatibility environment was used only for provenance probes, leaving the repository `Project.toml` and `Manifest.toml` unchanged. The manuscript's stated Julia 1.8.1 runtime does not reproduce the complete historical ensemble with the available generator. Available moment checks do not constitute independent hashes of the unsaved original node arrays; original node arrays and solver-selected allocations are still unavailable.

Primary rerun dataset: `manuscript_design_rerun`, using the recovered historical seed convention. A partial supplementary dataset, `reproducible_same_numeric_design`, used the later DemandProfile hash before the historical convention was recovered; its completed solutions are retained and excluded from the primary ensemble. Recovered fixture dataset: `recovered_validation_snapshot`; expected-only historical dataset: `historical_expected_only`. Dataset identifiers prevent combining these as independent observations. The supplementary batch was stopped once recovery made additional solves under the later seed convention unnecessary.

Physical parameters are unchanged: delta=1, s_max=63, s_min=s_I=0.2, e_c=e_d=0.95, aggregate charge/discharge limits=4, mu=5, beta=10, common household price draws from `1615.1:2228.1` divided by 10, battery/PV scales=1, mixed demand profiles. `pv_det` sums each block of four input PV samples and multiplies by 300/1000, exactly as in the source. Outputs retain this model unit convention; the analysis does not correct the source's PV sampling/scaling convention or reinterpret it as separately calibrated physical units.

Solver environment: `JuliaVersion=1.12.6
CPLEXVersion=22.1.1.0
Threads=1
TimeLimit=source_default
FairnessTolerance=source_default`. Thread count=1 is verified on the CPLEX optimizer. Solver feasibility/optimality tolerances remain the installed CPLEX defaults. The ordinary cost model keeps its 3,600-second limit; lexicographic routines keep their source defaults. SA uses tolerance 0 for the target design, following the earliest tracked shell runner; the recovered fixture used the function default 1. Lexicographic absolute tolerance is 1. The historical execution does not record overrides, so these source defaults cannot establish exact original tolerances.

## Extraction definitions and validity

For the complete leaf-to-root path N(omega), the output uses:

```
P[j,omega] = delta * sum(p[j,n])
B[j,omega] = delta * sum(nu[j,t(n)] * d[j,n])
K[j,omega] = delta * sum(mu*y[j,n] + nu[j,t(n)]*I[j,n] - beta*G[j,n])
S[j,omega] = B[j,omega] - K[j,omega]
E[P[j]] = sum(pi[omega] * P[j,omega])
E[S[j]] = sum(pi[omega] * S[j,omega])
```

Demand, grid import/export, battery charge/discharge are likewise delta times the path sums. The operating cost and benchmark match `multi.jl` exactly. The source's comparison PV expectation omits delta; generated instances have delta=1, so historical results agree. The new pipeline includes delta, and a nonunit-delta arithmetic test documents the corrected convention without altering old outputs.

```
Jain(x) = sum(x)^2 / (J * sum(x^2))
Gini(x) = sum_i sum_j abs(x[i]-x[j]) / (2 * J * sum(x))
MaxMin(x) = maximum(x) / minimum(x)
```

As in `fairness_comparison_metrics.jl`, negative outcomes invalidate Jain and Gini; this analysis also invalidates MaxMin on negative outcomes. There is **no clipping of negative savings**. All-zero or uniformly negligible vectors produce missing metrics, unlike the archived Python table builder's all-zero defaults (Jain=1,Gini=0,MaxMin=1). For nonnegative vectors containing a zero, Jain/Gini are defined when the vector has nonnegligible mass, but MaxMin is missing. The numerical minimum/vector threshold is an explicit absolute `1e-10` model-outcome units; no denominator is regularized. Every invalid metric records a reason, metric-specific validity flags, and actual outcome minima/maxima. Nonfinite values are diagnosed. Jain/Gini computations scale by the vector maximum solely to avoid arithmetic overflow.

`EquityOfExpectedOutcomes` applies the metric to expected household values. `ExpectedScenarioEquity` is the unnormalized probability integral of scenario metrics and is **missing if any positive-probability scenario has an undefined metric**. Undefined zero-probability scenarios do not affect the expectation. `ValidContribution`, valid/missing probability mass, and explicitly named `ConditionalValidMean` describe the valid subset separately. No partial valid-subset average is labeled an unconditional expectation.

The archived table builder requires strictly positive savings for all three metrics and averages over valid instances: NF excludes two of 40 low-sigma configurations and three of 40 high-sigma configurations due to negative expected savings. This historical convention is reproduced explicitly, with exclusion counts. The new analysis uses per-metric validity and retains undefined instance/scenario mass rather than hiding it.

Scenario dispersion uses the population, probability-weighted standard deviation within each instance. Scenario quantiles use the inverse weighted empirical CDF at 5,25,50,75,95 percent, with conditional-valid names if any scenario metric is missing. The primary summary then takes equal-weight means of the separate instance summaries and sample standard deviations of the instance means. Strict across-instance means are missing if any constituent is undefined; separately named conditional-valid-instance means report descriptive valid-subset results and counts. Min/max are supplied both as mean per-instance extrema and global valid extrema. There is no unnamed pooling of scenarios across instances.

## Outputs and execution accounting

All outputs are in `results_models/scenario_equity/`. Historical output files and the manuscript remain unchanged.

| File | Row definition / important schema |
| --- | --- |
| `scenario_household_results.csv` | Dataset x ConfigID x Fairness x Scenario x House; required PV/demand/grid/battery energies, benchmark/cost/savings, shares, leaf probability, status and full design metadata |
| `scenario_equity_metrics.csv` | Dataset x ConfigID x Fairness x Scenario; all six metrics, minima/maxima, totals, per-metric validity flags/reasons and scenario probability |
| `expected_household_results.csv` | Dataset x ConfigID x Fairness x House; includes the 3,000 reused historical expectations, recovered expectations and new solved outcomes, benchmark and cost |
| `equity_summary.csv` | Dataset x Sigma x Fairness x Resource; all three metrics with ex-ante and scenario expectations, scenario std/extrema/quantiles, across-instance variability, missing mass and counts |
| `instance_equity_summary.csv` | Dataset x ConfigID x Fairness x Resource x Metric; primary weighted instance results, valid contribution/mass and ex-ante minus scenario expectation |
| `historical_expected_household_results.csv`, `historical_instance_equity.csv` | Historical expected data and historical-table-convention per-instance metrics, recovered without optimization |
| `manuscript_comparison.csv` | All 60 manuscript values, recomputations, absolute/relative differences, rounding tolerance, validity counts and status |
| `rerun_historical_comparison.csv` | Per-instance new versus old equity and objective differences; dataset distinguishes matched-input primary and different-input supplementary solves |
| `rerun_manuscript_comparison.csv` | Primary rerun ex-ante means versus manuscript values; supplementary means remain explicitly marked `NOT_EXACT_REPLICATION_INPUT_MISMATCH` |
| `validation_results.csv`, `validation_tests.log` | Extraction residuals and the complete validation test output |
| `execution_status.csv`, `execution_failures.csv` | All 400 targets, completion/dataset/original-input flags, pending models and precise execution failures |
| `execution_workers.csv`, `execution_workers_initial_two.csv`, `worker_handoff.txt`, `rebalance_checkpoint_handoff.txt` | Disjoint worker ranges, one solver thread each, and checkpoint-preserving handoffs from the initial serial job and two-worker continuation |
| `snapshot_recovery_provenance.csv`, `optimization_provenance.csv`, `solver_quality.csv` | Recovered/duplicate decisions, solve/reuse accounting, runtime/seed/source/decision hashes, identical policy-input verification and recorded solver termination evidence |
| `solver_parameters.csv` | Installed CPLEX defaults queried through its native API and source/manifest overrides; original undocumented overrides are not inferred |
| `export_verification.json`, `export_verification.log` | Independent streaming CSV verification and row counts by dataset |
| `primary_metric_invalidity_diagnostics.json`, `resume_verification.json` | Export-derived causes of missing max-min-policy Jain metrics and the recorded five-policy resume check |
| `config_manifest.csv`, `reproducible_config_manifest.csv`, `input_validation*.csv` | Recovered design, explicitly identified fallback design, seeds/input hashes and failed original-input probes |
| `shards/<dataset>/<ConfigID>/<Fairness>/` | Incremental portable instance/solution checkpoint, CSVs, solver log, validation and completion checksums |

Policy configurations reused without optimization: **five distinct saved fixture solutions**, plus all **3,000 historical expected household rows** for table reproduction. Primary policy configurations newly solved and validated: **400**. Archived input checks verified for these new solves: **400**. Supplementary policy solutions completed under the later seed convention: **33**; these are retained separately and excluded from the target completion count. Saved overlapping snapshots are not independent instances. No OOS runs or heuristic solves were substituted. Lexicographic policies naturally include their original sequence of inner LP solves within one policy execution.

Full instance/decision arrays are saved before extraction; extraction failures can therefore resume from the checkpoint without re-solving. Completion markers are created only after validation and checksum every required shard file. Completed policies are skipped. The shell wrapper uses a writer lock and single-thread limits; the script preserves the exact original model source. Large consolidated scenario CSVs are streamed, avoiding materialization of all household scenarios in memory. Solver logs preserve termination evidence: boolean `Status` means primal availability, while `solver_quality.csv` identifies the statuses actually exported by source. All 433 rerun logs checked: 433 report optimal recorded stages. MM PEA's target LP statuses are not separately exported by the original source.

Provenance runtime columns are explicitly named `SourceReportedSolverTimeSeconds` and `SourceReportedPolicyTimeSeconds`. They retain `SolutionM.time` and `SolutionM.run_time`; they are not independently measured end-to-end durations. In particular, MM PEA's original `run_time` adds target-generation time to a timer that already includes it, so this field double-counts that component. No timing claim or equity result relies on these fields.

After the initial serial run, a completed solution checkpoint was retained at the recorded handoff and used for extraction on resume. The next continuation used two controlled workers, with disjoint ranges M001–M040 and M041–M080 and one CPLEX thread per worker. Once a workload imbalance became apparent, both workers stopped only after their active policy solutions had been atomically saved; the handoff record includes the saved binary hashes. The final continuation uses **four bounded workers** with disjoint ranges M001–M040, M041–M064, M065–M072 and M073–M080, one CPLEX thread each. The resource check recorded 16 available CPUs and approximately 22 GB available memory before adding the workers. No completed optimization is repeated during either handoff. Each worker has its own output directory and writer lock; reused shard-directory aliases contain disjoint configuration ranges. The campaign coordinator holds a global lock, waits for all workers, collects the worker shards without overwriting existing artifacts, and verifies identical generated inputs across policies. Retained shard-directory aliases keep recorded source paths valid. The coordinators invoke the same pinned solver/model code and add no model constraints.

Pending targets: **0**. Every target configuration has a validated analysis in its declared dataset.
Recorded current failures: **0**. No current solver or extraction failures.
The original selected scenario decisions remain unavailable for all 400 historical policies. Main reruns reconstruct inputs and produce new validated optimization solutions; they do not recover unsaved original optimizer choices.

## Validation

The extraction suite passed **7,114 checks**. It uses saved optimization decisions on the small stochastic instance rather than wasting solves, and checks every overlapping snapshot. It covers all 13 requested conditions: probabilities sum to one; complete parent-linked paths/time indices; expected PV; expected savings; solution costs; scenario/node PV conservation; Jain/Gini bounds; MaxMin and strictly positive denominators; identical vectors; ex-ante versus scenario metrics on a synthetic example; zero/negative/nonfinite outcomes; unchanged decision checksums; and unchanged historical files. Additional tests exercise unequal leaf probabilities, delta=0.5 arithmetic, invalid probability trees, valid-subset missing mass, weighted quantiles, and equal configuration weighting.

Physical/economic extraction validation passed for **438** available policy solutions. Validation tolerances: absolute `1e-6`, relative `1e-9` for expected quantities; probability/path checks `1e-10`. Node balance, SOC bounds/transitions/terminal state, charge/discharge rates and nonnegative decisions are independently checked. The original continuous-battery model's permitted simultaneous flows are retained; the newer binary formulation is not imposed on old solutions. Source arrays are hashed before and after extraction. PEA and SA expectation residuals are checked against their configured tolerance.

Checkpoint provenance verification covers **438** solutions and checks that every policy under a given dataset/configuration uses an identical full generated-instance digest. Independent streaming export verification: **True**. It checks the actual CSV key coverage, raw savings and signed shares, all six metrics and their validity flags, scenario totals/extrema, probability-weighted household expectations, ex-ante metrics, strict scenario expectations, missing probability mass and weighted standard deviations. This verification does not invoke optimization.

The explicit M001 resume check passed: **True**. It skipped all five validated policies, launched no optimization, and retained identical saved-solution binary hashes. Its before-hash record and execution log are retained alongside the result.

```json
{
  "manuscript_design_rerun": {
    "PolicySolutions": 400,
    "Scenarios": 409600,
    "HouseholdScenarios": 3072000,
    "MinimumScenarioProbability": 0.0009765625,
    "MaximumScenarioProbability": 0.0009765625
  },
  "recovered_validation_snapshot": {
    "PolicySolutions": 5,
    "Scenarios": 20,
    "HouseholdScenarios": 100,
    "MinimumScenarioProbability": 0.25,
    "MaximumScenarioProbability": 0.25
  },
  "reproducible_same_numeric_design": {
    "PolicySolutions": 33,
    "Scenarios": 33792,
    "HouseholdScenarios": 235520,
    "MinimumScenarioProbability": 0.0009765625,
    "MaximumScenarioProbability": 0.0009765625
  }
}
```

| Maximum extraction residual | Value |
| --- | --- |
| ExpectedPVResidual | 1.00044e-11 |
| ExpectedSavingsResidual | 5.25033e-08 |
| SolutionCostResidual | 5.29108e-08 |
| ScenarioPVConservationResidual | 1.92358e-10 |
| NodeBalanceResidual | 6.96332e-13 |
| SOCTransitionResidual | 8.77631e-14 |
| FairnessResidual | 5.80621e-09 |

## Reproduction of manuscript Tables 5 and 6

Source: `codes/docs/Multistage_stochastic_fair_energy_allocation-25.pdf`, Tables 5/6, pages 26/27. Table entry validation uses absolute tolerance `0.005 + 1e-10`, representing two-decimal rounding; relative difference is undefined when the manuscript value is zero. All 60/60 comparisons pass. Recomputed values use the historical script's explicitly documented valid-instance convention. Source `archive_legacy/results/equity_tables_1024.md` instead combines both sigmas; stratifying the same household data by Theta produces the two manuscript tables.

| Sigma | Policy | Resource | Metric | Manuscript | Recomputed | Abs. diff. | Rel. diff. | Valid/total | Status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0.2 | LEXMMFPEA | PV | Jain | 1 | 0.99999361 | 0.00000639 | 0.00000639 | 40/40 | PASS_ROUNDING |
| 0.2 | LEXMMFPEA | PV | Gini | 0 | 0.00088093 | 0.00088093 | undefined | 40/40 | PASS_ROUNDING |
| 0.2 | LEXMMFPEA | PV | MaxMin | 1.01 | 1.00659394 | 0.00340606 | 0.00337234 | 40/40 | PASS_ROUNDING |
| 0.2 | LEXMMFPEA | Savings | Jain | 0.74 | 0.74135336 | 0.00135336 | 0.00182887 | 40/40 | PASS_ROUNDING |
| 0.2 | LEXMMFPEA | Savings | Gini | 0.29 | 0.28671022 | 0.00328978 | 0.01134407 | 40/40 | PASS_ROUNDING |
| 0.2 | LEXMMFPEA | Savings | MaxMin | 5.15 | 5.14924151 | 0.00075849 | 0.00014728 | 40/40 | PASS_ROUNDING |
| 0.2 | LEXMMFSA | PV | Jain | 0.69 | 0.68572119 | 0.00427881 | 0.00620117 | 40/40 | PASS_ROUNDING |
| 0.2 | LEXMMFSA | PV | Gini | 0.34 | 0.33530581 | 0.00469419 | 0.01380644 | 40/40 | PASS_ROUNDING |
| 0.2 | LEXMMFSA | PV | MaxMin | 6.69 | 6.68792492 | 0.00207508 | 0.00031018 | 40/40 | PASS_ROUNDING |
| 0.2 | LEXMMFSA | Savings | Jain | 1 | 0.99999994 | 0.00000006 | 0.00000006 | 40/40 | PASS_ROUNDING |
| 0.2 | LEXMMFSA | Savings | Gini | 0 | 0.00010798 | 0.00010798 | undefined | 40/40 | PASS_ROUNDING |
| 0.2 | LEXMMFSA | Savings | MaxMin | 1 | 1.00050288 | 0.00050288 | 0.00050288 | 40/40 | PASS_ROUNDING |
| 0.2 | NONE | PV | Jain | 0.53 | 0.52614176 | 0.00385824 | 0.00727969 | 40/40 | PASS_ROUNDING |
| 0.2 | NONE | PV | Gini | 0.48 | 0.47622427 | 0.00377573 | 0.00786609 | 40/40 | PASS_ROUNDING |
| 0.2 | NONE | PV | MaxMin | 47.22 | 47.21956540 | 0.00043460 | 0.00000920 | 40/40 | PASS_ROUNDING |
| 0.2 | NONE | Savings | Jain | 0.54 | 0.54081858 | 0.00081858 | 0.00151589 | 38/40 | PASS_ROUNDING |
| 0.2 | NONE | Savings | Gini | 0.46 | 0.46399287 | 0.00399287 | 0.00868015 | 38/40 | PASS_ROUNDING |
| 0.2 | NONE | Savings | MaxMin | 28.38 | 28.37960348 | 0.00039652 | 0.00001397 | 38/40 | PASS_ROUNDING |
| 0.2 | PEA | PV | Jain | 0.98 | 0.98151229 | 0.00151229 | 0.00154316 | 40/40 | PASS_ROUNDING |
| 0.2 | PEA | PV | Gini | 0.04 | 0.03672919 | 0.00327081 | 0.08177013 | 40/40 | PASS_ROUNDING |
| 0.2 | PEA | PV | MaxMin | 1.28 | 1.28249317 | 0.00249317 | 0.00194779 | 40/40 | PASS_ROUNDING |
| 0.2 | PEA | Savings | Jain | 0.71 | 0.70597585 | 0.00402415 | 0.00566781 | 40/40 | PASS_ROUNDING |
| 0.2 | PEA | Savings | Gini | 0.31 | 0.31190724 | 0.00190724 | 0.00615240 | 40/40 | PASS_ROUNDING |
| 0.2 | PEA | Savings | MaxMin | 6.38 | 6.38432034 | 0.00432034 | 0.00067717 | 40/40 | PASS_ROUNDING |
| 0.2 | SA | PV | Jain | 0.66 | 0.66224918 | 0.00224918 | 0.00340785 | 40/40 | PASS_ROUNDING |
| 0.2 | SA | PV | Gini | 0.35 | 0.34911812 | 0.00088188 | 0.00251964 | 40/40 | PASS_ROUNDING |
| 0.2 | SA | PV | MaxMin | 7.74 | 7.74430093 | 0.00430093 | 0.00055568 | 40/40 | PASS_ROUNDING |
| 0.2 | SA | Savings | Jain | 0.93 | 0.92889337 | 0.00110663 | 0.00118992 | 40/40 | PASS_ROUNDING |
| 0.2 | SA | Savings | Gini | 0.08 | 0.08051244 | 0.00051244 | 0.00640556 | 40/40 | PASS_ROUNDING |
| 0.2 | SA | Savings | MaxMin | 1.83 | 1.82950406 | 0.00049594 | 0.00027100 | 40/40 | PASS_ROUNDING |
| 0.6 | LEXMMFPEA | PV | Jain | 1 | 0.99999297 | 0.00000703 | 0.00000703 | 40/40 | PASS_ROUNDING |
| 0.6 | LEXMMFPEA | PV | Gini | 0 | 0.00081818 | 0.00081818 | undefined | 40/40 | PASS_ROUNDING |
| 0.6 | LEXMMFPEA | PV | MaxMin | 1.01 | 1.00651727 | 0.00348273 | 0.00344825 | 40/40 | PASS_ROUNDING |
| 0.6 | LEXMMFPEA | Savings | Jain | 0.73 | 0.72737740 | 0.00262260 | 0.00359261 | 40/40 | PASS_ROUNDING |
| 0.6 | LEXMMFPEA | Savings | Gini | 0.31 | 0.31186863 | 0.00186863 | 0.00602784 | 40/40 | PASS_ROUNDING |
| 0.6 | LEXMMFPEA | Savings | MaxMin | 6.42 | 6.41826601 | 0.00173399 | 0.00027009 | 40/40 | PASS_ROUNDING |
| 0.6 | LEXMMFSA | PV | Jain | 0.65 | 0.64929936 | 0.00070064 | 0.00107791 | 40/40 | PASS_ROUNDING |
| 0.6 | LEXMMFSA | PV | Gini | 0.38 | 0.37736092 | 0.00263908 | 0.00694494 | 40/40 | PASS_ROUNDING |
| 0.6 | LEXMMFSA | PV | MaxMin | 7.98 | 7.97707211 | 0.00292789 | 0.00036690 | 40/40 | PASS_ROUNDING |
| 0.6 | LEXMMFSA | Savings | Jain | 1 | 0.99999993 | 0.00000007 | 0.00000007 | 40/40 | PASS_ROUNDING |
| 0.6 | LEXMMFSA | Savings | Gini | 0 | 0.00010785 | 0.00010785 | undefined | 40/40 | PASS_ROUNDING |
| 0.6 | LEXMMFSA | Savings | MaxMin | 1 | 1.00052672 | 0.00052672 | 0.00052672 | 40/40 | PASS_ROUNDING |
| 0.6 | NONE | PV | Jain | 0.52 | 0.52324460 | 0.00324460 | 0.00623962 | 40/40 | PASS_ROUNDING |
| 0.6 | NONE | PV | Gini | 0.48 | 0.48416448 | 0.00416448 | 0.00867600 | 40/40 | PASS_ROUNDING |
| 0.6 | NONE | PV | MaxMin | 65.35 | 65.35010516 | 0.00010516 | 0.00000161 | 40/40 | PASS_ROUNDING |
| 0.6 | NONE | Savings | Jain | 0.53 | 0.52562038 | 0.00437962 | 0.00826344 | 37/40 | PASS_ROUNDING |
| 0.6 | NONE | Savings | Gini | 0.48 | 0.48246093 | 0.00246093 | 0.00512695 | 37/40 | PASS_ROUNDING |
| 0.6 | NONE | Savings | MaxMin | 30.12 | 30.12476913 | 0.00476913 | 0.00015834 | 37/40 | PASS_ROUNDING |
| 0.6 | PEA | PV | Jain | 0.96 | 0.95580232 | 0.00419768 | 0.00437259 | 40/40 | PASS_ROUNDING |
| 0.6 | PEA | PV | Gini | 0.07 | 0.07311545 | 0.00311545 | 0.04450642 | 40/40 | PASS_ROUNDING |
| 0.6 | PEA | PV | MaxMin | 1.53 | 1.53050692 | 0.00050692 | 0.00033132 | 40/40 | PASS_ROUNDING |
| 0.6 | PEA | Savings | Jain | 0.67 | 0.67078887 | 0.00078887 | 0.00117742 | 40/40 | PASS_ROUNDING |
| 0.6 | PEA | Savings | Gini | 0.35 | 0.35339140 | 0.00339140 | 0.00968972 | 40/40 | PASS_ROUNDING |
| 0.6 | PEA | Savings | MaxMin | 11.75 | 11.74887231 | 0.00112769 | 0.00009597 | 40/40 | PASS_ROUNDING |
| 0.6 | SA | PV | Jain | 0.67 | 0.66882544 | 0.00117456 | 0.00175307 | 40/40 | PASS_ROUNDING |
| 0.6 | SA | PV | Gini | 0.35 | 0.35240911 | 0.00240911 | 0.00688318 | 40/40 | PASS_ROUNDING |
| 0.6 | SA | PV | MaxMin | 9.21 | 9.21368080 | 0.00368080 | 0.00039965 | 40/40 | PASS_ROUNDING |
| 0.6 | SA | Savings | Jain | 0.85 | 0.85337203 | 0.00337203 | 0.00396710 | 40/40 | PASS_ROUNDING |
| 0.6 | SA | Savings | Gini | 0.16 | 0.16471712 | 0.00471712 | 0.02948199 | 40/40 | PASS_ROUNDING |
| 0.6 | SA | Savings | MaxMin | 3.08 | 3.08372922 | 0.00372922 | 0.00121078 | 40/40 | PASS_ROUNDING |

## Ex-ante versus scenario equity

The following summaries apply **only to the primary reruns with the recovered historical seed convention**, with each metric first aggregated using each instance's leaf probabilities. Ex-ante values shown are the explicitly conditional mean across valid instances; their valid/total counts are shown, and strict full-ensemble means remain in `equity_summary.csv`. The unconditional expected scenario metric is undefined if any instance has undefined positive-probability scenarios. The next column is a separately labeled mean of per-instance conditional-valid-scenario means; it must not be interpreted as an expectation over all scenarios. Missing probability is averaged with equal configuration weight. All three metrics are compared below for both resources; quantiles and standard deviations are in the summary and instance CSVs. Supplementary later-seed results are excluded.

| Sigma | Policy | Resource | Metric | Ex-ante valid/total instances | Ex-ante equity (valid instances) | E[scenario metric], strict | Conditional valid-scenario metric | Missing probability |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0.2 | LEXMMFPEA | PV | Jain | 40/40 | 1.00000 | 0.75736 | 0.75736 | 0.000% |
| 0.2 | LEXMMFPEA | PV | Gini | 40/40 | 0.00000 | 0.30165 | 0.30165 | 0.000% |
| 0.2 | LEXMMFPEA | PV | MaxMin | 40/40 | 1.00000 | undefined | 47.07813 | 20.518% |
| 0.2 | LEXMMFPEA | Savings | Jain | 40/40 | 0.74014 | undefined | 0.64090 | 8.804% |
| 0.2 | LEXMMFPEA | Savings | Gini | 40/40 | 0.29649 | undefined | 0.39772 | 8.804% |
| 0.2 | LEXMMFPEA | Savings | MaxMin | 40/40 | 8.54505 | undefined | 82.59563 | 19.954% |
| 0.2 | LEXMMFSA | PV | Jain | 40/40 | 0.65892 | 0.55418 | 0.55418 | 0.000% |
| 0.2 | LEXMMFSA | PV | Gini | 40/40 | 0.35292 | 0.46610 | 0.46610 | 0.000% |
| 0.2 | LEXMMFSA | PV | MaxMin | 40/40 | 7.90769 | undefined | undefined | 49.414% |
| 0.2 | LEXMMFSA | Savings | Jain | 40/40 | 1.00000 | undefined | 0.77543 | 45.254% |
| 0.2 | LEXMMFSA | Savings | Gini | 40/40 | 0.00011 | undefined | 0.28632 | 45.254% |
| 0.2 | LEXMMFSA | Savings | MaxMin | 40/40 | 1.00052 | undefined | undefined | 48.645% |
| 0.2 | NONE | PV | Jain | 40/40 | 0.47240 | 0.44483 | 0.44483 | 0.000% |
| 0.2 | NONE | PV | Gini | 40/40 | 0.52130 | 0.56218 | 0.56218 | 0.000% |
| 0.2 | NONE | PV | MaxMin | 39/40 | 84.27264 | undefined | undefined | 53.242% |
| 0.2 | NONE | Savings | Jain | 38/40 | 0.48591 | undefined | undefined | 27.776% |
| 0.2 | NONE | Savings | Gini | 38/40 | 0.50866 | undefined | undefined | 27.776% |
| 0.2 | NONE | Savings | MaxMin | 38/40 | 100.89074 | undefined | undefined | 43.706% |
| 0.2 | PEA | PV | Jain | 40/40 | 0.98151 | 0.75184 | 0.75184 | 0.000% |
| 0.2 | PEA | PV | Gini | 40/40 | 0.03673 | 0.30746 | 0.30746 | 0.000% |
| 0.2 | PEA | PV | MaxMin | 40/40 | 1.28249 | undefined | 40.56654 | 21.270% |
| 0.2 | PEA | Savings | Jain | 40/40 | 0.70515 | undefined | 0.61442 | 5.725% |
| 0.2 | PEA | Savings | Gini | 40/40 | 0.32049 | undefined | 0.41673 | 5.725% |
| 0.2 | PEA | Savings | MaxMin | 40/40 | 11.09632 | undefined | 77.49700 | 21.086% |
| 0.2 | SA | PV | Jain | 40/40 | 0.66401 | 0.50799 | 0.50799 | 0.000% |
| 0.2 | SA | PV | Gini | 40/40 | 0.35239 | 0.51446 | 0.51446 | 0.000% |
| 0.2 | SA | PV | MaxMin | 40/40 | 8.39745 | undefined | 103.61154 | 60.098% |
| 0.2 | SA | Savings | Jain | 40/40 | 0.92889 | undefined | 0.61532 | 51.040% |
| 0.2 | SA | Savings | Gini | 40/40 | 0.08051 | undefined | 0.41278 | 51.040% |
| 0.2 | SA | Savings | MaxMin | 40/40 | 1.82950 | undefined | 81.27915 | 55.532% |
| 0.6 | LEXMMFPEA | PV | Jain | 40/40 | 1.00000 | undefined | 0.66795 | 0.264% |
| 0.6 | LEXMMFPEA | PV | Gini | 40/40 | 0.00000 | undefined | 0.37994 | 0.264% |
| 0.6 | LEXMMFPEA | PV | MaxMin | 40/40 | 1.00000 | undefined | 62.47502 | 33.301% |
| 0.6 | LEXMMFPEA | Savings | Jain | 39/40 | 0.72454 | undefined | 0.61672 | 21.187% |
| 0.6 | LEXMMFPEA | Savings | Gini | 39/40 | 0.31822 | undefined | 0.42329 | 21.187% |
| 0.6 | LEXMMFPEA | Savings | MaxMin | 39/40 | 9.12209 | undefined | 79.05272 | 33.562% |
| 0.6 | LEXMMFSA | PV | Jain | 40/40 | 0.60112 | undefined | 0.47134 | 0.264% |
| 0.6 | LEXMMFSA | PV | Gini | 40/40 | 0.40096 | undefined | 0.53870 | 0.264% |
| 0.6 | LEXMMFSA | PV | MaxMin | 40/40 | 9.29681 | undefined | undefined | 57.529% |
| 0.6 | LEXMMFSA | Savings | Jain | 40/40 | 1.00000 | undefined | 0.74837 | 48.303% |
| 0.6 | LEXMMFSA | Savings | Gini | 40/40 | 0.00011 | undefined | 0.30927 | 48.303% |
| 0.6 | LEXMMFSA | Savings | MaxMin | 40/40 | 1.00055 | undefined | 30.21697 | 53.503% |
| 0.6 | NONE | PV | Jain | 40/40 | 0.49685 | undefined | 0.45596 | 0.264% |
| 0.6 | NONE | PV | Gini | 40/40 | 0.51212 | undefined | 0.56445 | 0.264% |
| 0.6 | NONE | PV | MaxMin | 38/40 | 59.14142 | undefined | undefined | 60.176% |
| 0.6 | NONE | Savings | Jain | 36/40 | 0.50488 | undefined | 0.47960 | 38.542% |
| 0.6 | NONE | Savings | Gini | 36/40 | 0.50445 | undefined | 0.53681 | 38.542% |
| 0.6 | NONE | Savings | MaxMin | 36/40 | 608.58267 | undefined | undefined | 53.162% |
| 0.6 | PEA | PV | Jain | 40/40 | 0.95580 | undefined | 0.66180 | 0.264% |
| 0.6 | PEA | PV | Gini | 40/40 | 0.07312 | undefined | 0.38700 | 0.264% |
| 0.6 | PEA | PV | MaxMin | 40/40 | 1.53051 | undefined | 63.25502 | 33.379% |
| 0.6 | PEA | Savings | Jain | 39/40 | 0.66728 | undefined | 0.58181 | 19.810% |
| 0.6 | PEA | Savings | Gini | 39/40 | 0.35985 | undefined | 0.45131 | 19.810% |
| 0.6 | PEA | Savings | MaxMin | 39/40 | 12.85940 | undefined | 117.80556 | 33.401% |
| 0.6 | SA | PV | Jain | 40/40 | 0.66386 | undefined | 0.42491 | 0.264% |
| 0.6 | SA | PV | Gini | 40/40 | 0.36134 | undefined | 0.59206 | 0.264% |
| 0.6 | SA | PV | MaxMin | 40/40 | 9.75685 | undefined | undefined | 68.506% |
| 0.6 | SA | Savings | Jain | 40/40 | 0.85337 | undefined | 0.54752 | 55.491% |
| 0.6 | SA | Savings | Gini | 40/40 | 0.16472 | undefined | 0.47404 | 55.491% |
| 0.6 | SA | Savings | MaxMin | 40/40 | 3.08373 | undefined | 170.45474 | 60.542% |

The following export-derived diagnostics identify why the max-min-policy Jain expectations are missing. A negative outcome below `-1e-6` uses a separate diagnostic threshold; it does not modify any outcome or metric. Zero/negligible vectors use the metric's documented `1e-10` vector threshold. Each probability is first integrated within its configuration and then averaged with equal configuration weight. The equality of the two negative-probability columns in the completed MM SA results shows that its missing Jain mass is associated with negative savings beyond roundoff at this diagnostic scale. High-sigma MM PEA's missing Jain mass is associated with zero/negligible PV vectors. MaxMin has additional invalidity from zero/negligible individual denominators, already reported separately above.

| Sigma | Policy | Resource | Missing Jain probability | Negative outcome probability | Outcome below -1e-6 probability | Zero/negligible vector probability |
| --- | --- | --- | --- | --- | --- | --- |
| 0.2 | LEXMMFPEA | PV | 0.000% | 0.000% | 0.000% | 0.000% |
| 0.2 | LEXMMFSA | Savings | 45.254% | 45.254% | 45.254% | 0.000% |
| 0.6 | LEXMMFPEA | PV | 0.264% | 0.000% | 0.000% | 0.264% |
| 0.6 | LEXMMFSA | Savings | 48.303% | 48.303% | 48.303% | 0.000% |

Primary rerun illustration (M001, sigma=0.2, J=5, demand deviation=10, Drahi_1, 1,024 scenarios):

- M001, LEXMMFPEA, PV Jain: equity of expected outcomes = 1.00000000; strict expected scenario metric = 0.85381935; conditional-valid scenario mean = 0.85381935; missing probability = 0.0000%.
- M001, LEXMMFPEA, PV Gini: equity of expected outcomes = 0.00000000; strict expected scenario metric = 0.21452929; conditional-valid scenario mean = 0.21452929; missing probability = 0.0000%.
- M001, LEXMMFPEA, PV MaxMin: equity of expected outcomes = 1.00000000; strict expected scenario metric = undefined; conditional-valid scenario mean = 4.47013651; missing probability = 6.2500%.
- M001, LEXMMFSA, Savings Jain: equity of expected outcomes = 0.99999999; strict expected scenario metric = undefined; conditional-valid scenario mean = 0.87340087; missing probability = 33.8867%.
- M001, LEXMMFSA, Savings Gini: equity of expected outcomes = 0.00003784; strict expected scenario metric = undefined; conditional-valid scenario mean = 0.20004991; missing probability = 33.8867%.
- M001, LEXMMFSA, Savings MaxMin: equity of expected outcomes = 1.00023656; strict expected scenario metric = undefined; conditional-valid scenario mean = 34.95624161; missing probability = 33.8867%.

Recovered historical fixture illustration (one base instance, four scenarios; not the manuscript's 1,024-scenario ensemble):

- Recovered small instance, LEXMMFPEA (PV): Jain of expected outcomes = 1.00000000, expected scenario Jain = 0.99303299.
- Recovered small instance, LEXMMFSA (Savings): Jain of expected outcomes = 1.00000000, expected scenario Jain = 0.99933226.

These numerical comparisons establish that equity of expected outcomes and expected/conditional scenario equity are different in the available solutions. Near-equality of an expected resource vector therefore cannot by itself establish equality in each scenario. Negative savings additionally make conventional nonnegative-vector equity metrics undefined in affected scenarios; their probability mass is part of the result, not removed from the unconditional average. These reruns cannot identify the original unretained scenario allocations.

### Why rerun ex-ante values can differ despite matching inputs

The first recovered-seed pilot (M001) reproduces original NONE, PEA, SA and MM SA community objectives within approximately `6e-9`. NONE household expected PV nevertheless changes from `[284.11109,277.92570,65.62625,130.68478,265.43351]` to `[599.61006,176.96371,66.58578,130.79281,49.82896]`, with unchanged community cost. These figures are consistent with multiple cost-optimal household allocations. Available archived input checks pass, while the unsaved original node arrays prevent certifying complete input identity. PEA expected PV targets reproduce household by household. SA and MM SA also yield different household PV allocations at the same community objective. The source's allocation freedoms are preserved.

MM PEA's allocation LP admits different targets within its absolute lexicographic tolerance of 1. In M001, the original expected target is `[205.75627,204.75627,204.75627,203.75627,204.75627]`, while the rerun target is `[204.75627,204.75627,204.75627,204.75627,204.75627]`. Both have the same total and satisfy the allowed lexicographic tolerance, but exact target equalities in the subsequent cost model lead to a cost difference of `159.01`. Thus inner-LP target nonuniqueness can affect the downstream cost as well as household equity. The original source revision and solver overrides remain unrecorded; the observed tolerance/optimal-face mechanism is documented rather than silently forcing historical household outcomes as new constraints. Per-instance objective and all six equity differences are retained in `rerun_historical_comparison.csv`.

The complete available objective comparison follows. Differences are rerun minus historical community expected operating cost, in the unchanged model's cost units. The objective-agreement count uses absolute tolerance `1e-4`; this criterion is separate from the manuscript's rounding interval. Equal community objectives do not imply equal household allocations or equal scenario equity. Lexicographic target/constraint tolerances and the unrecorded original solver choices remain relevant where objectives differ.

| Sigma | Policy | Compared configurations | Objective agreements | Minimum cost difference | Maximum cost difference |
| --- | --- | --- | --- | --- | --- |
| 0.2 | LEXMMFPEA | 40 | 9 | -103.17222222 | 193.71000000 |
| 0.2 | LEXMMFSA | 40 | 40 | -0.00000012 | 0.00000018 |
| 0.2 | NONE | 40 | 40 | -0.00000001 | 0.00000001 |
| 0.2 | PEA | 40 | 40 | -0.00000000 | 0.00000001 |
| 0.2 | SA | 40 | 40 | -0.00000001 | 0.00000001 |
| 0.6 | LEXMMFPEA | 40 | 9 | -113.84000000 | 198.11000000 |
| 0.6 | LEXMMFSA | 40 | 40 | -0.00000013 | 0.00000007 |
| 0.6 | NONE | 40 | 40 | -0.00000001 | 0.00000001 |
| 0.6 | PEA | 40 | 40 | -0.00000000 | 0.00000001 |
| 0.6 | SA | 40 | 40 | -0.00000357 | 0.00000037 |

## Reproducibility commands

Run from the repository root. Keep the initial audit output for its historical checksums and reference source. The solver environment requires IBM ILOG CPLEX 22.1.1 and the Julia channel matching the checked-in environment (1.12.6).

```bash
# For a fresh, separate audit; never overwrite an existing baseline audit.
python3 scripts/models/audit_scenario_equity.py --output /absolute/path/to/new_analysis

# Seed-convention diagnostic, tests, saved-solution recovery, and input check:
julia +1.12.6 --project=. --startup-file=no codes/probe_scenario_equity_seed.jl
julia +1.12.6 --project=. --startup-file=no tests/scenario_equity/runtests.jl
bash scripts/models/run_scenario_equity.sh recover
bash scripts/models/run_scenario_equity.sh check-inputs

# Primary serial execution / ordinary resume: validated solutions are skipped.
bash scripts/models/run_scenario_equity.sh run

# Actual continuation after the recorded checkpoint handoff: bounded, disjoint workers.
# Use one execution mode at a time; campaign/writer locks enforce this.
bash scripts/models/run_scenario_equity_two_workers.sh

# Final balanced continuation, after the second saved-checkpoint handoff:
bash scripts/models/run_scenario_equity_four_workers.sh

# Recover any interrupted saved solution without optimization:
bash scripts/models/run_scenario_equity.sh extract-checkpoints

# Resume only selected targets; validated policies are skipped, checkpoints reused.
CONFIG_IDS=M001,M002 FAIRNESS_SET=NONE,PEA,SA,LEXMMFPEA,LEXMMFSA \
  bash scripts/models/run_scenario_equity.sh run

bash scripts/models/run_scenario_equity.sh merge
bash scripts/models/run_scenario_equity.sh provenance
bash scripts/models/run_scenario_equity.sh parameters
python3 scripts/models/verify_scenario_equity_exports.py
python3 scripts/models/audit_scenario_equity.py --verify-preservation
python3 scripts/models/report_scenario_equity.py
```

The primary solver integration check used `CONFIG_IDS=M001` and all five policies, then the full runner skipped those completed policies. Re-execution is idempotent for validated checkpoints. `run-reproducible` is an explicitly labeled fallback for mismatching inputs and is not required for the now-recovered primary seed convention. A fresh audit's source paths remain rooted in this repository; set `SCENARIO_EQUITY_DIR` to the alternate output for the runner and reports. The supplementary recovery fixture still uses its verified later seed convention, which is explicitly specified independently of the primary manifest.

Source formulation SHA256 checksums:

```
b0f6722f922ea9abbb4e1b100d63fb513935fd3c524b9140d322577aa65ca50e  /home/franco/Documentos/Multistage Energy/Code_stochastique/results_models/scenario_equity/reference_source/conditional_fairness.jl
eedfac6a55ec4246fcd2b1e7d6e19c50d43419decef528183dc4f59895ff9b60  /home/franco/Documentos/Multistage Energy/Code_stochastique/results_models/scenario_equity/reference_source/epp.jl
f25aa77a4d665ba41a9f72b3d4d5c9de7a5279b9d9956d95c2d3defc9d263a9d  /home/franco/Documentos/Multistage Energy/Code_stochastique/results_models/scenario_equity/reference_source/mmf_pea.jl
aa82bfa4e07652af92243ea8ab5be1518e27e658c7eece33c162e9db122e9f36  /home/franco/Documentos/Multistage Energy/Code_stochastique/results_models/scenario_equity/reference_source/mmf_sa.jl
6e304d2964c4a6b46a68298a4cd25baac5241fdf394a8aa40a1df3d79357a008  /home/franco/Documentos/Multistage Energy/Code_stochastique/results_models/scenario_equity/reference_source/multi.jl
bba657cf000ebd01819fca293b4330f99e111f43a5f3ebbbd013538d44e08a18  /home/franco/Documentos/Multistage Energy/Code_stochastique/results_models/scenario_equity/reference_source/parametersMS.jl
957aa582f8b62c4ae3353701ffd28342597e628c18367f366140a9a6242dd657  /home/franco/Documentos/Multistage Energy/Code_stochastique/results_models/scenario_equity/reference_source/static_demand_share.jl
a6566f56ecd55d75a7ad88c12d47f7ceb4601f402b6c621e7e8f40112e751fb4  /home/franco/Documentos/Multistage Energy/Code_stochastique/results_models/scenario_equity/reference_source/structuresMulti.jl
```
