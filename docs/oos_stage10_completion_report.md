# OOS redesign — Stage 10 completion report

**Stage:** 10 — Output schema, metadata, and policy-aligned metrics
**Scope authority:** `docs/oos_redesign_plan.md` §4.7, §4.8, §4.9 and §7 (Stage 10)
**Date:** 2026-08-08
**Status:** **COMPLETE**

## Outcome and scope

Until this stage a result row could be read only by reconstructing hidden configuration: which
structural instance it came from, which conditional support the decision used, which committed
block the period belonged to, and against what its cost should be compared. Stage 10 makes all of
that explicit and stable, and bumps `output_schema_version` from **2 to 3** with an explicit
migration.

The four claims of the acceptance gate are each checked directly by a focused test set rather
than argued.

## Scientific identity

`OOSRunIdentity` (`codes/oos_experiment/result_identity.jl`) carries everything needed to
identify a result scientifically and nothing that identifies a run. Every field is a
deterministic function of the configuration and the instance, which is precisely why it may key
a row while a worker number may not.

It keeps the temporal quantities **separate** rather than derivable at read time:

| Field | Meaning |
|---|---|
| `repository_instance_horizon`, `base_profile_length` | `T0` — the instance and the repeated profile |
| `evaluation_horizon`, `lookahead_horizon`, `implementation_step` | `H`, `L`, `h` |
| `required_period_support_end` | `max T(H,h) + L - 1` |
| `realized_period_end` | `max T(H,h) + h - 1` |

`objective_criterion` is written to every row as `risk_neutral_expectation`, because §4.7 forbids
inferring a risk measure from a method name: `MULTISTAGE_RH` is an information structure, not a
risk attitude.

`parallel_task_id` is `(PairedBaseID, OOSReplicationID)` — the approved schedulable unit. It
carries the replication and deliberately **not** the controller or the policy, because one task
evaluates all of them and folding either in would split a bundle the design requires to stay
intact. `OS4` asserts that, and that `OOSRunIdentity` has no `worker`, `retry`, `wall_clock`,
`solver_time` or `execution_order` member at all.

On the single-instance path the structural fields carry a degenerate placeholder. The columns
exist from stage 10 so the schema does not change again when stage 13 supplies the real ones.

## Three new files

| File | Contents |
|---|---|
| `run_identity.csv` | the full identity once per configuration, plus the seed-key contract and the applicable diagnostic family |
| `fairness_diagnostics.csv` | one row per household per configuration, every diagnostic family, with `ApplicableDiagnostic` naming the one that validates this policy |
| `execution_provenance.csv` | worker, retry, build and solve time, completion status |

The third exists for a specific reason: separating execution provenance from the scientific
payload is what lets a sequential run and a parallel run be compared for equality (§4.9). `OS4`
checks that `Worker` and `Retry` appear in **no** scientific file.

## Policy-aligned fairness metrics

§4.8 requires a fairness statistic to match the mathematical definition of the policy it is
reported against. Every family is computed for every run — they are cheap and comparable — but
exactly one is named as validating each policy:

| Policy | `ApplicableDiagnostic` | What validates it |
|---|---|---|
| `PEA` | `proportional_pv` | household PV rate and deviation from the realized proportional target |
| `SA` | `proportional_savings` | household savings rate and deviation from its target |
| `LEXMMFPEA` | `lexicographic_pv` | ordered PV vector, its cumulative order statistics, and the worst-off gap |
| `LEXMMFSA` | `lexicographic_savings` | the same on savings |
| `STATIC_DEMAND_SHARE` | `static_share_residual` | deviation from what the ex-ante table would have allocated out of the realized PV |
| `NONE` | `descriptive_only` | nothing validates it; the statistics are outcomes |

The `NONE` case is the sharpest and follows directly from a Stage-9 finding: with no distributive
rule the household split of the community PV is a **degenerate** optimum, so its allocations are
outcomes of an arbitrary vertex and must never be read as a distributive result or as a violation
of a rule that does not exist.

`lexicographic_shortfall` is `max(0, mean - min)` — the absolute amount by which the least-served
household falls below the average, in the resource's own unit. It is deliberately not a
dispersion ratio: a max-min rule is not a statement about dispersion.

## Economic comparators

`PairedSummary` gained `comparison_kind`, `mean_relative_percent` and
`zero_denominator_observations`. A `level` row reports one configuration's own metric, has no
comparator, and therefore reports **no** percentage. A `difference` row always names both sides.

