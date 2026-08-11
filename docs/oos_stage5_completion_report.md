# OOS redesign — Stage 5 completion report

**Stage:** 5 — Common conditional stochastic support across methods
**Scope authority:** `docs/oos_redesign_plan.md` §4.2, §4.3, §4.4, §4.9 and §7 (Stage 5)
**Date:** 2026-08-08
**Status:** **COMPLETE**

## Outcome and scope

Stage 5 removes the deepest confounder in the experiment. Until now each controller sampled its
own look-ahead from a stream keyed by `(experiment_seed, replication, period, controller)`, so
`TWO_STAGE_RH` and `MULTISTAGE_RH` saw unrelated Monte Carlo draws and `DETERMINISTIC_RH`
followed an analytic conditional mean generated separately from both. Any measured difference
between the three methods mixed the effect of the information structure — the quantity the study
exists to measure — with the effect of having received different samples.

From this stage there is **one conditional stochastic object per `(replication, rolling start)`**
and the three methods are views of it:

| Method | View |
|---|---|
| `MULTISTAGE_RH` | the complete tree, with its intermediate nonanticipativity |
| `TWO_STAGE_RH` | the same leaf paths and leaf probabilities, without intermediate nonanticipativity after the root |
| `DETERMINISTIC_RH` | the probability-weighted mean of those same leaves, period by period |

Stage 6 and later were not started: the known prefix is still one period, `implementation_step > 1`
is still rejected, and the structural manifest is still not consumed by the runner.

## The new seed contract

`codes/oos_experiment/common_support.jl` introduces the stream

```text
lookahead_support   keys: experiment_seed, oos_replication, rolling_start
```

and retires `lookahead`, whose key contained the controller. The exclusion is *structural*, not a
convention: `lookahead_support_seed` takes exactly three `Int` arguments, so no future edit can
introduce a controller, a fairness policy, a solver phase, a worker, a retry count or an
execution order without changing the signature. Test `CS0` asserts the arity and the types for
precisely that reason.

The legacy stream coexists with the structural one exactly as `oos_path` coexists with
`structural_oos_path`: the manifest-driven path keeps `conditional_support` with its full
structural key (`structural_catalog.jl`), and the single-instance runner uses
`lookahead_support`. The two names are distinct, so neither hierarchy can consume the other's
numbers.

## `OOSCommonConditionalSupport`

Immutable, RNG-free once built, and a pure function of its seed key. It carries the multistage
`ConditionalTree`, the leaf nodes, the leaf probabilities, the resolved branching and
periods-per-stage layout, the seed and its stream, and a `ScenarioSupportID`.

A **fresh support is generated at every rolling start** (plan §4.2). The experiment does not keep
one tree per replication and does not prune or update a previous tree in place; `CS8` checks that
the seeds differ across starts and that each root is that period's realization.

### The three views

`two_stage_support_view` converts each root-to-leaf path of the multistage tree into one
independent future chain carrying that leaf's probability. No value is resampled and no
probability is renormalized — the two structures are two readings of one object. On a bounded
probe with branching `[2, 2]` over a 24-period window: multistage 56 nodes, two-stage 93 nodes,
identical leaf `pv` paths, identical leaf probabilities.

`deterministic_support_view` computes `pv[k] = Σ_s p_s · pv_s[k]` and the same for demand, with
entry 1 copied verbatim from the observed root rather than averaged so the realized current
period stays exact. On the same probe the difference against an independently computed weighted
mean is `0.0`.

No PEA repair is applied to the mean path, and applying one would be wrong: every leaf was
already repaired when sampled, so each satisfies `Σ_j D_j ≥ C`; averaging preserves the
inequality, and repairing again would move the mean away from the leaves it must be derived
from. `CS2` checks both the identity and the preserved feasibility.

## `ScenarioSupportID`

A stable digest over the seed contract and the resolved tree geometry, through the canonical JSON
writer and the repository's persisted FNV-1a digest — never Julia's `hash`. It deliberately
contains no controller, fairness policy, worker or ordering information, so **the three
controllers at one rolling start report the same identifier**. That is what makes the
common-support claim auditable from the records rather than only from the code.

It is propagated into `PeriodRecord.scenario_support_id`. It does not reach the result CSVs yet:
the output schema is Stage 10, and `output_schema_version` stays at 2.

## Task-local cache

`OOSLookaheadCache` holds one support per rolling start plus the three views derived from it.
Indexing with `(rolling_start, controller)` returns the view, which keeps the simulator and the
fixtures on their familiar call shape while the object behind them is now shared. Nothing in it
is worker-global or mutable after construction, so one cache serves both battery variants, all
three controllers and all six fairness policies of a task (plan §4.9).

## Consequence: `two_stage_scenarios` no longer drives generation

`TWO_STAGE_RH` must use the leaves of the common support (§4.3), so the scenario count is fixed
by `multistage_branching` and `multistage_periods_per_stage`. `two_stage_scenarios` is preserved
for provenance and recorded in metadata as `two_stage_scenarios_drives_generation = false`, with
`two_stage_leaves_derived_from = "common_conditional_support"`.

