# Multistage Energy Sharing

Proyecto reorganizado en modo seguro para mantener solo:

- modelos exactos
- heurísticas `restricted-exact`
- análisis de sensibilidad

Todo lo legacy quedó movido a `archive_legacy/`. No se borró nada.

## Estructura

```text
.
├── README.md
├── codes/
│   ├── multi.jl
│   ├── parametersMS.jl
│   ├── structuresMulti.jl
│   ├── epp.jl
│   ├── mmf_pea.jl
│   ├── mmf_sa.jl
│   ├── heuristics_sa_restricted_exact.jl
│   ├── heuristics_lex_restricted_exact.jl
│   ├── run_restricted_exact.jl
│   ├── run_lex_restricted_exact.jl
│   └── inst/
├── scripts/
│   ├── common.sh
│   ├── models/
│   ├── heuristics/
│   └── sensitivity/
├── results_models/
├── results_heuristics/
├── results_sensitivity/
└── archive_legacy/
```

## Qué quedó activo

### Modelos exactos

- `PEA`
- `SA`
- `LEXMMFPEA`
- `LEXMMFSA`
- Reglas Erdinç: `ERDINC_PSR`, `ERDINC_ESR`, `ERDINC_PESR`, `ERDINC_PC`, `ERDINC_EC`, `ERDINC_PEC`
- Proporcionales condicionales: `CPEA`, `CSA`
- Lexicográficos condicionales: `CLEXMMFPEA`, `CLEXMMFSA`
- Benchmark estático no condicional: `STATIC_DEMAND_SHARE`

Scripts en `scripts/models/`.

### Heurísticas `restricted-exact`

- `PEA restricted-exact`
- `SA restricted-exact`
- `LEXMMFPEA restricted-exact`
- `LEXMMFSA restricted-exact`

Scripts en `scripts/heuristics/`.

### Sensibilidad

- battery scaling
- PV scaling
- demand profile

Scripts en `scripts/sensitivity/`.

## Resultados

Los outputs por defecto quedan organizados así:

- modelos exactos: `results_models/`
- heurísticas `restricted-exact`: `results_heuristics/`
- sensibilidad: `results_sensitivity/`

## Uso

### 1. Modelos exactos

Motor genérico:

```bash
bash scripts/models/script.sh
```

Requiere definir `FAIRNESS_SET`. Ejemplo:

```bash
FAIRNESS_SET='PEA' \
INSTANCE_FROM=1 INSTANCE_TO=10 \
TREE_SET='6:4:4' \
J_SET='5,10' \
THETA_SET='0.2,0.6' \
AVG_D_SET='100.0' \
DEV_D_SET='10.0,20.0' \
bash scripts/models/script.sh
```

Wrappers preparados:

```bash
bash scripts/models/script_OPTIMAL_MATCH_PEA_S6_C4_P4.sh
bash scripts/models/script_OPTIMAL_MATCH_SA_S6_C4_P4.sh
bash scripts/models/script_OPTIMAL_MATCH_LEXMMFPEA_S6_C4_P4.sh
bash scripts/models/script_OPTIMAL_MATCH_LEXMMFSA_S6_C4_P4.sh
bash scripts/models/script_OPTIMAL_MATCH_LEX_S6_C4_P4.sh
```

Nuevas políticas sobre la instancia pequeña de validación (`S=3`, `C=2`, `P=8`, `J=5`):

```bash
FAIRNESS_SET=CPEA CONDITIONAL_STAGE=2 \
bash scripts/models/run_conditional_fairness.sh
```

Todas las políticas nuevas:

```bash
bash scripts/models/run_conditional_fairness.sh
```

El runner escribe un resumen comparable con los modelos existentes, un CSV por hogar y un CSV largo de diagnósticos condicionales. Se configura con `CONDITIONAL_STAGE`, `FAIRNESS_MMR`, `FAIRNESS_ABS_TOL` y `LEX_EPS_ABS`, además de `FAIRNESS_SET` y las variables usuales de instancia.

Validación automatizada (probabilidades, equivalencias en la raíz, restricciones por nodo y regresión de modelos históricos):

```bash
bash scripts/models/validate_conditional_fairness.sh
```

Smoke test y regresión del benchmark `STATIC_DEMAND_SHARE`:

```bash
bash scripts/models/validate_static_demand_share.sh
```

### 2. Heurísticas `restricted-exact`

Wrappers preparados:

```bash
bash scripts/heuristics/script_PEA_RESTRICTED_EXACT_S6_C4_P4.sh
bash scripts/heuristics/script_SA_RESTRICTED_EXACT_S6_C4_P4.sh
bash scripts/heuristics/script_LEXMMFPEA_RESTRICTED_EXACT_S6_C4_P4.sh
bash scripts/heuristics/script_LEXMMFSA_RESTRICTED_EXACT_S6_C4_P4.sh
```

Wrappers agregados:

```bash
bash scripts/heuristics/script_RESTRICTED_EXACT_S6_C4_P4.sh
bash scripts/heuristics/script_LEX_RESTRICTED_EXACT_S6_C4_P4.sh
```

### 3. Sensibilidad

Battery:

```bash
bash scripts/sensitivity/script_SENSITIVITY_BATTERY_S6_C4_P4.sh
```

PV:

```bash
bash scripts/sensitivity/script_SENSITIVITY_PV_S6_C4_P4.sh
```

Demand profile:

```bash
bash scripts/sensitivity/script_SENSITIVITY_DEMAND_PROFILE_S6_C4_P4.sh
```

Versiones separadas por fairness también quedaron en `scripts/sensitivity/`.

