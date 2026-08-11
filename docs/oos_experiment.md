# Out-of-sample receding-horizon experiment

Additive experimental framework comparing fair energy-allocation policies under three
decision-making approaches, all evaluated on the same independently generated out-of-sample
trajectories, period by period.

The module lives entirely under `codes/oos_experiment/`, `scripts/oos/`, `results_oos/` and
`tests/oos/`. It does not modify the exact-model, heuristic, sensitivity or validation
workflows, and `tests/oos/runtests.jl` re-runs the repository's own regression suite to prove
it.

Redesign status: Stages 1 through 11 are **COMPLETE**. Stage 4 replaced the shrinking interval
`t:template.T` with a fixed `L`-period moving window and moved the terminal state-of-charge target
to the end of that window. Stage 5 replaced the three per-controller look-ahead samples with ONE
conditional support per `(replication, rolling start)`, of which the three methods are views, so
the only thing distinguishing them is the information structure. Stage 6 generalized the known prefix and the
committed block to every admissible `implementation_step`. Stage 7 turned the `STATIC_DEMAND_SHARE`
coefficients into an identified, immutable per-instance table. Stage 8 audited the decision
domain, found real household-level simultaneous grid import and export under `SA`, added the
exclusivity rule, and — because closing that channel made the `SA` savings equality structurally
unreachable — gave `SA` the same endogenous minimum band `PEA` already had. Stage 9 added the recoverability check on the state handed
between rolling solves and adapted the warm start to the moving window. Stage 10 made every result row carry its own scientific
identity, moved the result schema to v3 with an explicit v2 migration, and defined the shard
interfaces. Stage 11 established order, worker and resumption invariance on the serial kernel and added an independent recomputation of every summary from the period rows. Stages 12 and later have not been started.

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
| `temporal.jl` | Abstract temporal contract: `H`/`L`/`h` validation and the pure period helpers |
| `period_support.jl` | Pure abstract-period mapping and exact price/PV/demand-activity extension |
| `canonical_json.jl` | Pinned canonical JSON writer/parser and the stable identity digest |
| `structural_catalog.jl` | Structural factors, controlled demand assignments, identifiers, seed hierarchy, materialization |
| `structural_manifest.jl` | Canonical structural manifest: payload, `ManifestID`, standalone validator |
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

One shared-battery operating mode per relevant information state, created only by the
repository's verified `add_shared_battery_mode_constraints!`:

    sum_j y[j,n] <= F_d (1 - v_n),      sum_j z[j,n] <= F_c v_n

By default (`BATTERY_DIRECTION_EXCLUSIVITY=1`, `config.battery_direction_exclusivity=true`)
`v_n in {0,1}`, exactly as before. Setting `BATTERY_DIRECTION_EXCLUSIVITY=0` relaxes `v_n` to
a continuous `[0,1]` variable over the SAME two rows, to measure the price of integrality
without changing the formulation's structure (decision log, `docs/oos_redesign_plan.md`).

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

Under the `[0,1]` relaxation (`BATTERY_DIRECTION_EXCLUSIVITY=0`), `GeneratedModeBinaries`
correctly reports `0` for the shared-battery family (the mode is no longer `Bin`), while
`ExpectedModeNodes` stays the topological node count regardless of the toggle. The two must
never be compared across differing toggle values as if they meant the same claim.

## Abstract temporal structure (`H`, `L`, `h`)

A **period is an abstract model period.** No rolling-horizon parameter defines minutes, hours,
days or any clock-time interval, and no calendar cycle may be inferred from one. The physical
duration of a period lives only in the instance, in `template.delta`. There is deliberately no
`PERIOD_DURATION_MINUTES`, no `PROFILE_CYCLE` and no equivalent variable, and none may be added.

| Symbol | Field | Environment variable | Default | Meaning |
|---|---|---|---|---|
| `H` | `evaluation_horizon` | `EVALUATION_HORIZON` | 24 | periods included in the out-of-sample evaluation |
| `L` | `lookahead_horizon` | `LOOKAHEAD_HORIZON` | 24 | consecutive periods in every future rolling optimization |
| `h` | `implementation_step` | `IMPLEMENTATION_STEP` | 1 | consecutive periods committed before the next optimization |

Admissible parameters satisfy `H >= 1`, `L >= 1` and `1 <= h <= min(H, L)`, validated fail-fast in
the `OOSExperimentConfig` constructor. `h` is **any** integer in that range: it is not restricted
to a fixed set such as `{1, 4}`, and it need **not** divide `H`. Divisibility is deliberately not
a validation rule.

