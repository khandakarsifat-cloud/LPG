"""Verify/decrypt a recovery bundle and restore only to a new disposable DB."""
import hashlib
import hmac
import json
import os
from pathlib import Path
import sys
import tarfile
import tempfile
import uuid

from backend import require, run, sql_literal


def check(bundle):
    root = Path('/opt/lpg')
    require(os.geteuid() == 0 and bundle.resolve().parent == root / 'backups'
            and bundle.name.startswith('recovery-') and bundle.name.endswith('.tar.gz.enc'), 'Expected a private primary-VPS recovery bundle.')
    key = root / 'deploy/.backup-key'
    signature = hmac.new(key.read_bytes(), digestmod=hashlib.sha256)
    with bundle.open('rb') as source:
        while block := source.read(1024 * 1024):
            signature.update(block)
    require(hmac.compare_digest(signature.hexdigest(), bundle.with_suffix(bundle.suffix + '.hmac').read_text().strip()), 'Recovery bundle authentication failed.')
    cmd = ['docker', 'compose', '--project-directory', str(root), '--env-file', str(root / '.env'), '-p', 'lpg', '-f', str(root / 'compose.yml'), '-f', str(root / 'compose.vps.yml')]
    model = json.loads(run(cmd + ['config', '--format', 'json'], 'Restore-check target'))
    require(model['services']['api-gw']['environment']['SUPABASE_PUBLIC_URL'] == 'https://api.lpg.144.79.249.4.sslip.io', 'Restore-check target mismatch.')
    db = 'lpg_restore_' + uuid.uuid4().hex[:16]
    psql = cmd + ['exec', '-T', 'db', 'psql', '-X', '-U', 'supabase_admin', '-v', 'ON_ERROR_STOP=1', '-qAt']
    with tempfile.TemporaryDirectory(prefix='.restore-check-', dir=root / 'backups') as temporary:
        work = Path(temporary)
        run(['openssl', 'enc', '-d', '-aes-256-cbc', '-pbkdf2', '-iter', '200000', '-pass', 'file:' + str(key), '-in', str(bundle), '-out', str(work / 'recovery.tar.gz')], 'Decrypt authenticated recovery bundle')
        with tarfile.open(work / 'recovery.tar.gz') as archive:
            archive.extractall(work, filter='data')
        with tarfile.open(work / 'volumes.tar.gz') as archive:
            names = archive.getnames()
            require(all(not n.startswith('/') and '..' not in Path(n).parts for n in names), 'Unsafe recovery volume archive.')
            for volume in ['lpg_storage_data', 'lpg_db-config', 'lpg_caddy-data', 'lpg_caddy-config']:
                require(any(n == volume or n.startswith(volume + '/') for n in names), 'Missing recovery volume ' + volume)
            fixture = work / 'config/deploy/.storage-verification.json'
            storage_fixture = json.loads(fixture.read_text()) if fixture.exists() else None
            if storage_fixture:
                require(storage_fixture['bucket'].startswith('lpg-migration-fixture-'), 'Unexpected Storage verification fixture.')
                expected = b'LPG new VPS private Storage persistence fixture\n'
                require(any(member.isfile() and storage_fixture['bucket'] in member.name
                            and archive.extractfile(member).read() == expected for member in archive.getmembers()),
                        'Private Storage fixture bytes missing from recovery archive.')
        created = False
        try:
            run(psql + ['-d', 'postgres', '-c', 'CREATE DATABASE ' + db + ' TEMPLATE template0'], 'Create isolated restore database')
            created = True
            with (work / 'database.dump').open('rb') as source:
                run(cmd + ['exec', '-T', 'db', 'pg_restore', '-U', 'supabase_admin', '-d', db, '--clean', '--if-exists', '--exit-on-error', '--single-transaction'], 'Restore full recovery database in isolation', stdin=source)
            result = run(psql + ['-d', db, '-c', "select json_build_object('migrations',(select count(*) from supabase_migrations.schema_migrations),'tables',(select count(*) from pg_tables where schemaname='public'),'unprotected',(select count(*) from pg_tables where schemaname='public' and not rowsecurity))"], 'Restored schema verification').strip()
            summary = json.loads(result)
            require(summary['migrations'] > 0 and summary['tables'] > 0 and summary['unprotected'] == 0, 'Restored schema/history/RLS verification failed.')
            if storage_fixture:
                rows = run(psql + ['-d', db, '-c', 'select count(*) from storage.objects where bucket_id=' + sql_literal(storage_fixture['bucket'])], 'Restored Storage metadata verification').strip()
                require(rows == '1', 'Restored private Storage metadata mismatch.')
                print('Private Storage fixture bytes and restored metadata verified.', flush=True)
            print('Authenticated encrypted backup restored to an isolated database: ' + result, flush=True)
        finally:
            if created:
                run(psql + ['-d', 'postgres', '-c', 'DROP DATABASE ' + db + ' WITH (FORCE)'], 'Remove only the newly created restore-check database')


if __name__ == '__main__':
    os.umask(0o077)
    try:
        require(len(sys.argv) == 2, 'Usage: restore-check.py /opt/lpg/backups/recovery-<UTC>.tar.gz.enc')
        check(Path(sys.argv[1]))
    except Exception as error:
        print('Restore check failed: ' + str(error), file=sys.stderr)
        sys.exit(1)
