"""Primary-VPS physical compaction. No record deletion or index removal.

Run over the established privileged SSH path. Default: restore/rehearse only.
Set LPG_COMPACT_APPLY=1 only for an explicitly authorized write pause. Private
evidence and recovery dumps remain under /opt/lpg/backups/storage-compaction-*.
"""
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import time
import uuid

ROOT = Path('/opt/lpg')
BASE = ['docker', 'exec', '-i', 'lpg-db-1']
COMPOSE = ['docker', 'compose', '--project-directory', str(ROOT), '--env-file', str(ROOT / '.env'),
           '-p', 'lpg', '-f', str(ROOT / 'compose.yml'), '-f', str(ROOT / 'compose.vps.yml')]
SCHEMAS = "('public','app_private','auth','storage')"


def run(args, data=None):
    r = subprocess.run(args, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=300)
    if r.returncode:
        # DETAIL/CONTEXT can expose stored rows; retain raw stderr privately only.
        (FOLDER / 'private-error.txt').write_bytes(r.stderr)
        (FOLDER / 'private-error.txt').chmod(0o600)
        raise RuntimeError('Private command failed: ' + Path(str(args[0])).name)
    return r.stdout


def sql(q, db='postgres'):
    return run(BASE + ['psql', '-X', '-U', 'supabase_admin', '-d', db, '-qAt', '-v', 'ON_ERROR_STOP=1'], q.encode()).decode().strip()


def value(q, db='postgres'):
    return json.loads(sql(q, db))


def identifier(s):
    assert re.fullmatch(r'[a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*', s), 'Unsafe identifier'
    return s


def evidence(db='postgres'):
    tables = sql(f"select n.nspname||'.'||c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace where c.relkind='r' and n.nspname in {SCHEMAS} order by 1;", db).splitlines()
    queries = ["select '" + identifier(table) + "' name,jsonb_build_object('count',count(*),'digest',md5(coalesce(string_agg(digest,'' order by digest),''))) data from(select md5(to_jsonb(r)::text) digest from " + table + ' r)x' for table in tables]
    rows = value('select jsonb_object_agg(name,data) from (' + ' union all '.join(queries) + ') fingerprint;', db)
    indexes = value(f"select coalesce(jsonb_agg(jsonb_build_object('name',n.nspname||'.'||c.relname,'definition',pg_get_indexdef(i.indexrelid),'valid',i.indisvalid,'ready',i.indisready,'unique',i.indisunique) order by n.nspname,c.relname),'[]') from pg_index i join pg_class c on c.oid=i.indexrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname in {SCHEMAS};", db)
    constraints = value(f"select coalesce(jsonb_agg(jsonb_build_object('table',n.nspname||'.'||r.relname,'name',c.conname,'definition',pg_get_constraintdef(c.oid),'validated',c.convalidated) order by n.nspname,r.relname,c.conname),'[]') from pg_constraint c join pg_class r on r.oid=c.conrelid join pg_namespace n on n.oid=r.relnamespace where n.nspname in {SCHEMAS};", db)
    return {'tables': rows, 'indexes': indexes, 'constraints': constraints}


def sizes(db='postgres'):
    return value(f"select jsonb_agg(jsonb_build_object('table',n.nspname||'.'||c.relname,'heap',pg_table_size(c.oid),'indexes',pg_indexes_size(c.oid),'total',pg_total_relation_size(c.oid)) order by n.nspname,c.relname) from pg_class c join pg_namespace n on n.oid=c.relnamespace where c.relkind='r' and n.nspname in {SCHEMAS};", db)


def capture():
    for name, args in [('database.dump', ['pg_dump', '-U', 'supabase_admin', '-d', 'postgres', '-Fc']),
                       ('roles.sql', ['pg_dumpall', '-U', 'supabase_admin', '--roles-only'])]:
        p = FOLDER / name
        with p.open('wb') as destination:
            p.chmod(0o600)
            r = subprocess.run(BASE + args, stdout=destination, stderr=subprocess.PIPE, timeout=300)
            if r.returncode:
                raise RuntimeError('Recovery capture failed')


def save():
    p = FOLDER / 'evidence.json'
    p.write_text(json.dumps(STATE, indent=2) + '\n')
    p.chmod(0o600)