`temporal.jl` derives everything else with pure, side-effect-free helpers — no solver, no
scenario tree, no instance file, no filesystem state:

| Helper | Value | Example (`H = L = 24`) |
|---|---|---|
| `known_prefix_length(config)` | `h` | `h = 4` → `4` |
| `rolling_iteration_starts(config)` | `{1, 1+h, 1+2h, ...} ∩ 1:H` | `h = 10` → `[1, 11, 21]` |
| `rolling_solve_count(config)` | number of valid starts | `h = 10` → `3` |
| `is_rolling_iteration_start(config, t)` | `1 <= t <= H` and `(t-1) mod h == 0` | `h = 4, t = 2` → `false` |
| `final_rolling_iteration_start(config)` | `max(starts)` | `h = 10` → `21` |
| `implementation_block(config, t)` | `t:(t+h-1)`, **not clipped** | `h = 10, t = 21` → `21:30` |
| `evaluation_block(config, t)` | `t:min(t+h-1, H)` | `h = 10, t = 21` → `21:24` |
| `lookahead_periods(config, t)` | `t:(t+L-1)`, **not clipped** | `h = 10, t = 21` → `21:44` |
| `lookahead_end_period(config, t)` | `t+L-1` | `h = 10, t = 21` → `44` |
| `required_period_support_end(config)` | `max(starts) + L - 1` | `h = 1` → `47`; `h = 4` or `10` → `44` |

The final full committed block may run **past** `H`. That is intentional: the controller commits
the complete block and only its intersection with `1:H` contributes to reported OOS metrics.
A block is never silently truncated, and a valid final block is never rejected for extending
beyond the evaluation horizon. `implementation_block` and the look-ahead helpers reject a `t`
that is not one of `rolling_iteration_starts(config)`, distinguishing a range error from an
alignment error.

Stage 3 keeps five temporal quantities distinct:

| Symbol | Repository field/helper | Meaning |
|---|---|---|
| `T0` | `template.T` / `repository_instance_horizon` | horizon of the repository instance and length of its deterministic base profile |
| `H` | `evaluation_horizon` | periods included in future OOS evaluation |
| `L` | `lookahead_horizon` | length of every future moving optimization window |
| `Tsupport` | `required_period_support_end(config)` | last abstract period for which providers must be able to supply data |
| `Tdata` | `materialized_data_end` | stored endpoint, equal to `max(T0, Tsupport)` so the complete repository profile is retained |

`Tsupport = max(rolling_iteration_starts(config)) + L - 1`; it is neither `H` nor `L`, and
`Tdata` is not silently repurposed as any of the other four quantities. `OOSPeriodDataSupport`
records all three endpoints (`T0`, `Tsupport`, `Tdata`) and keeps `template.T == T0` unchanged.

### Centralized abstract-period mapping and exact extension

All Stage-3 profile repetition goes through the single pure function

```text
base_period_index(period, T0) = 1 + ((period - 1) mod T0),  period >= 1, T0 >= 1.
```

Its persisted contract is named `repository_base_period_repeat`, version
`base_period_index_v1`. PV, prices and household activity contain no second copy of this modular
arithmetic. For household `j` and abstract period `tau`, the exact extension is

```text
nu_ext[j, tau] = nu[j, base_period_index(tau, T0)]
pv_ext[tau]    = pv_det[base_period_index(tau, T0)]
active[j,tau] = active_base[j, base_period_index(tau, T0)].
```

The first `T0` columns/elements and every base household profile label and activity value are
required to compare with `==`, not a tolerance. Later values are copies of those base entries:
no price or PV is sampled or regenerated, and the already-resolved Stage-2 household assignment
is never resampled or replaced by the legacy independent `mixed` rule. `avg_demand` and
`dev_demand` remain unchanged. The words `morning`, `midday` and `night` remain repository profile
labels only; repetition does not interpret them, `T0`, or any period as clock time.