**This has a real modelling consequence that Stage 12 must settle.** The default branching
`[2, 2]` yields four leaves, where the previous two-stage controller drew twenty independent
scenarios. The common-support leaf count is already listed in §12 as an open decision; the
campaign will almost certainly need a larger branching vector than the current default, and that
choice is now a *single* decision governing all three methods instead of two unrelated ones.

## Consequence: the deterministic controller changed

It moved from the analytic conditional mean (`conditional_mean_path`) to the empirical
probability-weighted mean of the common leaves. This is required by §4.3 and it changes reported
numbers. `conditional_mean_path` is retained and still directly tested by `P3`; it is simply no
longer what the controller solves.

## Files changed for Stage 5

| File | Stage-5 change |
|---|---|
| `codes/oos_experiment/common_support.jl` | **new** — stream, seed, support type, three views, `ScenarioSupportID`, task-local cache |
| `codes/oos_experiment/simulator.jl` | `build_lookahead_tree` returns a view of the common support; `cache_lookahead_trees` builds one support per start; `PeriodRecord.scenario_support_id` |
| `codes/oos_experiment/uncertainty_provider.jl` | `lookahead_rng` retired, with the reason recorded in place |
| `codes/oos_experiment/oos_experiment.jl` | include order |
| `codes/oos_experiment/output.jl` | conditional-support seed contract and the `two_stage_scenarios` deprecation in metadata |
| `tests/oos/common_support_tests.jl` | **new** — focused sets `CS0`–`CS8` |
| `tests/oos/runtests.jl` | `22.6` and `22.13` migrated; include of the new set |
| `tests/oos/structural_catalog_tests.jl` | `S11` seed assertions migrated to the retired stream |
| `tests/oos/rolling_horizon_tests.jl` | `R8` builds an `OOSLookaheadCache` |
| `README.md`, `docs/oos_experiment.md`, `docs/oos_redesign_plan.md` | contracts, consequences, decisions, stage status |
| `docs/oos_stage5_completion_report.md` | **new** — this record |

## Tests migrated, and why

| Test | Old claim | New claim |
|---|---|---|
| `22.6` | the two-stage leaf count is `two_stage_scenarios` | it is the common support's leaf count, so the fixture sets `multistage_branching = [4]` and additionally asserts the count is *not* `two_stage_scenarios` |
| `22.13` | the independent full-horizon reference is built from `conditional_mean_path` | it is built from the deterministic VIEW the controller actually solves; the test now also asserts that view differs from the analytic mean while sharing its root |
| `S11` | the controller is still part of the look-ahead key, "removing it is stage 5" | `lookahead_rng` is gone; `lookahead_support_rng` is keyed without the controller, and the legacy and structural streams stay distinct |
| `R8` | the empty cache is a `Dict` | it is an empty `OOSLookaheadCache` |

## Tests and final verification

| Test set | Assertions | Result |
|---|---:|---|
| Stage 4 `R0`–`R9` | 1,547 | PASS |
| **Stage 5 `CS0`–`CS8`** | **998** | **PASS** |

Stage-5 counts by set were `19, 93, 123, 11, 218, 498, 19, 5` for `CS0`–`CS3` and `CS5`–`CS8`,
plus `CS4`. `CS4` was bounded to `H = L = 6` after an initial version took 3 m 49 s simulating the
full controller × policy matrix over 24 rolling starts; the claim it defends needs several
rolling starts, not a long horizon.

### Final results

| Gate | Result |
|---|---|
| full `validate_oos_experiment.sh` | exit 0, **17,630 assertions**, 0 failed, 305.0 s |
| bounded preflight | exit 0, **`PREFLIGHT_RESULT=READY`**, 0 failed checks, 564.9 s |
| shell syntax, `git diff --check` | PASS |

Preflight checks `01`–`04`, `06`–`14` and `17` all passed, with the two advisory warnings carried
since Stage 3. Check `09` still reports both branches of the PEA solve-sequence schema, so
replacing the per-controller sampling did not silently remove the recovery path from the audit.

## Decisions, deviations and remaining ownership

- **No deviation from the Stage-5 contract.**
- **No new dependency**; the identifier reuses the accepted canonical-JSON and digest layer.
- **`conditional_scenario_paths` is retained but unused by the simulator.** It remains a directly
  tested provider interface (`P3`); the two-stage structure is now derived from the tree.
- **Parallel readiness.** The support is immutable, seeded by a key that excludes worker and
  ordering, and cached task-locally and read-only. `CS6` proves controller/fairness order
  invariance; no worker, shard or concurrent writer was created.
- **Stage 6 and later were not started.** The known prefix is still one period, the multistage
  first stage is not yet forced to length `h`, and `implementation_step > 1` is still rejected.

## Prerequisites for Stage 6

Stage 6 generalizes the known prefix from one period to `h`. The support layer is where most of
that work lands: `build_common_conditional_support` must produce a tree whose first `h` periods
form a single deterministic chain carrying the *realized* values, with branching starting at
`t + h`. That requires `multistage_lookahead_tree` and `conditional_scenario_tree` to accept a
known-prefix length and `multistage_stage_layout` to force the first stage to `h`. All three
views inherit the prefix automatically, which is the point of having one object.
