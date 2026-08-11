# OOS redesign — Stage 14 report

**Stage:** 14 — Pilot, full campaign, and statistical analysis
**Scope authority:** `docs/oos_redesign_plan.md` §7 (Stage 14), §8 (paired analysis), §11 decision log
**Date:** 2026-08-09
**Status:** IN PROGRESS — freeze verified as a gate; pilot running over all design cells

---

## 1. What Stage 14 is for, and what changed

Stage 14 was specified as "how much does stochastic look-ahead save, across the structural
design". **The Stage-12 paired pilot answered the underlying question first, and negatively.**
Of 16 paired comparisons against `DETERMINISTIC_RH`, seven are significant and every one favours
the deterministic controller by +0.17 % to +0.41 % of operating cost; none favours a stochastic
controller. See `docs/oos_stage12_calibration_report.md` §5.

So the confirmatory question is no longer a magnitude. It is whether that **negative result holds
across the structural design** — both battery levels, both demand regimes, both uncertainty
levels, `K` draws — and, crucially, across the six fairness policies, where the interaction
between a distributive constraint and an information structure has not been probed at all. The
Stage-12 pilot ran `NONE` only.

This reframing must be approved before the confirmatory campaign, because it changes what the
campaign is for.

---

## 2. The freeze — a gate, not a document

Plan §7 requires the code version, manifest, calibrated levels, solver configuration, schema
versions, task granularity and merge procedure to be frozen. Every one of those is already
recorded by the producer, so the freeze is implemented as a **check** inside
`review_campaign` rather than as prose that can drift from reality.

| Frozen item | Where it is recorded | How it is verified |
|---|---|---|
| Code version | `experiment_config.json: code_commit`, `code_dirty` | **blocking** if `code_dirty` |
| Manifest and catalog | `structural_manifest.json`, `manifest_id` | `oos_tasks_from_manifest` regenerates the catalog and refuses on any identifier mismatch |
| Calibrated levels | manifest `battery_level_scales`, `uncertainty_level_thetas`, and the resolved `(s_min, s_max, s_I, f_under, f_bar)` per instance | isolation gate at manifest generation |
| Solver configuration | `experiment_config.json: solver`, `solver_settings` | **blocking** unless threads = 1 |
| Schema versions | `output_schema_version`, `pea_solve_sequence_version` | schema validator |
| Task granularity | `ParallelTaskID` = `(PairedBaseID, OOSReplicationID)` | `TR0` asserts both battery levels stay in one task |
| Merge procedure | canonical manifest order, refuse-if-incomplete, aggregates recomputed at merge | `TR3`–`TR5` |

**The one open freeze item is the code version.** The working tree carries the entire stages-4-14
redesign uncommitted, so `code_dirty = true` and the review blocks. A confirmatory campaign cannot
reference a version that does not exist in the history. Committing is the user's call; nothing
else blocks the freeze.

---

## 3. The review instrument

`codes/oos_experiment/campaign_review.jl` turns a merged dataset into the go / no-go evidence
plan §7 asks for. It is deliberately **not** the schema validator: `validate_output_directory`
asks whether the dataset is well-formed, the review asks whether the experiment it records is fit
to scale up. A dataset can be perfectly well-formed and still unfit.

It checks, and blocks on:

- **Completeness per design cell** — cells come from the manifest, not from parsing identifiers.
- **Aborted runs, and specifically an unbalanced design** — a policy that aborts in *some* cells
  and completes in others is worse than one that fails everywhere, because any comparison
  involving it is then taken over a different set of cells than the others.
- **Physical violations.**
- **Solves stopped on the time limit** — a time-limited solve reports a feasible incumbent, not
  an optimum, so the controller comparison would partly measure how far each got.
- **Fairness residuals read against each policy's own tolerance.** A lexicographic policy
  legitimately consumes its `lex_eps_abs`, so its raw residual is ~1.0 next to a physical residual
  of 1e-14 and means nothing of the sort; a non-lexicographic policy has no such allowance, and
  the same number there would be a real violation. Measured on the bounded campaign: lexicographic
  1.000000001 against a declared 1.0, everything else 7.7e-12 against a feasibility tolerance of
  1e-5.

And it reports, without blocking: recovery-band incidence per policy (warning if a band opens in
more than 95 % of periods — at that point the band has become the model), runtime and peak memory
as the sizing input, and the paired effects at the `(structural instance, replication)` unit.

The merge script runs it automatically and prints `OOS_CAMPAIGN_REVIEW_STATUS`.

---

## 4. Pilot over all design cells

Design: one base instance (`Drahi_1`), `K = 1` → **8 structural instances covering all eight
cells** of the `2 × 2 × 2` factorial, 4 paired bases, `R = 2` → 8 tasks, `H = L = 24`, `h = 1`,
branching `[4, 4]`, all 3 controllers × 6 policies = 18 configurations, `J = 5`. Executed through
the real script path — `scripts/oos/run_oos_task.sh` in eight independent processes against one
shard root, then `scripts/oos/merge_oos_shards.sh`.

### The first attempt, and the four things it caught

A first attempt at this pilot was **stopped and relaunched**, because it found defects in the very
configuration it was meant to validate. Validating a configuration nobody will run is not a
pilot. Nothing was lost: no shard had been committed.

