# Out-of-sample receding-horizon experiment

Additive experimental framework comparing fair energy-allocation policies under three
decision-making approaches, all evaluated on the same independently generated out-of-sample
trajectories, period by period.

The module lives entirely under `codes/oos_experiment/`, `scripts/oos/`, `results_oos/` and
`tests/oos/`. It does not modify the exact-model, heuristic, sensitivity or validation
workflows, and `tests/oos/runtests.jl` re-runs the repository's own regression suite to prove
it.

## Terminology

Use: shared-battery operating mode; node-level battery mode; aggregate charging; aggregate
discharging; household charging contribution; household discharge allocation;
allocation/fairness rule; controller; out-of-sample trajectory.

Do not use: household charging mode; percentage of households in charging mode; household mode
consistency; one mode per household.

`STATIC_DEMAND_SHARE` is **a static rule inspired by ex-ante energy-sharing coefficients**. It
is not virtual net billing.

## The 18 configurations

| | `DETERMINISTIC_RH` | `TWO_STAGE_RH` | `MULTISTAGE_RH` |
|---|---|---|---|
| `NONE` | ✓ | ✓ | ✓ |
| `STATIC_DEMAND_SHARE` | ✓ | ✓ | ✓ |
| `PEA` | ✓ | ✓ | ✓ |
| `SA` | ✓ | ✓ | ✓ |
| `LEXMMFPEA` | ✓ | ✓ | ✓ |
| `LEXMMFSA` | ✓ | ✓ | ✓ |

## Module layout

| File | Responsibility |
|---|---|
| `types.jl` | Enums, `OOSExperimentConfig`, `PeriodAction`, `ControllerResult`, path/tree types |
| `state.jl` | `SimulationState`, revelation, implementation, derived savings |
| `mode_nodes.jl` | **Centralized** mode-node convention and the expected binary counts |
| `lookahead_tree.jl` | `LookaheadTree` adapter and the three controller topologies |
| `uncertainty_provider.jl` | One calibrated conditional process, seeds, stream separation |
| `physical_model.jl` | **The single** remaining-horizon physical builder |
| `fairness_rules.jl` | `NONE`, `STATIC_DEMAND_SHARE`, `PEA`, `SA` and the shared expressions |
| `lexicographic.jl` | `LEXMMFPEA`, `LEXMMFSA` phases plus the economic tie-break |
| `controllers.jl` | `solve_current_action`, action extraction, failure attribution |
| `warm_starts.jl` | Node-level MIP starts derived from aggregate flows |
| `legacy_compatibility.jl` | Explicit legacy conversion, reference-objective rejection, source scan |
| `model_audit.jl` | Structural inspection and LP/MPS export |
| `validation.jl` | Implemented-action validation and the Phase-0 gate |
| `simulator.jl` | Instance template, look-ahead cache, the sequential loop |
| `metrics.jl` | Realized metrics, fairness diagnostics, paired statistics |
| `output.jl` | The six tidy artefacts |
| `oos_experiment.jl` | Entry point, preflight, campaign, environment configuration |

## Shared-battery formulation

One binary per relevant information state, created only by the repository's verified
`add_shared_battery_mode_constraints!`:

    sum_j y[j,n] <= F_d (1 - v_n),      sum_j z[j,n] <= F_c v_n,      v_n in {0,1}

There is no household-indexed mode anywhere: not in the models, not in the warm starts, not in
the outputs. Because the flows are nonnegative, the aggregate rows already imply
`z[j,n] <= F_c v_n` and `y[j,n] <= F_d (1 - v_n)`; the household rows exist only in the named
variant `aggregate_plus_redundant_links` and are never mixed into `aggregate_only` runs.

### Model-size effect

The corrected formulation changes the expected mode-binary count from `|H| |V_mode|` to
`|V_mode|`. Every solve reports `ExpectedModeNodes`, `GeneratedModeBinaries`,
`UniquePolicyModes` and `LegacyHouseholdModeBinaries`, and the campaign prints the reduction
factor per controller. **Runtime, memory and branch-and-bound differences must not be
attributed to the algorithm alone**: part of the difference comes from the corrected and
smaller formulation.