The builder allocates fresh arrays, mutates neither its template nor its stored assignment, uses
no RNG or cache, and preserves `template.delta` exactly. It performs no energy, power, price or
rate conversion. `OOSPeriodDataSupport` itself is immutable, defensively copies its nested
arrays/models, and exposes them as task-local read-only scientific inputs by contract. An
extended `RepositoryUncertaintyProvider` stores the three endpoints
separately and validates `sample_oos_path`, `conditional_mean_path`,
`conditional_scenario_paths`, `conditional_scenario_tree`, `filter_pv_state`, `pv_from_state`,
`sample_demand_column`, `mean_demand_column` and `in_sample_tree_data` against `Tsupport`.
Stochastic methods continue to require an explicit RNG. Repeated calls with the same inputs and
RNG seed are order- and worker-independent; there is no mutable process-global provider cache or
provider RNG. The legacy constructor still materializes only through `T0`, preserving the active
single-instance runner.

`experiment_config.json` records all of this under `temporal_structure`, alongside
`repository_instance_horizon`. The repository instance horizon `template.T` stays separately
identified there and under `instance.horizon`; it is never renamed or reinterpreted.

> **Current scope.** Stage 4 consumes the Stage-3 extension. The simulator iterates
> `rolling_iteration_starts(config)`, every look-ahead spans exactly `t : t+L-1`, the terminal
> state-of-charge target binds at `tree.last_period` instead of permanently at `template.T`, and
> the physical model, realized cost accounting and fairness aggregates read their prices from the
> extended support through the one `rolling_price` accessor. `template.T` keeps its own separate
> meaning as the repository horizon and base profile length.
>
> Still unwired: the known prefix and multi-period implementation blocks. Stage 4 reveals and
> implements exactly one period per rolling start and **rejects** `implementation_step > 1` with
> an attributable message naming Stage 6. The three controllers also still draw independent
> look-ahead samples; one common conditional support is Stage 5. Every result directory records
> this honestly in `temporal_structure.contract_status = "wired_moving_lookahead: ..."`.
>
> A consequence worth naming: because the terminal target now moves with the window, the state of
> charge reached at the end of the evaluation horizon is an **outcome** of the rolling policy, not
> a value the model promised. It is reported as a diagnostic and is only required to be
> physically admissible. Correspondingly, the strict `PEA` equality no longer becomes unreachable
> merely because the horizon ran out of PV — that was an artefact of the shrinking horizon. The
> adaptive-minimum recovery machinery is unchanged and is now exercised, in the tests, through a
> genuinely short look-ahead.

## Structural instances versus OOS replications

A **structural instance** fixes the physical and demand-composition characteristics that stay
constant while several stochastic trajectories are evaluated. An **OOS replication** is one such
trajectory *inside* a fixed structural instance. They are separate experimental levels: instance
factors are fixed first, then multiple paired stochastic paths are evaluated within each instance.

The primary structural design is

```
B base instances  x  2 battery levels  x  2 demand regimes  x  2 uncertainty levels  x  K draws
```

### Factor label sets

| Factor | Labels | Maps to |
|---|---|---|
| Battery level | `LOW_BATTERY`, `HIGH_BATTERY` | a `battery_scale` |
| Demand regime | `HOMOGENEOUS`, `HETEROGENEOUS` | a household profile composition |
| Uncertainty level | `LOW_UNCERTAINTY`, `HIGH_UNCERTAINTY` | a `theta` |

They are typed enums, not free strings, and the manifest records their canonical labels rather
than any integer representation. A **structural draw** `d` with `1 <= d <= K` is a blocking index:
it is shared across the battery and uncertainty variants of the same base instance and regime.

> **The numeric factor values are PROVISIONAL and UNCALIBRATED.** The battery scales, the `theta`
> values and `K` are explicit required inputs with no repository defaults, and every manifest
> records `factor_level_status = PROVISIONAL_UNCALIBRATED`. Stage 12 calibrates and approves the
> campaign levels. Any number appearing in a script comment, a test or this document is a fixture.

### Controlled demand assignment

`structural_demand_assignment(households, regime, assignment_seed)` is pure and returns one
ordered profile label per household, drawn only from `morning`, `midday`, `night`.

* `HOMOGENEOUS` draws **one** profile and gives it to every household. It never uses the legacy
  independent per-household `mixed` rule, which can turn a nominally homogeneous instance mixed.
* `HETEROGENEOUS` splits households as evenly as arithmetic allows, hands any remainder to a
  seeded ordering of the three profile labels, then applies a seeded permutation of household
  identities. Counts always satisfy `max - min <= 1`; with five households they are a permutation
  of `2, 2, 1`. Zero counts occur only when there are fewer households than profiles.

Composition is distinct from `dev_demand`, which keeps controlling stochastic dispersion *around*
an assigned profile. `avg_demand` and `dev_demand` are fixed across the primary design.