The zero-denominator rule §4.8 demands is stated in the data itself:
`OOS_RELATIVE_COMPARATOR_FLOOR = 1e-6`, written to every row as `RelativeDenominatorFloor`. An
observation whose baseline falls below it is excluded from the percentage and counted in
`ZeroDenominatorObservations` — never reported as a large or infinite value.

On the bounded probe: 441 difference rows, every one naming both sides; every level row reporting
`NaN` for the percentage.

## Shard interfaces — defined, not activated

Directory layout, atomic completion, conflict detection and canonical merge order are defined and
exercised by `OS5`. No worker, scheduler or concurrent writer exists; that is Stage 13.

- A directory **without** a marker is incomplete by definition, so a crash mid-write can never be
  mistaken for a finished shard.
- The marker is written last and carries the content digest, so content changed afterwards is
  reported as a **conflict** rather than silently overwritten.
- Re-committing identical content is idempotent: same bytes, same digest.
- `canonical_merge_order` sorts by task identifier, so the merge order is the manifest's and
  never the order in which tasks happened to finish.

## Explicit v2 to v3 migration

A directory declaring v1 or v2 predates the three new files and the new columns. It stays
readable: their absence is a **warning naming the version**, never an error and never a silent
reinterpretation. A directory that *claims* v3 but lacks them is an error, so the migration
cannot be used to smuggle an incomplete v3 directory through. `OS5` checks both directions.

## Files changed for Stage 10

| File | Stage-10 change |
|---|---|
| `codes/oos_experiment/result_identity.jl` | **new** — `OOSRunIdentity`, `parallel_task_id`, `scientific_row_key`, the shard interfaces |
| `codes/oos_experiment/metrics.jl` | `PolicyFairnessDiagnostics`, `applicable_fairness_diagnostic`, `lexicographic_shortfall`, `paired_relative_differences`; `PairedSummary` comparator fields |
| `codes/oos_experiment/output.jl` | identity columns on every period-level frame; the three new frames; the relative comparator; retained two-argument frame shapes |
| `codes/oos_experiment/output_schema.jl` | version 3, the new required columns, `OOS_SCHEMA_V3_FILES`/`_COLUMNS` and the migration path |
| `codes/oos_experiment/simulator.jl` | `PeriodRecord.rolling_start` |
| `codes/oos_experiment/oos_experiment.jl` | the campaign passes its real identity and share table |
| `tests/oos/result_schema_tests.jl` | **new** — focused sets `OS0`–`OS5` |
| `tests/oos/runtests.jl`, `structural_catalog_tests.jl` | schema-version and reader-scan assertions migrated |
| `docs/oos_stage10_completion_report.md` | **new** — this record |

## Tests migrated, and why

| Test | Old claim | New claim |
|---|---|---|
| `S7`, `S11` | `OOS_OUTPUT_SCHEMA_VERSION == 2` | it is 3; the manifest stayed at 2, and the pair now asserts the two contracts differ numerically, which is the point |
| `S11` | the downstream reader never mentions `StructuralInstanceID` | it is a legitimate result column now; the surviving claim — the reader must not require the manifest FILE — is asserted directly |
| `5.13` | a hand-built `ReplicationMetrics` fixture | it carries the new diagnostics bundle |

## Tests

| Test set | Assertions | Result |
|---|---:|---|
| `OS0` a written directory validates as v3 | 28 | PASS |
| `OS1` no percentage lacks a comparator | 1,336 | PASS |
| `OS2` no statistic validates an incompatible policy | 72 | PASS |
| `OS3` `NONE` and `STATIC_DEMAND_SHARE` stay separable | 7 | PASS |
| `OS4` the identity is deterministic and provenance-free | 30 | PASS |
| `OS5` shard interfaces and the v2 migration | 20 | PASS |

| Gate | Result |
|---|---|
| full `validate_oos_experiment.sh` | exit 0, **23,401 assertions**, 0 failed, 385.1 s |
| bounded preflight | exit 0, **`PREFLIGHT_RESULT=READY`**, 0 failed checks, 667.0 s |

## Decisions and remaining ownership

- **No deviation from the Stage-10 contract.**
- **Structural identifiers are degenerate on the single-instance path.** The columns exist so the
  schema is final; Stage 13 fills them from the manifest without another bump.
- **Stage 13 owns activation.** Everything here is an interface plus its tests. No worker,
  scheduler, concurrent writer or merge execution was created.