For the node-indexed models built here, generated and unique nonanticipative mode counts
coincide. A scenario-indexed implementation would report a larger generated count; both columns
exist so the distinction stays visible.

## Information timing

Current-period PV and household demands are observed **before** the current action is selected.
At the beginning of period `t` the controller knows realized PV and demand through `t`, the
state of charge entering `t`, all implemented past actions, the cumulative realized PV
allocations, demands, operating costs and all-grid benchmark costs, and the calibrated
stochastic model of future uncertainty. It never sees the out-of-sample suffix: only the
revealed prefix is copied into `ObservedHistory`.

The shared mode `v_t` is chosen after the current exogenous information is observed and before
the current physical flows are implemented. It is **not** carried into period `t+1` as an
optimization state: the common mathematical model contains no switching cost, startup cost,
minimum duration or transition rule. The previous mode is stored for reporting only.

## The calibrated uncertainty process

    PV       e_tau = 0.8 e_{tau-1} + 0.2 eps_{tau-1} + eps_tau,   eps ~ N(0, theta)
             C_tau = max(0, pv_det[tau] (1 + e_tau))
    demand   D_{j,tau} ~ N(avg, dev) inside household j's active window, 0 outside

The recursion, its coefficients, the active windows (morning 1:8, midday 9:16, night 17:24) and
the per-period PEA feasibility repair are the repository's own conventions from
`codes/parametersMS.jl`. Prices are deterministic: no stochastic prices in this first
implementation.

Two documented deviations make the process and the controllers' filter mutually consistent:

1. the pre-sample latent state starts at its unconditional mean (`e_0 = eps_0 = 0`) instead of
   the repository's `randn()` draw, so a controller's filter is exactly the conditional law of
   the generated process;
2. the first period receives a PV value (`pv_ms` leaves node 1 unset).

The filter identifies `e_tau` from observed PV whenever `pv_det[tau] > 0`. Two cases are not
identified and fall back to the conditional mean: `pv_det[tau] == 0` (no production is
possible, so the realization carries no signal), and `C_tau == 0` with `pv_det[tau] > 0`, where
the latent error is pinned to the truncation boundary `e_tau = -1`.

### Streams and common random numbers

Deterministic FNV-1a seeds, domain-separated by stream name:

| Stream | Key |
|---|---|
| out-of-sample trajectories | `(experiment_seed, "oos_path", replication)` |
| look-ahead | `(experiment_seed, "lookahead", replication, period, controller)` |
| common in-sample objects | `(experiment_seed, "in_sample")` |
| household demand profiles | `(experiment_seed, "demand_profiles")` |

The **fairness policy is deliberately absent** from the look-ahead key: all six rules under one
controller receive the same forecast, scenario set or tree. The look-ahead conditions only on
the observed history, which does not depend on the implemented actions, so the per-replication
cache is exact rather than approximate and all configurations consume literally the same
look-ahead objects.

## Controllers

`DETERMINISTIC_RH` — one point-forecast path over `t..T`; entry 1 is the observed current
period, later entries use the conditional mean. Every node has probability one.

`TWO_STAGE_RH` — one common root (the current period), immediate branching after the root, one
independent future chain per scenario, no nonanticipativity beyond the root. The complete
current action, `v_t` included, is the first-stage decision common to every scenario; future
scenario-specific modes and flows are second-stage recourse and are discarded after the solve.
There is no vector of scenario modes for the current period.

`MULTISTAGE_RH` — a conditional tree with progressive revelation. Storage is node-indexed, so
nonanticipativity is implicit: two scenarios sharing a history share the node and therefore the
same mode variable. The stage layout of a remaining horizon of `R` periods splits `R` over
`length(branching)+1` stages as evenly as possible (remainder to the earliest stages), or
follows `multistage_periods_per_stage` when given; trailing stages that would receive no period
are dropped with their branching factor, so the layout is well defined for every `(period,
horizon)` pair.

At the final period there is no future, so all three structures collapse to the single root
node and the three controllers solve the same physical and fairness problem.

## Allocation / fairness rules

All six use the same corrected physical model. The shared-mode correction changes the feasible
region; it does not redefine any rule. Fixed realized past quantities enter through
`FairnessPastState` exactly once.

