# Specification for Codex: Erdinç benchmark and stage-conditional fairness

## 1. Scope

Implement two extensions of the current multistage model without changing instance generation or the scenario tree, and without introducing rolling-horizon optimization:

1. An adaptation of the fairness rules in Erdinç (2023), Eqs. (20)-(22), to the current multistage stochastic model.
2. Stage-conditional versions of the current PEA and SA fairness rules, under proportional and lexicographic max-min fairness.

Out of scope:

- rolling-horizon optimization;
- new forecasts or scenario-generation procedures;
- network-flow or power-flow constraints;
- changes to the current PEA, SA, LEXMMFPEA, and LEXMMFSA implementations.

The new models must coexist with the current models and use the same instances. The Erdinç adaptation isolates the fairness rule; it does not reproduce the paper's rolling-horizon uncertainty treatment.

## 2. Current code and variable mapping

Relevant files:

- `multi.jl`: base multistage model and current proportional PEA/SA constraints;
- `mmf_pea.jl`: current resource-only lexicographic max-min PEA target model;
- `mmf_sa.jl`: current lexicographic max-min SA model;
- `structuresMulti.jl`: scenario-tree representation;
- `parametersMS.jl`: current instance generation.

Current variables at scenario-tree node `n` and household `j`:

- `p[j,n]`: PV electricity allocated to household `j`;
- `y[j,n]`: battery discharge allocated to household `j`;
- `z[j,n]`: battery charge attributed to household `j`;
- `I[j,n]`: grid import attributed to household `j`;
- `G[j,n]`: grid export attributed to household `j`;
- `s[n]`: shared battery state of charge.

Important interpretation for the Erdinç benchmark: the original paper separately tracks direct PV-to-house, PV-to-battery, and PV-to-grid flows. The current model does not. Therefore, the adaptation below uses `p[j,n]` as the household PV allocation and `y[j,n]` as the household ESS contribution. It is an accounting-flow adaptation on the current model, not an exact physical replication of the original flow decomposition.

## 3. Common notation

Let:

- `H = {1,...,J}` be the households;
- `V` be the scenario-tree nodes;
- `Theta` be the set of complete root-to-leaf scenarios;
- `q_theta` be the probability of scenario `theta`;
- `rho_n` be the probability of reaching node `n`;
- `sigma(n)` be the stage of node `n`;
- `t(n)` be its time period.

In the current code:

```julia
q_theta = tree.rho[scenario[1]]
```

because `scenario[1]` is the leaf node.

For stage `sigma`, define the stage-entry nodes:

\[
\mathcal B_1 := \{1\},
\]

and, for `sigma >= 2`,

\[
\mathcal B_\sigma :=
\{n\in V:\sigma(n)=\sigma,\ \sigma(a(n))=\sigma-1\}.
\]

These nodes represent the information states immediately after the uncertainty associated with stage `sigma` has been revealed.

For a node `n`, define:

\[
\Theta(n):=\{\theta\in\Theta:n\in\theta\},
\qquad
q_{\theta\mid n}:=\frac{q_\theta}{\rho_n},
\quad \theta\in\Theta(n).
\]

The implementation must verify

\[
\sum_{\theta\in\Theta(n)}q_{\theta\mid n}=1
\]

within numerical tolerance.

For each complete scenario `theta`, define the cumulative quantities

\[
P_j^\theta(x):=\delta\sum_{m\in\theta}p_{j,m},
\qquad
Y_j^\theta(x):=\delta\sum_{m\in\theta}y_{j,m},
\]

\[
D_j^\theta:=\delta\sum_{m\in\theta}D_{j,m},
\qquad
C_{\mathrm{PV}}^\theta:=\delta\sum_{m\in\theta}C_m,
\qquad
D^\theta:=\sum_{k\in H}D_k^\theta.
\]

The all-grid benchmark, operational cost, and savings are

\[
B_j^\theta:=
\delta\sum_{m\in\theta}\nu_{j,t(m)}D_{j,m},
\]

\[
C_j^\theta(x):=
\delta\sum_{m\in\theta}
\left(\mu y_{j,m}+\nu_{j,t(m)}I_{j,m}-\beta G_{j,m}\right),
\]

\[
S_j^\theta(x):=B_j^\theta-C_j^\theta(x),
\qquad
B^\theta:=\sum_{k\in H}B_k^\theta,
\qquad
S^\theta(x):=\sum_{k\in H}S_k^\theta(x).
\]

For any scenario quantity `Q_j^theta`, define its conditional expectation at node `n` by

