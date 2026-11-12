#!/usr/bin/env bash
# Two disjoint halves, one solver thread per worker, one campaign coordinator.
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$TASK_ROOT"
TASK_OUTPUT="${SCENARIO_EQUITY_DIR:-$TASK_ROOT/results_models/scenario_equity}"
TASK_OUTPUT="$(realpath "$TASK_OUTPUT")"
export SCENARIO_EQUITY_DIR="$TASK_OUTPUT"
exec 8>"$TASK_OUTPUT/campaign.lock"
flock -n 8 || { echo "Another scenario equity campaign is running." >&2; exit 1; }
# Check that an earlier serial runner has released its writer lock.
flock -n "$TASK_OUTPUT/execution.lock" true || {
  echo "An earlier serial writer is still running." >&2
  exit 1
}

python3 - <<'PY'
import csv, os
from pathlib import Path
root=Path(os.environ['SCENARIO_EQUITY_DIR'])
worker=root/'worker_2'
worker.mkdir(exist_ok=True)
for name in ('config_manifest.csv','historical_expected_household_results.csv','manuscript_comparison.csv'):
    target=worker/name
    content=(root/name).read_bytes()
    if target.exists() and target.read_bytes()!=content:
        raise SystemExit(f'Worker configuration changed: {target}')
    target.write_bytes(content)
reference=worker/'reference_source'
if not reference.exists():
    reference.symlink_to(root/'reference_source', target_is_directory=True)
with (root/'execution_workers.csv').open('w',newline='') as stream:
    writer=csv.DictWriter(stream,fieldnames=['Worker','ConfigIDFirst','ConfigIDLast','ConfigCount','SolverThreads','OutputDirectory'])
    writer.writeheader()
    writer.writerows([
        dict(Worker=1,ConfigIDFirst='M001',ConfigIDLast='M040',ConfigCount=40,SolverThreads=1,OutputDirectory=str(root)),
        dict(Worker=2,ConfigIDFirst='M041',ConfigIDLast='M080',ConfigCount=40,SolverThreads=1,OutputDirectory=str(worker))])
PY

TASK_FIRST_CONFIGS="$(python3 -c 'print(",".join(f"M{i:03d}" for i in range(1,41)))')"
TASK_SECOND_CONFIGS="$(python3 -c 'print(",".join(f"M{i:03d}" for i in range(41,81)))')"
export SCENARIO_EQUITY_COORDINATED_WORKER=1
export FAIRNESS_SET=NONE,PEA,SA,LEXMMFPEA,LEXMMFSA
CONFIG_IDS="$TASK_FIRST_CONFIGS" bash scripts/models/run_scenario_equity.sh run \
  >"$TASK_OUTPUT/original_seed_execution_part_2.log" 2>&1 &
TASK_FIRST_PID=$!
SCENARIO_EQUITY_DIR="$TASK_OUTPUT/worker_2" CONFIG_IDS="$TASK_SECOND_CONFIGS" \
  bash scripts/models/run_scenario_equity.sh run \
  >"$TASK_OUTPUT/worker_2_execution.log" 2>&1 &
TASK_SECOND_PID=$!
trap 'kill -TERM "$TASK_FIRST_PID" "$TASK_SECOND_PID" 2>/dev/null || true' INT TERM
echo "Workers started: $TASK_FIRST_PID (M001-M040), $TASK_SECOND_PID (M041-M080); one CPLEX thread each."
set +e
wait "$TASK_FIRST_PID"
TASK_FIRST_STATUS=$?
wait "$TASK_SECOND_PID"
TASK_SECOND_STATUS=$?
set -e
trap - INT TERM

# Keep original source paths valid after collecting worker artifacts. A resumed
# worker can also find all completed policies through the shard-directory alias.
python3 - <<'PY'
import csv, os, shutil
from pathlib import Path
root=Path(os.environ['SCENARIO_EQUITY_DIR'])
worker=root/'worker_2'
shards=worker/'shards'
if shards.exists() and not shards.is_symlink():
    for dataset in shards.iterdir():
        for config in dataset.iterdir():
            destination=root/'shards'/dataset.name/config.name
            if destination.exists():
                raise SystemExit(f'Refusing to overwrite existing policy artifacts: {destination}')
            destination.parent.mkdir(parents=True,exist_ok=True)
            shutil.move(str(config),destination)
    shutil.rmtree(shards)
    shards.symlink_to(root/'shards',target_is_directory=True)
failures=root/'execution_failures.csv'
extra=worker/'execution_failures.csv'
if extra.exists():
    with failures.open(newline='') as stream:
        reader=csv.DictReader(stream); fields=reader.fieldnames; rows=list(reader)
    with extra.open(newline='') as stream:
        rows.extend(csv.DictReader(stream))
    unique={tuple(row.items()): row for row in rows}
    with failures.open('w',newline='') as stream:
        writer=csv.DictWriter(stream,fieldnames=fields)
        writer.writeheader();writer.writerows(unique.values())
PY
bash scripts/models/run_scenario_equity.sh merge
bash scripts/models/run_scenario_equity.sh provenance
python3 - <<'PY'
import csv, os
from pathlib import Path
root=Path(os.environ['SCENARIO_EQUITY_DIR'])
with (root/'execution_status.csv').open(newline='') as stream:
    rows=list(csv.DictReader(stream))
if len(rows)!=400 or any(row['Complete']!='true' for row in rows):
    raise SystemExit('Some target policies remain incomplete; saved solutions are retained for resume.')
PY
echo "Worker exit codes: $TASK_FIRST_STATUS, $TASK_SECOND_STATUS."
if (( TASK_FIRST_STATUS != 0 || TASK_SECOND_STATUS != 0 )); then
  exit 1
fi
