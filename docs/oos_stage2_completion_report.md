# OOS redesign — Stage 2 completion report

**Stage:** 2 — Structural instance catalog and seed hierarchy
**Scope authority:** `docs/oos_redesign_plan.md` §5.2–§5.4, §4.4 and §7 (Stage 2)
**Date:** 2026-08-07

## Scope

Separate structural instances from OOS replications and create a deterministic, complete,
auditable manifest for the `B × 2 × 2 × 2 × K` factorial design: typed factor labels, controlled
household demand assignments, deterministic identifiers and pairing, the complete seed-key
hierarchy, structural-instance materialization with resolved battery parameters, a canonical
manifest generated before any campaign, and validation plus reproducibility tests.

No campaign was run. The active simulator is untouched.

## Baseline before editing

- `git status`: three pre-existing untracked paths — `docs/oos_redesign_plan.md`,
  `docs/oos_stage1_completion_report.md`, `results_oos/` — plus the Stage-1 modifications. All
  preserved. No `AGENTS.md` or `CLAUDE.md` exists in the repository.
- Stage 1 present and green: all nine `T1`–`T9` testsets ran and passed.
- `bash scripts/oos/validate_oos_experiment.sh`: **exit 0**, 9 802 assertions, no `Fail` / `Error`
  / `Broken` column in any test-set summary.
- `bash scripts/oos/preflight_oos_campaign.sh`: **exit 0**, `PREFLIGHT_RESULT=READY`,
  `PREFLIGHT_FAILED_CHECKS=0`. Two advisory `WARN`s, both pre-existing: `7a` (the untracked
  `results_oos/` predates `output_schema_version`) and `7b` (uncommitted changes).
- **No pre-existing failures.**

## Repository inspection findings that shaped the design

`generateInstance` (`codes/parametersMS.jl:296`) was audited empirically, not assumed:

1. It seeds the **global** task-local RNG at line 309 via `deterministic_seed(...)` and then draws
   from it. Verified consequence: the catalog must be built **sequentially**, and all catalog
   randomness must come from explicit `MersenneTwister` objects. Documented at the materializer.
2. It randomizes `c_pv`, `d`, `d_det` **and the price matrix `nu`** (line 322).
3. `deterministic_seed` keys on `basename(inFile)`, the tree geometry, `J`, `theta`, `avg`, `dev`
   and `demand_profile`. It excludes `pv_scale` and `battery_scale`, and it ignores the file's
   directory. Measured directly:
   - same inputs → identical `nu` ✔
   - `battery_scale` 1.0 vs 2.0 → identical `nu` ✔ (this is what makes a battery pair share prices)
   - `pv_scale` 1.0 vs 1.5 → identical `nu` ✔
   - `theta` 0.2 vs 0.4 → **different `nu`** ✘ (see the open dependency below)
   - `demand_profile` `mixed` vs `morning` → **different `nu`**, which is why the repository
     `demand_profile` argument is held FIXED across the catalog and is not the structural regime.
4. `build_instance_template` reads only `id`, `J`, `T`, `delta`, `e_c`, `e_d`, `s_I`, `s_min`,
   `s_max`, `f_under`, `f_bar`, `mu`, `beta`, `nu` and `pv_det` from `InstanceM`. `inst.d`,
   `inst.d_det` and `inst.c_pv` are unused by the OOS module, but their draws still shift `nu`, so
   the pipeline is used verbatim rather than partially.
5. `scaleInstance!` scales `s_max` by `scale` and `f_under`/`f_bar` by `scale*4`, and does nothing
   at `scale == 1.0`. `s_min` and `s_I` never scale.
6. The repository has no JSON package in `Project.toml`, so the manifest needed a pinned
   dependency-free writer **and** parser.

## Files changed

