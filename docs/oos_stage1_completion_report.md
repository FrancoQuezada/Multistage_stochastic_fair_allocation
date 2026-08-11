# OOS redesign — Stage 1 completion report

**Stage:** 1 — Abstract temporal configuration contract
**Scope authority:** `docs/oos_redesign_plan.md` §7 (Stage 1) and §4.1
**Date:** 2026-08-07

## Scope

Introduce, validate, parse, document and test the temporal configuration required by the later
redesign stages. `evaluation_horizon` (`H`), `lookahead_horizon` (`L`) and `implementation_step`
(`h`) become validated configuration fields with pure derived helpers and additive metadata.

Nothing else changes. The simulator, uncertainty generation, optimization models, fairness
calculations and implemented-action behavior are untouched.

## Baseline before editing

- Working tree: only two pre-existing untracked paths, `docs/oos_redesign_plan.md` and
  `results_oos/`. Both preserved; no unrelated change touched.
- `bash scripts/oos/validate_oos_experiment.sh` (full OOS suite including the nested repository
  regression suite): **PASS**, exit 0, 8 979 assertions, no `Fail` / `Error` / `Broken` column in
  any test-set summary.
- No pre-existing failures.
- Julia 1.12.6 (the channel `Manifest.toml` resolves to), CPLEX loaded.

## Files changed

| File | Change |
|---|---|
| `codes/oos_experiment/temporal.jl` | **new** — validation and the pure temporal helpers |
| `codes/oos_experiment/types.jl` | three config fields, three default constants, validation call |
| `codes/oos_experiment/oos_experiment.jl` | include `temporal.jl`; three env variables; `_env_int` names the offending variable |
| `codes/oos_experiment/output.jl` | additive `temporal_structure` metadata section |
| `scripts/oos/run_oos_experiment.sh` | forwards the three variables (no shell-side numeric default) |
| `scripts/oos/validate_shared_battery_formulation.sh` | forwards them into the explicit config |
| `scripts/oos/export_representative_models.sh` | forwards them into the explicit config |
| `scripts/oos/preflight_oos_campaign.sh` | new blocking check `10` for the temporal contract |
| `tests/oos/runtests.jl` | new test sets `T1`–`T9` |
| `docs/oos_experiment.md`, `README.md` | temporal-structure documentation |
| `docs/oos_redesign_plan.md` | Stage 1 roadmap status only |

## Configuration fields added

```julia
evaluation_horizon::Int    # H, default OOS_DEFAULT_EVALUATION_HORIZON  = 24
lookahead_horizon::Int     # L, default OOS_DEFAULT_LOOKAHEAD_HORIZON   = 24
implementation_step::Int   # h, default OOS_DEFAULT_IMPLEMENTATION_STEP = 1
```

All three are counted in **abstract model periods**. Placed in the struct as a labelled block;
the only positional construction is the keyword constructor's own inner call, which was updated.
Every other call site in the repository is keyword-based and needed no change.

## Validation rules added

`validate_temporal_contract(H, L, h)`, called from the `OOSExperimentConfig` keyword constructor:

    H >= 1,   L >= 1,   h >= 1,   h <= H,   h <= L

Deliberately **not** required: `H % h == 0`. `H = 24, h = 10` is valid. `h` is not restricted to
any fixed set. All pre-existing validation (`multistage_branching`,
`multistage_periods_per_stage`, solver, fairness, instance and formulation parameters) is
unchanged; no multistage stage-length or first-stage-length rule was added — those belong to the
later scenario-structure stages.

## Helper functions added (`codes/oos_experiment/temporal.jl`)

Pure and side-effect-free: they read the configuration and nothing else — no solver, scenario
tree, instance file or filesystem state.

| Helper | Semantics |
|---|---|
| `known_prefix_length(config)` | `h` |
| `rolling_iteration_starts(config)` | `{1, 1+h, 1+2h, …} ∩ 1:H` |
| `rolling_solve_count(config)` | number of valid rolling starts |
| `is_rolling_iteration_start(config, t)` | `1 <= t <= H` and `(t-1) mod h == 0` |
| `assert_rolling_iteration_start(config, t)` | rejects `t`, distinguishing a range error from an alignment error |
| `implementation_block(config, t)` | `t:(t+h-1)` — the **full** block, never clipped at `H` |
| `evaluation_block(config, t)` | `t:min(t+h-1, H)` — the evaluated portion |
| `lookahead_periods(config, t)` | `t:(t+L-1)` — never clipped at `H` |
| `lookahead_end_period(config, t)` | `t+L-1` |
| `final_rolling_iteration_start(config)` | `max T(H, h)` |
| `required_period_support_end(config)` | `max T(H, h) + L - 1` |

`implementation_block`, `evaluation_block`, `lookahead_periods` and `lookahead_end_period` reject
a `t` that is not a valid rolling start. A valid final block is never rejected for extending past
`H`: with `H = 24, h = 10, t = 21` the full block is `21:30` and the evaluated portion `21:24`.

## Environment parser and script changes