- `NONE` — minimize expected remaining operating cost, no explicit fairness constraint.
- `STATIC_DEMAND_SHARE` — `lambda[j,n] = lambda_static[j, tau(n)]`, computed once ex ante from
  the common in-sample expected demand via the repository's `static_demand_shares`. Identical
  across replications and controllers, never updated from realized information, does not
  determine the battery mode, and coexists with the shared-mode constraints on `z` and `y`.
- `PEA` — `E_t[P_j^past + sum_tau p_{j,tau}] == E_t[alpha^omega D_j^omega]`, with
  `alpha^omega = C^omega / D^omega` and all totals including the realized past.
- `SA` — `E_t[S_j^omega] == E_t[(S^omega / B^omega) B_j^omega]`, retaining the repository's
  denominator floor (`max(1.0, B^omega)`) and its absolute tolerance.
- `LEXMMFPEA` / `LEXMMFSA` — lexicographic max-min on
  `P_j^past + E_t[sum_tau p_{j,tau}]` and on `S_j^past + E_t[S_{j,t}]`.

### Lexicographic convention

One convention, stated explicitly: the fairness levels are computed **under the corrected
physical model**, and the expected remaining operating cost is then minimized while preserving
those levels within `lex_eps_abs`. No target is ever imported from the old formulation. Unlike
the legacy PV master in `codes/mmf_pea.jl`, which has no battery variables, **every** phase
here runs on the full corrected physical model including the node-level shared mode.

The linear characterization is the repository's own: `max k*zeta_k - sum_j d_{k,j}` subject to
`zeta_k - d_{k,j} <= X_j` equals the sum of the `k` smallest outcomes. The residual therefore
compares cumulative order statistics of the achieved outcomes against `omega_k`, which is
invariant to household relabelling.

## Strict-first / adaptive-minimum `PEA` recovery

### Why strict `PEA` can become unreachable

A horizon-total **equality** re-imposed every period on a fixed realized past is not guaranteed
to stay reachable: the target moves with new information while past allocations cannot be taken
back. Strict `PEA` fails at period `t` exactly when, for some household `j`, the updated target
lies outside the range still reachable with the remaining physical resources:

    Q[j,t]  <  P_past[j,t]                        (already over-allocated)
    Q[j,t]  >  P_past[j,t] + E_t[C_future]        (unreachable with all remaining PV)

**Zero remaining PV is only the extreme special case.** On the `Drahi` instances the last five
calendar periods have `pv_det[tau] == 0`, but the first failure occurs *earlier* — at `t = 19`,
where `E_t[C_future] = 13.53 kWh` is still positive but no longer enough to absorb the
accumulated deviation. Failures at `t = 9` and `t = 11` occur on other replications. The
criterion is insufficiency of the remaining resource, not its absence.

### The recovery

At **every** rolling-horizon period the strict equality is attempted first. The band is a
*decision variable*, never a value picked from a grid.

1. **Strict solve.** If it yields a solution the current action is implemented, the reported
   tolerance is `0.0`, and no recovery model is built.
2. **Guarded activation.** Recovery may start only when the strict model is *proven* infeasible
   **and** the same physical model without `PEA` is feasible. A time limit, a numerical error,
   an unknown status or a physically infeasible state never activates it.
3. **Phase I — minimum necessary band.** With `epsilon_pea >= 0` a single scalar:

       min  epsilon_pea
       s.t. the complete current physical model
            -epsilon_pea <= P_past[j] + E_t[P_future[j]] - Q[j] <= epsilon_pea   for all j

   giving `epsilon_pea_star`, the smallest common absolute household-level deviation, in kWh,
   that restores feasibility.
4. **Phase II — operational optimum at that band.** `epsilon_pea <= epsilon_pea_star +
   pea_tolerance_numeric_eps` is added, the expected remaining operating cost objective is
   restored, and the problem is re-solved. **The implemented action always comes from Phase II.**
   The Phase-I solution is never implemented; if Phase II fails the configuration stops — there
   is no silent fallback.

The tolerance is **local to one reoptimization**. At `t+1` the history is updated, the target
and look-ahead are rebuilt, and strict `PEA` is attempted again from `epsilon = 0`. A previous
band is never carried forward as a lower bound, so one replication can recover several times
with different minimum tolerances.

