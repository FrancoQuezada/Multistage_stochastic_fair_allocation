# OOS redesign — Stage 3 completion report

**Stage:** 3 — Extended abstract-period data support and deterministic-base isolation  
**Scope authority:** `docs/oos_redesign_plan.md` §4.1, §4.4, §4.9 and §7 (Stage 3)  
**Date:** 2026-08-07  
**Status:** **COMPLETE**

## Outcome and scope

Stage 3 adds a pure data-support layer that preserves the repository instance over its original
horizon and repeats its deterministic prices, deterministic PV reference and already-resolved
household activity through the temporal contract's required abstract-period endpoint. The
structural catalog now materializes every battery × demand-regime × uncertainty variant from one
uncertainty-independent deterministic repository base per `(base instance, structural draw)`.

All Stage-3 acceptance gates passed. The active simulator remains on its accepted legacy loop and
shrinking look-ahead, and it does not depend on the structural manifest. No Stage-4-or-later work,
campaign fan-out, worker creation, task sharding, concurrent writer or experimental campaign was
started.

## Baseline before Stage-3 editing

Repository instructions, the full repository tree, the accepted Stage-1/Stage-2 reports and every
named consumer in the Stage-3 request were inspected before editing. There is no repository
`AGENTS.md`; the applicable home instruction file was empty. The dirty working tree contained the
accepted, uncommitted Stage-1/Stage-2 work plus the pre-existing `results_oos/` directory. Those
changes and results were preserved.

The project manifest selects Julia 1.12.6. All reported Julia commands used that channel. The
machine's unqualified Julia 1.11.7 cannot load this already-resolved environment because its
installed `PrecompileTools` path refers to `Base.StaticData`; this pre-existing toolchain mismatch
is not a Stage-3 failure and no dependency was changed to work around it.

| Baseline command/gate | Result before editing |
|---|---:|
| focused Stage-1 `T1`–`T9` | PASS, 833/833 assertions, 24.92 s |
| focused Stage-2 `S0`–`S11` | PASS, 3,726/3,726 assertions, 69.18 s |
| `bash scripts/oos/validate_oos_experiment.sh` | PASS, exit 0, 13,538 assertions, 225.36 s |
| schema-v1 manifest generation and full rematerialization | PASS, 16/16 records, 0 issues |
| `bash scripts/oos/preflight_oos_campaign.sh` | `READY`, exit 0, 0 failed checks, 406.53 s |

The baseline full-suite total comprises 13,432 assertions in the OOS parent process and 106 in
the nested repository regression. No baseline test failed.

For the bounded pre-edit manifest fixture (`Drahi_1`, `J=4`, `K=2`, battery scales `0.5/2.0`,
theta values `0.1/0.4`, `H=L=T0=24`, `h=12`), schema v1 produced:

| Item | Baseline value |
|---|---|
| `ManifestID` | `MF-c9a52037f37d0426` |
| structural / paired / demand-assignment rows | 16 / 8 / 4 |
| planned OOS / conditional-support rows | 16 / 32 |
| JSON SHA-256 | `bb107c238fb65f53292b8a730ea5987477c34ec40b3bb9bab73355ea3ee5db10` |
| CSV SHA-256 | `aae2d85e564352b4557dfff0187f096de06622ad54db7d66dde15e1a047a6393` |

Preflight checks `01`, `02`, `03`, `04`, `06`, `07`, `08`, `09`, `10`, `11`, `12`, `13` and
`17` were `PASS`. Advisory warning `7a` identified the older preserved `results_oos/` directory;
warning `7b` identified the accepted dirty worktree.

## Repository findings reproduced before implementation

The legacy repository generator calls `Random.seed!(deterministic_seed(...))` and then consumes
Julia's current `TaskLocalRNG`. In the bounded probe, theta `0.1` and `0.4` produced legacy seeds
`994328389` and `175856947`, respectively. All 72 tested entries of `nu` differed, while
`pv_det` and the physical parameters were equal. `c_pv`, `d` and `d_det` also differed.

Repeating the same probe with one explicit common repository seed made `nu`, `pv_det` and the
physical parameters exactly equal. `c_pv` still differed because theta enters `pv_ms` directly;
`d` and `d_det` may then differ through the PEA feasibility repair. Therefore:

- theta changed `nu` only indirectly, by entering the legacy generator seed;
- theta changes the stochastic/calibration PV tree directly;
- repaired demand can change downstream of that stochastic PV tree; and
- no other tested deterministic or physical field depends directly on theta.

`Random.default_rng()` was confirmed to be a `TaskLocalRNG`. `generateInstance` reseeds and
consumes it even when Stage 3 supplies an override; it does not consume a separate caller-owned
`MersenneTwister`. Structural materialization consequently remains sequential, as required, while
the explicit seed makes each call reproducible and independent of catalog order.

## Temporal data-support contract

### Distinct endpoints

Stage 3 keeps these quantities separate:

- `T0 = template.T`: repository instance horizon and base-profile length;
- `H = evaluation_horizon`;
- `L = lookahead_horizon`;
- `required_period_support_end(config)`: last abstract period required by the future moving-window
  contract; and
- `materialized_data_end = max(T0, required_period_support_end)`.

`template.T` is unchanged and is never redefined as the evaluation or support horizon.

### One mapping

The sole repetition arithmetic is:

```julia
base_period_index(period::Int, base_horizon::Int)::Int =
    mod1(period, base_horizon)
```

after rejecting `period < 1` and `base_horizon < 1`. Equivalently,

\[
\kappa(\tau;T_0)=1+((\tau-1)\bmod T_0).
\]

The mapping is named `repository_base_period_repeat`, version
`base_period_index_v1`. A source gate confirms that the Stage-3 data layer contains exactly one
`mod1` operation and that `demand_active_periods` delegates to `base_period_index` instead of
retaining local cycling arithmetic.

### Immutable interface and exact extension

`OOSPeriodDataSupport` is an additive immutable contract exposing:

```text
repository_instance_horizon
required_period_support_end
materialized_data_end
households
period_mapping_name / period_mapping_version / period_mapping_formula
nu
pv_det
demand_models
```

`build_period_data_support(template, support_end)` allocates fresh arrays and resolved model
copies. `validate_period_data_support` independently rechecks dimensions, finiteness, endpoints,
mapping metadata and every repeated price, PV and activity entry. Provider constructors invoke
that validation, so a forged or subsequently mutated extended array cannot cross the provider
boundary unnoticed. These task-local arrays are documented as read-only scientific inputs; no
cache or worker-global mutable state was introduced.

For every household `j` and materialized period `tau`:

```text
nu_ext[j, tau] = template.nu[j, base_period_index(tau, T0)]
pv_ext[tau]    = template.pv_det[base_period_index(tau, T0)]
activity[j,tau] is the resolved base-profile activity at base_period_index(tau, T0)
```

The first `T0` values are compared with `==`, not a tolerance. Profiles are never resampled, the
legacy independent `mixed` assignment is never called during extension, and `avg_demand`,
`dev_demand`, profile labels, physical parameters and `template.delta` are unchanged. Extension
does not sample prices or deterministic PV and performs no unit conversion.

### Endpoint fixtures

| Fixture | `T0` | `H` | `L` | `h` | required support | data end | Purpose |
|---|---:|---:|---:|---:|---:|---:|---|
| multi-cycle period fixture | 24 | 50 | 24 | 7 | 73 | 73 | exceeds `2T0`; checks every repeated entry |
| bounded focused catalog | 24 | 24 | 24 | 6 | 42 | 42 | 16 structural variants, all isolation pairs |
| standalone final manifest | 24 | 24 | 24 | 12 | 36 | 36 | complete rematerialized schema-v2 artifact |

Mapping boundaries `1`, `T0`, `T0+1`, `2T0`, `2T0+1` and the final support period are all tested.
A shorter requested endpoint also retains the entire base profile by using `max(T0, Tsupport)`.

## Provider support and compatibility

`RepositoryUncertaintyProvider` now records the repository horizon, required support endpoint and
materialized endpoint separately. Its legacy `T` field remains as an exact alias of the repository
horizon for compatibility. The old eight-argument positional constructor is retained, and
`RepositoryUncertaintyProvider(template)` still builds support only through `template.T`.
Additive constructors accept an explicit `OOSPeriodDataSupport`.

