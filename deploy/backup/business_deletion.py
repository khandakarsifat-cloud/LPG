"""Root-only, fenced and resumable business removal with a verified recovery point.

Never runs through a service-role SQL RPC. All identifiers are parsed UUIDs;
Storage/Auth deletion uses their owning APIs, never metadata-only SQL cleanup.
"""
import json
import datetime as dt
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid

import confirmations
from core import ROOT, STATE, SECRETS, Lock, command, compose, event, now, read, write, process_identity


def identity(value):
    return str(uuid.UUID(value))


def literal(value):
    return "'" + str(value).replace("'", "''") + "'"


def sql(query):
    output = compose('exec', '-T', 'db', 'psql', '-X', '-U', 'supabase_admin', '-d', 'postgres',
                     '-v', 'ON_ERROR_STOP=1', '-At', '-c', "set lock_timeout='10s';set statement_timeout='120s';" + query)
    lines = [line for line in output.splitlines() if line.startswith('{') or line.startswith('[')]
    return json.loads(lines[-1]) if lines else None


def job_path(job_id):
    return STATE / 'business-deletions' / (identity(job_id) + '.json')


def public_job(job):
    return {key: value for key, value in job.items() if key not in ('manifest', 'pid', 'process_started')}


def job_state(record):
    if record['status'] == 'completed':
        return {**record, 'phase': 'Business deleted'}
    state = read(job_path(record['job_id']), record)
    if state.get('status') in ('queued', 'running'):
        alive = state.get('process_started') and process_identity(state.get('pid')) == state['process_started']
        if not alive and (now() - dt.datetime.fromisoformat(state.get('updated_at', state['created_at']))).total_seconds() > 30:
            state = {**state, 'status': 'interrupted', 'error': 'Worker stopped. Business remains blocked; resume this job.'}
    return state


def preview(target):
    target = identity(target)
    job = sql('select to_jsonb(j) from app_private.business_deletions j where business_id=' + literal(target) + '::uuid;')
    manifest = job['manifest'] if job else sql('select app_private.business_deletion_preview(' + literal(target) + '::uuid);')
    state = job_state(job) if job else None
    return {'business_id': target, 'business_name': manifest.get('business_name', job['business_name'] if job else ''),
            'tables': manifest.get('tables', {}), 'files': len(manifest.get('files', [])),
            'accounts': len(manifest.get('users', [])), 'preserved_accounts': len(manifest.get('preserved_users', [])),
            'job': public_job(state or job) if job else None,
            'backup_ready': (SECRETS / 'rclone.conf').exists()}


def jobs():
    records = sql("select coalesce(jsonb_agg(to_jsonb(j) - 'manifest' order by created_at desc),'[]') from "
                  '(select * from app_private.business_deletions order by created_at desc limit 30)j;')
    result = []
    for record in records:
        state = job_state(record)
        result.append(public_job(state))
    return result


def start(body, actor):
    if set(body) != {'target', 'request_id', 'business_name', 'confirmation_token', 'confirmation'}:
        raise ValueError('Review the business and complete both confirmation steps.')
    target, job_id = identity(body['target']), identity(body['request_id'])
    previous = read(job_path(job_id), {})
    if previous:
        previous = job_state(previous)
    if previous and (previous.get('business_id') != target or previous.get('actor_id') != actor):
        raise ValueError('This request belongs to a different deletion.')
    if previous.get('status') in ('queued', 'running', 'completed'):
        return public_job(previous)
    if not (SECRETS / 'rclone.conf').exists():
        raise ValueError('Connect Google Drive before deleting a business. A fresh verified recovery point is required.')
    with Lock(ROOT / 'deploy/.deployment.lock'):
        other = sql("select jsonb_build_object('exists',exists(select 1 from app_private.business_deletions where status<>'completed' and job_id<>" + literal(job_id) + '::uuid));')
        if other['exists']:
            raise ValueError('Finish or resume the existing business deletion before starting another.')
        current_backup = read(STATE / 'job.json', {})
        if current_backup.get('status') in ('queued', 'running'):
            raise ValueError('Wait for the current backup to finish.')
        confirmations.consume(actor, 'delete-business', target, body['confirmation_token'], body['confirmation'])
        job = sql('select app_private.prepare_business_deletion(' + ','.join([
            literal(target) + '::uuid', literal(job_id) + '::uuid', literal(actor) + '::uuid', literal(body['business_name'])]) + ');')
        if job['status'] == 'completed':
            return public_job(job_state(job))
        state = {key: value for key, value in job.items() if key != 'manifest'}
        state.update(status='queued', phase='Waiting to start', updated_at=now().isoformat())
        write(job_path(job_id), state)
        write(STATE / 'business-deletion-request.json', {'job_id': job_id})
        try:
            command(['systemctl', 'start', '--no-block', 'lpg-business-deletion.service'])
        except Exception:
            write(job_path(job_id), {**state, 'status': 'failed', 'error': 'Worker could not start. Resume this job.'})
            raise
    return public_job(state)


def request_api(path, method, body=None):
    config = read(ROOT / 'deploy/.account-service.json')
    headers = {'apikey': config['serviceKey'], 'Authorization': 'Bearer ' + config['serviceKey'], 'Content-Type': 'application/json'}
    data = json.dumps(body).encode() if body is not None else None
    try:
        with urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:54321' + path, data=data, method=method, headers=headers), timeout=60) as response:
            content = response.read()
            return json.loads(content) if content else None
    except urllib.error.HTTPError as error:
        if error.code == 404 and method == 'DELETE':
            return None  # An earlier successful attempt may have lost its response.
        raise RuntimeError('Identity or file cleanup failed. Business stays blocked; resume the deletion.') from error


