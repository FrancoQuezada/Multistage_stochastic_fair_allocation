# OOS redesign — Stage 4 completion report

**Stage:** 4 — Fixed moving look-ahead for `implementation_step = 1`
**Scope authority:** `docs/oos_redesign_plan.md` §4.1, §4.5, §4.9 and §7 (Stage 4)
**Date:** 2026-08-07
**Status:** **COMPLETE**

## Outcome and scope

Stage 4 is the first stage of the redesign that changes active simulator behaviour. The shrinking
interval `t:template.T` was replaced by a fixed `L`-period moving window anchored at each rolling
start, the terminal state-of-charge target moved from the repository horizon to the end of that
window, and the deterministic data support built in Stage 3 is now actually consumed: the
physical model, the realized cost accounting and the fairness aggregates read every price through
one accessor over the extended `J x materialized_data_end` matrix.

`template.T` keeps its own separate meaning throughout — repository instance horizon and length of
the repeated base profile — and is never redefined as `H`, `L`, `Tsupport` or `Tdata`.

Stage 5 and later were not started. The three controllers still draw independent look-ahead
samples (the controller is still part of the `lookahead` seed key), the structural manifest is
still not consumed by the runner, and `implementation_step > 1` is refused rather than
approximated.

## Baseline before Stage-4 editing

The working tree carried the accepted, uncommitted Stage-1/Stage-2/Stage-3 work plus the
pre-existing `results_oos/` directory; all of it was preserved. No pre-edit baseline run was
repeated in this session: the accepted `docs/oos_stage3_completion_report.md` records the
immediately preceding state as all-green (full gate exit 0 with 16,043 assertions, preflight
`READY` with 0 failed checks), so there are **no pre-existing failures** to distinguish from
introduced ones. Every failure observed during Stage 4 was introduced by Stage 4 and is accounted
for below.

The project manifest selects Julia 1.12.6 and all reported commands used that channel.

## The coupling Stage 4 had to break

With the default contract (`H = L = 24`, `h = 1`) on a `T0 = 24` instance, the required period
support ends at `max T(H,h) + L - 1 = 47`. Six sites indexed matrices of width `T0` and would
have failed at `tau = 25`:

| Site | What it indexed |
|---|---|
| `physical_model.jl` `node_cost` | `template.nu[j, tau[n]]` |
| `fairness_rules.jl` `scenario_aggregates` | `template.nu[j, calendar_period[n]]` |
| `fairness_rules.jl` `add_fairness_constraints!` | `static_shares[j, tau]`, validated as `(J, template.T)` |
| `state.jl` `apply_action!` / `action_household_costs` | `template.nu[j, t]` |
| `state.jl` `initial_simulation_state` | realized history sized `zeros(template.T)` |
| `physical_model.jl` | `tree.last_period == template.T`, `terminal_soc` at `template.T` |

Stage 3 deliberately left the extension in a standalone `OOSPeriodDataSupport` and documented that
as "the additive Stage-4 integration point". Stage 4 is that integration.

## `OOSRollingContext`

The new `codes/oos_experiment/rolling_context.jl` binds the three objects that a rolling
simulation needs and that no single pre-existing type carried together:

```julia
struct OOSRollingContext
    config::OOSExperimentConfig      # the temporal contract (H, L, h)
    template::OOSInstanceTemplate    # the repository instance, UNCHANGED (T = T0, nu is J x T0)
    support::OOSPeriodDataSupport    # extended deterministic data over 1:materialized_data_end
end
```

Construction enforces that the support extends *this* instance (matching `T0` and household
count), that it reaches exactly `required_period_support_end(config)`, and that
`realized_period_end(config) <= materialized_data_end`. The support is fully revalidated, so a
mutated or forged extended array cannot enter.