\[
\mathbb E_n[Q_j]
:=
\sum_{\theta\in\Theta(n)}q_{\theta\mid n}Q_j^\theta.
\]

All conditional rules below use full-horizon cumulative outcomes. Hence past allocations are retained in the fairness accounting.

---

# Part I. Erdinç fairness benchmark adapted to the current model

## 4. Scenario metrics

For each household `j` and scenario `theta`, define six metrics.

### 4.1 Ratio-based metrics

PV supply ratio:

\[
\operatorname{PSR}_j^\theta(x)
:=
\frac{P_j^\theta(x)}{D_j^\theta}.
\]

ESS supply ratio:

\[
\operatorname{ESR}_j^\theta(x)
:=
\frac{Y_j^\theta(x)}{D_j^\theta}.
\]

Combined PV and ESS supply ratio:

\[
\operatorname{PESR}_j^\theta(x)
:=
\frac{P_j^\theta(x)+Y_j^\theta(x)}{D_j^\theta}.
\]

The factor 100 used in the original paper is omitted because it does not affect the fairness constraints.

### 4.2 Absolute contribution metrics

PV contribution:

\[
\operatorname{PC}_j^\theta(x):=P_j^\theta(x).
\]

ESS contribution:

\[
\operatorname{EC}_j^\theta(x):=Y_j^\theta(x).
\]

Combined contribution:

\[
\operatorname{PEC}_j^\theta(x):=P_j^\theta(x)+Y_j^\theta(x).
\]

The instance must satisfy `D_j^theta > 0` for every household and scenario when a ratio-based rule is used. Otherwise, the model must stop with an explicit validation error.

## 5. Ex-ante stochastic adaptation

For one selected metric `M`, define

\[
\overline M_j(x)
:=
\sum_{\theta\in\Theta}q_\theta M_j^\theta(x).
\]

This is the expected scenario metric. Do not replace it by a ratio of expectations.

Introduce nonnegative variables

\[
N^{\min}\ge 0,
\qquad
N^{\max}\ge 0,
\]

and a parameter

\[
\kappa:=\operatorname{MMR}\ge 1.
\]

Add

\[
N^{\min}
\le
\overline M_j(x)
\le
N^{\max},
\qquad \forall j\in H,
\]

\[
N^{\max}
\le
\kappa N^{\min}.
\]

Only one of the six metrics is activated in a run, as in the original paper.

Interpretation:

- `kappa = 1` forces exact equality of the selected expected metric;
- larger `kappa` allows a controlled max-to-min range;
- `kappa = 1.2` reproduces the main fairness tolerance used in Erdinç (2023).

## 6. Required fairness labels

Add the following exact-model labels:

```text
ERDINC_PSR
ERDINC_ESR
ERDINC_PESR
ERDINC_PC
ERDINC_EC
ERDINC_PEC
```

Add keyword parameter:

```julia
fairness_mmr::Float64 = 1.2
```

All six models retain the current expected-cost objective.

## 7. Diagnostics for the Erdinç benchmark

For each run, output:

- selected metric;
- `fairness_mmr`;
- achieved minimum and maximum computed directly from the household metrics;
- `metric[j] = Mbar_j` for each household;
- achieved ratio

\[
\operatorname{MMR}_{\mathrm{achieved}}
=
\frac{\max_j\overline M_j}{\max(\min_j\overline M_j,\varepsilon)};
\]

- absolute violation of the MMR constraint.

## 8. Interpretation relative to the current fairness rules

The Erdinç rules are tolerance-band rules, not proportional or lexicographic max-min rules.

- `ERDINC_PSR` controls the max-to-min ratio of expected household PV supply ratios.
- Current `PEA` imposes an exact expected scenario-proportional entitlement.
- `ERDINC_PC` controls the max-to-min ratio of expected absolute PV allocations.
- Current `LEXMMFPEA` optimizes the worst-off expected absolute allocation lexicographically.
- `ERDINC_ESR`, `ERDINC_EC`, `ERDINC_PESR`, and `ERDINC_PEC` have no direct counterpart in the current manuscript and serve as additional simple resource-usage benchmarks.

Therefore, the comparison isolates two modeling choices:

1. fixed admissible dispersion through `MMR`;
2. exact proportional or optimized lexicographic fairness.

---

# Part II. Stage-conditional proportional fairness

## 9. Conditioning stage

The new conditional models are parameterized by one conditioning stage

\[
\sigma_c\in\{1,\ldots,\Sigma\}.
\]

Fairness is imposed separately at every stage-entry node