### Solve count per period

| Period outcome | Solves | Sequence |
|---|---|---|
| strict `PEA` feasible | **1** | strict |
| recovered | **4** | strict → diagnostic physical model → Phase I → Phase II |

**Recovery adds three extra solves** relative to a period where strict `PEA` succeeds. The
diagnostic solve is easy to overlook because it produces no implemented decision, but it is a
real optimization and is logged as such: every one of the four appears as its own row in
`solve_log.csv`, with labels `single_solve`, `pea_diagnostic_physical`,
`pea_phase1_min_tolerance` and `pea_phase2_operational` and `Phase` values `0, 1, 2, 3` in
execution order. Only non-PEA and strict-feasible periods produce a single row.

### Two tolerances that must not be confused

Both quantities appear in the same inequality, `epsilon_pea <= epsilon_pea_star +
pea_tolerance_numeric_eps`, so they necessarily carry the **same unit: kWh**. Neither is
dimensionless. What separates them is magnitude and purpose, not dimension.

| | `epsilon_pea` | `pea_tolerance_numeric_eps` |
|---|---|---|
| Meaning | maximum absolute household deviation admitted | absolute numerical allowance protecting Phase-II feasibility at the Phase-I optimum |
| Unit | **kWh** (horizon-total PV allocation) | **kWh** (same unit; *not* dimensionless) |
| Typical magnitude | 2–23 kWh (measured) | `1e-6` kWh — six or more orders of magnitude smaller |
| Value | computed endogenously, per period | fixed configuration constant |
| Economic content | **yes** | none, by magnitude rather than by dimension |
| Reported | `PEA_Tolerance_Used_kWh` and all aggregates | `PEA_Tolerance_Numeric_Eps_kWh`, plus `pea_tolerance_numeric_eps_kwh` in the metadata |

`FAIRNESS_ABS_TOL` is **deprecated** as a fixed economic band. It is honoured only under
`pea_tolerance_mode = :fixed_band`; setting it above zero in any other mode is a configuration
error rather than a silent policy change. A fixed value such as `100.0` is a ~15–30 %
relaxation of the rule on this instance family — it was never a solver tolerance.

### Reported statistics

Per period, in `pea_recovery.csv`: `PEA_Strict_Feasible`, `PEA_Tolerance_Activated`,
`PEA_Tolerance_Used_kWh`, `PEA_Strict_Status`, `PEA_Phase1_Status`, `PEA_Phase2_Status`,
`PEA_Recovery_Status`, `Failure_Source`. Per replication, in `replication_summary.csv`:
activations, activation rate, mean over active periods, mean over all periods, maximum. Pooled
per configuration, in `configuration_summary.csv`: the same quantities computed over *all*
active periods across replications, not as an unweighted mean of replication means.

`SA` and the lexicographic rules never needed this: their outcomes stay adjustable through grid
transactions even when no PV is left.

## `NONE` versus `STATIC_DEMAND_SHARE`: distinct, and they do differ

Two separate benchmark policies; neither may be removed or merged into the other.

- `NONE` adds **zero** distributive constraints, zero fairness objective and no post-solve
  distributive repair. The physical model and the operational objective alone determine the
  allocation.
- `STATIC_DEMAND_SHARE` imposes `lambda[j,n] = lambda_static[j,tau(n)]` at every node — an
  active, per-period demand-share rule computed once ex ante.

**Operating costs can coincide while allocations differ.** `generateInstance` gives every
household the same price row (`nu[j,t]` is `j`-invariant), so with no forced exports the total
cost does not depend on who receives the PV. Household allocations nevertheless differ on every
instance tested:

| instance | max_j abs(dPV) in kWh | total cost |
|---|---|---|
| default campaign config (J=4, `mixed`) | 1.168 | identical |
| J=3, `mixed` | 50.19 | identical |
| J=3, `alea` (heterogeneous) | 267.45 | identical |

Equal operating cost is therefore **not** evidence of equal allocation. Heterogeneous instances
are required to evaluate the distributive difference properly, and `tests/oos/runtests.jl` pins
this with a heterogeneous regression instance.