| File | Change |
|---|---|
| `codes/oos_experiment/canonical_json.jl` | **new** — pinned canonical JSON writer/parser, stable digest, atomic write |
| `codes/oos_experiment/structural_catalog.jl` | **new** — factors, design config, assignments, IDs, seeds, materialization |
| `codes/oos_experiment/structural_manifest.jl` | **new** — manifest payload, `ManifestID`, standalone validator |
| `codes/oos_experiment/generate_structural_instance_manifest.jl` | **new** — generator entry point |
| `codes/oos_experiment/validate_structural_instance_manifest.jl` | **new** — validator entry point |
| `scripts/oos/generate_structural_instance_manifest.sh` | **new** — generator wrapper |
| `scripts/oos/validate_structural_instance_manifest.sh` | **new** — validator wrapper |
| `tests/oos/structural_catalog_tests.jl` | **new** — testsets `S0`–`S11` |
| `codes/oos_experiment/oos_experiment.jl` | three new includes |
| `codes/oos_experiment/temporal.jl` | integer kernels factored out; behaviour identical |
| `codes/oos_experiment/simulator.jl` | additive `household_profiles` keyword on `build_instance_template` |
| `scripts/oos/preflight_oos_campaign.sh` | new blocking checks `11`, `12`, `13` |
| `tests/oos/runtests.jl` | includes the Stage-2 test file |
| `docs/oos_experiment.md`, `README.md` | structural-catalog documentation |
| `docs/oos_redesign_plan.md` | Stage 2 roadmap status only |

Not touched: `output.jl`, `output_schema.jl`, `uncertainty_provider.jl`, `controllers.jl`,
`lookahead_tree.jl`, `physical_model.jl`, `fairness_rules.jl`, `lexicographic.jl`, `metrics.jl`,
`validation.jl`, `state.jl`, `parametersMS.jl`, `structuresMulti.jl`.

## Types and interfaces introduced

```julia
@enum BatteryLevel      LOW_BATTERY HIGH_BATTERY
@enum DemandRegime      HOMOGENEOUS HETEROGENEOUS
@enum UncertaintyLevel  LOW_UNCERTAINTY HIGH_UNCERTAINTY

OOSStructuralDesignConfig          # immutable design space, separate from OOSExperimentConfig
OOSDemandAssignment                # one resolved household composition
OOSStructuralInstanceSpec          # identity + factor levels, self-contained and rematerializable
OOSResolvedInstanceParameters      # s_min, s_max, s_I, f_under, f_bar, e_c, e_d, delta, T, id
OOSStructuralInstanceRecord        # ordinal + spec + resolved
OOSPathSeedKey                     # exactly the path/support seed inputs; cannot hold battery
StructuralManifestWrite            # generator outcome
StructuralManifestIssue / StructuralManifestReport
```

`OOSExperimentConfig` gained no field and keeps every default. `OOSStructuralDesignConfig` is a
separate type on purpose: the legacy configuration describes one instance plus a campaign's solver
and fairness settings, and overloading it would have made the two shell scripts that construct it
silently inherit a design.

## Structural factor validation

`K ≥ 1`; the base-instance set non-empty, unique after normalization, and free of derived-ID
collisions (which would also collide in `deterministic_seed`, since it keys on `basename`);
`battery_scales` and `uncertainty_thetas` supplied as complete mappings covering exactly both
levels — a missing or unknown level is an error, not a default; all numbers finite;
`0 < LOW_BATTERY < HIGH_BATTERY`; `0 ≤ LOW_UNCERTAINTY < HIGH_UNCERTAINTY`; `households ≥ 2`;
`avg_demand > 0`; `dev_demand ≥ 0`; `pv_scale > 0`; `oos_replications ≥ 1`; the in-sample geometry
positive; a non-empty repository demand profile; `factor_level_status` restricted to
`:PROVISIONAL_UNCALIBRATED`; and the Stage-1 `validate_temporal_contract` for `H`, `L`, `h`.
Structural draws are validated to lie in `1:K` both when built and when read back.

## Exact demand-assignment algorithm

`structural_demand_assignment(households, regime, assignment_seed)`, pure, versioned
`structural_demand_assignment_v1`, over `("morning", "midday", "night")`:

- `HOMOGENEOUS`: `rng = MersenneTwister(seed)`; draw one index `rand(rng, 1:3)`; assign that single
  profile to every household.
- `HETEROGENEOUS`: `base = households ÷ 3`, `remainder = households mod 3`;
  `counts = fill(base, 3)`; take a seeded Fisher–Yates permutation of the three profile labels and
  give `+1` to the first `remainder` of them; build the profile pool in canonical profile order;
  take a second seeded Fisher–Yates permutation of `1:households` and place pool slot `k` at
  household `perm[k]`.

Fisher–Yates is written out in the repository (`_seeded_permutation`) rather than delegated to
`Random.shuffle`, so the algorithm is pinned rather than resting on a Base implementation detail.
Counts always satisfy `max − min ≤ 1`; zero counts occur only below three households.
No independent per-household `mixed` draw is used anywhere, and the legacy composite labels are
not even accepted as structural profiles.