For a fixed base instance, regime and draw the assignment is identical across both battery
levels, both uncertainty levels, every replication, every controller and every fairness policy —
battery level and uncertainty level are absent from its seed. `OOSHouseholdDemandModel` records
are built from the resolved assignment with no re-sampling.

### Identifiers

Readable prefix plus a stable `fnv1a64_v1` digest of an explicitly ordered token list. No
identifier depends on an absolute path, a timestamp, a process, a hostname, a worker, an output
directory or execution order, and none uses `Base.hash`.

| Identifier | Includes | Excludes |
|---|---|---|
| `BaseInstanceID` | the normalized file stem, e.g. `Drahi_1` | the directory, so a checkout location cannot change it |
| `DeterministicDataID` | experiment seed, normalized base instance, structural draw and every fixed repository-generator parameter listed below | battery, demand regime/assignment, uncertainty, replication, policy, worker and execution fields listed below |
| `DemandAssignmentID` | base instance, demand regime, structural draw, ordered profile vector | battery level and scale, uncertainty level, `theta`, controller, fairness, replication, worker |
| `PairedBaseID` | base instance, draw, regime, `DemandAssignmentID`, uncertainty level, `theta`, fixed primary-design parameters | battery level and battery scale |
| `StructuralInstanceID` | the `PairedBaseID` plus battery level and its scale | — unique across the catalog |
| `ManifestID` | digest of the whole canonical payload minus the digest field | ephemeral paths, timestamps, machine facts |

The repository-generated `InstanceM.id` is recorded separately as `repository_instance_id`; it is
`"J_V"` and therefore identical for every base file of the same geometry, so it is not an
instance identifier. Every `PairedBaseID` corresponds to exactly **two** structural instances,
one per battery level, and each `DemandAssignmentID` is shared by `2 x 2 = 4` of them. One
`DeterministicDataID` exists per `(normalized base instance, structural draw)` and is shared by
exactly eight structural variants: `2 battery x 2 demand regime x 2 uncertainty`. Thus the
bounded one-base, `K = 2` fixture has 2 deterministic blocks and 16 structural instances.

### Seed hierarchy

| Stream | Included keys | Excluded keys |
|---|---|---|
| `structural_deterministic_base` | experiment seed, normalized base-instance file, structural draw, in-sample stages, children and periods per stage, households, `avg_demand`, `dev_demand`, `pv_scale`, fixed repository demand-profile argument | battery level, battery scale, demand regime, `DemandAssignmentID`, uncertainty level, `theta`, OOS replication, rolling start, controller, fairness policy, solver phase, worker, retry, execution order |
| `structural_assignment` | experiment seed, base instance, demand regime, structural draw | battery level, uncertainty level, `theta`, replication, rolling start, controller, fairness, solver phase, worker, order |
| `structural_oos_path` | + demand assignment, uncertainty level, replication | battery level, `theta`, rolling start, controller, fairness, solver phase, worker, order |
| `conditional_support` | + rolling start | battery level, `theta`, controller, fairness, solver phase, worker, order |

All three are built on the repository's deterministic FNV-1a `oos_stream_seed` under distinct
stream names, so no hierarchy can consume another's numbers. `OOSPathSeedKey` cannot *represent*
a battery level or a controller, so no future edit can leak one into a seed by accident. That
exclusion is exactly what will give a low/high battery comparison the same exogenous trajectory.

The uncertainty **level** is a key of the planned OOS-path and conditional-support streams; its
numeric `theta` is not, so a Stage-12 recalibration of level values does not renumber those
streams. Stage 2 does not introduce common random numbers *across* uncertainty levels — their
planned OOS/support seeds deliberately remain different. Neither the uncertainty label nor
`theta` is a key of the deterministic repository-base stream.

### Legacy seed confound and the Stage-3 isolation path

Stage 2 empirically established that the default `generateInstance` path computes
`deterministic_seed(...)` from the in-sample tree geometry, household count,
`basename(inFile)`, `theta`, `avg`, `dev` and repository `demand_profile`; it excludes `pv_scale`
and `battery_scale`. The call then executes `Random.seed!` on Julia's `TaskLocalRNG` and draws the
legacy in-sample PV/demand objects **and `nu`**. Low/high `theta` values therefore produced
different task-local seeds, stochastic legacy objects and deterministic price matrices. Direct
inspection with a common override found exact equality of `nu`, `pv_det` and physical inputs:
`theta` affects legacy `c_pv` directly through the stochastic PV construction, can affect
`d`/`d_det` indirectly through the PEA demand-repair path, and affects `nu` only through the
legacy theta-keyed seed. An uncertainty-level cost contrast was consequently confounded by a
deterministic-price contrast under the legacy default, not because prices are a modeled
uncertainty process.