`rolling_price(context, j, tau)` is the only price accessor in the experiment; `template.nu` is no
longer indexed by an abstract period anywhere outside the support builder. `template` is retained
as a documented readability alias of `context.template`, following the existing convention by
which `RepositoryUncertaintyProvider.T` aliases `repository_instance_horizon`.

### Retained pre-Stage-4 call shapes

Rather than duplicating function bodies, the layers that used to take a bare
`OOSInstanceTemplate` now take an `OOSPricedSource = Union{OOSRollingContext,OOSInstanceTemplate}`
and read through `priced_template`, `priced_matrix`, `priced_realized_end` and
`assert_priced_period`. A bare template simply caps the available prices at `1:T0`, which is
exactly the pre-Stage-4 contract, and an out-of-range lookup names the remedy instead of raising
an opaque `BoundsError` inside a JuMP expression. The moving-window span check is enforced only on
the context path, so the retained shape still accepts a legacy shrinking tree.

## Behaviour changed, deliberately

### 1. The loop and the window

`simulate_configuration` iterates `rolling_iteration_starts(config)`; `cache_lookahead_trees`
builds each look-ahead on `t : lookahead_end_period(config, t)`. Completion is measured against
`rolling_solve_count(config)`, not against `template.T`. `metrics.jl` follows: `horizon_covered`
and the horizon-total diagnostics are gated on the same count.

### 2. The terminal state-of-charge target

`terminal_soc` binds at `tau[n] == tree.last_period`. For a legacy tree that still ends at
`template.T` the two coincide, so the retained path is unchanged.

`validate_period_action` gained an explicit `lookahead_end` keyword. The simulator passes
`tree.last_period`, so the realized action is held to the terminal requirement only when the
implemented period *is* the window end. Under the Stage-4 default (`h = 1 < L`) it never is.

**Consequence, recorded rather than hidden.** The state of charge reached at the end of the
evaluation horizon is now an *outcome* of the rolling policy, not a value the model promised. It
is reported as a diagnostic (`ReplicationMetrics.terminal_residual`) and is only required to be
physically admissible. Under the old formulation every run ended at `s_I` by construction; a
bounded probe now ends at roughly 1.9 kWh against `s_I = 0.2` on the default fixture.

### 3. Prices, costs and share coefficients

`node_cost`, `scenario_aggregates`, `apply_action!` and `action_household_costs` price through the
extended support. `compute_static_demand_shares` computes the base `J x T0` table exactly as
before — the repository's verified `static_demand_shares` call is untouched, so the benchmark
keeps its published definition — and then repeats it to `materialized_data_end` through
`extend_static_demand_shares`, which uses the one centralized `base_period_index`. The width check
in `add_fairness_constraints!` became "the table must cover this window" rather than "the width
must equal `template.T`".

### 4. `implementation_step > 1` is refused

`assert_single_period_implementation` rejects `h > 1` from both `cache_lookahead_trees` and
`simulate_configuration`, naming Stage 6. The *configuration* layer is unchanged: any valid `h` is
still constructed, validated and reported, and `rolling_iteration_starts`,
`implementation_block` and `evaluation_block` still work for it. Only the simulator refuses.

### 5. One provider bound corrected

`_assert_provider_period` and `in_sample_tree_data` were bounded by
`required_period_support_end`, i.e. the *minimum* the rolling contract demands. They are now
bounded by `materialized_data_end`, i.e. what actually exists. The two differ exactly when the
contract is shorter than the repository horizon — for instance `H = 12, L = 8` gives a required
endpoint of 19 on a `T0 = 24` instance — and in that case the legacy in-sample calibration tree
over `1:T0` was unservable. Since `materialized_data_end >= required_period_support_end` always
holds, nothing the rolling contract needs was ever rejected and nothing is now newly accepted
beyond materialized data.

## Metadata

`experiment_config.json` gains `realized_period_end`, `final_lookahead_window` and
`implementation_step_supported`, and its `contract_status` changed from
`configuration_contract_only: ...` to
`wired_moving_lookahead: ... implementation_step > 1 is not yet supported`.

