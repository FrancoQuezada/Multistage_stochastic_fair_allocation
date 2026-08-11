# OOS redesign — Stage 6 completion report

**Stage:** 6 — Arbitrary implementation blocks and known prefixes
**Scope authority:** `docs/oos_redesign_plan.md` §4.1, §4.9, §6 and §7 (Stage 6)
**Date:** 2026-08-08
**Status:** **COMPLETE**

## Outcome and scope

Stage 6 generalizes observation, nonanticipativity, action extraction, implementation and the
state update from `h = 1` to every admissible implementation step. `implementation_step` becomes
a real experimental factor rather than a validated configuration field the simulator refused.

At each rolling start `t` the simulator now:

1. reveals the **complete** known prefix `t : t+h-1` in one step, before any controller optimizes;
2. builds a conditional support whose first `h` periods are a single deterministic chain carrying
   those realizations, with branching beginning no earlier than `t+h`;
3. solves once and extracts the **ordered block** of `h` committed actions from that chain;
4. validates and implements them in order, advancing the physical and fairness state after each;
5. records only the periods inside `1:H`, while committing and validating every period of the
   block — including those of a final non-divisible block that runs past `H`.

With `h = 1` every one of these collapses to the Stage-5 behaviour exactly, which set `B1`
verifies rather than assumes.

## The known prefix

### Layout

`multistage_stage_layout_with_prefix` wraps the existing layout. Stage 1 never branches, so a
configured first stage already at least `h` periods long satisfies the requirement untouched.
When it does not, stage 1 grows to exactly `h`, taking periods from the later stages in order and
dropping any stage left empty together with the branching factor that would have entered it.

| `H`, `L`, `h` | Stage layout | Branching | First branch |
|---|---|---|---|
| 24, 24, 1 | `[8, 8, 8]` | `[2, 2]` | period 9 |
| 24, 24, 4 | `[8, 8, 8]` | `[2, 2]` | period 9 |
| 24, 24, 10 | `[10, 6, 8]` | `[2, 2]` | period 11 |
| 12, 8, 3 | `[3, 3, 2]` | `[2, 2]` | period 4 |
| 6, 6, 6 | `[6]` | `[]` | none |

`h = 1` and `h = 4` leave the layout untouched, which is why `h = 1` is an exact regression. The
degenerate contract `h = L` yields one deterministic chain with a single leaf, where all three
methods coincide.

### Values

Inside the prefix nothing is sampled. `multistage_lookahead_tree` takes `known_prefix` and
`known_values` and, for any node whose period lies in the prefix, writes the realization the
simulator revealed instead of calling the sampler. The frontier holds exactly one node there, so
the assignment is unambiguous. The construction also checks that the prefix's first entry equals
the observed root, so a caller cannot pass a prefix that disagrees with the period it starts at.

The latent PV state is filtered over the **whole** observed history, which now runs through
`t+h-1`. A node whose parent lies inside the prefix has no recorded parent state and continues
from that prefix-end filtered state, so branching starts conditioned on everything every
controller was told.

### All three views inherit it

`two_stage_lookahead_tree` gained the same `known_prefix`: it builds one common probability-one
chain over the prefix and starts the scenario-specific recourse chains only after it. It also
verifies that no scenario disagrees about a prefix value, so a two-stage view whose prefix was
not common is reported rather than built. The deterministic view is the weighted mean of the same
leaves and therefore reproduces the prefix exactly, because every leaf carries identical values
there.

## Block extraction and implementation

`extract_block_actions` walks the prefix chain from the root, extracting one action per committed
period through the new `extract_action_at`. A prefix that is **not** a chain is a contract
violation and is reported as one, naming the node and the period; nothing is averaged, selected
among scenarios, clipped or repaired. `extract_current_action` is retained as the root case.

`ControllerResult` gained `block_actions`, the complete ordered block. `action` remains
`first(block_actions)` so the many consumers that only look at the rolling start are unchanged.

The simulator implements the block period by period. Each action is validated against the
realized state before it is applied, and the loop aborts on the first violation, keeping the
partial records — there is still no fallback action and no clipped action.

## A defect the new tests found

`PeriodRecord.soc_before` was `result.soc_before`, the state of charge entering the **solve**.
With `h = 1` that is also the state entering the period, so the substitution was invisible. With
`h > 1` it made every record after the first in a block report the block's entering state of
charge instead of its own, breaking the chain `record[k].soc_before == record[k-1].soc_after`.

Set `B2` caught it. The simulator now captures `state.soc_before` immediately before
`apply_action!` and records that. This is a reporting correction, not a change to any decision:
no optimization input, action or physical transition was affected.

## Evaluation versus commitment

Completeness is now measured against the **evaluation horizon**, in both the simulator and
`metrics.jl`. With `h = 1` that equals the number of solves and nothing changes; with `h > 1` one
solve commits `h` periods, of which only those inside `1:H` are recorded.

For the plan's worked example `H = 24, h = 10`:

| Quantity | Value |
|---|---|
| rolling starts | `[1, 11, 21]` |
| final committed block | `21:30` |
| final evaluated block | `21:24` |
| realized trajectory endpoint | 30 |
| required data support endpoint | 44 |
| records produced | 24, periods `1:24` |
| solves performed | 3 |
| final state period after the run | 31 |

The periods past `H` were implemented and physically validated — the state advanced through all
of them — and none produced a record or entered a metric. The block is never silently truncated
for decision construction.

`pea_tolerances` holds one entry per **solve**, not per period, which is what makes the recovery
statistics interpretable when one solve commits several periods.

## Files changed for Stage 6

| File | Stage-6 change |
|---|---|
| `codes/oos_experiment/lookahead_tree.jl` | `multistage_stage_layout_with_prefix`; `known_prefix`/`known_values` in the multistage builder; prefix-aware two-stage builder |
| `codes/oos_experiment/uncertainty_provider.jl` | `conditional_scenario_tree` takes the prefix; `_check_history` requires the history through `t+h-1`; prefix-end filtering |
| `codes/oos_experiment/common_support.jl` | the support carries `known_prefix`; `support_prefix_nodes`; prefix-aware layout and views |
| `codes/oos_experiment/state.jl` | `reveal_block!` |
| `codes/oos_experiment/controllers.jl` | `extract_block_actions`, `extract_action_at`; `implementation_block` keyword; prefix-wide consistency assertion |
| `codes/oos_experiment/types.jl` | `ControllerResult.block_actions` |
| `codes/oos_experiment/simulator.jl` | block loop, sequential implementation, per-period `soc_before`, evaluated-only records, `assert_realized_path_covers_blocks` |
| `codes/oos_experiment/metrics.jl` | completeness against the evaluation horizon |
| `codes/oos_experiment/output.jl` | `contract_status` becomes `wired_rolling_blocks` |
| `scripts/oos/preflight_oos_campaign.sh` | check 14 extended to the non-divisible `h = 10` case |
| `tests/oos/block_implementation_tests.jl` | **new** — focused sets `B0`–`B6` |
| `tests/oos/runtests.jl`, `tests/oos/rolling_horizon_tests.jl`, `tests/oos/structural_catalog_tests.jl` | `T7`, `T9`, `R8`, `S11` migrated |
| `README.md`, `docs/oos_experiment.md`, `docs/oos_redesign_plan.md` | contracts, decisions, stage status |
| `docs/oos_stage6_completion_report.md` | **new** — this record |

## Tests migrated, and why

| Test | Old claim | New claim |
|---|---|---|
| `T9` | `h > 1` is rejected by the simulator | `h = 4` runs: six solves, twenty-four implemented and evaluated periods |
| `R8` | the metadata advertises `implementation_step_supported = [1]` | the metadata reports the wired contract; the restriction key is gone, and the block behaviour moved to `B0`–`B6` |
| `T7`, `S11` | `contract_status` is `wired_moving_lookahead: ... implementation_step > 1 is not yet supported` | it is `wired_rolling_blocks: ...`, which names the known prefix and the committed block |

## Tests and final verification

| Test set | Assertions | Result |
|---|---:|---|
| Stage 4 `R0`–`R9` | 1,544 | PASS |
| Stage 5 `CS0`–`CS8` | 998 | PASS |
| **Stage 6 `B0`–`B6`** | **2,505** | **PASS** |

Stage-6 counts by set were `1973, 23, 382, 18, 25, 24, 60` for `B0`–`B6`.

### Final results

| Gate | Result |
|---|---|
| full `validate_oos_experiment.sh` | exit 0, **20,125 assertions**, 0 failed, 302.9 s |
| bounded preflight | exit 0, **`PREFLIGHT_RESULT=READY`**, 0 failed checks, 583.9 s |
| shell syntax, `git diff --check` | PASS |

Preflight check 14 now covers both stages and reported:

```text
MOVING LOOKAHEAD OK: L=24 inicios=24 ventana final=24:47 T0=24
ROLLING BLOCKS OK: h=10 inicios=[1, 11, 21] bloque final=21:30 evaluado=21:24 registros=24
```

## Decisions, deviations and remaining ownership

- **One design decision worth recording.** The requirement is that branching begin no earlier
  than `t+h`, so the first stage is `max(h, configured first stage)` rather than exactly `h`. The
  alternative — forcing stage 1 to exactly `h` — would change the `h = 1` layout from `[8, 8, 8]`
  to `[1, ...]` and break the regression the plan explicitly asks for. Configuring a first stage
  longer than the prefix means the controller treats a few sampled periods as deterministic,
  which is the same assumption the pre-stage-6 default already made.
- **No new dependency**, no change to the physical model, the fairness formulations or the seed
  contract.
- **Parallel readiness.** `reveal_block!`, block extraction and sequential implementation all
  operate on the task's own `SimulationState`; the support and its prefix are immutable. Nothing
  worker-global was introduced.
- **Stage 9 still owns the hardening.** Recoverability checks on the state passed between rolling
  solves, and warm starts adapted to block-shifted windows, are Stage 9. What Stage 6 provides is
  the ordered extraction, sequential validation and the prohibition on silent repair.
