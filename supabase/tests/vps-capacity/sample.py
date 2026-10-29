"""Read-only five-second /proc, cgroup v2 and PostgreSQL sampler; no exporters/ports.

Run through one SSH stream. Only aggregated metrics and query IDs leave the VPS.
"""
import json
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import time

QUERY = """set statement_timeout='3s';
select jsonb_build_object(
 'connections',(select count(*) from pg_stat_activity where datname=current_database()),
 'client_connections',(select count(*) from pg_stat_activity where datname=current_database() and backend_type='client backend'),
 'replication_connections',(select count(*) from pg_stat_activity where datname=current_database() and backend_type='walsender'),
 'active',(select count(*) from pg_stat_activity where datname=current_database() and backend_type='client backend' and state='active' and pid<>pg_backend_pid()),
 'blocked',(select count(*) from pg_stat_activity where datname=current_database() and backend_type='client backend' and cardinality(pg_blocking_pids(pid))>0),
 'longest_seconds',(select coalesce(max(extract(epoch from clock_timestamp()-query_start)),0) from pg_stat_activity where datname=current_database() and backend_type='client backend' and state='active' and pid<>pg_backend_pid()),
 'waits',(select coalesce(jsonb_object_agg(event,n),'{}') from (select coalesce(wait_event_type||':'||wait_event,'CPU') event,count(*) n from pg_stat_activity where datname=current_database() and backend_type='client backend' and state='active' and pid<>pg_backend_pid() group by 1) w),
 'db',to_jsonb(d),
 'queries',(select coalesce(jsonb_agg(to_jsonb(q)),'[]') from (select queryid::text,calls,total_exec_time,mean_exec_time,max_exec_time,rows,shared_blks_hit,shared_blks_read,temp_blks_read,temp_blks_written,blk_read_time,blk_write_time from pg_stat_statements(false) where dbid=(select oid from pg_database where datname=current_database()) and toplevel and rows>0 and userid in(select oid from pg_roles where rolname in('authenticated','authenticator')) order by total_exec_time desc limit 35) q)
) from pg_stat_database d where datname=current_database();"""

# Query texts include large preparation DO blocks. Materializing them on every
# poll spills to temp files; only counters are needed in the measured window.
# API role/top-level/result-row filtering excludes those preparation DO blocks
# while admitting new PostgREST fingerprints without rereading their SQL text.
SAMPLER_SHA256 = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()


def inspect_groups():
    containers = json.loads(subprocess.check_output(['docker', 'inspect'] +
        subprocess.check_output(['docker', 'ps', '--format', '{{.Names}}'], text=True).split()))
    groups = {}
    for c in containers:
        if not c['Name'].startswith('/lpg-'):
            continue
        root = Path('/sys/fs/cgroup/system.slice') / ('docker-' + c['Id'] + '.scope')
        if root.exists():
            groups[c['Name'].lstrip('/')] = root
    return groups


def record(groups):
    sample_start=time.monotonic()
    r = {'time': time.time(), 'cores': os.cpu_count(), 'disk_free_bytes': shutil.disk_usage('/opt/lpg').free,
         'sampler_sha256': SAMPLER_SHA256}
    lines = Path('/proc/stat').read_text().splitlines()
    r['cpu'] = {x.split()[0]: list(map(int, x.split()[1:])) for x in lines if x.startswith('cpu')}
    r['memory'] = {x.split(':')[0]: int(x.split()[1])*1024 for x in Path('/proc/meminfo').read_text().splitlines()
        if x.split(':')[0] in ['MemTotal', 'MemAvailable', 'SwapTotal', 'SwapFree', 'Dirty', 'Writeback']}
    r['vm'] = {x.split()[0]: int(x.split()[1]) for x in Path('/proc/vmstat').read_text().splitlines()
        if x.split()[0] in ['pswpin', 'pswpout', 'pgmajfault', 'oom_kill']}
    r['disk'] = {x.split()[2]: list(map(int, x.split()[3:])) for x in Path('/proc/diskstats').read_text().splitlines() if x.split()[2] == 'vda'}
    r['net'] = {x.split(':')[0].strip(): list(map(int, x.split(':')[1].split())) for x in Path('/proc/net/dev').read_text().splitlines() if ':' in x and x.split(':')[0].strip() == 'ens3'}
    if not r['net']:
        r['net'] = {x.split(':')[0].strip(): list(map(int, x.split(':')[1].split())) for x in Path('/proc/net/dev').read_text().splitlines() if ':' in x and x.split(':')[0].strip().startswith(('eth','en'))}
    r['pressure'] = {name: Path('/proc/pressure/'+name).read_text().strip() for name in ['cpu','memory','io']}
    r['containers'] = {}
    for name, path in groups.items():
        r['containers'][name] = {
            'cpu_usec': int(dict(x.split() for x in (path/'cpu.stat').read_text().splitlines())['usage_usec']),
            'memory': int((path/'memory.current').read_text()),
            'limit': (path/'memory.max').read_text().strip(),
            'memory_stat': {x.split()[0]: int(x.split()[1]) for x in (path/'memory.stat').read_text().splitlines() if x.split()[0] in ['anon','file','shmem','inactive_file']},
            'events': {x.split()[0]: int(x.split()[1]) for x in (path/'memory.events').read_text().splitlines()},
        }
    q = subprocess.run(['docker','exec','-i','lpg-db-1','psql','-X','-U','supabase_admin','-d','postgres','-qAt','-v','ON_ERROR_STOP=1'],
        input=QUERY, text=True, capture_output=True, timeout=5)
    r['database'] = json.loads(q.stdout) if q.returncode == 0 else {'sample_error': True}
    r['sample_elapsed_seconds']=time.monotonic()-sample_start
    return r


if __name__ == '__main__':
    Path('/tmp/lpg-capacity-sample.pid').write_text(str(os.getpid()))
    groups = inspect_groups()
    while True:
        start = time.monotonic()
        try:
            print(json.dumps(record(groups)), flush=True)
        except Exception as error:
            print(json.dumps({'time': time.time(), 'sampler_error': type(error).__name__}), flush=True)
        time.sleep(max(0.1, 5-(time.monotonic()-start)))
