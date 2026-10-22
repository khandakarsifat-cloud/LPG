"""Read-only resource sampler for the exact disposable load-test database."""
import argparse
import json
import shutil
import subprocess
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--state', type=Path, required=True)
args = parser.parse_args()
state = args.state.resolve()
assert str(state).startswith('/tmp/lpg-business-load.')
manifest = json.loads((state / 'manifest.json').read_text())
database = manifest['database']
assert database.startswith('lpg_load_') and database[9:].isalnum()
containers = ['lpg-db-1', manifest['container'], 'lpg-rest-1']
groups = {}
for container in containers:
    identity = subprocess.check_output(['docker', 'inspect', '--format', '{{.Id}}', container], text=True).strip()
    path = Path('/sys/fs/cgroup/system.slice') / ('docker-' + identity + '.scope')
    if path.exists():
        groups[container] = path
query = """select jsonb_build_object('connections',(select count(*) from pg_stat_activity where datname=current_database()),
 'active',(select count(*) from pg_stat_activity where datname=current_database() and state='active' and pid<>pg_backend_pid()),
 'waits',(select coalesce(jsonb_object_agg(event,n),'{}') from (select coalesce(wait_event_type||':'||wait_event,'CPU') event,count(*) n
 from pg_stat_activity where datname=current_database() and state='active' and pid<>pg_backend_pid() group by 1) w),
 'db',to_jsonb(d)) from pg_stat_database d where datname=current_database();"""
while not (state / 'stop-monitor').exists():
    record = {'time': time.time(), 'disk_free_bytes': shutil.disk_usage('/').free,
              'load': Path('/proc/loadavg').read_text().strip(), 'cpu': Path('/proc/stat').read_text().splitlines()[0],
              'memory': {line.split(':')[0]: int(line.split()[1]) * 1024
                         for line in Path('/proc/meminfo').read_text().splitlines()
                         if line.split(':')[0] in ['MemTotal', 'MemAvailable', 'SwapTotal', 'SwapFree']}}
    record['containers'] = {name: {
        'cpu_usec': int(dict(line.split() for line in (path / 'cpu.stat').read_text().splitlines())['usage_usec']),
        'memory': int((path / 'memory.current').read_text()),
        'events': dict(line.split() for line in (path / 'memory.events').read_text().splitlines())}
        for name, path in groups.items()}
    result = subprocess.run(['docker', 'exec', '-i', 'lpg-db-1', 'psql', '-X', '-U', 'supabase_admin',
                             '-d', database, '-qAt', '-v', 'ON_ERROR_STOP=1'], input=query,
                            text=True, capture_output=True, timeout=20)
    record['database'] = json.loads(result.stdout) if result.returncode == 0 else {'error': result.stderr[-300:]}
    print(json.dumps(record), flush=True)
    time.sleep(5)