## Identifier definitions

Readable prefix + `fnv1a64_v1` digest of an explicitly ordered token list, 10 hex characters:

- `BaseInstanceID` — normalized file stem, e.g. `Drahi_1`. The repository-generated `InstanceM.id`
  (`"J_V"`) is stored separately as `repository_instance_id`; it is not an instance identifier.
- `DemandAssignmentID` — `DA-<base>-<HOM|HET>-d<draw>-<digest>`; digest over the identifier
  algorithm, experiment seed, normalized file, base ID, regime, draw and the ordered profile
  vector. Excludes battery level and scale, uncertainty level, `theta`, controller, fairness,
  replication and worker.
- `PairedBaseID` — `PB-<base>-d<draw>-<HOM|HET>-<ULO|UHI>-<digest>`; digest adds the uncertainty
  level, `theta` and the fixed primary-design tokens. Excludes battery level and battery scale.
- `StructuralInstanceID` — `SI-<base>-d<draw>-<HOM|HET>-<ULO|UHI>-<BLO|BHI>-<digest>`; digest over
  the `PairedBaseID`, battery level and battery scale.
- `ManifestID` — `MF-` + 16-hex digest of the canonical payload with `manifest_id` removed.

No identifier depends on an absolute path, timestamp, process, hostname, worker, output directory
or execution order. `Base.hash` is not used anywhere — not because it is salted (it is not) but
because it carries no cross-version stability contract, which a persisted digest requires.

## Exact seed keys

| Stream | Included | Excluded |
|---|---|---|
| `structural_assignment` | experiment seed, base instance, demand regime, structural draw | battery level, battery scale, uncertainty level, `theta`, replication, rolling start, controller, fairness, solver phase, worker, execution order |
| `structural_oos_path` | + demand assignment, uncertainty level, replication | battery level, battery scale, `theta`, rolling start, controller, fairness, solver phase, worker, execution order |
| `conditional_support` | + rolling start | battery level, battery scale, `theta`, controller, fairness, solver phase, worker, execution order |

All three use the repository's deterministic FNV-1a `oos_stream_seed` under new, distinct stream
names, so no hierarchy can consume another's numbers and no existing stream's key string changed.
`OOSPathSeedKey` has no field for a battery level, `theta`, a controller, a fairness policy, a
worker or a rolling start, so those exclusions are structural rather than merely intended.

**Deliberate choice, recorded:** the uncertainty **level label** is a seed key; its numeric `theta`
is not. This follows the Stage-2 prompt's enumeration literally and means a stage-12 recalibration
of the level values does not renumber the common random streams. `theta` *is* part of
`PairedBaseID`, so a recalibrated instance still gets a new identity. The plan's §5.4 sketch
(`g(s₀, PairedBaseID, uncertainty level, r)`) would have pulled `theta` in transitively; §5.4 is
explicitly "a suitable logical hierarchy", and every binding §4.4 exclusion is satisfied.

## Treatment of the repository generator seed

Recorded per structural instance as `repository_instance_seed`, with its own `legacy_active` entry
in the manifest seed contract naming its keys, its exclusions and exactly what it controls: the
legacy in-sample tree PV and demand, **and the price matrix `nu`** that the physical model
consumes. It is never relabelled as an experimental seed. A test pins it against the repository's
own `deterministic_seed` so the three places that derive that tuple cannot drift apart.

## Manifest schema and canonical ordering

`structural_manifest_schema_version = 1`, independent of `output_schema_version` (still `2`,
unchanged — asserted by a test). Sections: `design`, `seed_contract`, `demand_assignments`,
`structural_instances`, `planned_oos_replication_keys`, `planned_conditional_support_keys`,
`manifest_id`.

Canonical ordering, declared in the payload and enforced by the validator:
`normalized_base_instance_id`, `structural_draw`, `demand_regime`, `uncertainty_level`,
`battery_level`. Object keys are emitted in ascending byte order; base instances are sorted once at
design construction; enum values are recorded by canonical label. Nothing depends on dictionary
iteration, filesystem discovery order, controller or fairness order, worker number or task order.

The canonical payload contains no timestamp, absolute path, hostname, machine description or
git-dirty flag; those go to the explicitly noncanonical
`structural_instance_manifest_provenance.txt`. A normalized `structural_instance_manifest.csv`
companion is written for downstream convenience and is never digested.

## Manifest row counts for the bounded test

