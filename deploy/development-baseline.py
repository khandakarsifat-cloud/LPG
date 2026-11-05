"""Explicit development business reset with a quiesced, restored full backup.

Invoked by development-baseline.mjs over trusted primary-VPS SSH. Never part of
application RPCs. It preserves Auth/configuration and the original administrator.
"""
import datetime as dt
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import uuid

sys.path.insert(0, '/opt/lpg/deploy/backup')
from core import ROOT, STATE, SECRETS, Lock, command, compose, now, read, write
from worker import admin_evidence, volume
from control import start_full, status as backup_status

VERSION = '20261103175450'
FILE = STATE / 'core-baseline.json'
WRITERS = ['rest', 'account-service', 'attendance-receiver', 'storage']


def sql(source):
    result = subprocess.run(['docker', 'exec', '-i', 'lpg-db-1', 'psql', '-X', '-U', 'supabase_admin', '-d', 'postgres', '-qAt', '-v', 'ON_ERROR_STOP=1'], input=source.encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        error = next((line for line in result.stderr.decode(errors='replace').splitlines() if 'ERROR:' in line), 'Database operation failed')
        raise RuntimeError(error)
    return result.stdout.decode().strip()


def lit(value):
    return "'" + str(value).replace("'", "''") + "'"


def save(state):
    state['updated_at'] = now().isoformat()
    write(FILE, state)
    # Capture original scheduler/runtime intent with the pre-reset recovery point.
    metadata = {key: state.get(key) for key in ['active', 'phase', 'started_at', 'services', 'cron', 'timer_active']}
    metadata.update(generation=state.get('new_generation', state.get('generation')), previous_generation=state.get('generation'))
    write(ROOT / 'deploy/.baseline-maintenance.json', metadata)


def running(service):
    return command(['docker', 'inspect', '--format', '{{json .State.Running}}', 'lpg-' + service + '-1']).strip() == 'true'


def queue_full(state, key):
    previous = backup_status()['job']
    if previous.get('job_id') == state.get(key) and previous.get('status') in ('queued', 'running', 'completed'):
        return
    request = str(uuid.uuid4())
    with Lock(SECRETS / '.control.lock'):
        start_full({'request_id': request}, None)  # System maintenance; no fabricated human audit identity.
    state[key] = request
    save(state)


def restore_services(state):
    for entry in state.get('cron', []):
        sql('select cron.alter_job(' + str(int(entry['id'])) + ',active=>' + ('true' if entry['active'] else 'false') + ');')
    services = [service for service, was_running in state.get('services', {}).items() if was_running]
    if services:
        compose('up', '-d', *services)


def verified_point(snapshot, generation=None):
    if not re.fullmatch(r'[0-9a-f]{64}', snapshot or ''):
        raise RuntimeError('A complete verified snapshot ID is required.')
    point = next((p for p in read(STATE / 'history.json', []) if p.get('snapshot_id') == snapshot), None)
    recovery = read(STATE / 'restore.json', {})
    if not point or point.get('type') != 'full' or point.get('status') != 'verified' or not point.get('available'):
        raise RuntimeError('The chosen full recovery point is not verified and available.')
    if recovery.get('snapshot_id') != snapshot or not all(recovery.get(k) for k in ['files_verified', 'auth_health', 'storage_health']) or not recovery.get('database', {}).get('admin_identity_verified'):
        raise RuntimeError('The selected snapshot has no matching isolated restore and administrator verification.')
    if generation is not None and point.get('generation', 'original') != generation:
        raise RuntimeError('Recovery point belongs to a different data generation.')
    return point


def prepare(admin):
    if not re.fullmatch(r'[0-9a-f-]{36}', admin or '') or sql('select exists(select 1 from app_private.platform_superadmins where user_id=' + lit(admin) + '::uuid and is_active)') != 't':
        raise RuntimeError('The existing active administrator must be identified before maintenance.')
    state = read(FILE, {})
    if state.get('active'):
        if state.get('administrator') != admin or state.get('phase') != 'prepared':
            raise RuntimeError('A maintenance session already exists; inspect its status.')
        queue_full(state, 'pre_reset_job')
        return
    with Lock(ROOT / 'deploy/.deployment.lock'):
        evidence = admin_evidence()
        if evidence['administrators'] < 1:
            raise RuntimeError('No preservable platform administrator.')
        # Delete only this task's recorded disposable database before a cluster backup.
        rehearsal = read(STATE / 'core-overhaul/rehearsal.json', {})
        test_db = rehearsal.get('database')
        if test_db:
            if not re.fullmatch(r'lpg_core_rehearsal_[0-9a-f]{12}', test_db) or rehearsal.get('source') != 'postgres':
                raise RuntimeError('Disposable rehearsal ownership cannot be established.')
            sql('drop database if exists ' + test_db + ' with (force);')
            for suffix in ['.dump', '.restore-error']:
                target = STATE / 'core-overhaul' / (test_db + suffix)
                if target.resolve().parent != (STATE / 'core-overhaul').resolve():
                    raise RuntimeError('Unsafe rehearsal cleanup target.')
                target.unlink(missing_ok=True)
            (STATE / 'core-overhaul/rehearsal.json').unlink(missing_ok=True)
        if sql("select count(*) from pg_database where datname ~ '^lpg_core_(rehearsal|acceptance)_'") != '0':
            raise RuntimeError('Another disposable core database exists; finish its test before whole-cluster capture.')
        cron = json.loads(sql("select coalesce(jsonb_agg(jsonb_build_object('id',jobid,'name',jobname,'active',active)),'[]') from cron.job where jobname like 'lpg-%'"))
        state = {'active': True, 'phase': 'preparing', 'administrator': admin, 'admin_evidence': evidence,
                 'started_at': now().isoformat(), 'generation': read(STATE / 'generation.json', {}).get('id', 'original'),
                 'services': {service: running(service) for service in WRITERS}, 'cron': cron,
                 'old_tenants': json.loads(sql("select coalesce(jsonb_agg(tenant_id),'[]') from public.tenants")),
                 'migration_version': sql('select max(version) from supabase_migrations.schema_migrations'),
                 'timer_active': command(['systemctl', 'show', '--property=ActiveState', '--value', 'lpg-backup.timer']).strip() == 'active'}
        save(state)
        for entry in cron:
            if entry['active']:
                sql('select cron.alter_job(' + str(int(entry['id'])) + ',active=>false);')
        command(['systemctl', 'stop', 'lpg-backup.timer'])
        compose('stop', *WRITERS)
        state.update(phase='prepared', paused_at=now().isoformat())
        save(state)
    queue_full(state, 'pre_reset_job')


def storage_plan():
    objects = json.loads(sql("select coalesce(jsonb_agg(jsonb_build_object('bucket',bucket_id,'name',name)),'[]') from storage.objects where split_part(name,'/',1) in(select tenant_id::text from public.tenants) or owner_id in(select user_id::text from public.user_profiles union select user_id::text from app_private.tenant_actors)"))
    model = json.loads(compose('config', '--format', 'json'))
    env = model['services']['storage']['environment']
    if env.get('STORAGE_BACKEND') != 'file':
        raise RuntimeError('This reset supports only the inspected file Storage backend.')
    base = volume('lpg_storage_data').resolve()
    prefix = base / env['GLOBAL_S3_BUCKET'] / env['TENANT_ID']
    targets = []
    for item in objects:
        parts = PurePosixPath(item['name']).parts
        if not parts or item['name'].startswith('/') or any(p in ('.', '..') or '\\' in p for p in parts) or '/' in item['bucket'] or item['bucket'] in ('.', '..'):
            raise RuntimeError('Unsafe Storage key; inspect the business-object deletion plan.')
        target = (prefix / item['bucket'] / Path(*parts)).resolve()
        if not target.is_relative_to(base) or target in (base, prefix) or len(target.relative_to(base).parts) < 4:
            raise RuntimeError('Business Storage deletion escaped the verified volume.')
        if not target.exists():
            raise RuntimeError('A business Storage object has no matching physical path; inspect the file backend before reset.')
        targets.append(str(target))
    return str(base), targets


def reset(request):
    if request.get('delete_business_data') is not True:
        raise RuntimeError('Explicit business-data deletion authorization is required.')
    state = read(FILE, {})
    if state.get('phase') in ('reset', 'testing', 'completed') and state.get('administrator') == request.get('administrator') and state.get('pre_reset_snapshot') == request.get('snapshot'):
        return  # A lost response must never erase the newly established baseline.
    if not state.get('active') or state.get('phase') not in ('prepared', 'data_reset') or state.get('administrator') != request.get('administrator'):
        raise RuntimeError('No matching prepared maintenance session.')
    with Lock(ROOT / 'deploy/.deployment.lock'):
        point = verified_point(request.get('snapshot'), state['generation'])
        if point.get('job_id') != state.get('pre_reset_job') or dt.datetime.fromisoformat(point['captured_at']) < dt.datetime.fromisoformat(state['paused_at']):
            raise RuntimeError('A full backup captured after source writers stopped is required.')
        if admin_evidence() != state['admin_evidence']:
            raise RuntimeError('Administrator credentials or authority changed during maintenance.')
        if any(running(service) for service in WRITERS if service != 'storage'):
            raise RuntimeError('Business source writers are not quiesced.')
        compose('stop', 'storage')
        if (STATE / 'capture/manifest.json').exists():
            raise RuntimeError('A sealed recovery point is still pending; finish its upload first.')
        pins = read(STATE / 'protected-snapshots.json', [])
        write(STATE / 'protected-snapshots.json', list(dict.fromkeys([*pins, point['snapshot_id']])))
        if state['phase'] == 'prepared':
            base, targets = storage_plan()
            state.update(storage_base=base, storage_targets=targets, old_tenants=json.loads(sql("select coalesce(jsonb_agg(tenant_id),'[]') from public.tenants")))
            save(state)
            result = sql('set lpg.authorized_development_reset=' + lit(point['snapshot_id']) + ';\n' + request['reset_sql'])
            state.update(phase='data_reset', reset_at=now().isoformat(), pre_reset_snapshot=point['snapshot_id'], reset_result=json.loads(result.splitlines()[-1]))
            save(state)
        if sql('select count(*) from public.tenants') != '0':
            raise RuntimeError('New business activity exists; refusing further reset cleanup.')
        base = Path(state['storage_base']).resolve()
        if base != volume('lpg_storage_data').resolve():
            raise RuntimeError('Storage volume changed after the deletion plan was reviewed.')
        for name in state['storage_targets']:
            target = Path(name).resolve()
            if not target.is_relative_to(base) or target == base:
                raise RuntimeError('Stored business Storage target escaped its verified root.')
            if target.is_dir():
                shutil.rmtree(target)
            elif target.exists():
                target.unlink()
            parent = target.parent
            while parent.is_relative_to(base) and len(parent.relative_to(base).parts) > 3 and parent.is_dir() and not any(parent.iterdir()):
                parent.rmdir()
                parent = parent.parent
        archive = STATE / 'generations' / state['generation']
        archive.mkdir(parents=True, exist_ok=True, mode=0o700)
        for name in ['acceptance.json']:
            source = SECRETS / name
            if source.exists():
                shutil.copy2(source, archive / name)
                source.unlink()
        generation = 'core-components-' + uuid.uuid4().hex
        write(STATE / 'generation.json', {'id': generation, 'started_at': now().isoformat(), 'pre_reset_snapshot': point['snapshot_id']})
        write(STATE / 'baseline-required.json', {'generation': generation, 'required_at': now().isoformat()})
        state.update(phase='reset', new_generation=generation, storage_objects_removed=len(state['storage_targets']))
        state.pop('storage_targets', None)
        save(state)


def release():
    state = read(FILE, {})
    if not state.get('active') or state.get('phase') not in ('reset', 'testing') or sql('select exists(select 1 from supabase_migrations.schema_migrations where version=' + lit(VERSION) + ')') != 't':
        raise RuntimeError('Apply and verify the canonical core migration before releasing the application.')
    if admin_evidence() != state['admin_evidence']:
        raise RuntimeError('Administrator preservation check failed.')
    restore_services(state)
    state.update(phase='testing', application_released_at=now().isoformat())
    save(state)


def deployment_ready():
    """The standard updater requires healthy core API/Storage containers.

    No business membership exists on this baseline, and account creation stays
    stopped until the schema and dependent frontend have been deployed.
    """
    state = read(FILE, {})
    if state.get('phase') != 'reset':
        return
    if sql('select count(*) from public.tenants') != '0' or admin_evidence() != state['admin_evidence']:
        raise RuntimeError('The empty, administrator-preserved deployment baseline changed.')
    compose('up', '-d', '--no-deps', '--no-recreate', '--wait', '--wait-timeout', '120', 'rest', 'storage')


def complete(snapshot):
    state = read(FILE, {})
    if state.get('phase') == 'completed' and state.get('baseline_snapshot') == snapshot:
        return
    if not state.get('active') or state.get('phase') != 'testing':
        raise RuntimeError('No released baseline is awaiting full-backup verification.')
    point = verified_point(snapshot, state['new_generation'])
    if admin_evidence() != state['admin_evidence']:
        raise RuntimeError('Original administrator set or credentials differ from the preserved baseline.')
    if (STATE / 'baseline-required.json').exists():
        raise RuntimeError('The fresh full baseline has not completed.')
    recovery = read(STATE / 'restore.json', {})
    migrations = sql("select md5(string_agg(version,',' order by version)) from supabase_migrations.schema_migrations")
    source = read(ROOT / 'deploy/.source-version.json', {}).get('backend_sha256')
    if not source or recovery.get('backend_source_sha256') != source or recovery.get('database', {}).get('migration_fingerprint') != migrations:
        raise RuntimeError('The verified baseline predates the current backend or database schema; take a new full backup.')
    pins = [value for value in read(STATE / 'protected-snapshots.json', []) if value != state['pre_reset_snapshot']]
    write(STATE / 'protected-snapshots.json', pins)
    if state['timer_active']:
        command(['systemctl', 'start', 'lpg-backup.timer'])
    state.update(active=False, phase='completed', baseline_snapshot=point['snapshot_id'], completed_at=now().isoformat())
    save(state)


def abort():
    state = read(FILE, {})
    if not state.get('active') or state.get('phase') not in ('preparing', 'prepared'):
        raise RuntimeError('Only maintenance before business deletion can be aborted.')
    if sql('select max(version) from supabase_migrations.schema_migrations') != state['migration_version']:
        raise RuntimeError('Schema changed during maintenance; inspect it before releasing writers.')
    expected = set(state['old_tenants'])
    actual = set(json.loads(sql("select coalesce(jsonb_agg(tenant_id),'[]') from public.tenants")))
    if expected != actual:
        raise RuntimeError('Business membership changed; refuse an unsafe maintenance abort.')
    with Lock(ROOT / 'deploy/.deployment.lock'):
        restore_services(state)
        if state['timer_active']:
            command(['systemctl', 'start', 'lpg-backup.timer'])
        state.update(active=False, phase='aborted', aborted_at=now().isoformat())
        save(state)


def report():
    state = read(FILE, {})
    job = backup_status()['job']
    return {key: state.get(key) for key in ['active', 'phase', 'started_at', 'paused_at', 'pre_reset_job', 'pre_reset_snapshot', 'new_generation', 'reset_result', 'storage_objects_removed', 'baseline_snapshot']} | {
        'job': {key: job.get(key) for key in ['job_id', 'status', 'phase', 'detail', 'percent', 'processed_bytes', 'total_bytes', 'error']}}


if __name__ == '__main__':
    os.umask(0o077)
    try:
        request = json.load(sys.stdin)
        if os.geteuid() != 0 or ROOT != Path('/opt/lpg'):
            raise RuntimeError('The established primary VPS root context is required.')
        model = json.loads(compose('config', '--format', 'json'))
        if model['services']['api-gw']['environment']['SUPABASE_PUBLIC_URL'] != 'https://api.lpg.144.79.249.4.sslip.io':
            raise RuntimeError('Unexpected backend target.')
        action = request.get('action')
        if action == 'prepare':
            prepare(request.get('administrator'))
        elif action == 'reset':
            reset(request)
            deployment_ready()
        elif action == 'release':
            release()
        elif action == 'complete':
            complete(request.get('snapshot'))
        elif action == 'abort':
            abort()
        elif action == 'preflight':
            base, targets = storage_plan()
            print(json.dumps({'target': 'primary VPS', 'storage_objects': len(targets), 'physical_paths_verified': True, 'businesses': int(sql('select count(*) from public.tenants')), 'administrators': admin_evidence()['administrators']}))
            sys.exit(0)
        elif action != 'status':
            raise RuntimeError('Unknown baseline action.')
        print(json.dumps(report()))
    except Exception as error:
        print('Baseline operation stopped: ' + str(error), file=sys.stderr)
        sys.exit(1)