Direct tests exercise all of these interfaces at `T0`, `T0+1` and the maximum support period:

```text
sample_oos_path
conditional_mean_path
conditional_scenario_paths
conditional_scenario_tree
filter_pv_state
pv_from_state
sample_demand_column
mean_demand_column
```

Horizon checks use the resolved support endpoint. Every stochastic interface still takes an
explicit RNG; identical inputs and `MersenneTwister` seeds give identical results regardless of
call order. The default `build_instance_template(config)` result retains its accepted three-field
named tuple `(template, in_sample_tree, instance)` and byte-compatible legacy metadata. Only an
explicit structural seed override adds the fourth `actual_repository_generator_seed` field.

## Deterministic-base isolation

### Exact key

`OOSDeterministicBaseKey` and its canonical `DeterministicDataID` use exactly these scientific
inputs:

```text
experiment_seed
normalized_base_instance_file
structural_draw
in_sample_stages
in_sample_children
in_sample_periods_per_stage
households
avg_demand
dev_demand
pv_scale
repository_demand_profile
```

They exclude exactly:

```text
battery_level
battery_scale
demand_regime
demand_assignment_id
uncertainty_level
theta
oos_replication
rolling_start
controller
fairness_policy
solver_phase
worker
retry
execution_order
```

The actual repository generator seed is a stable FNV-1a stream seed named
`structural_deterministic_base`; neither the key nor the type can hold an excluded experimental
or execution field. `DeterministicDataID` uses canonical ordered tokens and a stable digest, never
Julia's `hash`.

### Legacy-preserving seed override

`generateInstance(...; repository_seed_override=nothing)` implements the narrow isolation path:

- `nothing` executes the exact legacy theta-dependent `deterministic_seed` path and retains its
  `TaskLocalRNG` side effect;
- a positive integer is the actual seed passed to `Random.seed!`;
- `build_instance_template` forwards it only when explicitly requested; and
- structural specs, rows and deterministic blocks record both the legacy audit seed and the
  unambiguous actual generator seed.

The repository-wide `deterministic_seed` was not changed. Ordinary repository callers therefore
produce the same instance ID, `nu`, `pv_det`, physical parameters and legacy in-sample tree as
before. The in-sample tree remains explicitly labeled a legacy/calibration object and is not
mistaken for rolling conditional support.

### Fields compared after materialization

For every fixed battery/regime low–high uncertainty pair, exact equality is enforced for:

```text
nu, pv_det, J, T0, delta, e_c, e_d, s_I, s_min, s_max, f_under, f_bar,
mu, beta, pv_scale, avg_demand, dev_demand, fixed household profiles,
extended prices, extended deterministic PV and extended household activity,
DeterministicDataID and actual repository generator seed
```

The uncertainty label and theta must differ. `StructuralInstanceID`, `PairedBaseID`, the planned
OOS-path seed, the planned conditional-support seed and theta-dependent stochastic/calibration
tree values may differ. Realized stochastic paths are deliberately not required to match, and no
common random numbers were introduced across uncertainty levels.

Battery variants share prices, deterministic PV, assigned activity and non-battery physical
fields while retaining a different resolved battery vector. Demand regimes share the repository
deterministic base and physical fields while retaining distinct controlled assignments and the
demand processes induced by them. Changing structural draw changes the deterministic ID and
actual seed. Controller order, fairness order, solver threads, simulated worker identity and task
order change none of the support payload.

For all eight bounded low/high pairs, `nu` and the deterministic price contribution of a fixed
import matrix were exactly equal. The Stage-2 uncertainty-specific OOS and support seeds remained
different. This removes deterministic-price movement from a future uncertainty-level cost
comparison without changing the approved stochastic seed pairing contract.

## Structural manifest schema v2

Only `structural_manifest_schema_version` increased, from 1 to 2. The period-level OOS result
schema remains version 2 and no CSV result column changed.

Schema v2 records:

- the three temporal data endpoints and mapping name/version/formula;
- the fixed repository generator tree geometry in the design header, reconciled against every
  deterministic block and structural row;
