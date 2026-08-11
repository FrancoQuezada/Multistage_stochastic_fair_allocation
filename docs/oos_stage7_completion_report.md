# OOS redesign — Stage 7 completion report

**Stage:** 7 — Static-demand-share extension and calibration
**Scope authority:** `docs/oos_redesign_plan.md` §4.6 and §7 (Stage 7)
**Date:** 2026-08-08
**Status:** **COMPLETE**

## Outcome and scope

Stage 4 already extended the `STATIC_DEMAND_SHARE` coefficients past the repository horizon
through `base_period_index`, as an approved deviation, because no model over a moving window can
be built without them. Stage 7 completes the rest of the scope: the coefficients become an
**auditable object with an identity** rather than a bare matrix passed around.

`OOSStaticShareTable` is resolved once per structural instance from the common ex-ante in-sample
expected demand, is immutable within a task, and carries a `ShareTableID`. It is provably
independent of the OOS replication, the controller and the fairness policy being solved, and it
never reads a realized future.

## What the table guarantees

The constructor validates, and rejects rather than repairs:

| Property | Check |
|---|---|
| shape | `J x base_horizon` base table, `J x period_end` extended table |
| allocation | every column sums to one within `OOS_SHARE_TABLE_SUM_TOL = 1e-9` |
| nonnegativity | no coefficient below `-1e-9` |
| base preservation | `shares[:, 1:T0] == base_shares`, with `==`, not a tolerance |
| repetition | `shares[:, tau] == shares[:, base_period_index(tau, T0)]` for every `tau` |

`ShareTableID` is a stable digest over the **base** coefficients plus the mapping contract and
`period_end`, through the canonical JSON writer and the repository's persisted digest. Two
contracts that differ only in window length therefore get different identifiers, so a reader can
distinguish "same benchmark, longer window" from "different benchmark" instead of guessing.

The repository's verified `static_demand_shares` is still what computes the base table, so the
benchmark keeps its published definition. Stage 7 wraps it; it does not redefine it.

## Independence, checked rather than asserted

Set `ST1` builds the table under four variations that must not move it — a different controller
set, a different fairness set, a different replication count, a different solver-thread setting —
and asserts the identifier and the coefficients are unchanged in all four. It then confirms that
an instance-level change (`households`) *does* move it, so the test cannot pass vacuously.

Set `ST3` adds a source gate: the body of `resolve_static_share_table` may not mention an OOS
path, a replication or a controller.

## Not an alias for `NONE`

Set `ST2` runs `NONE` and `STATIC_DEMAND_SHARE` on the same instance, replication and support,
and asserts that the maximum per-period allocation difference exceeds `1e-3`. It also verifies
that every implemented `lambda` equals its coefficient, so the rule is demonstrably binding and
not merely present. The two policies keep distinct `Resource` labels (`none` versus `pv`).

## Interface

`add_fairness_constraints!`, `solve_current_action`, `simulate_configuration` and
`run_controller_fairness_gate` all accept either the resolved table or a bare coefficient matrix.
Passing the table is the campaign path; passing the matrix is retained so the many existing
fixtures are unchanged. `ST2` checks the two produce identical decisions.

`OOSCommonObjects` gained `share_table`; `static_shares` remains as its coefficients under the
original name, so no existing consumer changed.

## Files changed for Stage 7

| File | Stage-7 change |
|---|---|
| `codes/oos_experiment/fairness_rules.jl` | `OOSStaticShareTable`, `share_table_id`, `resolve_static_share_table`, `share_table_summary`; the constraint installer accepts the table |
| `codes/oos_experiment/oos_experiment.jl` | `OOSCommonObjects.share_table`; the runner resolves the table once and reports its identifier |
| `codes/oos_experiment/controllers.jl`, `simulator.jl`, `validation.jl` | accept the table alongside the matrix |
| `tests/oos/policy_domain_tests.jl` | **new** — focused sets `ST0`–`ST3` (with the stage-8 `GD` sets) |
| `docs/oos_stage7_completion_report.md` | **new** — this record |

## Tests

| Test set | Assertions | Result |
|---|---:|---|
| `ST0` the table is resolved, identified and immutable | 160 | PASS |
| `ST1` it depends on the instance and nothing else | 12 | PASS |
| `ST2` it is imposed and differs from `NONE` | 77 | PASS |
| `ST3` it never reads a realized future | 6 | PASS |

Gate results are recorded jointly with Stage 8 in `docs/oos_stage8_completion_report.md`, because
the two stages were verified in one run; both are small and independent, and neither touches the
other's contract.

## Decisions and remaining ownership

- **The Stage-4 deviation is now closed.** The mechanical extension implemented early is the same
  code the table wraps; nothing was reimplemented.
- **Calibration is not Stage 7's.** The plan's Stage-7 title mentions calibration, but every
  numeric factor level remains a Stage-12 decision. Stage 7 delivers the object those probes will
  identify their results by.
