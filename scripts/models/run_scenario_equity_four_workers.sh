#!/usr/bin/env bash
# Balanced continuation after a saved-checkpoint handoff; four bounded workers.
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$TASK_ROOT"
TASK_OUTPUT="${SCENARIO_EQUITY_DIR:-$TASK_ROOT/results_models/scenario_equity}"
TASK_OUTPUT="$(realpath "$TASK_OUTPUT")"
export SCENARIO_EQUITY_DIR="$TASK_OUTPUT"
exec 8>"$TASK_OUTPUT/campaign.lock"
flock -n 8 || { echo "Another scenario equity campaign is running." >&2; exit 1; }
for TASK_DIR in "$TASK_OUTPUT" "$TASK_OUTPUT/worker_2" "$TASK_OUTPUT/worker_3" "$TASK_OUTPUT/worker_4"; do
  mkdir -p "$TASK_DIR"
  flock -n "$TASK_DIR/execution.lock" true || {
    echo "An earlier writer is still running: $TASK_DIR" >&2
    exit 1
  }
done

python3 - <<'PY'
import csv, os
from pathlib import Path
root=Path(os.environ['SCENARIO_EQUITY_DIR'])
ranges=[(1,1,40),(2,41,64),(3,65,72),(4,73,80)]
for index,first,last in ranges[1:]:
    worker=root/f'worker_{index}'
    worker.mkdir(exist_ok=True)
    for name in ('config_manifest.csv','historical_expected_household_results.csv','manuscript_comparison.csv'):
        target=worker/name
        content=(root/name).read_bytes()
        if target.exists() and target.read_bytes()!=content:
            raise SystemExit(f'Worker configuration changed: {target}')
        target.write_bytes(content)
    reference=worker/'reference_source'
    if not reference.exists():
        reference.symlink_to(root/'reference_source',target_is_directory=True)
plan=root/'execution_workers.csv'
history=root/'execution_workers_initial_two.csv'
if plan.exists() and not history.exists():
    history.write_bytes(plan.read_bytes())
with plan.open('w',newline='') as stream:
    fields=['Worker','ConfigIDFirst','ConfigIDLast','ConfigCount','SolverThreads','OutputDirectory']
    writer=csv.DictWriter(stream,fieldnames=fields)
    writer.writeheader()
    for index,first,last in ranges:
        writer.writerow(dict(Worker=index,ConfigIDFirst=f'M{first:03d}',ConfigIDLast=f'M{last:03d}',
            ConfigCount=last-first+1,SolverThreads=1,
            OutputDirectory=str(root if index==1 else root/f'worker_{index}')))
PY

export SCENARIO_EQUITY_COORDINATED_WORKER=1
export FAIRNESS_SET=NONE,PEA,SA,LEXMMFPEA,LEXMMFSA
TASK_PIDS=()
for TASK_INDEX in 1 2 3 4; do
  case "$TASK_INDEX" in
    1) TASK_FIRST=1; TASK_LAST=40; TASK_DIR="$TASK_OUTPUT" ;;
    2) TASK_FIRST=41; TASK_LAST=64; TASK_DIR="$TASK_OUTPUT/worker_2" ;;
    3) TASK_FIRST=65; TASK_LAST=72; TASK_DIR="$TASK_OUTPUT/worker_3" ;;
    4) TASK_FIRST=73; TASK_LAST=80; TASK_DIR="$TASK_OUTPUT/worker_4" ;;
  esac
  TASK_CONFIGS="$(python3 -c 'import sys; print(",".join(f"M{i:03d}" for i in range(int(sys.argv[1]),int(sys.argv[2])+1)))' "$TASK_FIRST" "$TASK_LAST")"
  SCENARIO_EQUITY_DIR="$TASK_DIR" CONFIG_IDS="$TASK_CONFIGS" \
    bash scripts/models/run_scenario_equity.sh run \
    >"$TASK_OUTPUT/four_worker_${TASK_INDEX}_execution.log" 2>&1 &
  TASK_PIDS+=("$!")
  echo "Worker $TASK_INDEX started: ${TASK_PIDS[-1]}, M$(printf '%03d' "$TASK_FIRST")-M$(printf '%03d' "$TASK_LAST"), one CPLEX thread."
done
trap 'kill -TERM "${TASK_PIDS[@]}" 2>/dev/null || true' INT TERM
TASK_STATUSES=()
set +e
for TASK_PID in "${TASK_PIDS[@]}"; do
  wait "$TASK_PID"
  TASK_STATUSES+=("$?")
done
set -e
trap - INT TERM

python3 - <<'PY'
import csv, os, shutil
from pathlib import Path
root=Path(os.environ['SCENARIO_EQUITY_DIR'])
for index in (2,3,4):
    worker=root/f'worker_{index}'
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
with failures.open(newline='') as stream:
    reader=csv.DictReader(stream); fields=reader.fieldnames; rows=list(reader)
for index in (2,3,4):
    extra=root/f'worker_{index}'/'execution_failures.csv'
    if extra.exists():
        with extra.open(newline='') as stream:
            rows.extend(csv.DictReader(stream))
unique={tuple(row.items()):row for row in rows}
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
echo "Worker exit codes: ${TASK_STATUSES[*]}."
for TASK_STATUS in "${TASK_STATUSES[@]}"; do
  if (( TASK_STATUS != 0 )); then exit 1; fi
done
