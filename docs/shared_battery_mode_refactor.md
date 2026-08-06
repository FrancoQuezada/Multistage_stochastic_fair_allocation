# Shared-battery operating-mode refactor

## Corrected formulation

The repository represents one battery shared by all households. Its operating mode is now
one binary value per relevant information state:

\[
v_n = 1 \text{ for charging mode},\qquad v_n = 0 \text{ for discharging mode}.
\]

All node-based formulations use the solver-visible name `battery_mode[n]` and impose

\[
\sum_j y_{j,n} \le f_{\mathrm{bar}}(1-v_n),\qquad
\sum_j z_{j,n} \le f_{\mathrm{under}}v_n.
\]

In this codebase, `y` is discharge, `z` is charge, `f_bar` is the aggregate discharge-rate
limit, and `f_under` is the aggregate charge-rate limit. Previous comments that reversed the
last two meanings were corrected. Both flow variables are declared nonnegative in every model.
Idle operation is feasible under either binary value.

The two-stage model stores recourse decisions by `(time, scenario)`, so its corresponding
shared mode is `battery_mode[t,o]`. It is not household-indexed. Multistage decisions are
stored directly by scenario-tree node, making nonanticipativity implicit: scenarios with the
same history refer to the same node variable.

## Impact map and constraint audit

The following active model builders contain the shared battery and were changed:

- `codes/multi.jl`: main multistage extensive form (`NONE`, `PEA`, `SA`, and dispatch into
  conditional/static/lexicographic policies).
- `codes/mmf_sa.jl`: persistent lexicographic savings-allocation model.
- `codes/conditional_fairness.jl`: Erdinç and conditional proportional/lexicographic full models.
- `codes/static_demand_share.jl`: static demand-share benchmark.
- `codes/heuristics_sa_restricted_exact.jl`: persistent full model used by restricted-exact
  algorithms.
- `codes/epp.jl`: deterministic/expected-value model.
- `codes/two_stage_none.jl`: two-stage stochastic and wait-and-see/VSS workflow.

The following archived but still repository-visible formulations were also made consistent:

- `archive_legacy/misc/src/multi.jl`.
- `archive_legacy/misc/src/epp.jl`.
- `archive_legacy/code/stochastic.jl`.
- `archive_legacy/code/heuristics_constructive.jl`.

For each builder, the two former aggregate rate constraints were classified as required and
modified to include the shared binary. State-of-charge equations, energy balances, terminal
conditions, efficiencies, objectives, fairness constraints, probabilities, PV data, and demand
data were classified as unrelated to the indexing correction and intentionally preserved.

The archived multistage model additionally had `2*J*V` individual constraints linked to
`x[j,n]`. They were removed. With nonnegative flows and the aggregate constraint, individual
links would be redundant because, for each household,

\[
0 \le z_{j,n} \le \sum_k z_{k,n} \le f_{\mathrm{under}}v_n
\]

and analogously

\[
0 \le y_{j,n} \le \sum_k y_{k,n} \le f_{\mathrm{bar}}(1-v_n).
\]

There are no tighter household-specific battery rate, contractual, or network limits in those
removed constraints.

## Algorithms and solution data

`SolutionM.x::Matrix` was removed and replaced by `SolutionM.battery_mode::Vector`, with one
entry per tree node. The deterministic/two-stage `Solution.x::Array{Float64,3}` was replaced by
`Solution.battery_mode::Matrix`, indexed by time and scenario. Grid direction storage `w` was
preserved because it is a separate concept.

Restricted-exact warm starts now set one mode start per node. Battery-fixing routines fix the
node-level mode together with `y` and `z`. Lexicographic restricted-exact solutions copy the
baseline node-level mode. The custom decomposed heuristic reconstructs the mode from aggregate
fixed flows and rejects simultaneous positive charge and discharge. No Benders master/subproblem,
cut, dual-extraction, callback, rolling-horizon, receding-horizon, or out-of-sample simulator
implementation exists in the repository. The files named “decomposed” implement a custom
allocation heuristic rather than a mathematical Benders/SDDP decomposition.