- `stage3_ready=true` and `deterministic_base_isolation_status="passed"`;
- one deterministic block per `(base instance, structural draw)`, including the actual generator
  seed, complete included/excluded key lists and base/extended price, PV and assignment-activity
  digests; and
- each Stage-2 structural row with all existing IDs/seeds plus a reference to its deterministic
  block and its extended-data digests.

The manifest document owns deep copies of nested vectors, so mutating a returned document cannot
alter module constants, the design, records or a later manifest in the same process. Demand
activity entries must be unique, canonically ordered and exhaustive over the two expected
assignments for each deterministic block.

Validation checks the saved payload, factor isolation, cardinalities, endpoints, mapping,
seed-contract exclusions, digests and `ManifestID`; with rematerialization enabled it reconstructs
all deterministic and physical fields. Corruption tests reject a wrong mapping, extended price,
extended PV, activity assignment, final endpoint, theta- or battery-dependent actual seed,
uncertainty-specific price split, deterministic digest, support endpoint and manifest digest.
A self-consistent forged digest and a duplicated activity entry are also rejected after
rematerialization. Refreshed-digest/full-rematerialization probes additionally reject forged
planned OOS/support seeds, contradictory design demand/battery/theta metadata, a noncanonical
rolling-start vector, and duplicate or unknown seed-contract streams.

Schema v1 remains recognizable but fails the Stage-3 gate with the explicit diagnostic
`regenerate as schema v2`; it is never silently reinterpreted or upgraded.

## Final bounded artifact and reproducibility

The final standalone fixture uses one normalized base instance, `K=2`, `J=4`, two OOS
replications, battery scales `0.5/2.0`, theta values `0.1/0.4`, tree geometry `3:2:8`, and
`H=L=24`, `h=12`. These numeric levels are test fixtures only.

| Item | Final value |
|---|---|
| schema / `ManifestID` | 2 / `MF-e869f585b8a51277` |
| `T0` / required support / data end | 24 / 36 / 36 |
| structural instances | 16 |
| paired bases | 8 |
| demand assignments | 4 |
| deterministic data blocks | 2 |
| uses per deterministic block | 8 |
| planned OOS / conditional-support keys | 16 / 32 |
| independently rematerialized | 16/16, 0 blocking issues |
| JSON SHA-256 | `b2c88da7c9b492841e027898a79042032b68595207962aa9229641d17d174f6a` |
| companion CSV SHA-256 | `ee3581ec30876c923526538ef778f32be8c8634c1fde28f478a0b94aa86b352d` |

The deterministic blocks are:

| `DeterministicDataID` | actual seed | extended-price digest | extended-PV digest | activity aggregate |
|---|---:|---|---|---|
| `DD-Drahi_1-d1-796f9c26ea` | 2049452669 | `b53f764e2454e70f` | `a027867196a02519` | `4557f59cefa98ecd` |
| `DD-Drahi_1-d2-7b580323c4` | 1886240101 | `18b910a465324a97` | `a027867196a02519` | `062f4da908efd60e` |

A separate Julia process generated the same manifest with reversed controller/fairness/task order,
simulated worker 77 and four solver threads. Its JSON bytes, SHA-256, `ManifestID`, deterministic
IDs, actual seeds, assignments, Stage-2 IDs/planned seeds and extended-data digests were identical.
Preflight repeated the two-process byte gate independently and passed check `13`.

## Files changed for Stage 3

The Stage-3 delta is concentrated in these files; pre-existing Stage-1/Stage-2 edits in the dirty
tree were preserved rather than reset.