\[
n\in\mathcal B_{\sigma_c}.
\]

Special cases:

- `sigma_c = 1`: current ex-ante fairness;
- `2 <= sigma_c <= Sigma-1`: nontrivial conditional fairness;
- `sigma_c = Sigma`: ex-post fairness with respect to each terminal-stage history.

The first implementation must support one conditioning stage per solve. Do not impose several stages simultaneously.

## 10. Conditional proportional PEA

For each scenario, define the proportional PEA target

\[
T_{j}^{\mathrm{PEA},\theta}
:=
\frac{C_{\mathrm{PV}}^\theta}{D^\theta}D_j^\theta.
\]

For every household `j` and every conditioning node
`n in B_{sigma_c}`, impose

\[
\boxed{
\mathbb E_n[P_j]
=
\mathbb E_n[T_j^{\mathrm{PEA}}]
}
\qquad
\forall j\in H,
\quad n\in\mathcal B_{\sigma_c}.
\]

Expanded form:

\[
\sum_{\theta\in\Theta(n)}
\frac{q_\theta}{\rho_n}
P_j^\theta(x)
=
\sum_{\theta\in\Theta(n)}
\frac{q_\theta}{\rho_n}
\frac{C_{\mathrm{PV}}^\theta}{D^\theta}D_j^\theta.
\]

This constraint is linear.

Required label:

```text
CPEA
```

with keyword parameter

```julia
conditional_stage::Int
```

## 11. Conditional proportional SA

For each scenario, define the household benchmark share

\[
a_j^\theta:=\frac{B_j^\theta}{B^\theta}.
\]

The scenario-wise proportional SA target is

\[
T_j^{\mathrm{SA},\theta}(x)
:=
a_j^\theta S^\theta(x).
\]

For every household `j` and conditioning node
`n in B_{sigma_c}`, impose

\[
\boxed{
\mathbb E_n[S_j]
=
\mathbb E_n[T_j^{\mathrm{SA}}]
}
\qquad
\forall j\in H,
\quad n\in\mathcal B_{\sigma_c}.
\]

Equivalent linear form:

\[
\boxed{
\sum_{\theta\in\Theta(n)}
\frac{q_\theta}{\rho_n}
\left[
S_j^\theta(x)
-
\frac{B_j^\theta}{B^\theta}
\sum_{k\in H}S_k^\theta(x)
\right]
=0
}
\]

for every `j` and `n in B_{sigma_c}`.

This is linear because all `B_j^theta` and `B^theta` are parameters.

Required label:

```text
CSA
```

with keyword parameter

```julia
conditional_stage::Int
```

## 12. Numerical tolerance

For `CPEA` and `CSA`, support either exact equality or an absolute tolerance:

\[
-\epsilon_F
\le
\text{LHS}-\text{RHS}
\le
\epsilon_F.
\]

Use a dedicated parameter:

```julia
fairness_abs_tol::Float64
```

Do not use the global `TOL` simultaneously as denominator protection, fairness tolerance, and lexicographic tolerance.

---

# Part III. Stage-conditional lexicographic max-min fairness

## 13. Definition selected for implementation

Independently computing a lexicographic max-min optimum at every conditioning node is generally incompatible with a single precommitted extensive-form policy. It is especially problematic for SA because each continuation problem depends on the endogenous battery state inherited at that node.

The implementable exact definition is therefore a probability-weighted stage-conditional leximin criterion.

For a selected stage `sigma_c`, define one conditional outcome for every household and stage-entry node.

PEA outcome:

\[
U_{j,n}^{\mathrm{PEA}}(x)
:=
\mathbb E_n[P_j].
\]

SA outcome:

\[
U_{j,n}^{\mathrm{SA}}(x)
:=
\mathbb E_n[S_j].
\]

For each node `n`, let

\[
U_{[1],n}^R(x)
\le
\cdots
\le
U_{[J],n}^R(x)
\]

be the ordered household outcomes for resource `R` in `{PEA,SA}`.

For `k=1,...,J`, define the stage-conditional ordered welfare

\[
\Phi_k^{R,\sigma_c}(x)
:=
\sum_{n\in\mathcal B_{\sigma_c}}
\rho_n
\sum_{\ell=1}^{k}
U_{[\ell],n}^R(x).
\]

The conditional lexicographic max-min solution is obtained by sequentially maximizing

\[
\Phi_1^{R,\sigma_c},
\Phi_2^{R,\sigma_c},
\ldots,
\Phi_J^{R,\sigma_c}.
\]

