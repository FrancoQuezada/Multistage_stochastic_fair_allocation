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
contrato temporal abstracto, campaña smoke de 18 configuraciones en un directorio nuevo, lector
downstream y manifiesto estructural). Devuelve 0 solo si todo pasa:

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
EVALUATION_HORIZON=24 LOOKAHEAD_HORIZON=24 IMPLEMENTATION_STEP=1 \
EXPERIMENT_SEED=12345 \
bash scripts/oos/run_oos_experiment.sh
```

`EVALUATION_HORIZON` (`H`), `LOOKAHEAD_HORIZON` (`L`) e `IMPLEMENTATION_STEP` (`h`) se cuentan en
**períodos abstractos del modelo**: no definen minutos, horas, días ni ningún ciclo de calendario;
la duración física de un período vive solo en la instancia y `template.delta` se conserva
exactamente. Se admite cualquier `h` con `1 <= h <= min(H, L)` y no se exige que `h` divida a `H`.

`MULTISTAGE_BRANCHING` admite lista por etapa (`"2,2"`) o triplete compacto simétrico
`stages:children:periods_per_stage` (`"4:4:6"`), en el mismo orden `S:C:P` que `TREE_SET`; ver
detalle en [docs/oos_experiment.md](docs/oos_experiment.md).

Las etapas 1 a 11 del rediseño están **COMPLETE**. La etapa 3 separa explícitamente
`T0 = template.T` (horizonte de la instancia del repositorio), `H` (horizonte de evaluación), `L`
(longitud de cada futura ventana móvil),
`Tsupport = required_period_support_end(config)` y
`Tdata = max(T0, Tsupport)`. Una única función pura,
`base_period_index(t, T0) = 1 + ((t - 1) mod T0)`, gobierna la repetición: precios, referencia PV
y actividad de los perfiles ya asignados coinciden exactamente con los datos del repositorio en
`1:T0` y repiten esos mismos valores hasta `Tdata`, sin volver a muestrear ni reescalar por
`delta`. El proveedor admite llamadas directas hasta `Tsupport` con RNG explícitos y sin caché
global mutable.

La etapa 4 consume esa disponibilidad extendida. El simulador itera ahora
`rolling_iteration_starts(config)`, cada optimización cubre exactamente la ventana móvil fija
`t : t+L-1` —incluida la del último período evaluado— y el SOC terminal se impone al final de esa
ventana en lugar de quedar anclado en `template.T`. El modelo físico, la contabilidad de costos
realizados y los agregados de equidad leen sus precios del soporte extendido a través del único
accesor `rolling_price`; `Tdata` columnas también para la tabla de cuotas estáticas. `template.T`
conserva su significado propio: horizonte de la instancia del repositorio y largo del perfil base.

Dos consecuencias deliberadas: el SOC al final del horizonte de evaluación pasa a ser un
**resultado** de la política rodante (se reporta como diagnóstico, solo se exige que sea
físicamente admisible), y la igualdad estricta `PEA` deja de volverse inalcanzable por agotamiento
del horizonte, que era un artefacto de la ventana decreciente.

La etapa 5 elimina el confusor central de la comparación: en lugar de tres muestras de look-ahead
independientes hay **un solo soporte condicional** por `(réplica, inicio de iteración)`, del que
los tres métodos son vistas —el árbol completo, sus mismas hojas sin no-anticipatividad
intermedia, y la media ponderada de esas mismas hojas—. El controlador ya no entra en la semilla.
Consecuencia: `two_stage_scenarios` deja de generar escenarios (el conteo de hojas lo fija
`multistage_branching`) y el controlador determinista pasa de la media condicional analítica a la
media empírica de las hojas comunes.

La etapa 6 generaliza el prefijo conocido y el bloque comprometido a cualquier
`implementation_step` admisible: se revela `t:t+h-1` completo antes de que ningún controlador
optimice, la primera etapa del árbol es determinista y común, un solo solve entrega el bloque
ordenado de acciones, se validan e implementan en orden, y un bloque final no divisible se
compromete completo aunque solo su intersección con `1:H` se evalúe.

La etapa 7 convierte los coeficientes de `STATIC_DEMAND_SHARE` en una tabla identificada
(`ShareTableID`), resuelta una vez por instancia estructural e independiente de réplica,
controlador y política.

La etapa 8 auditó el dominio de decisión y encontró **importación y exportación simultáneas por
hogar** —hasta 318 kWh en un período, siempre bajo `SA`—: inflar el costo propio era una forma de
bajar los ahorros hasta el objetivo de equidad. Como un hogar tiene un solo punto de conexión, se
añadió exclusividad de dirección de red (un binario por hogar y nodo, uniforme para todos los
controladores y políticas). Cerrar ese canal dejó la igualdad de `SA` estructuralmente inalcanzable
—ni una banda fija de 1e5 la restaura—, así que `SA` recibió la misma banda mínima endógena que ya
tenía `PEA`: `sa_tolerance_mode=:adaptive_minimum` y `sa_fairness_abs_tol` en desuso.

El manifiesto estructural sigue sin ser consumido por el runner activo. Detalles y hoja de ruta en
`docs/oos_experiment.md` y `docs/oos_redesign_plan.md`.

Catálogo de instancias estructurales (etapa 2, **COMPLETE**) y aislamiento determinista
(etapa 3, **COMPLETE**). Una **instancia estructural** fija
las características físicas y de composición de demanda que permanecen constantes; una **réplica
OOS** es una trayectoria estocástica *dentro* de una instancia estructural fija. El diseño primario
es `B instancias base x 2 niveles de batería x 2 regímenes de demanda x 2 niveles de incertidumbre
x K sorteos`, con etiquetas tipadas `LOW_BATTERY`/`HIGH_BATTERY`,
`HOMOGENEOUS`/`HETEROGENEOUS` y `LOW_UNCERTAINTY`/`HIGH_UNCERTAINTY`:

```bash
# Generar el manifiesto canónico. Los cuatro niveles numéricos y K son OBLIGATORIOS y no tienen
# valor por defecto: los de abajo son fixtures, NO niveles de campaña (los calibra la etapa 12).
INSTANCE_DRAWS_PER_CELL=2 \
LOW_BATTERY_SCALE=0.5 HIGH_BATTERY_SCALE=2.0 \
LOW_UNCERTAINTY_THETA=0.1 HIGH_UNCERTAINTY_THETA=0.4 \
STRUCTURAL_MANIFEST_PATH=results_oos_structural/structural_instance_manifest.json \
bash scripts/oos/generate_structural_instance_manifest.sh