Fixture: 1 base instance, `K = 2`, `J = 3`, `R = 2`, `H = L = 24`, `h = 6` (so `N_t = 4`).

| Quantity | Expected | Actual |
|---|---|---|
| structural instances (`B×2×2×2×K`) | 16 | 16 |
| `PairedBaseID`s | 8 | 8 |
| `DemandAssignmentID`s | 4 | 4 |
| planned OOS-path keys (`8R`) | 16 | 16 |
| planned conditional-support keys (`8R·N_t`) | 64 | 64 |

## Reproducibility evidence

Generated twice from the same logical inputs into different destinations, in **separate Julia
processes**, with the controller order reversed, the fairness order reversed, `SOLVER_THREADS=4`,
a changed simulated worker identifier and a changed task-enumeration variable:

```
JSON bytes            identical (cmp)
CSV bytes             identical (cmp)
sha256(manifest.json) 69c8c1c6d4c8f5d78a6920051f0b829e14b1b42d137bff3b1294bac45cecd7ef  (both)
ManifestID            MF-a68a2d8a9483e997                                              (both)
provenance report     differs, by design — it is noncanonical
```

(that run used the `J = 5` illustrative fixture). Testset `S10` additionally spawns two Julia
subprocesses, neither of them the test process, and asserts identical bytes, identical
`ManifestID`, identical structural identifiers, identical assignment seeds, identical household
assignments and identical OOS-path and conditional-support seeds; the test process's own manifest
is then compared against both. Idempotence, conflict refusal, explicit overwrite and rejection of
a hand-edited but still-parseable file are all covered.

## Physical-parameter rematerialization

Every one of the 16 fixture instances was rematerialized and compared: `s_min`, `s_max`, `s_I`,
`f_under`, `f_bar`, `e_c`, `e_d`, `delta`, the instance horizon and the household demand models all
matched exactly. A spec rebuilt from a manifest **row** (through the JSON parser) rematerializes to
the same physics, which is what makes the manifest self-sufficient. Battery pairs were confirmed to
share `s_min`, `s_I`, `e_c`, `e_d`, `delta` and the horizon while differing in `s_max`, `f_under`
and `f_bar` exactly as `scaleInstance!` dictates (`s_max = 63·scale`, `f_under = f_bar = 4·scale·4`).
The standalone validator rematerializes from disk in a separate process and reported
`STRUCTURAL_MANIFEST_COUNT_REMATERIALIZED=16`, `STRUCTURAL_MANIFEST_BLOCKING_ISSUES=0`.

## Two findings worth the reader's attention

**1. Uncertainty levels are not price-paired.** `theta` is a key of `deterministic_seed`, so the two
uncertainty levels receive different `inst.nu`. A cost difference attributed to uncertainty
intensity therefore also contains a price difference. Battery pairs are unaffected. Stage 2 records
`repository_instance_seed` per instance so the confound is visible; removing it would mean editing
the verified repository pipeline (or adding a provider-level `theta`), which is outside this
stage's authority. **Flagged as a dependency for Stage 12 calibration and for any uncertainty-level
comparison.**

**2. Battery scaling is not self-similar.** `s_max *= scale` but `f_under, f_bar *= scale*4`, with
no scaling at all at `scale == 1.0`. Capacity and power do not move together, a scale below `0.25`
*raises* the rate limit, and a level placed exactly at `1.0` is off-curve. The generator prints a
non-blocking advisory naming the resolved rate limits, and the resolved parameters are recorded per
instance. **A Stage-12 calibration input, not something corrected here.**

## Commands executed and results

| Command | Result |
|---|---|
| Stage-1 focused tests `T1`–`T9` (inside the suite) | PASS, 833 assertions |
| Stage-2 focused tests `S0`–`S11`, isolated | PASS, 3 726 assertions |
| `bash scripts/oos/validate_oos_experiment.sh` (baseline) | **exit 0**, 9 802 assertions |
| `bash scripts/oos/validate_oos_experiment.sh` (after) | **exit 0**, 13 538 assertions |
| `bash scripts/oos/preflight_oos_campaign.sh` (baseline) | **exit 0**, `READY`, `PREFLIGHT_FAILED_CHECKS=0` |
| `bash scripts/oos/preflight_oos_campaign.sh` (after) | **exit 0**, `READY`, `PREFLIGHT_FAILED_CHECKS=0`, new checks `11`/`12`/`13` PASS |
| `generate_structural_instance_manifest.sh` (fixture) | `STRUCTURAL_MANIFEST_RESULT=OK` |
| `validate_structural_instance_manifest.sh` (fixture, rematerializing) | `STRUCTURAL_MANIFEST_VALIDATION=OK`, 16/16 rematerialized, 0 blocking issues |