| File | Stage-3 change |
|---|---|
| `codes/oos_experiment/period_support.jl` | **new** — centralized mapping, immutable support contract, exact extension, validation and digests |
| `codes/oos_experiment/uncertainty_provider.jl` | separate endpoints, extended constructors/bounds, compatibility constructor, centralized demand cycling |
| `codes/parametersMS.jl` | legacy-preserving `repository_seed_override` |
| `codes/oos_experiment/simulator.jl` | forwards fixed profiles and the explicit structural seed without changing the default API |
| `codes/oos_experiment/structural_catalog.jl` | deterministic key/ID/actual seed, extended materialization and factor-isolation gates |
| `codes/oos_experiment/structural_manifest.jl` | schema v2 payload, deterministic blocks, exhaustive validation and rematerialization |
| `codes/oos_experiment/oos_experiment.jl` | includes the support layer before its consumers |
| `codes/oos_experiment/generate_structural_instance_manifest.jl` | Stage-3 schema-v2 generation entry point and explicit temporal fixture inputs |
| `codes/oos_experiment/validate_structural_instance_manifest.jl` | Stage-3 standalone validation/rematerialization entry point |
| `scripts/oos/generate_structural_instance_manifest.sh` | schema-v2 wrapper documentation and forwarding |
| `scripts/oos/validate_structural_instance_manifest.sh` | schema-v2 validation wrapper |
| `scripts/oos/preflight_oos_campaign.sh` | Stage-3 support/isolation/rematerialization and byte-reproducibility gates |
| `tests/oos/period_support_tests.jl` | **new** — focused test sets `P0`–`P10` |
| `tests/oos/structural_catalog_tests.jl` | Stage-2 regression reconciled with additive schema-v2 fields/gates |
| `tests/oos/runtests.jl` | includes the Stage-3 focused suite |
| `README.md`, `docs/oos_experiment.md`, `docs/oos_redesign_plan.md` | contracts, migration, decisions, scope and stage status |
| `docs/oos_stage3_completion_report.md` | **new** — this completion record |

Already-dirty Stage-1 files such as `types.jl`, `output.jl`, the active run/export/physical-gate
wrappers and `temporal.jl`, plus Stage-1/Stage-2 reports and `results_oos/`, remain in place. No
cleanup, overwrite or unrelated rewrite was performed.

## Tests and final verification

### Focused counts

| Test set | Assertions | Result |
|---|---:|---|
| Stage 1 `T1`–`T9` | 835 | PASS |
| Stage 2 `S0`–`S11` | 5,413 | PASS, 102.50 s |
| Stage 3 `P0`–`P10` | 816 | PASS |

The Stage-1 count is two above baseline only because `T7` scans each production `.jl` source and
now sees the new Stage-3 file; all Stage-1 semantics remain unchanged.

Stage-2 counts by test set were `28, 65, 21, 129, 433, 329, 54, 3403, 717, 79, 60, 95` for
`S0` through `S11`. Stage-3 counts were `17, 247, 21, 71, 8, 28, 309, 5, 29, 67, 14` for `P0`
through `P10`.

### End-to-end commands

The principal commands executed from the repository root were:

```bash
bash scripts/oos/validate_oos_experiment.sh

STRUCTURAL_MANIFEST_REMATERIALIZE=1 \
  bash scripts/oos/validate_structural_instance_manifest.sh \
  /tmp/oos_stage3_final_manifest_v2.JuPhzY/structural_instance_manifest.json

bash scripts/oos/preflight_oos_campaign.sh

bash -n scripts/oos/*.sh
git diff --check
```

Manifest generation used the standalone wrapper with explicit provisional fixture values:

```bash
INSTANCE_DRAWS_PER_CELL=2 \
LOW_BATTERY_SCALE=0.5 HIGH_BATTERY_SCALE=2.0 \
LOW_UNCERTAINTY_THETA=0.1 HIGH_UNCERTAINTY_THETA=0.4 \
J_SET=4 OOS_REPLICATIONS=2 \
EVALUATION_HORIZON=24 LOOKAHEAD_HORIZON=24 IMPLEMENTATION_STEP=12 \
STRUCTURAL_MANIFEST_PATH=<fresh-dir>/structural_instance_manifest.json \
bash scripts/oos/generate_structural_instance_manifest.sh
```

Focused Julia harnesses selected the named `T1`–`T9`, `S0`–`S11` and `P0`–`P10` blocks from the
same project/channel and helper prelude as `tests/oos/runtests.jl`; the public full-suite command
then executed all three sets together and the nested repository suite.

### Final results

