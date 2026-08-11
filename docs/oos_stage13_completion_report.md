# OOS redesign — Stage 13 report

**Stage:** 13 — Safe campaign parallelization and deterministic merge
**Scope authority:** `docs/oos_redesign_plan.md` §4.9, §7 (Stage 13), §11 decision log (2026-08-07, decision 2)
**Date:** 2026-08-09
**Status:** **COMPLETE**

---

## Scope

Per the approved decision of 2026-08-07 this stage delivers the deterministic serial kernel plus
the shard and merge machinery, and **no Julia coordinator**. Concurrency comes from launching
independent processes over disjoint task subsets, which is why every property that makes that
safe lives in the runner rather than in a scheduler.

`codes/oos_experiment/task_runner.jl` provides:

| Function | Role |
|---|---|
| `oos_tasks_from_manifest(path; replications)` | enumerate tasks from the validated catalog; `R` stays a parameter |
| `oos_tasks_from_specs(specs, replications)` | the same enumeration from specs, for tests and probes |
| `tasks_for_shard(tasks, index, shards)` | deterministic stride partition — no coordination, no shared cursor |
| `run_oos_task(config, task; shard_root)` | the serial kernel; materializes, simulates, commits atomically |
| `recompute_campaign_aggregates(directory)` | rebuild the pooled aggregates from merged rows |
| `merge_oos_shards(root, out, expected)` | inventory, refuse-if-incomplete, concatenate in manifest order |

Entry points and scripts: `codes/oos_experiment/run_oos_task.jl` +
`scripts/oos/run_oos_task.sh --shard-index i --shards N`, and
`codes/oos_experiment/merge_oos_shards.jl` + `scripts/oos/merge_oos_shards.sh`. The fan-out
script pins `CPXPARAM_Threads`, `JULIA_NUM_THREADS`, `OPENBLAS_NUM_THREADS` and `OMP_NUM_THREADS`
to one, so `N` processes are `N` units of work and a shard's content cannot depend on how many of
them happen to be running.

One task bundles **both battery levels, all three controllers, all six policies and every rolling
start** of its replication. Splitting any of those across processes would break the pairing the
design depends on.

---

## The parallel-equivalence gate — PASSES

Bounded campaign: one base instance, `K = 1`, `R = 2` → 8 structural instances, 4 paired bases,
**8 tasks of 2 instances each**, `H = L = 4`, 3168 period rows.

| Execution | Merged | Scientific digest | Identical |
|---|---|---|---|
| 1 process | yes | `adeab05e3d71a55d` | — |
| 2 processes | yes | `adeab05e3d71a55d` | **yes** |
| 3 processes, task order shuffled | yes | `adeab05e3d71a55d` | **yes** |
| interrupted (2 tasks skipped), then resumed | yes | `adeab05e3d71a55d` | **yes** |

The digest covers every CSV **except** `execution_provenance.csv` and `solve_provenance.csv`.
Worker number, retry count and wall clock are deliberately outside the scientific comparison —
that separation is what lets the equality be exact rather than "within tolerance".

And the refusal works: with two shards missing, the merge **declines** and names them —

```text
merge refused while incomplete = true
detail: faltan 2: TK-PB-Drahi_1-d1-HET-UHI-2131b6cc74-r2, TK-PB-Drahi_1-d1-HOM-UHI-1571e1babc-r1
```

Resuming re-runs every task; the ones already committed are recognized as idempotent by content
digest and skipped, and the finished dataset is byte-identical to the uninterrupted one.

On the merged dataset:

```text
blocking issues = 0
independent recompute: 8448/8448 cantidades reproducidas  passed=true
```

---

## Three defects the gate found, all fixed

### 1. A task's two battery levels were indistinguishable in the output

`run_oos_task` originally wrote one output directory per task with a single identity taken from
the last spec processed. Since a task bundles both battery levels, **every row was stamped with
the same `StructuralInstanceID`** and the two levels could not be told apart.

Fixed: the task now writes **one directory per structural instance**, each with its own identity,
and concatenates them into the shard in canonical row order.

### 2. The downstream readers grouped without the structural instance