This criterion maximizes the expected conditional outcome of the worst-off household at each information state, then the expected sum of the two worst outcomes, and so on.

At `sigma_c = 1`, there is one conditioning node with probability one, so this definition reduces to the current ex-ante lexicographic max-min criterion.

## 14. Direct linear formulation

For each lexicographic level `k`, conditioning node `n`, and household `j`, introduce

\[
\zeta_{k,n}\in\mathbb R,
\qquad
d_{k,j,n}\ge 0,
\]

with

\[
\zeta_{k,n}-d_{k,j,n}
\le
U_{j,n}^R(x).
\]

Then

\[
\sum_{\ell=1}^{k}U_{[\ell],n}^R(x)
=
\max
\left\{
 k\zeta_{k,n}-\sum_{j\in H}d_{k,j,n}
\right\}.
\]

At lexicographic step `k`, maximize

\[
\boxed{
\Phi_k^{R,\sigma_c}(x)
=
\sum_{n\in\mathcal B_{\sigma_c}}
\rho_n
\left(
 k\zeta_{k,n}
 -
 \sum_{j\in H}d_{k,j,n}
\right)
}
\]

while preserving every previous level:

\[
\Phi_h^{R,\sigma_c}(x)
\ge
\omega_h-\epsilon_{\mathrm{lex}},
\qquad h=1,\ldots,k-1,
\]

where `omega_h` is the optimal value obtained at step `h`.

This requires `J` lexicographic solves, not `J * |B_sigma|` solves.

## 15. Conditional max-min PEA

Required label:

```text
CLEXMMFPEA
```

### 15.1 Fairness target model

Generalize the current `mmf_pea.jl` resource-only model.

Variables:

\[
p_{j,n}\ge 0.
\]

Constraints:

\[
\sum_{j\in H}p_{j,n}=C_n,
\qquad \forall n\in V,
\]

\[
P_j^\theta(x)
\le
D_j^\theta,
\qquad \forall j\in H,\ \theta\in\Theta.
\]

Define

\[
U_{j,n}^{\mathrm{PEA}}(x)
=
\sum_{\theta\in\Theta(n)}
\frac{q_\theta}{\rho_n}P_j^\theta(x),
\qquad n\in\mathcal B_{\sigma_c}.
\]

Run the `J` sequential lexicographic solves and store the optimal levels

\[
\omega_1^{\mathrm{PEA}},\ldots,
\omega_J^{\mathrm{PEA}}.
\]

### 15.2 Final cost-minimization model

In the full operational model, add the same scenario-wise demand caps, recreate the conditional outcome and order-statistic expressions, and impose

\[
\Phi_k^{\mathrm{PEA},\sigma_c}(x)
\ge
\omega_k^{\mathrm{PEA}}-
\epsilon_{\mathrm{lex}},
\qquad k=1,\ldots,J.
\]

Then minimize the current expected community cost.

Do not fix one arbitrary household target vector if the lexicographic levels admit several equivalent allocations. Preserve the lexicographic levels and use expected cost as the final tie-breaker.

## 16. Conditional max-min SA

Required label:

```text
CLEXMMFSA
```

Build the full operational model, retain the same SA feasibility restrictions currently used in `mmf_sa.jl`, define

\[
U_{j,n}^{\mathrm{SA}}(x)
=
\sum_{\theta\in\Theta(n)}
\frac{q_\theta}{\rho_n}S_j^\theta(x),
\qquad n\in\mathcal B_{\sigma_c},
\]

and solve the `J` lexicographic levels using the formulation in Section 13.

After all levels have been fixed, perform one final solve:

\[
\min \sum_{j\in H}\operatorname{cost}_j(x)
\]

subject to the base model and

\[
\Phi_k^{\mathrm{SA},\sigma_c}(x)
\ge
\omega_k^{\mathrm{SA}}-
\epsilon_{\mathrm{lex}},
\qquad k=1,\ldots,J.
\]

This final solve provides the minimum-cost solution within the conditionally leximin-optimal set.

---

# Part IV. Implementation requirements

## 17. New helper functions

Create a new source file, preferably

```text
conditional_fairness.jl
```

with at least:

```julia
stage_entry_nodes(tree::Tree, stage::Int)::Vector{Int}
scenario_probabilities(tree::Tree)::Vector{Float64}
scenarios_through_node(tree::Tree, n::Int)::Vector{Int}
conditional_scenario_probabilities(tree::Tree, n::Int)::Vector{Pair{Int,Float64}}
validate_conditional_stage(tree::Tree, stage::Int)
validate_positive_scenario_denominators(inst::InstanceM)
```

