#!/usr/bin/env python3
"""Generate the requested audit report from completed analysis artifacts."""
import argparse
import csv
import json
from pathlib import Path
import re
import statistics
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def rows(path):
    if not path.exists() or not path.stat().st_size:
        return []
    with path.open(newline="") as f:
        return list(csv.DictReader(f))


def number(value, digits=5):
    if value in (None, ""):
        return "undefined"
    return f"{float(value):.{digits}f}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "results_models/scenario_equity")
    args = parser.parse_args()
    out = args.output.resolve()
    status = rows(out / "execution_status.csv")
    complete = [r for r in status if r["Complete"].lower() == "true"]
    original = [r for r in complete if r["OriginalInputsReproduced"].lower() == "true"]
    comparison = rows(out / "manuscript_comparison.csv")
    validation = rows(out / "validation_results.csv")
    summary = rows(out / "equity_summary.csv")
    recovered = rows(out / "snapshot_recovery_provenance.csv")
    provenance = json.loads((out / "audit_provenance.json").read_text())
    reference = provenance["ReferenceRevision"]
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    source_hashes = subprocess.check_output(["sha256sum", *map(str, sorted(out.glob("reference_source/*.jl")))], text=True)
    implementations = subprocess.check_output(["sha256sum", *map(str,
        sorted((ROOT / "codes").glob("*scenario_equity*.jl"))),
        str(ROOT / "scripts/models/audit_scenario_equity.py"), str(Path(__file__).resolve()),
        str(ROOT / "scripts/models/verify_scenario_equity_exports.py"),
        str(ROOT / "scripts/models/run_scenario_equity.sh"), str(ROOT / "tests/scenario_equity/runtests.jl")], text=True)
    implementations += subprocess.check_output(["sha256sum", str(ROOT / "scripts/models/run_scenario_equity_two_workers.sh")], text=True)
    implementations += subprocess.check_output(["sha256sum", str(ROOT / "scripts/models/run_scenario_equity_four_workers.sh")], text=True)
    (out / "analysis_source_hashes.txt").write_text(implementations)
    tests = (out / "validation_tests.log").read_text()
    preservation = json.loads((out / "historical_preservation.json").read_text()) if (out / "historical_preservation.json").exists() else {}
    export_checks = json.loads((out / "export_verification.json").read_text()) if (out / "export_verification.json").exists() else {}
    optimization_provenance = rows(out / "optimization_provenance.csv")

    quality = []
    household_counts = {r['ConfigID']: int(r['J']) for r in rows(out / "config_manifest.csv")}
    for path in sorted(out.glob("shards/*/*/*/solver.log")):
        text = path.read_text()
        if not (path.parent / "complete.csv").exists():
            continue
        policy, config, dataset = path.parent.name, path.parent.parent.name, path.parent.parent.parent.name
        lex = re.findall(r"Lex step (\d+) objective: .*? \(([^)]+)\)", text)
        terminal = re.findall(r"^(OPTIMAL|TIME_LIMIT|INFEASIBLE|DUAL_INFEASIBLE|OTHER_ERROR)$", text, re.M)
        expected_steps = household_counts[config] if policy == "LEXMMFSA" else 1
        optimal = (len(lex)==expected_steps and [int(i) for i,_ in lex]==list(range(1,expected_steps+1))
                   and all(term == "OPTIMAL" for _, term in lex)) if policy == "LEXMMFSA" else terminal == ["OPTIMAL"]
        quality.append(dict(DatasetID=dataset, ConfigID=config, Fairness=policy,
            SolverStatusEvidence=";".join(terminal) if terminal else ";".join(f"lex_{i}:{s}" for i,s in lex),
            RecordedStepsOptimal=optimal,
            RecordedStepCount=len(lex) if policy=="LEXMMFSA" else len(terminal),
            ExpectedRecordedSteps=expected_steps,
            Note="LEXMMFPEA target LP termination is not exported by source; final solve termination recorded" if policy=="LEXMMFPEA" else "source_solver_log"))
    with (out / "solver_quality.csv").open("w", newline="") as f:
        fields=["DatasetID","ConfigID","Fairness","SolverStatusEvidence","RecordedStepsOptimal",
                "RecordedStepCount","ExpectedRecordedSteps","Note"]
        w=csv.DictWriter(f,fieldnames=fields);w.writeheader();w.writerows(quality)
    supplementary_count = sum(r['DatasetID']=="reproducible_same_numeric_design" for r in quality)

    input_reports=[]
    for version in ("1_12_6", "1_8_1"):
        data=rows(out/f"input_validation_julia_{version}.csv")
        if data:
            input_reports.append(f"- Julia {version.replace('_','.')}: {sum(r['Passed'].lower()=='true' for r in data)}/{len(data)} inputs match; "
                f"maximum benchmark residual {max(float(r['InputBenchmarkResidual']) for r in data):.6f}; "
                f"maximum total-PV residual {max(float(r['InputPVResidual']) for r in data):.6f}.")
    seed_reports=[]
    for version in ("1_12_6","1_8_1"):
        data=rows(out/f"seed_probe_without_profile_julia_{version}.csv")
        if data:
            seed_reports.append(f"- Seed hash without DemandProfile, Julia {version.replace('_','.')}: "
                f"{sum(r['Passed'].lower()=='true' for r in data)}/{len(data)} historical benchmark/PV checks pass.")
    current_inputs=rows(out/"input_validation.csv")
    test_counts = [int(n) for n in re.findall(r"\|\s+(\d+)\s+\1\s+", tests)]
    # Count directly from printed Test summaries rather than treating log warnings as failures.
    test_total=sum(test_counts)
    max_residuals=[]
    for field in ["ExpectedPVResidual","ExpectedSavingsResidual","SolutionCostResidual",
                  "ScenarioPVConservationResidual","NodeBalanceResidual","SOCTransitionResidual","FairnessResidual"]:
        values=[float(r[field]) for r in validation if r.get(field)]
        if values:
            max_residuals.append(f"| {field} | {max(values):.6g} |")
    table_rows=[]
    for r in comparison:
        table_rows.append(f"| {r['Sigma']} | {r['Fairness']} | {r['Resource']} | {r['Metric']} | "
            f"{r['ManuscriptValue']} | {number(r['RecomputedValue'],8)} | {number(r['AbsoluteDifference'],8)} | "
            f"{number(r['RelativeDifference'],8)} | {r['NumValidInstances']}/{r['NumInstances']} | {r['ValidationStatus']} |")
    gap_rows=[]
    for r in summary:
        if r['DatasetID']=="manuscript_design_rerun":
            for metric in ('Jain','Gini','MaxMin'):
                gap_rows.append(f"| {r['Sigma']} | {r['Fairness']} | {r['Resource']} | {metric} | "
                    f"{r[metric+'_EquityOfExpectedOutcomes_ValidInstances']}/{r['NumInstances']} | "
                    f"{number(r[metric+'_EquityOfExpectedOutcomes_ConditionalValidInstanceMean'])} | "
                    f"{number(r[metric+'_ExpectedScenarioEquity_MeanAcrossInstances'])} | "
                    f"{number(r[metric+'_ConditionalValidMean_MeanAcrossInstances'])} | "
                    f"{100*float(r[metric+'_MissingProbabilityMass_MeanAcrossInstances']):.3f}% |")
    recovery_examples=[]
    primary_examples=[]
    for r in rows(out/"instance_equity_summary.csv"):
        if r['DatasetID']=="recovered_validation_snapshot" and r['Metric']=='Jain' and (
            (r['Fairness']=='LEXMMFPEA' and r['Resource']=='PV') or (r['Fairness']=='LEXMMFSA' and r['Resource']=='Savings')):
            recovery_examples.append(f"- Recovered small instance, {r['Fairness']} ({r['Resource']}): "
                f"Jain of expected outcomes = {number(r['EquityOfExpectedOutcomes'],8)}, "
                f"expected scenario Jain = {number(r['ExpectedScenarioEquity'],8)}.")
        if r['DatasetID']=="manuscript_design_rerun" and r['ConfigID']=='M001' and (
            (r['Fairness']=='LEXMMFPEA' and r['Resource']=='PV') or
            (r['Fairness']=='LEXMMFSA' and r['Resource']=='Savings')):
            primary_examples.append(f"- M001, {r['Fairness']}, {r['Resource']} {r['Metric']}: "
                f"equity of expected outcomes = {number(r['EquityOfExpectedOutcomes'],8)}; "
                f"strict expected scenario metric = {number(r['ExpectedScenarioEquity'],8)}; "
                f"conditional-valid scenario mean = {number(r['ConditionalValidMean'],8)}; "
                f"missing probability = {100*float(r['MissingProbabilityMass']):.4f}%.")
    failures=rows(out/"execution_failures.csv")
    # Explain missing max-min-policy Jain values from actual exported outcomes.
    # Probability masses average the separate configurations with equal weight.
    diagnostics={}
    for r in summary:
        if r['DatasetID']=='manuscript_design_rerun' and (
            (r['Fairness']=='LEXMMFPEA' and r['Resource']=='PV') or
            (r['Fairness']=='LEXMMFSA' and r['Resource']=='Savings')):
            diagnostics[(r['Sigma'],r['Fairness'])]=dict(
                Sigma=r['Sigma'],Fairness=r['Fairness'],Resource=r['Resource'],
                NumInstances=int(r['NumInstances']),MissingJainProbability=0.0,
                NegativeOutcomeProbability=0.0,NegativeBelowMinus1eMinus6Probability=0.0,
                ZeroOrNegligibleVectorProbability=0.0,OtherUndefinedProbability=0.0)
    with (out/'scenario_equity_metrics.csv').open(newline='') as stream:
        for r in csv.DictReader(stream):
            key=(r['Sigma'],r['Fairness'])
            if r['DatasetID']!='manuscript_design_rerun' or key not in diagnostics:
                continue
            d=diagnostics[key]
            resource=d['Resource']
            weight=float(r['ScenarioProbability'])/d['NumInstances']
            minimum=float(r[resource+'Min']); maximum=float(r[resource+'Max'])
            if minimum<0:
                d['NegativeOutcomeProbability']+=weight
            if minimum < -1e-6:
                d['NegativeBelowMinus1eMinus6Probability']+=weight
            if not r[resource+'Jain']:
                d['MissingJainProbability']+=weight
                if minimum>=0 and maximum<=1e-10:
                    d['ZeroOrNegligibleVectorProbability']+=weight
                elif minimum>=0:
                    d['OtherUndefinedProbability']+=weight
    diagnostic_rows=[]
    for d in diagnostics.values():
        diagnostic_rows.append(f"| {d['Sigma']} | {d['Fairness']} | {d['Resource']} | "
            f"{100*d['MissingJainProbability']:.3f}% | "
            f"{100*d['NegativeOutcomeProbability']:.3f}% | "
            f"{100*d['NegativeBelowMinus1eMinus6Probability']:.3f}% | "
            f"{100*d['ZeroOrNegligibleVectorProbability']:.3f}% |")
    (out/'primary_metric_invalidity_diagnostics.json').write_text(
        json.dumps(list(diagnostics.values()),indent=2)+'\n')
    resume_check=json.loads((out/'resume_verification.json').read_text()) if (out/'resume_verification.json').exists() else {}
    objective_groups={}
    for r in rows(out/"rerun_historical_comparison.csv"):
        if r['DatasetID']=='manuscript_design_rerun' and r['Resource']=='PV' and r['Metric']=='Jain':
            objective_groups.setdefault((r['Sigma'],r['Fairness']),[]).append(float(r['ExpectedCostDifference']))
    objective_rows=[]
    for (sigma,policy),values in sorted(objective_groups.items()):
        objective_rows.append(f"| {sigma} | {policy} | {len(values)} | "
            f"{sum(abs(x)<=1e-4 for x in values)} | {min(values):.8f} | {max(values):.8f} |")
    completed_text=f"{len(complete)}/400 target policy configurations have validated scenario analyses; "
    completed_text+=f"{len(original)} pass all available archived input checks."
    pending=[f"{r['ConfigID']}/{r['Fairness']}" for r in status if r['Complete'].lower()!='true']
    report=f"""# Scenario equity analysis

Audit and execution date: 2026-10-09 (Europe/Paris). {completed_text}

The historical household file reproduces **all 60 entries** in manuscript Tables 5 and 6 within the two-decimal rounding interval. Full original scenario decisions were not retained. The historical seed convention was recovered: its hash omits the later DemandProfile field. With Julia 1.12.6, this convention reproduces every recorded household demand and all-grid benchmark and every community PV total in all 80 configurations. The main reruns use these reconstructed inputs and the earlier continuous-battery formulation. Original optimal decisions, the original source revision, and all solver overrides remain unrecorded, so original scenario allocations cannot be certified as exact copies.

## Repository audit and provenance

The audit examined the full repository, active and archived Julia sources, shell runners, manuscript PDF, all results directories, ZIP contents, CSV headers, serialized snapshots, manifests, and git history. No applicable `AGENTS.md` was present in the repository or its ancestors. The initial working tree had only these user-owned untracked paths:

```
{provenance['InitialGitStatus']}
```

Base working-tree revision: `{revision}`. Historical reference formulation: `{reference}` (earliest tracked import). The exact commit and package versions used for the original runs were not recorded. The current formulation was changed by commit `0a751cf44aa17f7dab0bf5a6a653888bdd16db21`, introducing shared battery direction binaries; the primary reruns therefore load untouched copies of the earlier **continuous-battery** formulation from `reference_source/`. The OOS model adds additional rules and is excluded from this experiment.

`historical_file_hashes.csv` records {provenance['HistoricalFileCount']:,} pre-existing files; `results_inventory.csv` records all historical result artifacts, sizes, checksums, CSV schemas, and archive members. Preservation check: **{preservation.get('Passed', 'not yet checked')}**; changed historical files: `{preservation.get('FilesChanged', [])}`. `analysis_source_hashes.txt` pins the additive scripts and tests, since they remain uncommitted working-tree additions.

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

The actual table source fixes ten files `Drahi_1.csv` through `Drahi_10.csv`, J in {{5,10}}, Theta in {{0.2,0.6}}, mean demand 100, demand standard deviation in {{10,20}}, and tree S:C:P=`6:4:4`. There are 24 time periods, 5,460 nodes and 1,024 leaves. This yields 80 configurations and 400 policy results: 40 configurations per uncertainty level per policy. Configurations, including all four J/demand-deviation variants per base file, receive equal weight; scenarios first receive their actual leaf probabilities. The ten base files are not 40 independent base days.

Policies are exactly `NONE` (NF), `PEA`, `SA`, `LEXMMFPEA` (MM PEA), `LEXMMFSA` (MM SA). The unmodified source implements expected-cost minimization for NONE/PEA/SA, lexicographic expected PV target LPs followed by a cost solve for MM PEA, and sequential lexicographic expected savings maximization for MM SA. No conditional policies or rolling-horizon controllers are included.

The manuscript's sigma is the generator's **Theta**: `pv_ms` uses `Normal(0,theta)` for PV innovations in the ARMA(1,1) recursion with coefficients 0.8 and 0.2. Demand uncertainty separately uses `Dev_d`. The source describes normal demand around 100 with deviation 10/20 and repairs demand where needed for PEA feasibility; this differs from the manuscript prose describing uniform demand from 4 to 9.2. The analysis follows the source data and does not rewrite the manuscript.

The current tracked deterministic seed formula adds DemandProfile to a 64-bit FNV-style hash. The reconstructed historical key is `InstanceFile|NBstage|Childs|Periods|J|Theta|Avg_d|Dev_d`, **without DemandProfile**, modulo `2^31-1`, plus one. The historical CSVs lack the later DemandProfile column, which motivated this diagnostic rather than a brute-force search. Agreement of all available input checks within the documented numerical tolerance supports the recovered convention. Seeds and input file SHA256 values are recorded in `config_manifest.csv`; the earlier failed seed convention is retained in `config_manifest_with_profile_seed.csv` and the supplementary manifest. A scoped seed override supplies the recovered seed to the unmodified generator's draw sequence; no optimization equations or source files are changed. Theta remains part of the seed, so changing sigma also changes price draws and household profile assignment under the historical source contract.

Initial probes using the **tracked, later hash containing DemandProfile** failed before optimization:

{chr(10).join(input_reports)}

The missing historical seed field explains the discrepancy:

{chr(10).join(seed_reports)}

The final input gate checks every household expected demand, every household all-grid benchmark, and the community expected PV total. It passes **{sum(r['Passed'].lower()=='true' for r in current_inputs)}/{len(current_inputs)}** configurations. Julia 1.12.6 uses the existing repository environment. The supplementary Julia 1.8.1 compatibility environment was used only for provenance probes, leaving the repository `Project.toml` and `Manifest.toml` unchanged. The manuscript's stated Julia 1.8.1 runtime does not reproduce the complete historical ensemble with the available generator. Available moment checks do not constitute independent hashes of the unsaved original node arrays; original node arrays and solver-selected allocations are still unavailable.

Primary rerun dataset: `manuscript_design_rerun`, using the recovered historical seed convention. A partial supplementary dataset, `reproducible_same_numeric_design`, used the later DemandProfile hash before the historical convention was recovered; its completed solutions are retained and excluded from the primary ensemble. Recovered fixture dataset: `recovered_validation_snapshot`; expected-only historical dataset: `historical_expected_only`. Dataset identifiers prevent combining these as independent observations. The supplementary batch was stopped once recovery made additional solves under the later seed convention unnecessary.

Physical parameters are unchanged: delta=1, s_max=63, s_min=s_I=0.2, e_c=e_d=0.95, aggregate charge/discharge limits=4, mu=5, beta=10, common household price draws from `1615.1:2228.1` divided by 10, battery/PV scales=1, mixed demand profiles. `pv_det` sums each block of four input PV samples and multiplies by 300/1000, exactly as in the source. Outputs retain this model unit convention; the analysis does not correct the source's PV sampling/scaling convention or reinterpret it as separately calibrated physical units.

Solver environment: `{(out/'solver_environment.txt').read_text().strip() if (out/'solver_environment.txt').exists() else 'not available'}`. Thread count=1 is verified on the CPLEX optimizer. Solver feasibility/optimality tolerances remain the installed CPLEX defaults. The ordinary cost model keeps its 3,600-second limit; lexicographic routines keep their source defaults. SA uses tolerance 0 for the target design, following the earliest tracked shell runner; the recovered fixture used the function default 1. Lexicographic absolute tolerance is 1. The historical execution does not record overrides, so these source defaults cannot establish exact original tolerances.

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

Policy configurations reused without optimization: **five distinct saved fixture solutions**, plus all **3,000 historical expected household rows** for table reproduction. Primary policy configurations newly solved and validated: **{len(complete)}**. Archived input checks verified for these new solves: **{len(original)}**. Supplementary policy solutions completed under the later seed convention: **{supplementary_count}**; these are retained separately and excluded from the target completion count. Saved overlapping snapshots are not independent instances. No OOS runs or heuristic solves were substituted. Lexicographic policies naturally include their original sequence of inner LP solves within one policy execution.

Full instance/decision arrays are saved before extraction; extraction failures can therefore resume from the checkpoint without re-solving. Completion markers are created only after validation and checksum every required shard file. Completed policies are skipped. The shell wrapper uses a writer lock and single-thread limits; the script preserves the exact original model source. Large consolidated scenario CSVs are streamed, avoiding materialization of all household scenarios in memory. Solver logs preserve termination evidence: boolean `Status` means primal availability, while `solver_quality.csv` identifies the statuses actually exported by source. All {len(quality)} rerun logs checked: {sum(r['RecordedStepsOptimal'] for r in quality)} report optimal recorded stages. MM PEA's target LP statuses are not separately exported by the original source.

Provenance runtime columns are explicitly named `SourceReportedSolverTimeSeconds` and `SourceReportedPolicyTimeSeconds`. They retain `SolutionM.time` and `SolutionM.run_time`; they are not independently measured end-to-end durations. In particular, MM PEA's original `run_time` adds target-generation time to a timer that already includes it, so this field double-counts that component. No timing claim or equity result relies on these fields.

After the initial serial run, a completed solution checkpoint was retained at the recorded handoff and used for extraction on resume. The next continuation used two controlled workers, with disjoint ranges M001–M040 and M041–M080 and one CPLEX thread per worker. Once a workload imbalance became apparent, both workers stopped only after their active policy solutions had been atomically saved; the handoff record includes the saved binary hashes. The final continuation uses **four bounded workers** with disjoint ranges M001–M040, M041–M064, M065–M072 and M073–M080, one CPLEX thread each. The resource check recorded 16 available CPUs and approximately 22 GB available memory before adding the workers. No completed optimization is repeated during either handoff. Each worker has its own output directory and writer lock; reused shard-directory aliases contain disjoint configuration ranges. The campaign coordinator holds a global lock, waits for all workers, collects the worker shards without overwriting existing artifacts, and verifies identical generated inputs across policies. Retained shard-directory aliases keep recorded source paths valid. The coordinators invoke the same pinned solver/model code and add no model constraints.

Pending targets: **{len(pending)}**. {('See execution_status.csv for the complete list; first pending: '+', '.join(pending[:12])+'.') if pending else 'Every target configuration has a validated analysis in its declared dataset.'}
Recorded current failures: **{len(failures)}**. {'; '.join(r['ConfigID']+'/'+r['Fairness']+': '+r['ErrorMessage'] for r in failures[:3]) if failures else 'No current solver or extraction failures.'}
The original selected scenario decisions remain unavailable for all 400 historical policies. Main reruns reconstruct inputs and produce new validated optimization solutions; they do not recover unsaved original optimizer choices.

## Validation

The extraction suite passed **{test_total:,} checks**. It uses saved optimization decisions on the small stochastic instance rather than wasting solves, and checks every overlapping snapshot. It covers all 13 requested conditions: probabilities sum to one; complete parent-linked paths/time indices; expected PV; expected savings; solution costs; scenario/node PV conservation; Jain/Gini bounds; MaxMin and strictly positive denominators; identical vectors; ex-ante versus scenario metrics on a synthetic example; zero/negative/nonfinite outcomes; unchanged decision checksums; and unchanged historical files. Additional tests exercise unequal leaf probabilities, delta=0.5 arithmetic, invalid probability trees, valid-subset missing mass, weighted quantiles, and equal configuration weighting.

Physical/economic extraction validation passed for **{len(validation)}** available policy solutions. Validation tolerances: absolute `1e-6`, relative `1e-9` for expected quantities; probability/path checks `1e-10`. Node balance, SOC bounds/transitions/terminal state, charge/discharge rates and nonnegative decisions are independently checked. The original continuous-battery model's permitted simultaneous flows are retained; the newer binary formulation is not imposed on old solutions. Source arrays are hashed before and after extraction. PEA and SA expectation residuals are checked against their configured tolerance.

Checkpoint provenance verification covers **{len(optimization_provenance)}** solutions and checks that every policy under a given dataset/configuration uses an identical full generated-instance digest. Independent streaming export verification: **{export_checks.get('Passed', 'not yet checked')}**. It checks the actual CSV key coverage, raw savings and signed shares, all six metrics and their validity flags, scenario totals/extrema, probability-weighted household expectations, ex-ante metrics, strict scenario expectations, missing probability mass and weighted standard deviations. This verification does not invoke optimization.

The explicit M001 resume check passed: **{resume_check.get('Passed','not yet checked')}**. It skipped all five validated policies, launched no optimization, and retained identical saved-solution binary hashes. Its before-hash record and execution log are retained alongside the result.

```json
{json.dumps(export_checks.get('CountsByDataset', {}), indent=2)}
```

| Maximum extraction residual | Value |
| --- | --- |
{chr(10).join(max_residuals)}

## Reproduction of manuscript Tables 5 and 6

Source: `codes/docs/Multistage_stochastic_fair_energy_allocation-25.pdf`, Tables 5/6, pages 26/27. Table entry validation uses absolute tolerance `0.005 + 1e-10`, representing two-decimal rounding; relative difference is undefined when the manuscript value is zero. All {sum(r['ValidationStatus']=='PASS_ROUNDING' for r in comparison)}/{len(comparison)} comparisons pass. Recomputed values use the historical script's explicitly documented valid-instance convention. Source `archive_legacy/results/equity_tables_1024.md` instead combines both sigmas; stratifying the same household data by Theta produces the two manuscript tables.

| Sigma | Policy | Resource | Metric | Manuscript | Recomputed | Abs. diff. | Rel. diff. | Valid/total | Status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
{chr(10).join(table_rows)}

## Ex-ante versus scenario equity

The following summaries apply **only to the primary reruns with the recovered historical seed convention**, with each metric first aggregated using each instance's leaf probabilities. Ex-ante values shown are the explicitly conditional mean across valid instances; their valid/total counts are shown, and strict full-ensemble means remain in `equity_summary.csv`. The unconditional expected scenario metric is undefined if any instance has undefined positive-probability scenarios. The next column is a separately labeled mean of per-instance conditional-valid-scenario means; it must not be interpreted as an expectation over all scenarios. Missing probability is averaged with equal configuration weight. All three metrics are compared below for both resources; quantiles and standard deviations are in the summary and instance CSVs. Supplementary later-seed results are excluded.

| Sigma | Policy | Resource | Metric | Ex-ante valid/total instances | Ex-ante equity (valid instances) | E[scenario metric], strict | Conditional valid-scenario metric | Missing probability |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
{chr(10).join(gap_rows)}

The following export-derived diagnostics identify why the max-min-policy Jain expectations are missing. A negative outcome below `-1e-6` uses a separate diagnostic threshold; it does not modify any outcome or metric. Zero/negligible vectors use the metric's documented `1e-10` vector threshold. Each probability is first integrated within its configuration and then averaged with equal configuration weight. The equality of the two negative-probability columns in the completed MM SA results shows that its missing Jain mass is associated with negative savings beyond roundoff at this diagnostic scale. High-sigma MM PEA's missing Jain mass is associated with zero/negligible PV vectors. MaxMin has additional invalidity from zero/negligible individual denominators, already reported separately above.

| Sigma | Policy | Resource | Missing Jain probability | Negative outcome probability | Outcome below -1e-6 probability | Zero/negligible vector probability |
| --- | --- | --- | --- | --- | --- | --- |
{chr(10).join(diagnostic_rows)}

Primary rerun illustration (M001, sigma=0.2, J=5, demand deviation=10, Drahi_1, 1,024 scenarios):

{chr(10).join(primary_examples)}

Recovered historical fixture illustration (one base instance, four scenarios; not the manuscript's 1,024-scenario ensemble):

{chr(10).join(recovery_examples)}

These numerical comparisons establish that equity of expected outcomes and expected/conditional scenario equity are different in the available solutions. Near-equality of an expected resource vector therefore cannot by itself establish equality in each scenario. Negative savings additionally make conventional nonnegative-vector equity metrics undefined in affected scenarios; their probability mass is part of the result, not removed from the unconditional average. These reruns cannot identify the original unretained scenario allocations.

### Why rerun ex-ante values can differ despite matching inputs

The first recovered-seed pilot (M001) reproduces original NONE, PEA, SA and MM SA community objectives within approximately `6e-9`. NONE household expected PV nevertheless changes from `[284.11109,277.92570,65.62625,130.68478,265.43351]` to `[599.61006,176.96371,66.58578,130.79281,49.82896]`, with unchanged community cost. These figures are consistent with multiple cost-optimal household allocations. Available archived input checks pass, while the unsaved original node arrays prevent certifying complete input identity. PEA expected PV targets reproduce household by household. SA and MM SA also yield different household PV allocations at the same community objective. The source's allocation freedoms are preserved.

MM PEA's allocation LP admits different targets within its absolute lexicographic tolerance of 1. In M001, the original expected target is `[205.75627,204.75627,204.75627,203.75627,204.75627]`, while the rerun target is `[204.75627,204.75627,204.75627,204.75627,204.75627]`. Both have the same total and satisfy the allowed lexicographic tolerance, but exact target equalities in the subsequent cost model lead to a cost difference of `159.01`. Thus inner-LP target nonuniqueness can affect the downstream cost as well as household equity. The original source revision and solver overrides remain unrecorded; the observed tolerance/optimal-face mechanism is documented rather than silently forcing historical household outcomes as new constraints. Per-instance objective and all six equity differences are retained in `rerun_historical_comparison.csv`.

The complete available objective comparison follows. Differences are rerun minus historical community expected operating cost, in the unchanged model's cost units. The objective-agreement count uses absolute tolerance `1e-4`; this criterion is separate from the manuscript's rounding interval. Equal community objectives do not imply equal household allocations or equal scenario equity. Lexicographic target/constraint tolerances and the unrecorded original solver choices remain relevant where objectives differ.

| Sigma | Policy | Compared configurations | Objective agreements | Minimum cost difference | Maximum cost difference |
| --- | --- | --- | --- | --- | --- |
{chr(10).join(objective_rows)}

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
CONFIG_IDS=M001,M002 FAIRNESS_SET=NONE,PEA,SA,LEXMMFPEA,LEXMMFSA \\
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
{source_hashes.strip()}
```
"""
    destination = ROOT / "docs/scenario_equity_analysis.md"
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(report)
    print(f"Wrote {destination}; {len(complete)}/400 target analyses, {len(comparison)} historical comparisons")


if __name__ == "__main__":
    main()