def restore_and_rehearse(before, plan):
    db = 'lpg_storage_rehearsal_' + uuid.uuid4().hex[:12]
    assert re.fullmatch(r'lpg_storage_rehearsal_[0-9a-f]{12}', db)
    tocpath = '/tmp/' + db + '.toc'
    created = False
    try:
        dump = (FOLDER / 'database.dump').read_bytes()
        toc = run(BASE + ['pg_restore', '--list'], dump).decode()
        toc = '\n'.join(line for line in toc.splitlines() if not re.search(r'\bEXTENSION(?: -)? pg_cron\b|\bSCHEMA(?: -)? cron\b| cron ', line)) + '\n'
        run(BASE + ['sh', '-c', 'umask 077; cat > "$1"', 'storage-rehearsal', tocpath], toc.encode())
        sql('create database ' + db + ' template template0;')
        created = True
        run(BASE + ['pg_restore', '-U', 'supabase_admin', '-d', db, '--use-list', tocpath,
                    '--exit-on-error', '--single-transaction'], dump)
        restored_evidence = evidence(db)
        # PostgreSQL reparses dumped expressions: three old varchar-array casts
        # become per-element text casts; four CHECK expressions get equivalent
        # parser formatting. Never relax the exact live before/after comparison.
        normalized = []
        expected_restore = json.loads(json.dumps(before))
        allowed = {'purchase_payment_once', 'purchase_movements_once', 'transit_close_once',
                   'employee_payment_kind', 'authorization_role_names',
                   'employees_business_unit_check', 'fifo_shell_value_valid'}
        def canonical(definition):
            assert not re.search(r'\b(OR|NOT)\b', definition), 'Unexpected boolean expression'
            return re.sub(r'[()\s]', '', re.sub(r'::text\[\]|::text|::character varying', '', definition))
        for key in ['indexes', 'constraints']:
            for original, restored in zip(expected_restore[key], restored_evidence[key]):
                if original != restored and original['name'].split('.')[-1] in allowed:
                    assert canonical(original['definition']) == canonical(restored['definition'])
                    original['definition'] = restored['definition']
                    normalized.append(original['name'])
        STATE['restore_parser_normalizations'] = normalized
        if restored_evidence != expected_restore:
            STATE['restore_difference'] = {key: {'expected': before[key], 'restored': restored_evidence[key]} for key in before if before[key] != restored_evidence[key]}
            save()
            raise RuntimeError('Restored fingerprints or definitions differ; private evidence retained')
        restored = {row['table']: row for row in sizes(db)}
        original = {row['table']: row for row in STATE['original_sizes']}
        plan[:] = [action for action in plan if
                   original[action['table']]['heap' if action['kind'] == 'heap' else 'indexes'] >
                   max(4 * restored[action['table']]['heap' if action['kind'] == 'heap' else 'indexes'], 1024 * 1024)]
        STATE['restored_sizes'] = list(restored.values())
        STATE['plan'] = plan; save()
        compact(plan, db)
        assert evidence(db) == restored_evidence, 'Rehearsal changed records or definitions'
        STATE['rehearsal'] = {'passed': True, 'database_bytes': int(sql('select pg_database_size(current_database());', db))}
        save()
    finally:
        if created:
            sql('drop database ' + db + ' with (force);')
        run(BASE + ['rm', '-f', '--', tocpath])


def compact(plan, db='postgres'):
    for action in plan:
        sql("set lock_timeout='10s'; set statement_timeout='120s'; " + action['sql'], db)
    sql('analyze;', db)