The per-period PEA repair in the uncertainty provider sets `D_{j,tau} = C_tau / J` whenever no
household is naturally active, which pushes `NONE` toward the demand-share allocation on
low-heterogeneity instances and explains why the gap is small there. It is applied identically
to every policy and is a property of the data generator, not a distributive rule.

## Conditional PEA is not part of this study

Conditional PEA (`CPEA`, `CSA`, `CLEXMMFPEA`, `CLEXMMFSA` in `codes/conditional_fairness.jl`) is
**not** part of the main OOS experiment and cannot enter it:

- the `FairnessPolicy` enum has exactly six members, none conditional;
- `parse_fairness_policy` rejects `CPEA`, `CSA`, `CLEXMMFPEA`, `CLEXMMFSA`, `ERDINC_*` and the
  legacy aliases `MMFPEA`, `PAE`, `PPEA`;
- `codes/conditional_fairness.jl` is never included — the OOS entry point loads only
  `structuresMulti.jl`, `parametersMS.jl` and `static_demand_share.jl`, none of which include it;
- the default campaign matrix enumerates exactly the intended 18 labels.

Re-solving the **root-level ex-ante** PEA rule at every rolling-horizon period is *not*
conditional PEA. Conditional PEA imposes separate proportionality requirements at future nodes
or future stages; the rule implemented here is a single family of `J` rows per solve, each
spanning the whole remaining horizon.

## Implemented-action validation

Every implemented action is re-derived by the simulator and checked with the configured
tolerances, never with exact comparisons against zero:

| Check | Condition |
|---|---|
| PV allocation | `\|sum_j p_j - C_t\| <= eps_feas` |
| Household balance | `\|D_{j,t} - (p+y+I-z-G)\| <= eps_feas` |
| Battery transition | `\|s_after - (s_before + delta e_c Z - delta Y / e_d)\| <= eps_feas` |
| Simultaneity | not (`Z_t > eps_flow` and `Y_t > eps_flow`) |
| Charge link | `Z_t <= F_c v_t + eps_feas` |
| Discharge link | `Y_t <= F_d (1 - v_t) + eps_feas` |
| Integrality | `min(\|v_t\|, \|1 - v_t\|) <= eps_int` |
| Bounds | state-of-charge window, rate limits, nonnegativity, terminal residual |

The stored aggregates are also verified against the sums of the household flows, and the
model-reported state of charge against the simulator's own transition.

## Failure handling

A solve or replication is invalid, and that configuration stops, when a household-indexed mode
variable is detected, the mode-node count differs from the centralized expected count, the
current mode is missing, simultaneous aggregate flows exceed tolerance, a mode-linking
constraint is violated, a legacy solution cannot be converted, an unverified old reference
objective is used, one compared model uses different battery physics, result parsing expects
household-mode fields, or an exported LP/MPS contains obsolete mode variables.

## Outputs

Everything under `results_oos/`, all rows carrying `formulation_id`. Existing model-result files
are never touched.

| File | Grain |
|---|---|
| `replication_summary.csv` | experiment × replication × controller × rule × formulation |
| `household_summary.csv` | household × replication × controller × rule |
| `period_actions.csv` | household × period |
| `battery_operation.csv` | physical period (**canonical mode record**) |
| `solve_log.csv` | one row per optimization solve, lexicographic and PEA phases included |
| `pea_recovery.csv` | one row per solved period, every policy (uniform schema) |
| `solve_log.csv` rows for a recovered PEA period | 4: strict, diagnostic, Phase I, Phase II |
| `configuration_summary.csv` | pooled PEA statistics per controller x rule |
| `paired_statistics.csv` | levels and paired controller / rule differences |
| `model_audit_summary.csv` | representative-model audit results |
| `experiment_config.json` | resolved configuration and reproducibility metadata |
| `validation_report.txt` | gate and audit transcript |
| `solve_failures.csv` | aborted configurations, written only when some exist |
| `model_audit/*.lp`, `*.mps` | representative exports, kept apart from run outputs |

No output carries a household battery-mode field, and none reports a percentage of households in
a battery mode. `period_actions.csv` repeats the shared mode only as a foreign-key convenience.