Precompute the scenario lists and conditional probabilities once per instance. Do not rebuild them inside each household constraint.

## 18. New model-building functions

Recommended API:

```julia
add_erdinc_fairness!(model, inst, refs, metric;
    fairness_mmr=1.2)

add_conditional_proportional_pea!(model, inst, refs;
    conditional_stage,
    fairness_abs_tol=0.0)

add_conditional_proportional_sa!(model, inst, refs;
    conditional_stage,
    fairness_abs_tol=0.0)

conditional_lex_pea_levels(inst;
    conditional_stage,
    lex_eps_abs)

solve_conditional_lex_pea(inst;
    conditional_stage,
    lex_eps_abs)

solve_conditional_lex_sa(inst;
    conditional_stage,
    lex_eps_abs)
```

`refs` should expose the current JuMP variables and node-cost expressions, following the tuple returned by `_build_full_multistage_model` in `heuristics_sa_restricted_exact.jl`.

## 19. Integration into `solveMulti`

Extend `solveMulti` without changing existing calls:

```julia
function solveMulti(
    inst::InstanceM,
    fairness::String,
    lambdaS=zeros(10,10),
    EEV=false;
    sa_fairness_abs_tol::Float64=TOL,
    fairness_abs_tol::Float64=0.0,
    fairness_mmr::Float64=1.2,
    conditional_stage::Union{Nothing,Int}=nothing,
    lex_eps_abs::Float64=TOL,
)
```

New fairness dispatch:

```text
ERDINC_PSR
ERDINC_ESR
ERDINC_PESR
ERDINC_PC
ERDINC_EC
ERDINC_PEC
CPEA
CSA
CLEXMMFPEA
CLEXMMFSA
```

For every conditional label, `conditional_stage` is mandatory.

## 20. Required diagnostics

For `CPEA` and `CSA`, output for every pair `(household, conditioning node)`:

- conditional actual value;
- conditional target value;
- signed gap;
- absolute gap.

For `CLEXMMFPEA` and `CLEXMMFSA`, output:

- conditioning stage;
- stage-entry node probabilities;
- conditional household outcomes `U[j,n]`;
- optimal lexicographic levels `omega[k]`;
- achieved levels after the final cost-minimization solve;
- maximum lexicographic-level violation.

For all new models, retain the current cost, scenario-cost, PV allocation, and runtime outputs.

## 21. Acceptance tests

### 21.1 Probability tests

For every stage-entry node `n`:

```text
sum(q_theta / rho_n for theta containing n) = 1
```

within `1e-8`.

### 21.2 Root equivalence for proportional rules

With `conditional_stage = 1`:

- `CPEA` must reproduce the current PEA fairness equations;
- `CSA` must reproduce the current SA fairness equations.

The resulting objective values and household fairness gaps must agree within the configured fairness tolerance.

### 21.3 Root equivalence for max-min rules

With `conditional_stage = 1`:

- `CLEXMMFPEA` must attain the same lexicographic fairness levels as the current `LEXMMFPEA` target model;
- `CLEXMMFSA` must attain the same lexicographic fairness levels as the current `LEXMMFSA` model.

Exact node allocations need not coincide when several lexicographically equivalent solutions exist.

### 21.4 Terminal-stage interpretation

With `conditional_stage = Sigma`, `CPEA` and `CSA` must satisfy their proportional equations separately for every terminal-stage history.

### 21.5 Erdinç MMR test

For each Erdinç metric:

```text
max(metric[j]) <= fairness_mmr * min(metric[j]) + tolerance
```

when the model is feasible.

For `fairness_mmr = 1`, all household metric values must be equal within tolerance.

### 21.6 Backward compatibility

The following existing labels must produce unchanged results:

```text
NONE
PEA
SA
LEXMMFPEA
LEXMMFSA
```

## 22. First validation instance

Use a small existing instance with

```text
NBstage = 3
childs = 2
periods = 8
J = 5
```

and test:

```text
conditional_stage = 1, 2, 3
```

before running the current larger configurations.

## 23. Source reference

F. G. Erdinç, "Rolling horizon optimization based real-time energy management of a residential neighborhood considering PV and ESS usage fairness," Applied Energy 344 (2023), 121275. The benchmark above adapts the paper's PV/ESS metrics in Eqs. (20.a)-(20.f) and its min-max ratio constraints in Eqs. (21.a)-(22), while deliberately excluding its rolling-horizon procedure.