The empirical RNG probe identified `Random.default_rng()` as a `TaskLocalRNG`: each
`generateInstance` call reseeds and consumes that current task-local default stream. An explicit
`MersenneTwister` held by the caller is not reseeded or consumed. This is why pure Stage-3
providers take their RNG as an argument and why the legacy generator is never invoked
concurrently during catalog construction.

Stage 3 adds the narrowly scoped keyword
`generateInstance(...; repository_seed_override=nothing)`. `nothing` takes the exact legacy
branch: the seed construction, `TaskLocalRNG` reseeding, repository instance ID, `nu`, `pv_det`,
physical parameters and legacy in-sample tree remain unchanged. The structural OOS materializer
instead supplies `actual_repository_generator_seed(OOSDeterministicBaseKey)`, whose exact
included and excluded fields are the `structural_deterministic_base` row above. It records both
the counterfactual theta-dependent `legacy_default_repository_instance_seed` and the seed that
actually controlled generation, `actual_repository_generator_seed`, without relabelling either
as an OOS-path or support seed.

With the common actual seed, all low/high-uncertainty pairs compare exactly equal on `nu`,
`pv_det`, `J`, `T0`, `delta`, `e_c`, `e_d`, `s_I`, `s_min`, `s_max`, `f_under`, `f_bar`, `mu`,
`beta`, `pv_scale`, `avg_demand`, `dev_demand`, fixed household assignment, extended prices,
extended PV reference and extended household activity. They retain different uncertainty labels,
`theta`, `StructuralInstanceID`, `PairedBaseID`, planned OOS-path seeds, planned conditional-
support seeds, stochastic PV laws and the theta-dependent legacy/calibration stochastic fields.
The repository's legacy in-sample tree remains explicitly a calibration object, not rolling
conditional support.

Because even the override path still calls `Random.seed!` on the task-local RNG, structural
catalog materialization remains deliberately **sequential**. The explicit seed at the top of
each call makes the result deterministic and order-independent, but Stage 3 does not authorize a
threaded generator. Pure extension/provider work uses explicit `MersenneTwister` instances and
can be reconstructed independently without worker identity or initialization order.

### Battery scaling is not self-similar

`scaleInstance!` applies `s_max *= scale` but `f_under *= scale*4` and `f_bar *= scale*4`, and it
does nothing at all when `scale == 1.0`. So capacity and power do not move together, a scale
below `0.25` yields a *larger* rate limit than the repository default, and a level placed exactly
at `1.0` is off-curve. `s_min` and `s_I` never scale. These are properties of the verified
pipeline; the catalog records the resolved `s_min`, `s_max`, `s_I`, `f_under` and `f_bar` for
every structural instance and prints an advisory rather than silently working around them.
Stage 12 must therefore calibrate battery levels against the complete resolved vector
`(s_min, s_max, s_I, f_under, f_bar)`, including the discontinuity at `battery_scale == 1.0` and
the rate-scaling behavior around `0.25`, rather than treating `battery_scale` alone as the
scientific factor. It may calibrate the low/high `theta` values only after the deterministic-
isolation gate above passes; Stage 3 proves that prerequisite but does not choose either value.

### Manifest generation and validation

```bash
# Generate. The four factor levels and K are REQUIRED; the values here are fixtures.
INSTANCE_DRAWS_PER_CELL=2 \
LOW_BATTERY_SCALE=0.5 HIGH_BATTERY_SCALE=2.0 \
LOW_UNCERTAINTY_THETA=0.1 HIGH_UNCERTAINTY_THETA=0.4 \
STRUCTURAL_MANIFEST_PATH=results_oos_structural/structural_instance_manifest.json \
bash scripts/oos/generate_structural_instance_manifest.sh

# Validate a saved manifest standalone, rematerializing every instance.
bash scripts/oos/validate_structural_instance_manifest.sh \
  results_oos_structural/structural_instance_manifest.json
```