def remove_files(manifest):
    buckets = {}
    for entry in manifest.get('files', []):
        buckets.setdefault(entry['bucket'], []).append(entry['name'])
    for bucket, paths in buckets.items():
        for offset in range(0, len(paths), 100):
            request_api('/storage/v1/object/' + urllib.parse.quote(bucket, safe=''), 'DELETE', {'prefixes': paths[offset:offset + 100]})
    residual = sql('select jsonb_build_object(\'count\',count(*)) from storage.objects where split_part(name,\'/\',1)=' + literal(manifest['business_id']) +
                   ' or owner_id=any(array[' + ','.join(literal(u) for u in manifest.get('users', [])) + ']::text[]);')
    if residual['count']:
        raise RuntimeError('Some business files remain. No business records were removed; resume cleanup.')


def run():
    if os.geteuid() != 0:
        raise RuntimeError('Root-owned deletion worker required.')
    job_id = identity(read(STATE / 'business-deletion-request.json', {})['job_id'])
    state = read(job_path(job_id), {})
    def progress(phase, **extra):
        state.update(status='running', phase=phase, updated_at=now().isoformat(), pid=os.getpid(), process_started=process_identity(os.getpid()), **extra)
        write(job_path(job_id), state)
    try:
        with Lock(ROOT / 'deploy/.deployment.lock'):
            job = sql('select to_jsonb(j) from app_private.business_deletions j where job_id=' + literal(job_id) + '::uuid;')
            if not job or job['status'] == 'completed':
                return
            manifest = job['manifest']
            if job['status'] == 'prepared':
                progress('Creating and restoring a fresh recovery backup')
                from worker import nightly
                point = nightly(manual=True, lock_held=True, request_override={'request_id': str(uuid.uuid4()), 'actor': job['actor_id']})
                if not point or point.get('status') != 'verified' or not point.get('available') or point.get('type') != 'full' or dt.datetime.fromisoformat(point['captured_at']) < dt.datetime.fromisoformat(job['created_at']):
                    raise RuntimeError('A fresh verified full recovery point is required. No business data was deleted.')
                # Keep the original pre-delete evidence through arbitrarily long
                # interruptions; normal retention resumes only after completion.
                protection = STATE / 'protected-snapshots.json'
                write(protection, sorted(set(read(protection, [])) | {point['snapshot_id']}))
                sql("update app_private.business_deletions set status='backed_up',backup_id=" + literal(point['snapshot_id']) + ' where job_id=' + literal(job_id) + '::uuid;')
                job.update(status='backed_up', backup_id=point['snapshot_id'])
            progress('Removing uploaded files', backup_id=job['backup_id'])
            if job['status'] == 'backed_up':
                remove_files(manifest)
                progress('Removing business records in one database transaction')
                sql('select app_private.purge_business_data(' + literal(job_id) + '::uuid);')
            progress('Removing dedicated login accounts')
            for user_id in manifest.get('users', []):
                request_api('/auth/v1/admin/users/' + identity(user_id), 'DELETE')
            remaining_users = sql("select jsonb_build_object('count',count(*)) from auth.users where id=any(array[" + ','.join(literal(identity(u)) + '::uuid' for u in manifest.get('users', [])) + ']::uuid[]);')
            if remaining_users['count']:
                raise RuntimeError('Dedicated identity cleanup has not completed.')
            if manifest.get('users'):
                # These GoTrue tables are not all covered by auth.users foreign
                # keys. Scope cleanup to exact dedicated identities, never email
                # patterns, shared users, the platform actor or other businesses.
                ids = 'array[' + ','.join(literal(identity(u)) for u in manifest['users']) + ']::text[]'
                sql('delete from auth.refresh_tokens where user_id=any(' + ids + ');'
                    'delete from auth.flow_state where user_id::text=any(' + ids + ');'
                    "delete from auth.audit_log_entries where payload->>'actor_id'=any(" + ids + ") or payload->'traits'->>'user_id'=any(" + ids + ');')
            # Validate every currently registered tenant table, not just the list
            # present at preview time. No unrelated table/index is dropped.
            sql("do $$declare r record;n bigint;begin for r in select n.nspname,c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace join pg_attribute a on a.attrelid=c.oid and a.attname='tenant_id' where c.relkind='r' and n.nspname in('public','app_private') loop execute format('select count(*) from %I.%I where tenant_id=$1',r.nspname,r.relname) into n using " + literal(job['business_id']) + "::uuid;if n<>0 then raise exception 'Business rows remain';end if;end loop;end$$;")
            remove_files(manifest)
            sql("update app_private.business_deletions set status='completed',completed_at=clock_timestamp(),manifest=manifest-'users'-'preserved_users'-'files' where job_id=" + literal(job_id) + '::uuid;')
            protection = STATE / 'protected-snapshots.json'
            write(protection, [snapshot for snapshot in read(protection, []) if snapshot != job['backup_id']])
            state.update(status='completed', phase='Business deleted', completed_at=now().isoformat(), error=None)
            write(job_path(job_id), state)
            event('business_deleted', job['actor_id'])
    except Exception:
        state.update(status='failed', error='Deletion stopped safely. The business remains blocked. Its verified backup, if created, is preserved. Resume this job to finish cleanup.', updated_at=now().isoformat())
        write(job_path(job_id), state)
        raise


if __name__ == '__main__':
    os.umask(0o077)
    try:
        run()
    except Exception:
        # Upstream errors can contain records/credentials. Keep the service log
        # deliberately generic; detailed state is limited to private job phases.
        sys.exit('Business deletion stopped; inspect private job state and retry.')