# Validar un manifiesto guardado de forma independiente (sin correr ninguna campaña).
bash scripts/oos/validate_structural_instance_manifest.sh \
  results_oos_structural/structural_instance_manifest.json
```

Cada `PairedBaseID` corresponde exactamente a dos instancias estructurales (una por nivel de
batería) que comparten asignación de hogares, semilla de asignación y semillas planificadas de
trayectoria y soporte. El nivel de batería sigue excluido de esas tres semillas. La etapa 2
descubrió que la ruta por defecto de `generateInstance` construye su semilla con `theta`, por lo
que bajo el contrato legacy también cambiaba la matriz determinista de precios `nu`; además,
`generateInstance` resembra el `TaskLocalRNG` de Julia y por eso el catálogo se materializa
secuencialmente.

La etapa 3 elimina ese confusor **solo en la ruta estructural OOS** mediante
`repository_seed_override`: cada bloque `(instancia base, sorteo estructural)` recibe un
`DeterministicDataID` y una semilla real independiente de batería, régimen de demanda e
incertidumbre. El bloque incluye exactamente `experiment_seed`, instancia base normalizada,
sorteo estructural, `in_sample_stages`, `in_sample_children`,
`in_sample_periods_per_stage`, hogares, `avg_demand`, `dev_demand`, `pv_scale` y el argumento
fijo `repository_demand_profile`. Excluye exactamente nivel y escala de batería, régimen de
demanda, `DemandAssignmentID`, nivel de incertidumbre, `theta`, réplica OOS, inicio rodante,
controlador, política de equidad, fase del solver, worker, reintento y orden de ejecución. Con una
instancia base y `K=2` hay 2 bloques deterministas y 16 instancias; cada bloque se comparte entre
sus ocho variantes `2 × 2 × 2`.

La llamada legacy sin override conserva exactamente la construcción y el comportamiento
anteriores, incluida su semilla contrafactual dependiente de `theta`; el manifiesto distingue
`legacy_default_repository_instance_seed` de `actual_repository_generator_seed`. El JSON
canónico usa `structural_manifest_schema_version = 2`, mientras `output_schema_version` sigue en
2. Un manifiesto v1 conserva significado histórico de etapa 2, pero el validador lo rechaza como
no listo para etapa 3 con la instrucción explícita de regenerarlo como v2.

Los valores numéricos de batería, `theta` y `K` siguen siendo
`PROVISIONAL_UNCALIBRATED`. La etapa 12 solo puede calibrar `theta` después de superar el
aislamiento determinista, y debe juzgar cada nivel de batería por el vector físico resuelto
`(s_min, s_max, s_I, f_under, f_bar)`, incluidas las discontinuidades de `scaleInstance!`, no por
`battery_scale` solamente. El manifiesto **todavía no lo consume el simulador activo**. La
ejecución multiproceso, los shards reiniciables y el merge determinista siguen reservados sin
cambios a la etapa 13. Detalles en `docs/oos_experiment.md`,
`docs/oos_stage2_completion_report.md` y `docs/oos_stage3_completion_report.md`.

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

#### Variables de entorno del experimento OOS

`scripts/oos/run_oos_campaign_parallel.sh` (la campaña paralela: `generate_structural_instance_manifest.sh`
→ N × `run_oos_task.sh` en paralelo → `merge_oos_shards.sh`) no define ningún parámetro propio:
hereda **todas** las variables de entorno del proceso que lo invoca, exactamente como si se las
pasaras a mano a cada script hijo. La tabla siguiente cubre esas variables (más las que solo
aplican al camino de una sola corrida, `run_oos_experiment.sh`, marcadas explícitamente). Los
valores **obligatorio** no tienen default: el script aborta si faltan.

**Escenarios / árbol de look-ahead**

| Variable | Predeterminado | Significado |
|---|---|---|
| `MULTISTAGE_BRANCHING` | `[2,2]` | Ramificación del árbol de look-ahead **compartido** por los tres controladores (lista por etapa `"2,2"` o triplete compacto `"stages:children:periods_per_stage"`, ej. `"4:4:6"`). Es EL parámetro real que fija el número de escenarios: `MULTISTAGE_RH` usa el árbol completo, `TWO_STAGE_RH` sus mismas hojas sin no-anticipatividad intermedia, y `DETERMINISTIC_RH` la media ponderada de esas hojas. |
| `MULTISTAGE_PERIODS_PER_STAGE` | vacío (reparto automático de `LOOKAHEAD_HORIZON`) | Períodos por etapa del árbol; incompatible con la forma compacta S:C:P de `MULTISTAGE_BRANCHING`. |
| `TWO_STAGE_SCENARIOS` | `20` | **Vestigial desde la etapa 5 del rediseño**: se valida y se guarda por trazabilidad, pero ya no genera escenarios (`common_support.jl` construye la vista two-stage a partir de las hojas del árbol de `MULTISTAGE_BRANCHING`; ver `codes/oos_experiment/output.jl:790-791`, campo `two_stage_scenarios_drives_generation=false`). Cambiarlo no tiene efecto observable en el modelo. |
| `TREE_SET` | `3:2:8` (S:C:P) | Árbol **in-sample legado** que calibra la instancia base y la tabla `STATIC_DEMAND_SHARE` (`generateInstance`); no es el árbol de look-ahead de la simulación rolling — no confundir con `MULTISTAGE_BRANCHING`. |
| `OOS_REPLICATIONS` | `20` | Número de trayectorias fuera de muestra (Monte Carlo) simuladas por configuración; es evaluación, no escenarios del recurso two-stage. |
| `INSTANCE_DRAWS_PER_CELL` | **obligatorio** | K: sorteos estructurales independientes por celda del catálogo (batería × demanda × incertidumbre); multiplica el catálogo, no es un escenario estocástico del optimizador. |

**Formulación / variables binarias**

| Variable | Predeterminado | Significado |
|---|---|---|
| `FORMULATION_ID` | **obligatorio** en `run_oos_campaign_parallel.sh`/`run_oos_experiment.sh`; `shared_battery_mode_node_level_v1` por defecto en las compuertas de validación | Identificador de la formulación de batería compartida. Único valor implementado: `shared_battery_mode_node_level_v1` (un binario de modo `v_n` por nodo del árbol, nunca por hogar). |
| `FORMULATION_VARIANT` | `aggregate_only` | `aggregate_plus_redundant_links` agrega filas de enlace redundantes por hogar reutilizando `v_n`; no crea binarias nuevas ni cambia binario-vs-continuo. |
| `GRID_DIRECTION_EXCLUSIVITY` | `1` | Batería aparte: esta es la binaria de **dirección de compra/venta de energía**. En `1` agrega `grid_import_direction[j,n]` (una por hogar y nodo) que impide importar y exportar simultáneamente en el mismo estado de información. En `0` esa familia desaparece. |
| `BATTERY_DIRECTION_EXCLUSIVITY` | `1` | Controla el binario de **modo de batería** `v_n` (carga vs. descarga). En `1` (default) `v_n` es binario `{0,1}`, como siempre. En `0` se relaja a una variable continua en `[0,1]` sobre las MISMAS dos restricciones de tasa agregada — mide el precio de la integralidad sin cambiar la estructura del modelo. Aplica uniformemente a todo controlador y política de equidad. Ver la bitácora de decisiones en `docs/oos_redesign_plan.md`. |
| `ALLOW_LEGACY_CONVERSION` | `0` | No afecta el modelo actual; solo habilita convertir artefactos legacy (warm starts con modo por hogar, pre-rediseño) a la convención nueva. |
| `REQUIRE_SHARED_BATTERY_VALIDATION` | `1` | Exige que la compuerta Fase-0 de batería compartida pase antes de correr la campaña completa (`run_oos_experiment.sh`). |
| `OOS_ACKNOWLEDGE_UNVALIDATED` | `0` | Override explícito para correr sin esa validación (resultados marcados como no publicables). |

**Horizonte rolling-horizon (contrato H, L, h)**

| Variable | Predeterminado | Significado |
|---|---|---|
| `EVALUATION_HORIZON` (`H`) | `24` | Períodos abstractos evaluados. |
| `LOOKAHEAD_HORIZON` (`L`) | `24` | Períodos abstractos que abarca cada optimización de look-ahead. |
| `IMPLEMENTATION_STEP` (`h`) | `1` | Períodos implementados por resolución rodante antes de re-optimizar; cualquier entero `1<=h<=min(H,L)`, no necesita dividir a `H`. |

**Controladores y equidad**

| Variable | Predeterminado | Significado |
|---|---|---|
| `CONTROLLER_SET` | `DETERMINISTIC_RH,TWO_STAGE_RH,MULTISTAGE_RH` | Controladores a evaluar. |
| `FAIRNESS_SET` | `NONE,STATIC_DEMAND_SHARE,PEA,SA,LEXMMFPEA,LEXMMFSA` | Reglas de equidad/asignación a evaluar. |
| `PEA_TOLERANCE_MODE` / `SA_TOLERANCE_MODE` | `adaptive_minimum` | `adaptive_minimum`, `strict` o `fixed_band` (deprecated). |
| `PEA_TOLERANCE_NUMERIC_EPS` | `1e-6` | Holgura numérica absoluta (kWh) del recovery `PEA` Fase II. |
| `FAIRNESS_ABS_TOL` / `SA_FAIRNESS_ABS_TOL` | `0.0` | Bandas económicas fijas, deprecadas; solo activas con `*_TOLERANCE_MODE=fixed_band`. |
| `LEX_EPS_ABS` | `1.0` | Épsilon absoluto de la maquinaria lexicográfica max-min (`LEXMMFPEA`/`LEXMMFSA`). |

**Instancia física (hogares, demanda, PV, batería)**

| Variable | Predeterminado | Significado |
|---|---|---|
| `INST_FOLDER` | `codes/oos_experiment/inst/inst2020` | Carpeta de instancias base candidatas. |
| `INSTANCE_FROM` / `INSTANCE_TO` | `1` / `INSTANCE_FROM` | Rango de índices (1-based) dentro del listado ordenado de `INST_FOLDER`. |
| `STRUCTURAL_BASE_INSTANCES` | vacío (usa `INST_FOLDER`) | Lista explícita de archivos de instancia, separada por comas. |
| `J_SET` | `5` | Número de hogares (solo se usa el primer valor de la lista). |
| `AVG_D_SET` / `DEV_D_SET` | `100.0` / `10.0` | Media/desviación de la demanda por hogar. |
| `THETA_SET` | `0.2` | Desviación estándar del ruido PV. |
| `DEMAND_PROFILE_SET` / `REPOSITORY_DEMAND_PROFILE` | `mixed` | Perfil de actividad de demanda por hogar. |
| `BATTERY_SCALE_SET` / `PV_SCALE_SET` | `1.0` / `1.0` | Factores de escala de batería/PV. |
| `LOW_BATTERY_SCALE` / `HIGH_BATTERY_SCALE` | **obligatorio** | Niveles de escala de batería del catálogo estructural (etapa 12 los calibra). |
| `LOW_UNCERTAINTY_THETA` / `HIGH_UNCERTAINTY_THETA` | **obligatorio** | Niveles de `theta` del catálogo estructural. |

**Solver**

| Variable | Predeterminado | Significado |
|---|---|---|
| `SOLVER_TIME_LIMIT_SEC` | `600.0` | Límite de tiempo por resolución. |
| `SOLVER_MIP_GAP` | `1e-6` | Gap relativo de MIP (CPLEX hereda `1e-4`; se declara explícito porque es del mismo orden que los efectos que el estudio estima). |
| `SOLVER_THREADS` / `OOS_SOLVER_THREADS` | `0` (general) / `1` (fijo por shard) | Hilos de CPLEX; el runner de shard lo fuerza a 1 para reproducibilidad entre procesos paralelos. |
| `USE_WARM_STARTS` | `0` | Arranques MIP (warm starts) entre resoluciones rodantes. |
| `FLOW_TOL` / `FEASIBILITY_TOL` / `INTEGRALITY_TOL` | `1e-5` / `1e-5` / `1e-6` | Tolerancias numéricas de validación de la acción implementada. |

**Reproducibilidad / trazabilidad**

| Variable | Predeterminado | Significado |
|---|---|---|
| `EXPERIMENT_SEED` | `12345` | Semilla maestra de toda la jerarquía de streams. |
| `EXPERIMENT_ID` | `oos_experiment` | Etiqueta del experimento/campaña, escrita en las salidas. |
| `PROMPT_VERSION` | `oos_receding_horizon_prompt_v1` | Versión de la especificación que produjo la corrida. |

**Orquestación de la campaña paralela**

| Variable | Predeterminado | Significado |
|---|---|---|
| `OOS_SHARDS` | `$(nproc)` | Número de procesos paralelos (shards) del fan-out. |
| `STRUCTURAL_MANIFEST_PATH` | `results_oos/campaign/structural_manifest.json` | Manifiesto estructural compartido por los tres pasos del pipeline. |
| `OOS_SHARD_ROOT` | `results_oos/campaign/shards` | Raíz donde cada shard escribe su salida parcial. |
| `OOS_MERGED_DIR` | `results_oos/campaign/merged` | Directorio de la fusión determinista final. |
| `OOS_OUTPUT_DIR` | `results_oos` | Directorio base de salida (no puede preexistir como uno de los directorios protegidos). |
| `OOS_CAMPAIGN_REVIEW` | `1` | Activa la revisión operacional de campaña tras el merge. |
| `EXPORT_REPRESENTATIVE_MODELS` | `1` | Exporta y audita un modelo LP/MPS representativo por controlador × regla de equidad. |
| `JULIA_BIN` / `JULIA_CHANNEL` | `julia` / versión fijada en `Manifest.toml` | Ejecutable/canal de Julia usado para invocar cada paso. |

Ejemplo, con `MULTISTAGE_BRANCHING` (no `TWO_STAGE_SCENARIOS`) como la perilla real del número de
escenarios:

```bash
FORMULATION_ID='shared_battery_mode_node_level_v1' \
INSTANCE_DRAWS_PER_CELL=2 LOW_BATTERY_SCALE=0.5 HIGH_BATTERY_SCALE=2.0 \
LOW_UNCERTAINTY_THETA=0.1 HIGH_UNCERTAINTY_THETA=0.4 \
OOS_REPLICATIONS=1000 EVALUATION_HORIZON=24 LOOKAHEAD_HORIZON=24 IMPLEMENTATION_STEP=1 \
MULTISTAGE_BRANCHING='4,4' GRID_DIRECTION_EXCLUSIVITY=1 BATTERY_DIRECTION_EXCLUSIVITY=1 \
OOS_SHARDS=8 \
bash scripts/oos/run_oos_campaign_parallel.sh
```

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