lock = (ROOT / 'deploy/.deployment.lock').open('a')
fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
FOLDER = ROOT / 'backups' / ('storage-compaction-' + dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ'))
FOLDER.mkdir(mode=0o700)
APPLY = os.environ.get('LPG_COMPACT_APPLY') == '1'
STATE = {'phase': 'preflight', 'apply': APPLY, 'backup_path': str(FOLDER)}
paused = False
try:
    model = json.loads(run(COMPOSE + ['config', '--format', 'json']))
    assert model['services']['api-gw']['environment']['SUPABASE_PUBLIC_URL'] == 'https://api.lpg.144.79.249.4.sslip.io'
    initial = sizes()
    assert all(i['valid'] and i['ready'] for i in evidence()['indexes']), 'Existing invalid indexes require investigation'
    # Restored compact sizes provide actual live-storage evidence, not row estimates.
    STATE['before_bytes'] = int(sql('select pg_database_size(current_database());'))
    STATE['original_sizes'] = initial
    ps = run(COMPOSE + ['ps', '--format', 'json']).decode().strip()
    services = json.loads(ps) if ps.startswith('[') else [json.loads(line) for line in ps.splitlines()]
    STATE['services'] = [x['Service'] for x in services if x['State'] == 'running' and x['Service'] != 'db']
    STATE['cron'] = value("select coalesce(jsonb_agg(jsonb_build_object('id',jobid,'active',active)),'[]') from cron.job;")
    STATE['timer_active'] = run(['systemctl', 'show', '--property=ActiveState', '--value', 'lpg-backup.timer']).decode().strip() == 'active'
    save()
    if APPLY:
        paused = True  # Set before the first mutation; finally restores original intent.
        STATE['phase'] = 'pausing'; save()
        for job in STATE['cron']:
            if job['active']:
                sql('select cron.alter_job(' + str(int(job['id'])) + ',active=>false);')
        run(['systemctl', 'stop', 'lpg-backup.timer'])
        run(COMPOSE + ['stop', '--timeout', '30', *STATE['services']])
        for _ in range(30):
            active = int(sql("select count(*) from pg_stat_activity where datname=current_database() and pid<>pg_backend_pid() and backend_type='client backend';"))
            jobs = int(sql("select count(*) from cron.job_run_details where status in ('starting','running') and end_time is null and start_time>now()-interval '1 hour';"))
            if active == 0 and jobs == 0:
                break
            time.sleep(1)
        else:
            raise RuntimeError('Other sessions or jobs did not drain; no compaction performed')
    STATE['phase'] = 'backup'; save()
    before = evidence()
    STATE['before'] = before; save()
    capture()
    # First restore with no live mutations, then select only measured oversized storage.
    # Reindexing compact clones is inexpensive and verifies every targeted command.
    plan = []
    for row in initial:
        table = identifier(row['table'])
        if row['heap'] >= 8 * 1024 * 1024:
            # The exact compact comparison is checked below before live rewriting.
            plan.append({'table': table, 'kind': 'heap', 'sql': 'vacuum (full, analyze) ' + table + ';'})
        elif row['indexes'] >= 1024 * 1024:
            plan.append({'table': table, 'kind': 'index', 'sql': 'reindex table ' + table + ';'})
    STATE['plan'] = plan; save()
    restore_and_rehearse(before, plan)
    # A complete logical restore with identical records is only ~tens of MB;
    # nevertheless require substantial measured aggregate excess before applying.
    assert STATE['before_bytes'] - STATE['rehearsal']['database_bytes'] > 100 * 1024 * 1024, 'No substantial reclaimable space'
    if APPLY:
        assert evidence() == before, 'Sources changed during write pause'
        STATE['phase'] = 'compacting'; save()
        compact(plan)
        after = evidence()
        assert after == before, 'Post-maintenance preservation gate failed'
        STATE['after'] = after
        STATE['after_sizes'] = sizes()
        STATE['after_bytes'] = int(sql('select pg_database_size(current_database());'))
        STATE['reclaimed_bytes'] = STATE['before_bytes'] - STATE['after_bytes']
    STATE['phase'] = 'passed'; save()
except Exception:
    if STATE['phase'] == 'compacting':
        try:
            STATE['recovery_required'] = evidence() != STATE['before']
        except Exception:
            STATE['recovery_required'] = True
    STATE['phase'] = 'failed'; save()
    raise
finally:
    if paused and not STATE.get('recovery_required'):
        for job in STATE['cron']:
            sql('select cron.alter_job(' + str(int(job['id'])) + ',active=>' + ('true' if job['active'] else 'false') + ');')
        if STATE['services']:
            run(COMPOSE + ['up', '-d', *STATE['services']])
        if STATE['timer_active']:
            run(['systemctl', 'start', 'lpg-backup.timer'])
        STATE['services_restored'] = True; save()
print(json.dumps({k: STATE.get(k) for k in ['phase', 'apply', 'backup_path', 'before_bytes', 'after_bytes', 'reclaimed_bytes', 'rehearsal', 'services_restored']}), flush=True)
