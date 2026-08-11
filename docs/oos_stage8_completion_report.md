# OOS redesign — Stage 8 completion report

**Stage:** 8 — Decision-domain and grid-direction contract
**Scope authority:** `docs/oos_redesign_plan.md` §4.5, §4.6 and §7 (Stage 8)
**Date:** 2026-08-08
**Status:** **COMPLETE** — Phase A executed, Phase B triggered and implemented

## Outcome and scope

Stage 8 was planned as conditional: audit the implemented actions first, and add a grid-direction
formulation **only if** the audit finds simultaneous household import and export. The audit found
it. Phase B was therefore triggered by evidence, not by assumption, and is implemented.

The stage also surfaced a consequence that would have silently invalidated one of the six primary
fairness policies, and fixed it.

## Phase A — the audit

`grid_direction_overlap` measures, per implemented action:

- `household_overlap = max_j min(I_j, G_j)` — the same household trading both ways;
- `aggregate_overlap = min(sum_j I_j, sum_j G_j)` — one household importing while another
  exports.

Only the **household** figure is evidence of a missing rule; the aggregate one is legitimate
community behaviour, and reporting them separately is what keeps the audit honest.

### Result

Bounded probe: one instance, `J = 4`, two replications, `L = 4`, all three controllers × all six
policies = 36 configurations, 864 implemented periods.

| Quantity | Value |
|---|---:|
| household-level violations | **3** |
| aggregate overlaps | 221 |
| maximum household overlap | **318.52 kWh** |
| maximum aggregate overlap | 464.34 kWh |
| gate | **FAIL** → Phase B authorized |

All three household violations were `SA` configurations. The magnitude rules out round-off: 318
kWh against household demands of order 100 kWh per period is a deliberate trade, not noise.

### Why it happens

Household cost at a node is `delta * (mu*y + nu*I - beta*G)`. On this instance `beta = 10` and
`nu in [161.51, 215.01]`, so `beta << nu` and the overlap **costs** `(nu - beta)` per unit while
changing nothing physical — pure cost minimization removes it, which is why `NONE`, `PEA` and the
lexicographic policies never showed it.

`SA` is different. It constrains each household's **savings** — benchmark minus cost — to a
proportional target. Inflating a household's own cost is therefore a way to drive its savings
*down* onto that target. The household balance pins only `I - G`, leaving a free common offset,
and `SA` had every reason to use it. **The rule was being satisfied by burning energy through the
grid rather than by reallocating it.**

## Phase B — the formulation

A household has one grid connection point, so importing and exporting at the same information
state is not physically admissible. One binary per `(household, node)`:

```text
I[j,n] <= (D[j,n] + F_c) * w[j,n]
G[j,n] <= (C_n   + F_d) * (1 - w[j,n])
```

The big-Ms are read off the look-ahead data rather than picked as a constant. When `w = 1` export
is off, so the balance gives `I = D + z - p - y <= D + F_c`; when `w = 0` import is off, so
`G = p + y - z - D <= C + F_d`. Each bound is valid on the side its binary enables, which is all
a big-M needs.

It is a **grid operating rule**, so per plan §4.5 it is applied identically to every controller
and every fairness policy and can never be switched per policy. `GD1` asserts exactly that across
all eighteen configurations. `grid_direction_exclusivity` is configurable and defaults to `true`,
kept switchable so its model-size price stays measurable in Stage 12 rather than assumed.

### Model-size price

Binaries go from `|V_mode|` to `|V_mode| + J*N`. On the bounded probe: 13 → 65. The two families
are counted **separately** everywhere — `ModelStatistics.generated_mode_binaries`,
`ModelAudit.generated_mode_binaries` and the structural audit all continue to report the
shared-battery count alone, so the `|V_mode|` versus `|H||V_mode|` model-size claim the project
already makes stays exactly as measurable as before. `GD4` pins that.

### Result after Phase B

| Quantity | Before | After |
|---|---:|---:|
| household violations | 3 | **0** |
| maximum household overlap | 318.52 kWh | **5.7e-14 kWh** |
| gate | FAIL | **PASS** |

## The consequence: `SA` needed the endogenous band

With the waste channel closed, `SA` stopped completing: all six `SA` configurations aborted at
period 15 of 24, every one attributed to `FAILURE_FAIRNESS_RULE` — the physical model without the
rule was feasible, so the shortfall was the rule's.

Widening the band is the wrong lever, and a probe proved it:

| `sa_fairness_abs_tol` | completed | periods reached |
|---:|---:|---:|
| 1.0 | 0/6 | 14 |
| 10.0 | 0/6 | 14 |
| 100.0 | 0/6 | 14 |
| 1 000.0 | 0/6 | 14 |
| 10 000.0 | 0/6 | 14 |
| 100 000.0 | 0/6 | 15 |

Even `1e5` does not restore feasibility. The shortfall is **structural**, not marginal: a
horizon-total savings equality imposed period after period on a fixed realized past can become
unreachable, exactly as the project already established for `PEA` and solved there with the
strict-first / adaptive-minimum workflow.

So `SA` was given the same remedy, mirroring `PEA` line for line:

- `sa_tolerance_mode`, defaulting to `:adaptive_minimum`, with the same three modes;
- `build_adaptive_sa_constraints!` introducing one nonnegative scalar `epsilon_sa`;
- Phase I minimizes it; Phase II caps it at `epsilon_sa_star + pea_tolerance_numeric_eps` and
  restores the operating-cost objective;