The generator validates the design *before* materializing anything, builds the complete catalog
through the verified pipeline, checks every invariant, writes atomically, and prints the path,
the `ManifestID` and the expected versus actual counts. Identical content is an idempotent no-op;
conflicting content fails unless `STRUCTURAL_MANIFEST_OVERWRITE=1`, so a different manifest is
never silently replaced. The catalog is built **sequentially** on purpose:
`generateInstance` reseeds the task-local RNG, so a threaded build would not be reproducible.

`structural_instance_manifest.json` is the authority and carries its own
`structural_manifest_schema_version` (currently **2**), independent of
`output_schema_version` — a manifest change never forces a results-schema bump. A normalized
`structural_instance_manifest.csv` is a convenience companion and is never digested. Machine- and
moment-dependent facts go to `structural_instance_manifest_provenance.txt`, which is explicitly
**noncanonical**: the canonical payload contains no timestamp, absolute path, hostname or
git-dirty flag, which is what makes it byte-identical across machines and processes.

Schema v2 retains every Stage-2 identity, assignment, pairing and planned OOS/support seed and
adds `deterministic_data_blocks`. Each block records its `DeterministicDataID`, actual generator
seed, exact included/excluded seed keys, normalized base instance, structural draw, fixed
generator parameters, `T0`, `Tsupport`, `Tdata`, mapping name/version/formula and stable digests
of base/extended price, base/extended PV reference and base/extended demand activity. Every
structural row references its block; each demand assignment records its own activity digest.
`design.deterministic_base_isolation_status = "passed"` and `design.stage3_ready = true` are
validated claims, not informational labels.

The standalone validator recomputes the manifest digest and all IDs/seeds/cardinalities, checks
the mapping and endpoints, verifies the eight-way deterministic grouping, enforces low/high
uncertainty, battery and demand-regime isolation, and can rematerialize rows to compare the
stored support digests and resolved physics. Corruption tests reject wrong mappings, missing
support, altered price/PV/activity/digests, factor-dependent repository seeds, isolation breaks
and an incorrect `ManifestID`; the canonical scientific payload also rejects clock/calendar
interpretations and worker/order-dependent fields. Separate-process generation is required to
produce identical JSON bytes, `ManifestID`, `DeterministicDataID`s, actual seeds and extended-
data digests.

A schema-v1 document remains an interpretable Stage-2 artifact, but it contains no proof of
extended support or deterministic isolation. The current validator therefore rejects it
explicitly as not Stage-3-ready with `regenerate as schema v2`; it is never silently upgraded or
reinterpreted. `output_schema_version` remains **2**, because no active period-level output
schema changed in Stage 3.

Stage 3 is **COMPLETE** on the focused `P0`–`P10` acceptance tests and direct core probes. Exact
full-suite and bounded-preflight command totals belong to
`docs/oos_stage3_completion_report.md`; this design document does not manufacture or duplicate
those final run counts. No package dependency was added.

> **The manifest is not yet consumed by the active simulator.** The single-instance runner keeps
> its own defaults and behaviour, `oos_path_rng` and `lookahead_rng` are untouched (the look-ahead
> key still includes the controller — removing it is stage 5), and the planned OOS-path and
> conditional-support entries are **seed and identity contracts only**: no scenario tree, two-stage
> scenario set, deterministic forecast or `ScenarioSupportID` is generated. Every manifest states
> this in `design.consumed_by_active_simulator = false`, and the validator enforces it.
>
> **Superseded by stage 13.** The campaign runner now enumerates its tasks from the manifest
> through `oos_tasks_from_manifest`, which regenerates the catalog and refuses to run if any
> recorded identifier differs. The flag is `true` and the validator enforces the new direction.

Stage 3 satisfies only the parallel-readiness side of the contract: pure period extension,
immutable/task-local provider inputs, explicit RNGs, no worker-dependent scientific key and
independent reconstruction in another process. It creates no workers, schedulers, campaign
shards or concurrent writers. Structural generation stays a sequential pre-campaign operation.
Actual process-level tasks, isolated restartable shards and deterministic coordinator-only merge
remain wholly assigned to Stage 13 under `docs/oos_redesign_plan.md` §4.9.

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

### Campaign outputs, produced only by the merge

A **shard** holds row-level data for one replication of one paired base, so it deliberately omits
every file that aggregates over replications. Those are produced once, by
`scripts/oos/merge_oos_shards.sh`, from the merged replication-level rows.