`replication_summary.csv` and `household_summary.csv` carry an explicit `Resource` column
(`none` / `pv` / `savings`), so downstream analysis never has to infer the resource from the
fairness-rule string. `replication_summary.csv` also carries `HorizonCovered` and sets the
horizon-total *diagnostics* (`RealizedAlpha`, the relative deviations, `MinHouseholdPV`,
`MinHouseholdSavings`) to `NaN` on an aborted run, so a truncated trajectory can never be
compared against a complete one. The raw accumulations are retained and labelled.

The `results_oos/model_audit/*.lp` and `*.mps` exports are regenerable inspection artifacts and
are git-ignored; the audit *verdicts* in `model_audit_summary.csv` and `validation_report.txt`
are tracked.

## Statistical comparison and old/new separation

`paired_statistics.csv` reports, for each metric, the level per configuration and the paired
differences across controllers (rule fixed) and across rules (controller fixed), with mean,
standard deviation, standard error and a normal-approximation interval. Only replications
completed by **both** members of a pair contribute, so every difference is a genuine paired
observation on the same trajectory.

Old and corrected results must never be combined without a formulation identifier. Do not use
old objective values as reference optima, old bounds in gaps, or call an old incumbent feasible
without validation, and do not claim algorithmic improvement without separating formulation
effects. `reject_legacy_reference_objective` enforces this in code.

## Parameter scaling review (specification §24)

Reviewed for dependence on the mode-binary count:

| Parameter | Old basis | New basis | Action |
|---|---|---|---|
| `solver_time_limit_sec` | one-shot horizon, `60*60` in `multi.jl` | one solve per period, model far smaller | default `600.0`, configurable |
| `flow_tol` | `SHARED_BATTERY_FLOW_TOL = 1e-7` | unchanged; not dimension-dependent | kept at `1e-7` |
| `feasibility_tol`, `integrality_tol` | new | absolute residual checks | `1e-6` |
| `sa_fairness_abs_tol` | repository `TOL = 1.0` | unchanged rule, new feasible region | kept at `1.0` |
| `lex_eps_abs` | repository `TOL = 1.0` | unchanged | kept at `1.0` |
| `fairness_abs_tol` | fixed economic band | **deprecated**; only under `:fixed_band` | default `0.0`, guarded |
| `pea_tolerance_mode` | absent | strict-first with endogenous recovery | `:adaptive_minimum` |
| `pea_tolerance_numeric_eps` | absent | absolute allowance in **kWh**, sized at CPLEX's default primal feasibility scale | `1e-6` kWh |
| `OOS_PEA_ACTIVATION_THRESHOLD` | absent | separates a real band from solver noise | `1e-9` |
| SA denominator floor | `max(TOL, B)` with `TOL = 1.0` | unchanged safeguard | kept |
| `two_stage_scenarios`, `multistage_branching` | absent | drive `\|V_mode\|` directly | explicit, logged |

No calibration was mechanically retained on a `|H| |V_mode|` basis, and no generic solver
parameter was changed without a reason: only the time limit and, optionally, the thread count
are set. There are no neighborhood sizes, candidate fixings or cut limits in this module.

## Reproducibility metadata

`experiment_config.json` records the formulation ID and variant, mode-node convention,
experiment ID, prompt version, code commit and dirty flag, UTC date, Julia version, solver
version, hardware, operating system, all seeds and stream names, every controller and fairness
parameter, all tolerances, the instance parameters including the ex-ante household demand
profiles, the uncertainty-process coefficients, the warm-start settings, and the full gate and
audit transcript.

## Usage

Julia note: the `Manifest.toml` is resolved for one Julia version and the scripts pass that
channel automatically (`JULIA_CHANNEL` overrides it). On this machine CPLEX loads under
`julia +1.12.6`; plain `julia` resolves to a version whose `PrecompileTools` build fails.