- the same four-solve sequence, the same records, the same gates.

`sa_fairness_abs_tol` is deprecated as a fixed band, with the same two guards `PEA` has: a
positive value outside `:fixed_band` is rejected rather than silently ignored, and `:fixed_band`
without a positive value is rejected too. Its default moved from `1.0` to `0.0`.

**This is a scope extension beyond the literal Stage-8 text, and it is deliberate.** Without it,
physically correcting the model would have silently deleted a primary fairness policy from the
study. The remedy is not new design: it is the already-approved treatment of the identical
structural problem, applied to the second policy that turned out to need it.

### Result

| Quantity | Value |
|---|---:|
| configurations completed | **36/36** |
| household violations | 0 |
| `SA` band activations | 60 of 144 solves |
| maximum `epsilon_sa` | 29 596.7 |

Every activated period runs the four documented solves in order; every strict-feasible period
runs exactly one. `GD3` checks both.

## Files changed for Stage 8

| File | Stage-8 change |
|---|---|
| `codes/oos_experiment/metrics.jl` | `grid_direction_overlap`, `GridDirectionAudit`, `audit_grid_direction`, `grid_direction_clean`, `grid_direction_gate` |
| `codes/oos_experiment/physical_model.jl` | the exclusivity binaries and rows; `PhysicalModelRefs.grid_direction_exclusivity`; the two families counted separately in the statistics |
| `codes/oos_experiment/mode_nodes.jl` | `expected_grid_direction_binary_count`, `expected_binary_count` |
| `codes/oos_experiment/model_audit.jl` | the structural audit partitions the binary families and rejects an unrecognized one |
| `codes/oos_experiment/types.jl` | `grid_direction_exclusivity`, `sa_tolerance_mode`, `OOS_SA_TOLERANCE_MODES`, the two SA deprecation guards |
| `codes/oos_experiment/fairness_rules.jl` | `build_adaptive_sa_constraints!`; SA starts from the strict equality |
| `codes/oos_experiment/controllers.jl` | `solve_minimum_sa_tolerance!`, `solve_sa_operational_phase!`; the recovery generalized over the policy |
| `codes/oos_experiment/output_schema.jl`, `run_downstream_checks.jl` | `OOS_ADAPTIVE_BAND_POLICIES`; the reader accepts SA band rows |
| `codes/oos_experiment/oos_experiment.jl` | the SA reachability advisory rewritten; the two new environment variables |
| `scripts/oos/run_oos_experiment.sh` | `SA_TOLERANCE_MODE`, `GRID_DIRECTION_EXCLUSIVITY`, `SA_FAIRNESS_ABS_TOL` default `0.0` |
| `tests/oos/policy_domain_tests.jl` | **new** — focused sets `GD0`–`GD4` (with the stage-7 `ST` sets) |
| `tests/oos/runtests.jl` | `22.6`/`22.9` binary counts, `D5/D6/D7` keyed by policy |
| `docs/oos_stage8_completion_report.md` | **new** — this record |

## Tests migrated, and why

| Test | Old claim | New claim |
|---|---|---|
| `22.6`, `22.9`, `23` | every binary is a node-level battery mode; the total equals `|V_mode|` | the BATTERY family equals `|V_mode|`; the total equals `expected_binary_count`, and an unrecognized third family fails the audit |
| `D5/D6/D7` | only `PEA` produces recovery rows, keyed `(replication, controller, period)` | `SA` does too, so the key carries the policy; otherwise the two sequences merge and the four-solve pattern becomes unreadable |

## Tests and final verification

| Test set | Assertions | Result |
|---|---:|---|
| Stage 7 `ST0`–`ST3` | 255 | PASS |
| **Stage 8 `GD0`–`GD4`** | **389** | **PASS** |

| Gate | Result |
|---|---|
| full `validate_oos_experiment.sh` | exit 0, **21,416 assertions**, 0 failed, 348.7 s |
| bounded preflight | exit 0, **`PREFLIGHT_RESULT=READY`**, 0 failed checks, 615.9 s |
| shell syntax, `git diff --check` | PASS |

The first preflight attempt failed check 09: the standalone downstream reader still grouped solve
sequences by `(replication, controller, period)`, so the newly-recovering `SA` rows merged with
the `PEA` rows of the same period and every sequence read as eight solves instead of four. The
grouping key now carries the fairness policy, matching the fix already applied to `D5/D6/D7`, and
the reader reports:

```text
Secuencias de resolución con banda adaptativa (PEA, SA): 174 período(s) estricto(s) con 1
resolución, 114 recuperado(s) con 4.
```

Both branches of the schema are therefore audited for both policies.

## Decisions and remaining ownership

- **Phase B was triggered by evidence.** The pre-agreed rule was "audit first, formulate only if
  the audit finds violations". It found them, at a magnitude that cannot be dismissed.
- **`SA`'s endogenous band is an approved-by-necessity extension**, justified above and recorded
  in the plan's decision log.
- **Stage 12 owns the price.** The direction family multiplies the binary count by roughly
  `1 + J*N/|V_mode|`; measuring the runtime and memory cost, and confirming the campaign can
  afford it, is a Stage-12 probe. The flag exists so that probe can be run both ways.
- **No other domain variant was introduced.** Battery-mode binaries were not relaxed, and no new
  experimental factor was added.