No period-level CSV column changed and `output_schema_version` remains **2**; per-row structural,
support and block identifiers are Stage 10. The redundant `base_profile_cycle` key was
deliberately *not* added: `repository_instance_horizon` already carries that number, and the
clock-time vocabulary gate in `T7` correctly rejects the word "cycle".

## Approved deviation from the plan

The mechanical half of Stage 7 — repeating the `STATIC_DEMAND_SHARE` table beyond `T0` through
`base_period_index` — was implemented here. A default `H = L = 24` contract requires share
coefficients through period 47, so Stage 4 cannot build a model without it. Recorded in the
decision log of `docs/oos_redesign_plan.md` and struck through in the Stage-7 scope; Stage 7
retains the per-structural-instance definition, task-local immutability, the recorded share-table
identifier and the tests that the rule is not an alias for `NONE`.

## Files changed for Stage 4

| File | Stage-4 change |
|---|---|
| `codes/oos_experiment/rolling_context.jl` | **new** — the context, the price accessor and the retained pre-Stage-4 source shapes |
| `codes/oos_experiment/temporal.jl` | `realized_period_end`; stage-scope header rewritten |
| `codes/oos_experiment/simulator.jl` | rolling-start loop, moving window, `h > 1` guard, context-based solve/validate/apply |
| `codes/oos_experiment/physical_model.jl` | `source` field, span contract, terminal target at the window end, extended prices |
| `codes/oos_experiment/state.jl` | history sized from the contract, extended prices in cost and benchmark |
| `codes/oos_experiment/validation.jl` | explicit `lookahead_end`, context-based controller/fairness gate |
| `codes/oos_experiment/controllers.jl` | priced source threaded through solve, diagnostic and PEA recovery; `failure_source` renamed to stop it shadowing the source |
| `codes/oos_experiment/fairness_rules.jl` | aggregates priced from the source, share-table extension, coverage-based width check |
| `codes/oos_experiment/metrics.jl` | completion and coverage measured against `rolling_solve_count` |
| `codes/oos_experiment/uncertainty_provider.jl` | provider bound corrected to the materialized endpoint |
| `codes/oos_experiment/oos_experiment.jl` | context in `OOSCommonObjects`, three resolved endpoints, include order |
| `codes/oos_experiment/output.jl` | new temporal keys and the honest `contract_status` marker |
| `scripts/oos/preflight_oos_campaign.sh` | **new check 14** — the moving window is wired into the simulator; bounded `SMOKE_LOOKAHEAD` fixture so check 09 audits both PEA solve-sequence branches |
| `scripts/oos/validate_shared_battery_formulation.sh` | context-based gate call |
| `tests/oos/rolling_horizon_tests.jl` | **new** — focused sets `R0`–`R9` |
| `tests/oos/runtests.jl` | helpers on the campaign path; `T9` replaced; `22.4`, `22.8`, `T7`, PEA and smoke fixtures migrated |
| `tests/oos/structural_catalog_tests.jl` | `S11` migrated |
| `README.md`, `docs/oos_experiment.md`, `docs/oos_redesign_plan.md` | contracts, consequences, decisions, stage status |
| `docs/oos_stage4_completion_report.md` | **new** — this record |

## Tests migrated, and why

None were deleted. Each of these asserted behaviour that Stage 4 replaces by design.

