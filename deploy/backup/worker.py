"""One nightly job, one deployment lock, one encrypted cloud repository."""
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import time
import uuid

from core import DHAKA, ROOT, REMOTE, SECRETS, STATE, Lock, command, compose, event, job_update, next_run, now, pg, process_identity, read, restic, retain_ids, retry, snapshot_generation, window, write

CAPTURE = STATE / 'capture'


def engine_message(line):
    """Restic JSON and its prefixed rclone stderr share the measured stream."""
    try:
        start = line.find('{')
        value = json.loads(line[start:]) if start >= 0 else None
        return value if isinstance(value, dict) else {}
    except ValueError:
        return {}


def admin_evidence():
    sql = """select json_build_object('administrators',(select count(*) from app_private.platform_superadmins),
      'auth_identity',(select md5(coalesce(string_agg(concat_ws(':',u.id,u.email,u.encrypted_password,u.raw_app_meta_data::text,u.role,u.aud), '|' order by u.id),''))
        from auth.users u join app_private.platform_superadmins a on a.user_id=u.id),
      'platform_authority',(select md5(coalesce(json_agg(to_jsonb(a) order by a.user_id)::text,'')) from app_private.platform_superadmins a),
      'bootstrap',(select md5(coalesce(json_agg(to_jsonb(b))::text,'')) from app_private.platform_bootstrap b))"""
    return json.loads(compose('exec', '-T', 'db', 'psql', '-X', '-U', 'supabase_admin', '-d', 'postgres', '-At', '-v', 'ON_ERROR_STOP=1', '-c', sql))


def resume_storage():
    marker = STATE / 'storage-paused.json'
    if marker.exists():
        compose('up', '-d', '--no-deps', '--wait', '--wait-timeout', '180', 'storage')
        marker.unlink()


def volume(name):
    info = json.loads(command(['docker', 'volume', 'inspect', name]))[0]
    if info['Name'] != name or info['Driver'] != 'local':
        raise RuntimeError('Persistent volume identity mismatch.')
    return Path(info['Mountpoint'])


def copy_tree(source, destination):
    destination.mkdir(parents=True, exist_ok=True)
    command(['cp', '-a', '--reflink=auto', str(source) + '/.', destination])


def sealed_repository(source, destination):
    """Data/WAL files are immutable. Copy mutable metadata, link immutable payloads."""
    def copy(file, target):
        name = Path(file).name
        if 'info' in name or 'manifest' in name:
            return shutil.copy2(file, target)
        os.link(file, target)
        return target
    shutil.copytree(source, destination, copy_function=copy, symlinks=True)


def tree_hashes(folder):
    entries = {}
    for path in sorted(folder.rglob('*')):
        if path.is_file() and not path.is_symlink():
            digest = hashlib.sha256()
            with path.open('rb') as stream:
                while block := stream.read(1024 * 1024):
                    digest.update(block)
            entries[str(path.relative_to(folder))] = digest.hexdigest()
    return entries