### 4. Merge de sensibilidad

```bash
bash scripts/sensitivity/merge_sensitivity_battery_reports.sh
bash scripts/sensitivity/merge_sensitivity_pv_reports.sh
bash scripts/sensitivity/merge_sensitivity_demand_profile_reports.sh
```

### 5. Corridas paralelas de sensibilidad

```bash
bash scripts/sensitivity/run_parallel_sensitivity_battery_fairness.sh
bash scripts/sensitivity/run_parallel_sensitivity_pv_fairness.sh
bash scripts/sensitivity/run_parallel_sensitivity_demand_profile_fairness.sh
```

### 6. Experimento fuera de muestra (receding horizon)

Módulo aditivo que compara reglas de asignación/equidad bajo tres enfoques de decisión sobre las
mismas trayectorias fuera de muestra: `DETERMINISTIC_RH`, `TWO_STAGE_RH` y `MULTISTAGE_RH`,
cruzados con `NONE`, `STATIC_DEMAND_SHARE`, `PEA`, `SA`, `LEXMMFPEA` y `LEXMMFSA` (18
configuraciones). Vive en `codes/oos_experiment/`, `scripts/oos/`, `results_oos/` y `tests/oos/`,
y no altera los flujos de modelos exactos, heurísticas, sensibilidad ni validación.

Verificación previa completa (entorno, ambas suites, ambas compuertas, matriz por defecto,
campaña smoke de 18 configuraciones en un directorio nuevo y lector downstream). Devuelve 0
solo si todo pasa:

```bash
bash scripts/oos/preflight_oos_campaign.sh
```

Compuertas individuales:

```bash
FORMULATION_ID='shared_battery_mode_node_level_v1' \
bash scripts/oos/validate_shared_battery_formulation.sh

FORMULATION_ID='shared_battery_mode_node_level_v1' \
bash scripts/oos/export_representative_models.sh

bash scripts/oos/validate_oos_experiment.sh
```

Campaña completa:

```bash
FORMULATION_ID='shared_battery_mode_node_level_v1' \
OOS_REPLICATIONS=1000 \
CONTROLLER_SET='DETERMINISTIC_RH,TWO_STAGE_RH,MULTISTAGE_RH' \
FAIRNESS_SET='NONE,STATIC_DEMAND_SHARE,PEA,SA,LEXMMFPEA,LEXMMFSA' \
TWO_STAGE_SCENARIOS=100 MULTISTAGE_BRANCHING='4,4' \
EXPERIMENT_SEED=12345 \
bash scripts/oos/run_oos_experiment.sh
```

Los resultados van solo a `results_oos/` (nunca a `results_models/` y similares) y cada fila lleva
`formulation_id`, de modo que resultados de formulaciones distintas nunca se mezclan sin
etiqueta. El diseño, las desviaciones documentadas, la revisión de escalamiento de parámetros y
una propiedad importante de `PEA` con igualdad estricta en horizonte deslizante están en
`docs/oos_experiment.md`.

El único lector sancionado de `results_oos/` es
`codes/oos_experiment/run_downstream_checks.jl` (esquema, recomputación independiente de las
tolerancias PEA, secuencias de resolución, recurso y separación NONE/STATIC_DEMAND_SHARE).
Cualquier análisis nuevo debe seguir sus convenciones: etiquetas semánticas de resolución en
lugar de enteros de fase, columna `Resource` explícita y filtrado por `CompletionStatus`.

## Variables de entorno útiles

Comunes a casi todos los scripts:

- `INST_FOLDER`
- `INSTANCE_FROM`
- `INSTANCE_TO`
- `TREE_SET`
- `J_SET`
- `THETA_SET`
- `AVG_D_SET`
- `DEV_D_SET`
- `DEMAND_PROFILE_SET`
- `BATTERY_SCALE_SET`
- `PV_SCALE_SET`
- `OUT_CSV`
- `OUT_CSV_HOUSE`

Adicionales:

- modelos exactos: `FAIRNESS_SET`, `SA_FAIRNESS_ABS_TOL`
- heurísticas restringidas: `OUT_CSV_DIAG`, `OUT_CSV_DIAG_HOUSE`

## Notas de implementación

- Los scripts usan rutas absolutas derivadas desde `scripts/common.sh`.
- El código activo vive en `codes/`, y los scripts siempre ejecutan desde ahí.
- La familia principal de aproximación es ahora solo la familia `restricted-exact`.
- La vieja heurística constructiva quedó archivada en `archive_legacy/`.
- La batería comunitaria usa un único `battery_mode` por nodo del árbol: carga y descarga
  agregadas no pueden ser positivas simultáneamente. El impacto y la compatibilidad están
  documentados en `docs/shared_battery_mode_refactor.md`.
- El experimento fuera de muestra es un módulo paralelo y aditivo con un único constructor físico
  verificado y capas separadas de controlador y de equidad: `docs/oos_experiment.md`.
- El `Manifest.toml` está resuelto para una versión de Julia concreta; los scripts de
  `scripts/oos/` la pasan automáticamente (`JULIA_CHANNEL` la sobreescribe).

## Archivo legacy

Todo lo que ya no forma parte del flujo principal quedó guardado en:

```text
archive_legacy/
```

Eso incluye:

- scripts antiguos
- código antiguo
- outputs viejos
- análisis auxiliares

## Validación realizada

- sintaxis shell validada para todos los scripts activos con `bash -n`
- la reorganización preserva rutas consistentes `scripts -> codes -> results`

La validación completa ejecutando Julia desde este entorno quedó limitada por el launcher `juliaup` del sandbox, no por la estructura del proyecto.