| Test | Old claim | New claim |
|---|---|---|
| `T9` | H/L/h are configuration only and cannot reach the simulator; two hostile contracts give identical 24-period runs | H/L/h drive the loop, the window, the horizon and the terminal target, while leaving the instance and the calibrated process alone; `h > 1` is refused. The stage-1 version said in its own comment that stages 4 and 6 must replace it |
| `S11` | the default run covers `1:template.T` over a shrinking look-ahead with the terminal SOC at `template.T` | the catalog and manifest are still invisible to the simulator — the actual claim of the test — but the run is checked against the temporal contract |
| `22.4` | "no future" produced by standing at the last calendar period of a shrinking horizon | "no future" expressed in the contract as `L = 1`; the three structures still collapse to one node and every controller returns the battery to `s_I` |
| `22.8` | the final state of charge equals `s_I` | the final state of charge is feasible and reachable; no implemented action carries a terminal residual |
| `T7` | `contract_status` says `configuration_contract_only` | it says `wired_moving_lookahead` and names the one thing still unwired; the new endpoint keys are checked; the clock-time vocabulary gate is untouched |
| `pea_config`, `generate_smoke_outputs` | strict `PEA` becomes unreachable near the end of a shrinking horizon | `lookahead_horizon = 4`, so infeasibility arises from a genuinely short window rather than from a collapsing one. `PEA_INFEASIBLE_START = 19` is asserted, not assumed |
| `C1` | the numeric allowance recovers by subtraction to within `1e-15` absolute | to within `8 * eps(epsilon_star)`: the subtraction cancels the band's leading digits, so the achievable accuracy is set by its magnitude, not by a constant |

The `PEA` fixture change deserves emphasis because it is a scientific result, not a test
convenience: **strict `PEA` unreachability caused purely by the horizon running out of PV was an
artefact of the shrinking horizon and no longer occurs.** The adaptive-minimum recovery
formulation is unchanged and remains fully exercised.

## Tests and final verification

### Focused counts

| Test set | Assertions | Result |
|---|---:|---|
| Stage 1 `T1`–`T9` | 656 | PASS |
| Stage 2 `S0`–`S11` | 5,414 | PASS |
| Stage 3 `P0`–`P10` | 816 | PASS |
| **Stage 4 `R0`–`R9`** | **1,547** | **PASS** |

Stage-4 counts by set were `181, 108, 300, 36, 81, 184, 593, 13, 21, 30` for `R0` through `R9`.

The Stage-1 total moved from 835 to 656. The entire movement is `T9`: its stage-1 version compared
24 implemented periods field by field across two temporal contracts to prove they were identical,
which Stage 4 makes false by construction. `T7` gained assertions for the new metadata keys and
for the new source file. Stage-2 and Stage-3 counts are unchanged apart from `S11`'s migrated
block and `S7`'s one-assertion drift already present before this stage.

### End-to-end commands

```bash
bash scripts/oos/validate_oos_experiment.sh
bash scripts/oos/preflight_oos_campaign.sh
bash -n scripts/oos/*.sh
git diff --check
```

### Final results

Both gates below were run on the final tree, with no source edited between them.

| Gate | Result |
|---|---|
| full `validate_oos_experiment.sh` | exit 0, **16,623 assertions**, 0 failed, 276.7 s |
| nested repository regression (`22.14`, subprocess) | PASS, 33.3 s |
| bounded preflight | exit 0, **`PREFLIGHT_RESULT=READY`**, 0 failed checks, 503.9 s |
| shell syntax (`bash -n scripts/oos/*.sh`) | PASS |
| `git diff --check` | PASS |

Preflight checks `01`, `02`, `03`, `04`, `06`, `07`, `08`, `09`, `10`, `11`, `12`, `13`, `14` and
`17` all passed. The two advisory warnings are the expected ones carried since Stage 3: `7a`, the
preserved older `results_oos/` directory, and `7b`, the uncommitted working tree.

Check **14** is new and specific to this stage. On a bounded single-controller configuration it
verifies that every solve spans exactly `L` abstract periods, that the final window reaches past
`T0`, that the realized trajectory covers exactly the final implementation block, that the
static-share table spans the materialized support, that no implemented action carries a terminal
residual, and that `implementation_step = 4` is refused with an attributable message. It reported:

```text
MOVING LOOKAHEAD OK: L=24 inicios=24 ventana final=24:47 T0=24
```