def capture(backup_type=None):
    if backup_type not in (None, 'full', 'incr'):
        raise RuntimeError('Unsupported backup type.')
    if CAPTURE.exists():
        # Never replace the only sealed copy of an interrupted upload.
        if not (CAPTURE / 'manifest.json').exists():
            shutil.rmtree(CAPTURE)
        else:
            resume_storage()
            return read(CAPTURE / 'manifest.json')
    job_update('Preparing', detail='Checking free space and preparing a consistent recovery point.')
    db_bytes = shutil.disk_usage(volume('lpg_db_data')).free
    if db_bytes < 8 * 1024**3:
        raise RuntimeError('Less than 8 GiB free: backup stopped before creating a recovery point. Free local disk safely.')
    CAPTURE.mkdir(parents=True, mode=0o700)
    local = now().astimezone(DHAKA)
    info = json.loads(pg('--output=json', 'info'))[0]
    backups = info.get('backup', [])
    # First run and first successful backup in a new Dhaka month are full.
    latest_full = next((b for b in reversed(backups) if b['type'] == 'full'), None)
    month = local.strftime('%Y-%m')
    cloud_monthly = any(p.get('monthly') and p.get('status') == 'verified' and p.get('date', '').startswith(month) for p in read(STATE / 'history.json', []))
    monthly = not latest_full or not cloud_monthly or dt.datetime.fromtimestamp(latest_full['timestamp']['start'], DHAKA).strftime('%Y-%m') != month
    kind = 'full' if monthly else 'incr'
    if backup_type:
        # Isolated acceptance can exercise incremental capture without forging history.
        kind, monthly = backup_type, backup_type == 'full'
    started = now().isoformat()
    administrators = admin_evidence()
    try:
        write(STATE / 'storage-paused.json', {'paused_by_backup_at': started})
        compose('stop', 'storage')
        try:
            job_update('File Backup', detail='Copying uploaded objects while Storage is paused.')
            copy_tree(volume('lpg_storage_data'), CAPTURE / 'storage')
            job_update('Database Backup', detail='Capturing the PostgreSQL cluster with Zstandard compression.')
            pg('--type=' + kind, 'backup')
            point = json.loads(pg('--output=json', 'info'))[0]['backup'][-1]
            with Lock(STATE / 'repo.lock', blocking=True):
                sealed_repository(STATE / 'repository', CAPTURE / 'pgbackrest')
            job_update('File Backup', detail='Sealing database recovery files, configuration and persistent volumes.')
            # Essential encryption configuration and TLS volumes, including modes/owners.
            for name in ['lpg_db-config', 'lpg_caddy-data', 'lpg_caddy-config']:
                copy_tree(volume(name), CAPTURE / 'volumes' / name)
            config = CAPTURE / 'config'
            config.mkdir()
            for name in ['.env', 'compose.yml', 'compose.vps.yml', 'supabase', 'attendance-receiver', 'account-service']:
                path = ROOT / name
                if path.is_dir():
                    shutil.copytree(path, config / name, ignore=shutil.ignore_patterns('__pycache__', 'node_modules', '.temp', 'data', 'storage', 'logs'))
                else:
                    shutil.copy2(path, config / name)
            shutil.copytree(ROOT / 'deploy', config / 'deploy', ignore=shutil.ignore_patterns(
                'backup-secrets', '__pycache__', '.env.*', '.backup-key', '*.lock', '*.new', '*_test.py', '*.test.mjs'))
            for generated in ['.account-service.json', '.attendance-token']:
                source = ROOT / 'deploy' / generated
                destination = config / 'deploy' / generated
                if source.exists():
                    os.chown(destination, source.stat().st_uid, source.stat().st_gid)
            # Rebuildable source is included, plus the actual essential host configuration.
            for host_path in ['/etc/docker/daemon.json', '/usr/local/sbin/lpg-docker-firewall',
                              '/etc/systemd/system/docker.service.d/20-lpg-firewall.conf',
                              '/etc/ssh/sshd_config.d/00-lpg-hardening.conf', '/etc/fail2ban/jail.local']:
                source = Path(host_path)
                if source.is_file():
                    destination = config / 'host' / host_path.lstrip('/')
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(source, destination)
            for source in Path('/etc/systemd/system').glob('lpg-*.*'):
                if source.is_file():
                    destination = config / 'host/etc/systemd/system' / source.name
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(source, destination)
            # Never depend on the original VPS or a later Git checkout for recovery.
            job_update('Verification', detail='Calculating SHA256 inventories of captured files.')
            write(CAPTURE / 'file-hashes.json', {'storage': tree_hashes(CAPTURE / 'storage'),
                'volumes': tree_hashes(CAPTURE / 'volumes'), 'config': tree_hashes(config)})
            state = CAPTURE / 'backup-state'
            state.mkdir()
            for name in ['audit.json', 'settings.json', 'history.json', 'repository-identity.json']:
                if (STATE / name).exists():
                    shutil.copy2(STATE / name, state / name)
            manifest = {'version': 1, 'started_at': started, 'captured_at': now().isoformat(),
                'date': local.date().isoformat(), 'monthly': monthly, 'type': point['type'], 'label': point['label'],
                'database_bytes': point['info']['size'], 'backup_bytes': point['info']['repository']['delta'],
                'postgres_image': 'lpg-postgres-backup:17.6.1.140-pgbackrest2.57.0',
                'pgbackrest_version': '2.57.0', 'source': read(ROOT / 'deploy/.source-version.json', {}),
                'retention': {'daily_days': 30, 'monthly_fulls': 12}}
            manifest['generation'] = read(STATE / 'generation.json', {}).get('id', 'original')
            manifest['admin_evidence'] = administrators
            write(CAPTURE / 'manifest.json', manifest)
            return manifest
        finally:
            resume_storage()
    except Exception:
        # A complete manifest is written last. Unsealed captures cannot be uploaded.
        if not (CAPTURE / 'manifest.json').exists():
            shutil.rmtree(CAPTURE)
        raise