```bash
# 1. Phase-0 gate (blocks everything else)
FORMULATION_ID='shared_battery_mode_node_level_v1' \
bash scripts/oos/validate_shared_battery_formulation.sh

# 2. Representative LP/MPS export and inspection
FORMULATION_ID='shared_battery_mode_node_level_v1' \
bash scripts/oos/export_representative_models.sh

# 3. Required validation suite (also re-runs the repository's own suite)
bash scripts/oos/validate_oos_experiment.sh

# 4. Full campaign
FORMULATION_ID='shared_battery_mode_node_level_v1' \
OOS_REPLICATIONS=1000 \
CONTROLLER_SET='DETERMINISTIC_RH,TWO_STAGE_RH,MULTISTAGE_RH' \
FAIRNESS_SET='NONE,STATIC_DEMAND_SHARE,PEA,SA,LEXMMFPEA,LEXMMFSA' \
TWO_STAGE_SCENARIOS=100 \
MULTISTAGE_BRANCHING='4,4' \
EXPERIMENT_SEED=12345 \
PEA_TOLERANCE_MODE=adaptive_minimum \
FLOW_TOL=1e-7 FEASIBILITY_TOL=1e-6 INTEGRALITY_TOL=1e-6 \
REQUIRE_SHARED_BATTERY_VALIDATION=1 \
EXPORT_REPRESENTATIVE_MODELS=1 \
bash scripts/oos/run_oos_experiment.sh
```

The validation gate and the representative-model export use the **same** PEA policy as the
campaign (`PEA_TOLERANCE_MODE`, default `adaptive_minimum`); one policy is never validated while
another is run. The export additionally emits the strict, Phase-I and Phase-II PEA models.

The runner honours the repository's usual instance variables (`INST_FOLDER`, `INSTANCE_FROM`,
`TREE_SET`, `J_SET`, `THETA_SET`, `AVG_D_SET`, `DEV_D_SET`, `DEMAND_PROFILE_SET`,
`BATTERY_SCALE_SET`, `PV_SCALE_SET`) and uses the first entry of each, since one campaign runs on
one instance configuration. It refuses to start when `FORMULATION_ID` is missing, when the
validation gate is disabled without `OOS_ACKNOWLEDGE_UNVALIDATED=1`, or when `OOS_OUTPUT_DIR`
points at a pre-existing results directory. Representative-model inspection failures and
inconsistent battery physics abort inside Julia, before any configuration runs.

Instance note: `demandProfile` writes into `demand_det[17:24]`, so `TREE_SET` must satisfy
`S*P >= 24`. `3:2:8` is the repository's small validation geometry.

## Downstream interface and schema version

`experiment_config.json` carries `output_schema_version`. **Version 2** is current:
`PEA_Tolerance_Numeric_Eps_kWh`, metadata keys `pea_tolerance_numeric_eps_kwh` /
`pea_tolerance_numeric_eps_unit`, and the four-solve recovery sequence. Version 1 (unitless
column name, three-solve logging) is obsolete; a directory without the key predates versioning.
`validate_output_directory` refuses to read a mismatched version, so incompatible directories
cannot be aggregated together.

The single sanctioned consumer is `codes/oos_experiment/run_downstream_checks.jl`, driven by
`scripts/oos/preflight_oos_campaign.sh`. Any new analysis must follow its four conventions:

1. address solves by **semantic label** (`single_solve`, `pea_diagnostic_physical`,
   `pea_phase1_min_tolerance`, `pea_phase2_operational`), never by the raw `Phase` integer —
   the integers moved when the diagnostic solve was added to the log;
2. take the resource from the explicit **`Resource`** column, never from the rule name;
3. gate horizon-total comparisons on **`CompletionStatus` / `HorizonCovered`**; truncated
   trajectories carry `NaN` diagnostics and must not be compared against complete ones;
4. keep **`NONE` and `STATIC_DEMAND_SHARE` as distinct categories** — equal operating cost is
   not equal allocation.

`Phase-I` objective values are bands in kWh, not operating costs. The diagnostic solve is
bookkeeping and never a policy action.

## Deliberate exclusions

Not implemented, per the specification: conditional-stage fairness variants, Erdinç's six
resource variants, restricted-exact heuristics, stochastic prices, machine-learned policies,
perfect-information out-of-sample decisions, automatic fallback controllers, switching costs,
minimum mode duration, mode persistence, a separate import/export binary, undocumented
redundant household linking constraints, and direct reuse of old reference optima.

`solveMulti` is not used as the receding-horizon engine: it assumes a one-shot horizon and
provides none of the state, fixed-past, current-action or mode-audit interfaces this experiment
requires. Legacy `SolutionM.x` / `SolutionM.w` fields are never repurposed as the shared mode.