A replication number identifies a trajectory only *within* one structural instance. A dataset
merged from the manifest therefore has one row per instance for the same
`(replication, controller, policy, period)`, and a reader that grouped without the instance
spliced unrelated solve sequences together — reporting them as malformed four- and eight-solve
patterns, and later summing the period rows of unrelated instances into one total.

Fixed in `output_schema.jl`, `run_downstream_checks.jl` and `independent_recompute.jl`: the
grouping key now carries the structural instance, through a shared `_row_instance` helper that
falls back to the single-instance placeholder so a legacy directory stays readable.

### 3. Campaign aggregates cannot be concatenated — the one that was open

`configuration_summary.csv` and `paired_statistics.csv` **aggregate over replications**.
Concatenating them across shards produced one row per shard instead of one pooled row, which the
validator correctly rejected:

```text
configuration_summary.csv :: ("DETERMINISTIC_RH", "LEXMMFPEA") PeriodsSolved:
  reportado 4.0, recomputado 64.0
```

This was a design gap, not a merge bug: a per-shard aggregate over replications is meaningless,
because a shard holds exactly one replication of one paired base.

**Fixed, by the recommended route.** A shard is row-level data and no longer emits the two files
(`write_campaign_outputs(...; write_aggregates=false)`). `recompute_campaign_aggregates` rebuilds
both inside `merge_oos_shards`, from the merged replication-level rows, with plain arithmetic —
the same discipline `independent_recompute.jl` uses, so a producer-side aggregation bug cannot
validate itself.

**And it surfaced a deeper defect.** The original `paired_statistics` paired on the replication
number alone. In a structural campaign that number identifies a trajectory only within one
instance, so pairing on it would have differenced rows from **unrelated structural instances**.
The merge-time version keys on `(StructuralInstanceID, OOSReplicationID)` — which is also the
unit plan §8 requires the final analysis to use. `replication_summary.csv` and
`household_summary.csv` gained `StructuralInstanceID`, `PairedBaseID` and `ParallelTaskID` so a
merged dataset can be paired at all; the schema contract requires them.

---

## The manifest is now the campaign's authority

Stage 3 recorded `design.consumed_by_active_simulator = false` and its validator enforced it,
because at that point nothing read the manifest. Stage 13 reverses this deliberately.

`oos_tasks_from_manifest` rebuilds the design from the manifest, regenerates the catalog, and
**compares every regenerated identifier against the one the manifest recorded, in order**. A
single mismatch aborts the campaign. That check is the point of routing through the manifest at
all: it proves the code about to run reproduces the catalog that was generated and validated,
instead of quietly enumerating a different one.

The flag, its validator, its test and `docs/oos_experiment.md` were all updated together. The
manifest still generates no scenario support — the conditional support is drawn per task from the
seed contract, and its `ScenarioSupportID` is produced at run time.

---

## Stage-13 gate

| Item | Status |
|---|---|
| Task enumeration in canonical order, `R` parameterized | **DONE** |
| Manifest-driven enumeration with catalog cross-check | **DONE** |
| Stride partition without coordination | **DONE** |
| Serial per-task kernel | **DONE** |
| Atomic commit, idempotent re-run, conflict detection | **DONE** |
| Merge refuses missing / incomplete / conflicting | **DONE** |
| Identical merged content across 1, 2, 3 processes, shuffled and resumed | **DONE** |
| Aggregate recomputation at merge time | **DONE** |
| `scripts/oos/run_oos_task.sh`, `merge_oos_shards.sh` | **DONE** |
| Focused test set `TR0..TR7` | **DONE** — `tests/oos/campaign_shard_tests.jl` |

---

## Migrated tests

| Test | Change | Why |
|---|---|---|
| `structural_catalog_tests.jl` metadata assertion | `consumed_by_active_simulator === true` | Stage 13 connected the manifest to the runner. |
| `structural_catalog_tests.jl` corruption case | the corrupt document is now the one denying consumption | Same reversal, from the other direction. |

---

## What Stage 13 does NOT settle

The machinery is correct and reproducible. Whether the campaign it would run answers a question
is the **Stage-12 blocking finding**: the three controllers barely separate and their ranking is
unstable across leaf counts. A confirmatory campaign launched before that is resolved would spend
the compute and measure sampling noise.