def cloud_metrics():
    base = ['rclone', '--config', SECRETS / 'rclone.conf', '--tpslimit', '4']
    about = json.loads(command(base + ['about', 'lpg-drive:', '--json']))
    usage = json.loads(command(base + ['size', REMOTE, '--json']))
    write(STATE / 'usage.json', {**about, 'backup_bytes': usage['bytes'], 'objects': usage['count'], 'measured_at': now().isoformat()})
    connection = read(STATE / 'connection.json', {})
    write(STATE / 'connection.json', {**connection, 'connected': True,
        'status': 'Connected', 'validated_at': now().isoformat()})


def upload(manifest):
    # An absent config file is different from an inaccessible existing repository.
    # Check listing once, initialize ONLY an empty dedicated destination.
    job_update('Preparing', detail='Validating the encrypted Google Drive repository.')
    base = ['rclone', '--config', SECRETS / 'rclone.conf', '--tpslimit', '4']
    listing = json.loads(command(base + ['lsjson', 'lpg-drive:', '--dirs-only']))
    exists = any(item['Name'] == 'LPG-System-Recovery' for item in listing)
    identity = read(STATE / 'repository-identity.json', {})
    if not exists:
        if identity.get('id'):
            raise RuntimeError('The established cloud repository is missing. No replacement repository was initialized.')
        command(base + ['mkdir', REMOTE])
        restic('init', '--repository-version', '2')
    else:
        children = json.loads(command(base + ['lsjson', 'lpg-drive:LPG-System-Recovery', '--dirs-only']))
        if not any(item['Name'] == 'restic' for item in children):
            if identity.get('id'):
                raise RuntimeError('The established repository directory is missing. No replacement was initialized.')
            command(base + ['mkdir', REMOTE])
        # Empty interrupted initial setup can retry. Nonempty damaged repos fail closed.
        if not json.loads(command(base + ['lsjson', REMOTE])):
            if identity.get('id'):
                raise RuntimeError('The established cloud repository is empty. Restore its original configuration before retrying.')
            restic('init', '--repository-version', '2')
    # Remove only locks verifiably stale by restic's age/host rules, under our one-job lock.
    restic('unlock')
    repo = json.loads(restic('cat', 'config'))
    identity = read(STATE / 'repository-identity.json', {})
    if identity.get('id') and identity['id'] != repo['id']:
        raise RuntimeError('Cloud repository identity changed. Reconnect the original account; no retention cleanup was attempted.')
    write(STATE / 'repository-identity.json', {'id': repo['id'], 'account': read(STATE / 'connection.json', {}).get('account')})
    snapshots = json.loads(restic('snapshots', '--json'))
    tag = 'point:' + manifest['label']
    existing = next((s for s in snapshots if tag in s.get('tags', [])), None)
    started = time.monotonic()
    previous_summary = read(STATE / 'upload-summary.json', {})
    summary = previous_summary.get('summary', {}) if previous_summary.get('label') == manifest['label'] else {}
    upload_seconds = previous_summary.get('seconds', 0) if summary else 0
    if existing:
        if snapshot_generation(existing) != manifest.get('generation', 'original'):
            raise RuntimeError('This recovery label belongs to another data generation; no recovery point was replaced.')
        snapshot_id = existing['id']
    else:
        args = ['backup', str(CAPTURE), '--host', 'lpg-system', '--tag', 'lpg-system', '--tag', tag,
                '--tag', 'generation:' + manifest.get('generation', 'original'),
                '--time', dt.datetime.fromisoformat(manifest['captured_at']).astimezone().strftime('%Y-%m-%d %H:%M:%S'), '--json']
        if manifest['monthly']:
            args += ['--tag', 'monthly-full']
        job_update('Uploading to Google Drive', detail='Restic is compressing, encrypting and uploading the sealed recovery point.')
        transferred_before = read(STATE / 'job.json', {}).get('network_transferred_bytes') or 0
        def progress(line):
            status = engine_message(line)
            if status.get('message_type') == 'status':
                percent = status.get('percent_done')
                job_update(percent=round(percent * 100, 1) if isinstance(percent, (int, float)) else None,
                           processed_bytes=status.get('bytes_done'), total_bytes=status.get('total_bytes'),
                           remaining_seconds=status.get('seconds_remaining'))
            stats = status.get('stats')
            if isinstance(stats, dict) and type(stats.get('bytes')) is int and stats['bytes'] >= 0:
                job_update(network_transferred_bytes=transferred_before + stats['bytes'])
        output = restic(*args, on_output=progress)
        summary = next(item for item in map(engine_message, output.splitlines()) if item.get('message_type') == 'summary')
        upload_seconds = max(1, time.monotonic() - started)
        write(STATE / 'upload-summary.json', {'label': manifest['label'], 'summary': summary, 'seconds': upload_seconds})
        snapshot_id = summary['snapshot_id']
    job_update('Verification', detail='Checking encrypted repository data and uploaded recovery manifest.',
               transferred_bytes=summary.get('data_added_packed', summary.get('data_added')),
               processed_bytes=summary.get('total_bytes_processed'))
    # restic's summary uses a short ID; retain canonical full IDs in history.
    snapshots = json.loads(restic('snapshots', '--json'))
    snapshot_id = next(s['id'] for s in snapshots if tag in s.get('tags', []))
    history = [p for p in read(STATE / 'history.json', []) if p.get('label') != manifest['label']]
    point_fields = {key: value for key, value in manifest.items() if key != 'source'}
    write(STATE / 'history.json', [{**point_fields, 'snapshot_id': snapshot_id, 'status': 'uploaded', 'available': False,
        'cloud_bytes_added': summary.get('data_added_packed', summary.get('data_added', 0)),
        'processed_bytes': summary.get('total_bytes_processed', 0), 'upload_bytes_per_second': 0, 'duration_seconds': 0}] + history)
    # Metadata check every night; rotating full data coverage over seven nights.
    subset = now().astimezone(DHAKA).weekday() + 1
    restic('check', '--read-data-subset', f'{subset}/7')
    # Prove the uploaded point is readable before retaining/pruning anything.
    downloaded = json.loads(restic('dump', snapshot_id, str(CAPTURE / 'manifest.json')))
    if downloaded != manifest:
        raise RuntimeError('Uploaded recovery manifest does not match the sealed local recovery point.')
    # Monthly full restore drill reads the whole cloud recovery point, not the live DB.
    restore = read(STATE / 'restore.json', {})
    due = read(STATE / 'job.json', {}).get('mode') == 'manual-full' or manifest['monthly'] or not restore.get('verified_at') or now().timestamp() - dt.datetime.fromisoformat(restore['verified_at']).timestamp() > 31 * 86400
    if due:
        job_update(detail='Restoring the uploaded database and files on an isolated network; testing Auth, Storage and accounting.')
        command(['python3', '-B', ROOT / 'deploy/backup/restore.py', '--snapshot', snapshot_id], timeout=86400)
    job_update(detail='Restore verification passed; checking retained recovery points and repository retention.')
    snapshots = json.loads(restic('snapshots', '--json'))
    keep = retain_ids(snapshots, protected_ids=read(STATE / 'protected-snapshots.json', []))
    expired = [s['id'] for s in snapshots if 'lpg-system' in s.get('tags', []) and s['id'] not in keep]
    if expired:
        job_update(detail='Restore verification passed; applying the existing retention policy and checking repository integrity.')
        restic('forget', *expired)
        restic('prune', '--max-repack-size', '256M')
        restic('check')
    job_update(detail='Finalizing verified recovery history and measuring cloud repository size.')
    cloud_metrics()
    elapsed = max(1, time.monotonic() - started)
    history = read(STATE / 'history.json', [])
    history = [p for p in history if p.get('label') != manifest['label']]
    retained = {s['id'] for s in snapshots if s['id'] in keep}
    for record in history:
        record['available'] = record.get('status') == 'verified' and record.get('snapshot_id') in retained
    record = {**point_fields, 'snapshot_id': snapshot_id, 'status': 'verified', 'available': True,
        'verified_at': now().isoformat(), 'cloud_bytes_added': summary.get('data_added_packed', summary.get('data_added', 0)),
        'processed_bytes': summary.get('total_bytes_processed', 0), 'duration_seconds': round(elapsed),
        'upload_seconds': round(upload_seconds),
        'upload_bytes_per_second': round(summary.get('data_added_packed', summary.get('data_added', 0)) / max(1, upload_seconds))}
    job = read(STATE / 'job.json', {})
    if job.get('status') == 'running':
        record.update(job_id=job.get('job_id'), mode=job.get('mode'), started_at=job.get('started_at'),
                      destination='Google Drive · encrypted system repository')
    write(STATE / 'history.json', ([record] + history)[:400])
    shutil.rmtree(CAPTURE)
    return record