`shared_battery_violations` provides a common policy/simulation check. Fairness comparison
reports now include maximum simultaneous-flow, mode, and rate violations. The result and test
paths use a numerical flow tolerance of `1e-7`.

No code accesses solver variables by numerical column offset. No objective contains the mode,
so no household-multiplied mode cost needed re-derivation. There are no switching/startup or
minimum-duration constraints.

## Compatibility

The operational solution schema is intentionally changed: household-indexed `x` is no longer
accepted as current solution storage. `convert_legacy_battery_mode` is the explicit conversion
entry point for legacy arrays:

1. agreeing binary household values are retained only when compatible with aggregate flows;
2. disagreements are repaired from aggregate flows and returned in `repaired_indices`;
3. charging-only maps to `1`, discharging-only maps to `0`, and idle maps to `0`;
4. simultaneous aggregate charge and discharge is rejected;
5. invalid nonbinary legacy values are rejected.

This conversion never silently selects an arbitrary household. Old Julia-serialized `SolutionM`
or `Solution` objects have a different type layout and must be explicitly migrated; repository
baseline files serialize field snapshots rather than those mutable solution objects.

CSV experiment outputs do not serialize household-level battery modes, so no existing CSV input
schema required reinterpretation. Fairness output tables gained only aggregate violation columns.

## `B` and `b` audit

Every standalone `B`/`b` occurrence was inspected:

- `B_j^theta` and `B^theta` in `FAIRNESS_FORMALIZATION_FOR_CODEX.md` are exogenous fairness
  benchmark values, not battery variables; preserved.
- `b` in `codes/conditional_fairness.jl`, `codes/run_conditional_fairness.jl`, and
  `codes/fairness_comparison_metrics.jl` indexes conditioning-node bundles; preserved.
- `b` in `codes/parametersMS.jl` is a byte in the deterministic hash; preserved.
- `b` in validation files is the second comparison operand; preserved.
- `b` in `archive_legacy/code/structures.jl` is a constructor argument assigned to the electricity
  price matrix `nu`; preserved.
- No uppercase or lowercase solver variable named `B` or `b` represents battery mode, state of
  charge, capacity, Benders state, or a solver bound.

The battery state of charge remains `s`; the battery capacities and rates remain instance
parameters `s_min`, `s_max`, `f_under`, and `f_bar`.

## Model-size effect

For active formulations, the previous implementation had no operating-mode binary, so the
coherent correction changes `0 -> V` binaries while keeping continuous variables and linear
constraint count unchanged; the `2V` aggregate rate rows gain one mode coefficient each.

For the archived household-indexed formulation, the intended dimension reduction is
`J*V -> V` binaries. Removing the redundant household links changes the battery-mode subsystem
from `2*J*V + 2V` rate/link rows to `2V` aggregate mode rows. Continuous-variable counts are
unchanged.

## Repository inspection scope

The audit searched all tracked Julia, shell, Markdown, TOML, CSV-schema/report, and archived
source paths. All active files under `codes/`, all experiment drivers under `scripts/`, the root
documentation and package files, and all Julia formulations under `archive_legacy/code/` and
`archive_legacy/misc/src/` were inspected. Shell drivers and configuration code only pass
instance/fairness/battery-scaling parameters and contain no mode storage or solver lookups.

The PV-only target models in `codes/mmf_pea.jl` and the PV-allocation master in
`codes/heuristics_lex_restricted_exact.jl` do not contain battery flows or state and therefore do
not require a battery mode. Reporting and VSS files consume corrected solution objects but do not
construct independent household battery actions.

## Verification

`test/runtests.jl` includes:

- the old household-indexed counterexample and a throughput objective where the old formulation
  reaches `7` by charging and discharging simultaneously while the shared formulation reaches `4`;
- charging-only, discharging-only, aggregate-limit, same-household, cross-household, and idle cases;
- one binary per node, solver naming, nonnegativity, node-based information sharing, LP export,
  warm-start/fixing, solution extraction, two-stage dimensions, decomposed reconstruction, legacy
  conversion, and simulation-violation checks;
- a final source scan for obsolete solution fields and household-indexed mode declarations.

