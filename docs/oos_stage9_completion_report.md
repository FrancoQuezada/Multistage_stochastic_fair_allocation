# OOS redesign — Stage 9 completion report

**Stage:** 9 — Multi-period action extraction, recoverability, and warm starts
**Scope authority:** `docs/oos_redesign_plan.md` §4.9 and §7 (Stage 9)
**Date:** 2026-08-08
**Status:** **COMPLETE**

## Outcome and scope

Stage 6 delivered ordered block extraction and sequential implementation. Stage 9 hardens the
hand-off between rolling solves and adapts the warm start to a window that moves.

The state passed to the next solve is now the product of `h` sequential physical transitions, and
the next look-ahead is built as if that state were exactly reachable. Stage 9 makes that
*checkable* rather than assumed, and makes an unrecoverable state stop the configuration.

## Recoverability

`check_state_recoverability` runs after every implemented block and tests three independent
conditions that the per-action validation does not already cover:

| Condition | What it catches |
|---|---|
| **Continuity** | the state stands at `last(block) + 1` and its revealed history covers the block — a skipped or twice-implemented period |
| **Admissibility** | the *carried* state of charge lies in `[s_min, s_max]`; the per-action check verifies the transition, this verifies the value the next model will use as `state.soc_before` |
| **Replay** | re-applying the block's implemented aggregate flows to the state of charge that entered the block reproduces the carried value — an accumulated drift no single-period residual is large enough to reveal |

The replay tolerance scales with the block length (`h * feasibility_tol`): `h` sequential
transitions can accumulate `h` times the per-transition round-off, and holding a ten-period block
to a one-period tolerance would reject arithmetic rather than error.

A failing check is **blocking**. It raises `physical_violations`, records the named violations in
the failure message and stops the configuration. It repairs nothing — `RC1` asserts that the
state it was handed is byte-identical afterwards.

## No silent repair

The prohibition is enforced three ways rather than asserted once:

1. **Structurally.** `PeriodAction` and `ActionValidation` are immutable, so no layer can edit an
   extracted action in place even by accident. `RC4` asserts `!ismutabletype` on both.
2. **By source gate.** No `clamp(` on the implementation path. `min(max(...))` is deliberately
   *not* forbidden: it appears in `model_side_residuals` as the simultaneous-flow measurement,
   which reports a violation rather than removing one, and a gate that banned it would be
   forbidding the diagnostic instead of the repair.
3. **By behaviour.** A deliberately invalid action is rejected with its violation named, and the
   action object is unchanged.

A failed warm start falls back to solving **cold**. It is never permission to change the model or
the implemented action.

## Warm starts under a moving window

`derive_mode_start_from_previous` maps the previous solve forward **by calendar period**, which is
exactly what a shifted fixed window needs: the previous window `t : t+L-1` and the new one
`t+h : t+h+L-1` overlap on `t+h : t+L-1`, those periods map across by their own labels, and the
`h` newly entered tail periods have no predecessor and take the documented idle value. Nothing is
aligned by node index, which would be wrong the moment the window moves.

It now also reports `carried_nodes` and `fresh_nodes`, so the split between reused and newly
entered information is measurable rather than implicit. `lookahead_window_overlap` exposes the
overlap itself; `RC2` checks it equals `L - h` for `h in {1, 4, 10}`:

| `h` | window overlap | observed |
|---:|---:|---:|
| 1 | `L - 1 = 23` | 23 |
| 4 | `L - 4 = 20` | 20 |
| 10 | `L - 10 = 14` | 14 |

## Cold and warm equivalence, and two degeneracies it exposed

A bounded `MULTISTAGE_RH` probe gives identical total operating cost to the last printed digit:

| `h` | warm | completed | periods | total cost |
|---:|---|---|---:|---:|
| 1 | no | yes | 24 | 431 899.8786 |
| 1 | yes | yes | 24 | 431 899.8786 |
| 4 | no | yes | 24 | 431 982.1179 |
| 4 | yes | yes | 24 | 431 982.1179 |

Writing `RC3` surfaced two genuine degeneracies that a naive equality assertion would have
mislabelled as warm-start defects. Both are now asserted explicitly instead of tolerated:

- **The household PV split under `NONE` is not unique.** With no distributive rule, total cost
  depends on the aggregates alone, so any split with the same community total is equally optimal.
  Cold and warm land on different vertices of that optimal face — observed as exact permutations
  of one another with identical sums. `RC3` therefore asserts equality of total cost, state of
  charge, aggregate flows and the community PV total, and separately re-runs under
  `STATIC_DEMAND_SHARE`, which *does* pin the split, to confirm household-by-household agreement
  there. That contrast is what shows the difference is degeneracy and not a warm-start effect on
  the decision.
- **The shared mode is free at an idle period.** Where both aggregate flows are zero the binary is
  unconstrained and `OOS_IDLE_MODE_VALUE` breaks the tie, so cold and warm may disagree. `RC3`
  requires mode agreement only where the battery actually moves.

**This matters beyond the test.** `NONE`'s per-household PV allocation is an arbitrary optimum,
so the Stage-10 fairness reporting must present `NONE` household allocations as *outcomes* of a
degenerate problem, not as a meaningful distributive result. The plan already requires `NONE`
statistics to be labelled as outcomes rather than violations; this is the concrete reason.

## Files changed for Stage 9

| File | Stage-9 change |
|---|---|
| `codes/oos_experiment/validation.jl` | `StateRecoverability`, `check_state_recoverability` |
| `codes/oos_experiment/warm_starts.jl` | window-shift semantics documented; `carried_nodes`/`fresh_nodes`; `lookahead_window_overlap` |
| `codes/oos_experiment/simulator.jl` | the recoverability check after every block; the warm start consumes the new return shape and falls back cold |
| `tests/oos/recoverability_tests.jl` | **new** — focused sets `RC0`–`RC4` |
| `tests/oos/runtests.jl` | `22.11` migrated to the new deriver shape |
| `docs/oos_stage9_completion_report.md` | **new** — this record |

## Tests

| Test set | Assertions | Result |
|---|---:|---|
| `RC0` a legitimate hand-off is accepted | 21 | PASS |
| `RC1` a broken hand-off is rejected and named | 13 | PASS |
| `RC2` the warm start follows the moving window | 24 | PASS |
| `RC3` cold and warm are semantically equivalent | 404 | PASS |
| `RC4` no silent repair on the implementation path | 15 | PASS |

`RC1` exercises all four failure modes — discontinuity, inadmissibility, drift and a block/action
count mismatch — and asserts the specific violation text for each, so a check that silently
stopped detecting one of them would fail.

| Gate | Result |
|---|---|
| full `validate_oos_experiment.sh` | exit 0, **21,896 assertions**, 0 failed, 361.8 s |
| bounded preflight | exit 0, **`PREFLIGHT_RESULT=READY`**, 0 failed checks, 645.1 s |

## Decisions and remaining ownership

- **No deviation from the Stage-9 contract.**
- **Warm starts remain off by default.** They are a performance lever; `RC3` establishes the
  equivalence that makes turning them on safe, and Stage 12 can measure whether they pay.
- **The two degeneracies are recorded, not fixed.** They are properties of the formulation, not
  defects: `NONE` genuinely does not pin the split, and an idle battery genuinely has a free mode.
  Stage 10 must label `NONE` household allocations accordingly.