def nightly(manual=False):
    if not manual and read(STATE / 'core-baseline.json', {}).get('active'):
        return  # The authorized reset retains its pre-reset point until a new full baseline is verified.
    if not manual and not window():
        raise RuntimeError('Cloud access may start only from 02:00–02:14 Asia/Dhaka. Queue a backup for the next nightly window.')
    if not manual and not read(STATE / 'settings.json', {'enabled': True})['enabled']:
        return
    with Lock(ROOT / 'deploy/.deployment.lock'):
        if not manual and read(STATE / 'job.json', {}).get('status') == 'queued' and (STATE / 'manual-request.json').exists():
            return  # The immediate worker owns the durable reservation.
        request = read(STATE / 'manual-request.json', {}) if manual else {}
        started = now().isoformat()
        job = {'status': 'running', 'pid': os.getpid(), 'job_id': request.get('request_id', str(uuid.uuid4())),
               'actor': request.get('actor'), 'mode': 'manual-full' if manual else 'scheduled',
               'started_at': started, 'phase': 'Preparing', 'percent': None,
               'destination': 'Google Drive · encrypted system repository', 'process_started': process_identity(os.getpid()),
               'stages': [{'stage': 'Preparing', 'started_at': started}]}
        write(STATE / 'job.json', job)
        try:
            # Existing sealed point is resumed first, then tonight's fresh point.
            for _ in range(2):
                force_full = manual or (STATE / 'baseline-required.json').exists()
                manifest = capture('full' if force_full else None)
                job_update(label=manifest['label'])
                if not (SECRETS / 'rclone.conf').exists():
                    raise RuntimeError('Connect Google Drive. The sealed local recovery point is preserved for the next nightly upload.')
                result = retry(lambda: upload(manifest))
                if force_full and manifest.get('type') == 'full' and manifest['captured_at'] >= started:
                    (STATE / 'baseline-required.json').unlink(missing_ok=True)
                if manual and manifest.get('type') == 'full' and manifest['captured_at'] >= started or not manual and manifest['date'] == now().astimezone(DHAKA).date().isoformat():
                    break
            (STATE / 'queued.json').unlink(missing_ok=True)
            finished = {**read(STATE / 'job.json'), 'status': 'completed', 'phase': 'Completed', 'percent': 100,
                        'detail': 'The encrypted recovery point and required restore verification completed successfully.',
                        'completed_at': now().isoformat(), 'snapshot_id': result['snapshot_id'],
                        'duration_seconds': round((now() - dt.datetime.fromisoformat(started)).total_seconds()),
                        'total_bytes': result['processed_bytes'], 'processed_bytes': result['processed_bytes'],
                        'transferred_bytes': result['cloud_bytes_added']}
            write(STATE / 'job.json', finished)
            write(STATE / 'jobs.json', ([finished] + read(STATE / 'jobs.json', []))[:400])
            (STATE / 'manual-request.json').unlink(missing_ok=True)
            event('manual_full_backup_verified' if manual else 'nightly_backup_verified')
        except Exception as error:
            failed = {**read(STATE / 'job.json'), 'status': 'failed', 'phase': 'Failed', 'failed_at': now().isoformat(),
                      'error': str(error)[:400], 'duration_seconds': round((now() - dt.datetime.fromisoformat(started)).total_seconds())}
            write(STATE / 'job.json', failed)
            write(STATE / 'jobs.json', ([failed] + read(STATE / 'jobs.json', []))[:400])
            if manual:
                (STATE / 'manual-request.json').unlink(missing_ok=True)
            manifest = read(CAPTURE / 'manifest.json', {})
            history = read(STATE / 'history.json', [])
            for point in history:
                if point.get('label') == manifest.get('label') and point.get('status') != 'verified':
                    point.update(status='failed', error=str(error)[:400], available=False)
            write(STATE / 'history.json', history)
            event('manual_full_backup_failed' if manual else 'nightly_backup_failed')
            raise


if __name__ == '__main__':
    os.umask(0o077)
    try:
        if len(sys.argv) == 2 and sys.argv[1] == '--local-capture':
            with Lock(ROOT / 'deploy/.deployment.lock'):
                print(json.dumps(capture()))
        elif sys.argv[1:] == ['--manual-full']:
            nightly(manual=True)
        elif len(sys.argv) in (2, 3) and sys.argv[1] == '--resume-storage':
            if (STATE / 'storage-paused.json').exists():
                try:
                    with Lock(ROOT / 'deploy/.deployment.lock', blocking='--if-idle' not in sys.argv):
                        resume_storage()
                except BlockingIOError:
                    # A deployer already verified Storage health and owns configuration.
                    if '--if-idle' not in sys.argv:
                        raise
        elif len(sys.argv) == 1:
            nightly()
        else:
            raise RuntimeError('Usage: worker.py [--local-capture]')
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