`EVALUATION_HORIZON`, `LOOKAHEAD_HORIZON`, `IMPLEMENTATION_STEP` are read through the runner's
existing `_env_int` convention. Absent or blank uses the documented Julia default; an explicitly
malformed value now aborts naming the variable (`_env_int` switched from a bare `parse` to
`tryparse` plus an attributable `error`, which improves the message for every integer variable and
changes behavior for no valid input); an invalid combination aborts during config construction.

The shell never re-declares a numeric default — it forwards each variable only when the caller set
it, mirroring the established `FLOW_TOL` / `FEASIBILITY_TOL` pattern, so the temporal contract has
exactly one source of truth. No clock-time or calendar variable was introduced:
`PERIOD_DURATION_MINUTES`, `PROFILE_CYCLE` and any equivalent are absent and tested for.

## Metadata changes

One additive `temporal_structure` section in `experiment_config.json`, recording
`evaluation_horizon`, `lookahead_horizon`, `implementation_step`, `known_prefix_length`,
`rolling_solve_count`, `rolling_iteration_starts`, `required_period_support_end`,
`final_rolling_iteration_start`, `final_implementation_block`, `final_evaluation_block`,
`repository_instance_horizon`, `period_semantics`, `period_unit` and `contract_status`.

`template.T` stays separately identified as `instance.horizon` and as
`temporal_structure.repository_instance_horizon`; it is neither renamed nor reinterpreted. No
period-level CSV schema changed, so `output_schema_version` stays at 2. `contract_status` marks a
stage-1 directory as contract-only so these values cannot be misread as the realized rolling
structure.

## Tests and results

| Command | Result |
|---|---|
| `bash scripts/oos/validate_oos_experiment.sh` (baseline, before editing) | exit 0, 8 979 assertions |
| `bash scripts/oos/validate_oos_experiment.sh` (after) | exit 0, 9 802 assertions |
| `bash scripts/oos/preflight_oos_campaign.sh` (after) | exit 0, `PREFLIGHT_RESULT=READY`, `PREFLIGHT_FAILED_CHECKS=0` |

The delta is exactly the 823 assertions of the new `T1`–`T9` test sets. No `Fail`, `Error` or
`Broken` column appears in any test-set summary, before or after. No pre-existing failure existed
and none was introduced.

Pre-flight per-check results: `01`, `02`, `03`, `04`, `06`, `07`, `08`, `09`, `10` (new), `17` all
`PASS`. Two advisory `WARN`s, neither blocking and neither caused by this stage:

- `7a` — the pre-existing untracked `results_oos/` was produced before `output_schema_version`
  existed, so it carries no such key. Nothing in this stage read or wrote that directory.
- `7b` — the working tree has uncommitted changes, which is this stage's own patch.

New test sets:

| Test set | Covers |
|---|---|
| `T1` | default configuration and single-source-of-truth defaults |
| `T2` | `h = 1` |
| `T3` | `h = 4` |
| `T4` | non-divisible `h = 10`, full block `21:30` vs evaluated `21:24` |
| `T5` | `h = 6` plus every admissible `h` in `1:24` — no fixed allowed set |
| `T6` | invalid horizons, invalid steps, invalid rolling starts, admissible boundary `h = min(H, L)` |
| `T7` | metadata section, derived values, separate instance horizon, no clock-time field |
| `T8` | environment parsing: defaults, explicit values, malformed values, invalid combinations, ignored clock-time variables, runner forwarding |
| `T9` | **non-goal gate**: a hostile temporal contract produces identical decisions |

## Behavior confirmations

- **Simulation and optimization unchanged.** `T9` runs a full 24-period configuration twice —
  once with the defaults and once with `H = 12, L = 8, h = 5` — and asserts exact equality of
  every implemented `p`, `z`, `y`, `I`, `G`, `lambda`, shared battery mode, state of charge before
  and after, and the total operating cost. It also pins that the simulator still iterates
  `1:template.T` and that every look-ahead still spans the shrinking interval `t:template.T`
  rather than `t:t+L-1`, and that the terminal state-of-charge target still binds on `template.T`.
- **No clock-time assumption.** Periods are abstract everywhere. `template.delta` is unchanged, no
  duration or calendar parameter exists in the configuration, the environment or the metadata, and
  `T7` / `T8` / preflight check `10` assert their absence.
- **Stage 2 not started.** No structural instance catalog, no battery-level or demand-regime
  factor, no seed-hierarchy change, no instance identifiers.

## Deviations from the plan

None in scope or semantics. Two judgement calls worth recording:

1. `_env_int` was hardened to name the offending variable. This satisfies the stage requirement
   that a malformed value fail clearly and improves every integer variable's message; behavior for
   valid input is identical.
2. The helpers live in a new `codes/oos_experiment/temporal.jl` rather than inside `types.jl`,
   matching the module's one-file-per-concern layout. The layout table in
   `docs/oos_experiment.md` was updated accordingly.

## Remaining work / prerequisites for the next stage

`T9` is the test that Stage 4 and Stage 6 must replace when the contract is actually wired in.
Stage 3 must satisfy `required_period_support_end(config)` before Stage 4 can build a fixed
`t:t+L-1` look-ahead. Stage 2 (structural instance catalog and seed hierarchy) is the next
authorized step and has not been started.
