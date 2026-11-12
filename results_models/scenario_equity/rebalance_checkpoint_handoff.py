"""Stop campaign workers only after their current policy solution is saved."""
import hashlib
import os
from pathlib import Path
import signal
import time
from datetime import datetime

root = Path(__file__).resolve().parent
workers = {
    31272: (root, root / 'original_seed_execution_part_2.log'),
    31273: (root / 'worker_2', root / 'worker_2_execution.log'),
}
record = root / 'rebalance_checkpoint_handoff.txt'
with record.open('w') as stream:
    stream.write('Checkpoint-preserving handoff to four disjoint single-thread workers.\n')
    stream.flush()
    while workers:
        for pid, (output, log) in list(workers.items()):
            runs = [line for line in log.read_text().splitlines() if line.startswith('RUN ')]
            if not runs:
                continue
            config, policy = runs[-1].split()[1:3]
            checkpoint = output / 'shards/manuscript_design_rerun' / config / policy / 'solution.bin'
            if not checkpoint.is_file():
                continue
            try:
                os.kill(pid, signal.SIGSTOP)
            except ProcessLookupError:
                del workers[pid]
                continue
            current = [line for line in log.read_text().splitlines() if line.startswith('RUN ')][-1]
            if current != runs[-1]:
                os.kill(pid, signal.SIGCONT)
                continue
            digest = hashlib.sha256(checkpoint.read_bytes()).hexdigest()
            stream.write(f'{datetime.now().isoformat()} PID={pid} {current} saved={checkpoint} SHA256={digest}\n')
            stream.flush()
            os.kill(pid, signal.SIGTERM)
            os.kill(pid, signal.SIGCONT)
            del workers[pid]
        time.sleep(0.05)