**1. The relative MIP gap was CPLEX's inherited default, and it is of the same order as the
estimand.** Nothing set the gap, so every solve accepted `1e-4`. The mean look-ahead objective is
283 847, so that admits ~28 cost units of slack per solve and a 24-solve trajectory can absorb
several hundred — against a smallest paired controller effect of 337. A tolerance able to swallow
the quantity being measured cannot be an unstated property of the solver. It is now a declared
field, `solver_mip_gap = 1e-6` (~0.28 units per solve, three orders below the smallest effect),
recorded in `solver_settings`. In fairness to the old runs: 2291 of 2297 optimal solves already
had gap exactly 0, and the 6 that did not sat just under `1e-4`.

**2. Two solves hit the time limit.** Out of 1152, both at period 17 under `PEA`, one
`MULTISTAGE_RH` and one `TWO_STAGE_RH`, with gaps of 0.17 % and 0.07 % — hundreds of cost units.
A time-limited solve reports a feasible incumbent, not an optimum, so the controller comparison
would partly measure how far each one got. The review blocks on it; the pilot was relaunched at
1800 s.

**3. Peak memory was never measured.** `ModelStatistics.peak_memory_mb` was a declared field that
nothing ever filled, so the memory diagnostic Stage 14 requires did not exist. It is now
`Sys.maxrss()` at solve time. Being machine-dependent, it is emitted only in
`solve_provenance.csv` and stays outside the scientific digest.

**4. The two-stage model is the big one, not the multistage one.** On the same common support at
`L = 24` with branching `[4, 4]`:

| View | Look-ahead nodes | Binary variables |
|---|---:|---:|
| `DETERMINISTIC_RH` | 24 | 144 |
| `MULTISTAGE_RH` | 168 | 1 008 |
| `TWO_STAGE_RH` | **369** | **2 214** |

The multistage tree shares its intermediate stages; the two-stage view keeps 16 scenarios
unshared after the root. So the two-stage view sets the campaign's worst-case model size, which
is the opposite of the usual intuition.

Runtime from that attempt, one CPLEX thread: 1152 solves per structural instance, 920 s of solver
time, mean 0.80 s per solve. Heterogeneous-demand cells ran markedly slower than homogeneous
ones — 4 of 8 shards finished their first instance in ~21 minutes while the other 4 were still
running at 70, which matters for scheduling because a campaign's wall clock is set by its slowest
task, not its average.

_Results of the relaunched pilot pending._

### The short-horizon rehearsal, and what it caught

A first bounded rehearsal at `H = L = 4` was run through the same path and is reported here
because it caught a real admissibility condition. `PEA` aborted in **all four HOMOGENEOUS cells**
and completed in all four HETEROGENEOUS ones:

```text
La demanda comunitaria total del escenario 1 no es positiva (0.0);
la regla PEA no está definida.
```

The instance has 8 active demand periods out of 24. In the homogeneous regime every household
shares one profile, so a window lying entirely on inactive periods has zero community demand and
the proportional rule has no denominator. The refusal is correct — the rule genuinely is
undefined there — but the consequence is that **short `L` is inadmissible on this instance**,
because it silently removes `PEA` from one level of the demand factor. It does not arise at
`L = 24`, where every window spans active periods. Recorded as an admissibility condition on
`(L, instance)`, and now caught automatically by the review's unbalanced-design check.

The rehearsal also confirmed the merge machinery end to end: 8 shards from 2 real processes,
merge accepted, schema validation clean, 8448/8448 quantities reproduced by independent
recomputation, and `configuration_summary.csv` carrying 18 pooled rows rather than 18 per shard.

---

## 5. Blocked: the `h` factor of the design

The approved design has `h in {1, 4}`. **The `h > 1` arm is anticipative and is on hold.**

The plan specifies a known prefix of length `h` carrying realized values, and the code enforces
it as a hard invariant: [`controllers.jl`](../codes/oos_experiment/controllers.jl) requires every
period of the implementation block to reproduce the realization the simulator revealed, and
[`simulator.jl`](../codes/oos_experiment/simulator.jl) reveals the whole block before solving. At
`h = 4` the action for period `t` is therefore chosen knowing what happens in `t+1`, `t+2` and
`t+3`. Under the observe-then-act convention the design itself uses at `h = 1` — where the prefix
is the current, already-observed period — the information available at epoch `t` is `1..t`.

The cost evidence is uniform: `DETERMINISTIC_RH` is **cheaper at `h = 4` than at `h = 1` in all
four cells** (−479, −1228, −5126, −1955). Given the same information set, a controller that
re-optimizes every period can replicate any plan the `h`-committing controller makes, so `h = 1`
weakly dominates; observing the reverse everywhere says the information sets differ. It also
explains why `TWO_STAGE_RH` and `MULTISTAGE_RH` coincide in three of four `h = 4` cells: with a
long deterministic prefix, the branching structure beyond it barely reaches the implemented
decision.

The correction is narrow — the prefix should carry realized values only for period `t` and
forecast values for `t+1..t+h-1`, staying branch-free so the `h` actions remain nonanticipative;
the tree geometry already supports it. It is not applied here because it redefines what `h` means
in an approved design.

**`h = 1` is unaffected** and the pilot runs there.

---

## 6. Gate status

| Item | Status |
|---|---|
| Freeze recorded and machine-verified | **DONE** — blocking on `code_dirty` |
| Code version committed | **OPEN** — the redesign is uncommitted |
| Pilot over all design cells | running |
| Completeness, infeasibility, recovery, numerics, runtime, memory review | **DONE** as an instrument; results pending |
| Paired analysis at `(structural instance, OOS replication)` | **DONE** as an instrument; results pending |
| Reframed primary claim approved | **OPEN** — §1 |
| `h > 1` arm | **BLOCKED** — §5 |
| Confirmatory campaign | not started |