| Gate | Result |
|---|---|
| full `validate_oos_experiment.sh` | exit 0, **16,043 assertions**, 293.39 s |
| parent / nested split | 15,937 / 106 assertions |
| standalone all-record schema-v2 rematerialization | 16/16, 0 blocking issues, `OK` |
| bounded preflight | exit 0, `PREFLIGHT_RESULT=READY`, 0 failed checks, 534.56 s |
| shell syntax | PASS |
| `git diff --check` | PASS |

Final preflight checks `01`, `02`, `03`, `04`, `06`, `07`, `08`, `09`, `10`, `11`, `12`, `13`
and `17` all passed. Check `08` completed a fresh bounded smoke run of all 18 default
controller/policy configurations; this was the required verification workflow, not an
experimental campaign. Check `11` validated schema-v2 support/isolation, check `12` independently
rematerialized it, and check `13` compared separate-process bytes.

Two expected advisory warnings remain:

- `7a`: the pre-existing `results_oos/` directory belongs to an older schema and was deliberately
  left untouched; a fresh directory is required for a later full campaign;
- `7b`: the working tree is dirty, so the recorded commit alone cannot reproduce uncommitted work.

The suites also print deliberate failure diagnostics while testing rejection paths (for example a
corrupted structural design or a downstream CSV missing `Resource`). Those assertions passed and
do not represent test failures. No test was skipped or left unable to run.

## Independent audit fixes

A separate read-only audit identified seven adversarial/compatibility gaps before final
validation; all were corrected and covered by regression tests:

1. deterministic blocks now require unique, canonical and exhaustive demand-assignment activity
   entries, so a duplicated regime cannot replace another after recomputing digests;
2. support construction and provider boundaries independently reject forged non-repeating
   extended prices, PV or activity;
3. manifest construction deep-copies seed-contract and nested vector state, preserving reentrancy
   after caller mutation; and
4. the legacy provider positional constructor and the default three-field template-builder result
   are preserved exactly;
5. every planned OOS/support seed is now linked to its paired structural row, checked for exact
   Cartesian coverage and recomputed from the approved Stage-2 factories;
6. design base files/IDs, fixed generator inputs, factor maps and exact temporal derivations are
   reconciled with all rows and deterministic blocks; and
7. the seed-contract table requires exactly one of each known stream and rejects duplicates and
   extras rather than permitting dictionary overwrite.

The corrected focused suites, full repository gate, standalone rematerialization and preflight all
ran after these fixes.

## Decisions, deviations and remaining ownership

- **No scientific deviation from the Stage-3 contract.** A separate `OOSPeriodDataSupport` was
  chosen instead of redefining `OOSInstanceTemplate.nu`, `pv_det` or `T`; this is the documented
  additive Stage-4 integration point and preserves the active simulator.
- **Repository-style entry points retained.** Julia entry points remain under
  `codes/oos_experiment/` with shell wrappers under `scripts/oos/`, matching the accepted Stage-2
  layout.
- **No dependency added.** Canonical serialization/digests continue to use the accepted local
  implementation.
- **Factor values remain provisional.** The battery scales, theta levels, `K` and OOS replication
  count used above are bounded fixtures, not recommendations. Stage 12 still calibrates low/high
  theta only after this now-passing isolation gate and evaluates battery levels through the full
  resolved `(s_min, s_max, s_I, f_under, f_bar)` vector, including the known legacy scaling
  discontinuity.
- **`template.delta` is unchanged.** No price, energy, power, rate or cost was rescaled.
- **Periods remain abstract.** No minutes, hours, days, dates, time zones, calendars or clock-time
  interpretation was introduced; profile names remain labels only.
- **Active science remains unchanged.** The simulator still iterates `1:template.T`, uses the
  shrinking `t:template.T` look-ahead, the current OOS and controller-specific look-ahead streams,
  one implemented period, the existing state transition/action extraction, terminal SOC at
  `template.T`, existing fairness formulations and existing period-level result schemas.
- **Parallel readiness only.** Pure extension, explicit provider RNGs, immutable/task-local state,
  worker/order-independent keys and cross-process reconstruction are complete. Catalog generation
  stays sequential because of the legacy `TaskLocalRNG`. Stage 13 still owns workers, task shards,
  restartability and deterministic merge.
- **Stage 4 and later are not started.** In particular, the active simulator does not yet consume
  a fixed moving look-ahead or the structural manifest.