The assertion delta accounts exactly: `9 802 + 3 726 + 10 = 13 538`. The `+10` is Stage-1 `T7`'s
per-file source scan (two assertions per `.jl` file under `codes/oos_experiment`) picking up the
five new module files — not a behavioural change. No `Fail`, `Error` or `Broken` column appears in
any test-set summary. The only pre-flight warnings are the two pre-existing advisories, `7a` and
`7b`; no pre-existing failure existed and none was introduced. Nothing could not be run.

Testsets added: `S0` canonical JSON and digest; `S1` factor and design validation; `S2` cardinality
and canonical ordering; `S3` homogeneous assignments; `S4` heterogeneous assignments
(`J = 2, 3, 5, 6, 7`); `S5` pairing; `S6` seed inclusions and exclusions; `S7` manifest structure,
identity and reproducibility; `S8` materialization and resolved parameters; `S9` validation and
nine classes of corruption; `S10` generation, idempotence and cross-process reproducibility;
`S11` the Stage-2 non-goal gate.

## Confirmations

- **Factor values remain provisional.** No calibrated value is proposed. The four numeric levels
  and `K` have no defaults anywhere; every manifest records
  `factor_level_status = PROVISIONAL_UNCALIBRATED`, and the validator rejects any other value.
- **The active simulator and optimization behaviour are unchanged.** `S11` pins that the legacy
  `build_instance_template(config)` path draws the same profiles from the same stream and produces
  identical metadata (the structural marker appears only on the structural path); that
  `oos_path_rng`, `lookahead_rng` (controller still included — removing it is Stage 5),
  `in_sample_rng` and `demand_profile_rng` are byte-for-byte unchanged; that the loop still covers
  `1:template.T` over a shrinking `t:template.T` look-ahead with the terminal state of charge on
  `template.T`; that the results reader was not taught to require a manifest; and that no
  simulator-side file references any catalog symbol. Stage 1's `T9` gate is retained unmodified and
  passes.
- **No clock-time assumption was introduced.** Periods stay abstract, `template.delta` is
  untouched and recorded as `instance_period_length_delta` without a unit, and the validator
  rejects any payload key containing `minute`, `hour`, `day`, `week`, `month`, `calendar`, `clock`,
  `duration` or `cycle`. This caught a real defect during development: `profile_counts` had been
  keyed by profile name, and `midday` contains "day" — the counts are now two parallel arrays with
  the labels in values.
- **Stage 3 and later were not started.** No period cycling or reindexing, no data extension, no
  scenario support, no `ScenarioSupportID`, no change to `lookahead_rng`, to the look-ahead
  horizon, to nonanticipativity, to fairness rules, to decision domains, to warm starts or to any
  CSV schema. No dependency was added to `Project.toml`; the JSON writer and parser are
  hand-written for exactly that reason.

## Deviations from the master plan

1. **Entry-point paths.** The prompt suggested `scripts/oos/generate_structural_instance_manifest.jl`.
   Following the repository's actual convention (`codes/oos_experiment/run_downstream_checks.jl`
   driven by a `scripts/oos/*.sh` wrapper), the Julia entry points live in
   `codes/oos_experiment/` and the shell wrappers in `scripts/oos/`. The prompt explicitly allowed
   paths "consistent with repository style".
2. **`theta` excluded from the seed keys** while retained in `PairedBaseID`. Rationale above; every
   binding §4.4 exclusion holds.
3. **`temporal.jl` refactored** to expose integer kernels so the structural design reuses Stage 1's
   arithmetic rather than duplicating it. No behaviour or API change; Stage 1's tests are unmodified
   and pass.
4. **A `household_profiles` keyword was added to `build_instance_template`** rather than duplicating
   the template builder. The default `nothing` reproduces the previous behaviour exactly, which is
   asserted.

## Remaining work and prerequisites for Stage 3

The manifest is a contract, not a driver: nothing consumes it yet. Stage 3 must supply exogenous
data through `required_period_support_end`, which the manifest already records per design. The two
findings above are inputs to Stage 12. Stage 5 still owns removing the controller from the
look-ahead seed, and Stage 13 owns parallelization — note that the catalog must be materialized
sequentially, because `generateInstance` reseeds the task-local RNG.