| File | Grain | Produced by |
|---|---|---|
| `configuration_summary.csv` | pooled PEA statistics per controller x rule | merge |
| `paired_statistics.csv` | levels and paired differences, keyed on `(StructuralInstanceID, OOSReplicationID)` | merge |
| `campaign_cost_by_cell.csv` | cost crossed with controller, rule, resource, objective criterion, battery level, demand regime, uncertainty level and implementation step | merge |
| `campaign_paired_by_cell.csv` | controller effect differenced **inside** each design cell | merge |

The pairing key is the pair, never the replication number alone: a replication number identifies
a trajectory only *within* one structural instance, so differencing on the number by itself would
subtract rows belonging to unrelated instances.

`campaign_paired_by_cell.csv` differences first and averages second. Controller-rule rows that
share one out-of-sample path are not independent observations, so pooling before differencing
would throw away the pairing that gives the estimate its precision.

The merge also prints an **operational review** (`OOS_CAMPAIGN_REVIEW_STATUS`). It is not the
schema validator: `validate_output_directory` asks whether the dataset is well-formed, the review
asks whether the experiment it records is fit to scale up. It blocks on an unfrozen code tree, an
unpinned solver thread count, incomplete cells, aborted runs, a design left unbalanced by a rule
that aborts in only some cells, physical violations, and solves stopped on the time limit. It
reads each fairness residual against the tolerance that rule declares — a lexicographic rule
legitimately consumes its `lex_eps_abs`, so its raw residual is ~1.0 and means nothing like what
the same number would mean under a rule with no band.

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
profiles, the uncertainty-process coefficients, the warm-start settings, the abstract temporal
contract under `temporal_structure`, and the full gate and audit transcript.

The `temporal_structure` section is additive and touches no CSV schema, so it does not bump
`output_schema_version`. It records `evaluation_horizon`, `lookahead_horizon`,
`implementation_step`, `known_prefix_length`, `rolling_solve_count`, `rolling_iteration_starts`,
`required_period_support_end`, the final full committed block and its evaluated portion,
`repository_instance_horizon` (`= template.T`, kept separate from every rolling-horizon
quantity) and a `contract_status` marker. Stage 4 adds `realized_period_end`, the final moving
window and `implementation_step_supported`. It contains no period duration and no calendar cycle,
and the vocabulary gate in `T7` keeps it that way.
The separate schema-v2 structural manifest additionally records `materialized_data_end`, the
mapping contract and all deterministic-support digests. Those manifest-only fields are still not
added to the active runner's period CSVs: per-row structural, support and block identifiers are
Stage 10, and `output_schema_version` therefore remains **2**.

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
EVALUATION_HORIZON=24 LOOKAHEAD_HORIZON=24 IMPLEMENTATION_STEP=1 \
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
one instance configuration. `EVALUATION_HORIZON`, `LOOKAHEAD_HORIZON` and `IMPLEMENTATION_STEP`
are forwarded only when set explicitly, so the shell never re-declares a numeric default that
could drift from the Julia constants; an absent or blank value uses the Julia default and an
explicitly malformed one aborts naming the variable.

`MULTISTAGE_BRANCHING` (the `MULTISTAGE_RH` look-ahead tree, unrelated to `TREE_SET`, which
builds the underlying instance) accepts two notations, both parsed by
`parse_multistage_tree_spec` in `codes/oos_experiment/types.jl`:

  * a per-stage-transition **list**, e.g. `"2,2"` for 3 stages branching by 2 each time. Combine
    with `MULTISTAGE_PERIODS_PER_STAGE` (same list convention, `length(branching)+1` entries) for
    an explicit periods-per-stage split, or leave it blank for the automatic even split of the
    remaining look-ahead window across stages.
  * a compact **symmetric** `stages:children:periods_per_stage` triplet, e.g. `"4:4:6"`, in the
    same `S:C:P` order as `TREE_SET`. It expands to `fill(children, stages-1)` branching factors
    and `fill(periods_per_stage, stages)` periods, and fixes `periods_per_stage` by itself:
    combining it with an explicit `MULTISTAGE_PERIODS_PER_STAGE` is rejected rather than letting
    one of the two win silently.

The runner refuses to start when `FORMULATION_ID` is missing, when the validation gate is disabled
without `OOS_ACKNOWLEDGE_UNVALIDATED=1`, or when `OOS_OUTPUT_DIR` points at a pre-existing results
directory. Representative-model inspection failures and inconsistent battery physics abort inside
Julia, before any configuration runs.

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
