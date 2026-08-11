# OOS redesign — Stage 11 completion report

**Stage:** 11 — Integrated validation and reproducibility gates
**Scope authority:** `docs/oos_redesign_plan.md` §4.9 and §7 (Stage 11)
**Date:** 2026-08-08
**Status:** **COMPLETE**

## Outcome and scope

Stage 11 establishes, on the **serial** kernel and before any concurrency exists, that the
campaign's results depend only on its science and not on the order in which it happened to
compute them. That ordering has to be settled first: once Stage 13 turns on real processes, a
disagreement must be attributable to the scheduling, never to an ambiguity that was there all
along.

It also adds an independent recomputation path, so the reported summaries are checked against
the raw rows by code that shares nothing with the code that produced them.

## Independent recomputation

`codes/oos_experiment/independent_recompute.jl` reads `period_actions.csv` and rebuilds, by
plain arithmetic over CSV columns:

- total operating cost, all-grid benchmark, total savings, total PV, grid import and export,
  aggregate charge and discharge, against `replication_summary.csv`;
- each household's PV allocation, demand, cost and savings, against `household_summary.csv`;
- each household's realized proportional PV and savings targets, deviations and PV rate, against
  `fairness_diagnostics.csv`.

Independence is the whole point, so the module reuses **no** accumulator, metric struct or
deviation helper from the metrics layer — sharing one would reduce the check to a function
agreeing with itself. `IV1` enforces that with a literal source gate, which is why the avoided
names are deliberately not spelled anywhere in that file.

On the bounded end-to-end run: **630 quantities across 18 configurations, all reproduced**; on
the 36-configuration integration fixture, every quantity reproduced. `IV1` also corrupts one
period row and confirms the mismatch is detected and named, so a passing check is evidence rather
than the absence of one.

## What the order-invariance tests found

Two runs differing only in the order of the controller/policy loop produced **byte-different
CSVs with identical content**. Two distinct causes, both fixed in the code rather than tolerated
in the test:

### 1. Rows were written in production order

`write_campaign_outputs` now sorts every frame through `canonical_row_sort` before writing,
using `OOS_CANONICAL_ROW_ORDER` — the scientific key columns, in a fixed priority. Files are
order-invariant **by construction** instead of by luck. Execution provenance never appears in
that key list.

### 2. Timing was still embedded in three scientific files

This is the Stage-10 provenance separation, completed. `solve_log.csv` still carried
`BuildTimeSec`, `SolveWallTimeSec`, `SolverTimeSec` and `PeakMemoryMB`;
`replication_summary.csv` carried `TotalBuildTimeSec` and `TotalSolveTimeSec`; and
`campaign_statistics` computed paired comparisons of `total_solve_time_sec`, putting a **runtime
metric into the scientific statistics file**.

A runtime number legitimately differs between two runs that computed exactly the same thing, so
any scientific file carrying one can never be compared for byte equality. All of it moved:

| Moved from | Moved to |
|---|---|
| `solve_log.csv` timing and memory columns | **new** `solve_provenance.csv`, per phase |
| `replication_summary.csv` total build and solve time | `execution_provenance.csv` |
| `paired_statistics.csv` `total_solve_time_sec` metric | removed; runtime is measured from the provenance files |

`OOS_PROVENANCE_FILES` now names the two provenance files in the code. Every scientific-equality
comparison — reordered execution, resumption, and the future parallel-versus-sequential gate —
excludes exactly that list and nothing else. The tests read the constant rather than a literal,
so a new provenance file cannot be silently swept into the comparison or silently left out of it.

Schema v3 was adjusted rather than bumped again: it has not shipped.

## Invariances established

| Perturbation | Result |
|---|---|
| controller × policy loop reversed (18 → 1) | every scientific CSV byte-identical; metrics equal field by field |
| replication order reversed | every scientific CSV byte-identical |
| simulated worker changed (0 → 7) | every scientific CSV byte-identical; only `execution_provenance.csv` moves |
| interrupted mid-task and resumed | the resumed shard is byte-identical to the uninterrupted one |
| an already-complete task re-run | idempotent: same digest, no conflict |
| shard production order reversed | `canonical_merge_order` unchanged |

`IV2` states the invariance twice — once on a content digest and once on the metric values field
by field — so neither a hash collision nor a formatting coincidence can make it pass.

## Adversarial checks

`IV5` confirms that injected inconsistencies are **detected rather than absorbed**: a tampered
shard is reported as a conflict, a results directory missing a required column fails the reader
and names the column, and a physically impossible action is rejected with its violation named.

## Property checks

`IV6` samples 40 random admissible `(H, L, h)` triples and asserts the temporal contract on each:
the rolling starts are exactly `1:h:H`; the final committed block ends at `realized_period_end`;
the final window ends at `required_period_support_end`; both orderings the simulator relies on
hold; every committed block has exactly `h` periods and every window exactly `L`; and the union
of the evaluated blocks is exactly `1:H`. Inadmissible triples are rejected rather than corrected.

## Files changed for Stage 11

| File | Stage-11 change |
|---|---|
| `codes/oos_experiment/independent_recompute.jl` | **new** — the independent recomputation path |
| `codes/oos_experiment/output.jl` | `OOS_CANONICAL_ROW_ORDER`, `canonical_row_sort`; timing removed from two frames; **new** `solve_provenance_frame` |
| `codes/oos_experiment/output_schema.jl` | `OOS_PROVENANCE_FILES`; `solve_provenance.csv` declared; timing columns moved |
| `codes/oos_experiment/metrics.jl` | the runtime metric removed from `campaign_statistics` |
| `codes/oos_experiment/oos_experiment.jl` | include order |
| `tests/oos/integrated_validation_tests.jl` | **new** — focused sets `IV0`–`IV6` |
| `tests/oos/result_schema_tests.jl` | `OS4` extended to assert no timing column in any scientific file |
| `docs/oos_stage11_completion_report.md` | **new** — this record |

## Tests

| Test set | Assertions | Result |
|---|---:|---|
| `IV0` a bounded end-to-end run passes every gate | 9 | PASS |
| `IV1` downstream recomputation reproduces the summaries | 12 | PASS |
| `IV2` controller and fairness ordering change nothing | 181 | PASS |
| `IV3` replication order and worker assignment change nothing | 16 | PASS |
| `IV4` interruption and resumption produce identical shards | 14 | PASS |
| `IV5` injected inconsistencies are detected | 6 | PASS |
| `IV6` property checks over randomized configurations | 1,031 | PASS |

| Gate | Result |
|---|---|
| full `validate_oos_experiment.sh` | exit 0, **24,537 assertions**, 0 failed, 438.4 s |
| bounded preflight | exit 0, **`PREFLIGHT_RESULT=READY`**, 14 checks passed, 0 failed, 728.7 s |

## Decisions and remaining ownership

- **No deviation from the Stage-11 contract.**
- **Schema v3 was adjusted, not re-bumped.** It has not shipped, and adding a version for an
  in-progress schema would make the version number meaningless.
- **Everything here is serial.** No worker, scheduler or concurrent writer was created; Stage 13
  activates them against the invariances established here.