Check **08**, the 18-configuration smoke, gained the bounded fixture `LOOKAHEAD_HORIZON = 4`
(`PREFLIGHT_SMOKE_LOOKAHEAD_HORIZON`), for the same reason as the test fixtures: the downstream
reader in check `09` audits *both* branches of the PEA solve-sequence schema, and a full
24-period window keeps the strict equality reachable throughout, so the four-solve branch would
never be produced. With the short window check `09` reported

```text
Secuencias de resolución PEA: 90 período(s) estricto(s) con 1 resolución, 54 recuperado(s) con 4.
DOWNSTREAM_READER=OK
```

against `0 recuperado(s)` and `DOWNSTREAM_READER=FAIL` on the first attempt with the unchanged
smoke. Check `07` continues to verify the DEFAULT configuration matrix independently, so the
default campaign shape is still preflighted.

## Parallel readiness (plan §4.9)

`OOSRollingContext` is immutable, holds no RNG, cache or filesystem handle, and is fully
determined by the configuration and the instance; two contexts built in different processes or
orders are equal. `simulate_configuration` is a self-contained serial kernel: everything it reads
is immutable and everything it writes lives in its own freshly allocated `SimulationState`. Set
`R6` runs the full controller × policy matrix forward and backward and checks that every
implemented action, state of charge and cumulative cost is identical, that nothing the kernel read
was mutated, and that a freshly built context reproduces a run exactly.

No worker, scheduler, task shard or concurrent writer was created. Stage 13 still owns all of
that, under the reduced scope recorded in the decision log.

## Decisions, deviations and remaining ownership

- **One approved deviation**, the pulled-forward share extension, recorded above and in the plan.
- **No new dependency**, no rescaling of any energy, power, price or rate quantity, and
  `template.delta` untouched.
- **Periods remain abstract.** No minutes, hours, days, dates or calendar semantics were
  introduced; `T7`'s vocabulary gate still passes and was the reason a redundant metadata key was
  dropped rather than the gate relaxed.
- **Warm starts were not adapted, and did not need to be.** `derive_mode_start_from_previous`
  maps the previous solve forward by calendar period, which remains correct for shifted fixed
  windows: the overlap `t+1 : t+L-1` maps across and the one newly entered period falls back to
  the documented idle value. A bounded `MULTISTAGE_RH` probe under the default contract confirms
  it: cold and warm runs both complete, their total operating cost agrees to the last printed
  digit (431 985.508619), and the largest state-of-charge difference is 8.9e-16. Nine periods
  report a different shared mode, and all nine are periods with `Z = Y = 0` exactly — the binary
  is unconstrained there and `OOS_IDLE_MODE_VALUE` breaks the tie, which is the documented
  behaviour. Formal cold/warm equivalence remains a Stage-9 acceptance gate; `use_warm_starts` is
  still `false` by default.
- **Stage 5 and later were not started.** In particular the controller is still part of the
  `lookahead` seed key, `two_stage_scenarios` still generates independent samples, no
  `ScenarioSupportID` exists, and the structural manifest is still not consumed by the runner.

## Prerequisites for Stage 5

Stage 5 replaces the three per-controller look-aheads with one conditional support per
`(paired structural instance, uncertainty level, replication, rolling start)` and derives the
two-stage and deterministic views from it. The pieces it will need are already in place:
`conditional_support_rng` (whose key already excludes the controller) exists in
`structural_catalog.jl`; `lookahead_from_conditional_tree`, `two_stage_lookahead_tree` and
`deterministic_lookahead_tree` already build the three views; and `OOSRollingContext` is the
natural place to carry the `OOSPathSeedKey` and the task-local support cache.

Two consequences to settle in the Stage-5 prompt: `two_stage_scenarios` stops generating
independent samples once the leaf count is fixed by `multistage_branching`, and the deterministic
controller moves from the analytic conditional mean to the probability-weighted mean of the common
leaves. Both are required by §4.3 and both change reported numbers.
