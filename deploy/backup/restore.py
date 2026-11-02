"""Read cloud snapshot and perform a physical cluster restore on an isolated network.

No live volume mounts, external network, public listeners, or live SQL writes.
Invoked only by the nightly worker; original-VPS-independent steps are in recovery.md.
"""
import argparse
import json
import os
from pathlib import Path
import secrets
import shutil
import tempfile
import time
import urllib.request
import urllib.error

from core import ROOT, SECRETS, STATE, command, now, read, restic, write
from worker import tree_hashes


def drill(snapshot, local_repo=None):
    if not snapshot or not all(c in '0123456789abcdef' for c in snapshot) or len(snapshot) not in (8, 64):
        raise RuntimeError('A specific cloud snapshot ID is required.')
    # A fresh directory and new container/network identities are mandatory.
    identity = 'lpg-recovery-drill-' + secrets.token_hex(5)
    if local_repo:
        if Path(local_repo).resolve() != STATE / 'validation-repository':
            raise RuntimeError('Local validation may use only the dedicated validation repository.')
        def repository(*args):
            return command(['restic', '--repo', local_repo, '--password-file', SECRETS / 'restic-password', *args], env={'GOMAXPROCS': '2'}, timeout=86400)
    else:
        repository = restic
    with tempfile.TemporaryDirectory(prefix='restore-', dir=STATE) as temporary:
        work = Path(temporary)
        command(['docker', 'network', 'create', '--internal', identity])
        names = []
        try:
            repository('restore', snapshot, '--target', str(work / 'download'), '--verify')
            captured = work / 'download' / str(STATE / 'capture').lstrip('/')
            manifest = read(captured / 'manifest.json')
            expected = read(captured / 'file-hashes.json')
            for name, hashes in expected.items():
                if tree_hashes(captured / name) != hashes:
                    raise RuntimeError('Restored ' + name + ' files differ from the captured SHA256 inventory.')
            data = work / 'postgres'
            data.mkdir(mode=0o700)
            os.chown(data, 100, 101)
            # Downloaded repo/config become readable only inside the throwaway container.
            command(['chmod', 'o+x', work, work / 'download'])
            repo = captured / 'pgbackrest'
            image = manifest['postgres_image']
            common = ['docker', 'run', '--rm', '--network', 'none', '--user', '0', '--memory', '512m', '--cpus', '1',
                '-v', str(repo) + ':/repo:ro', '-v', str(data) + ':/restore', '--entrypoint', 'pgbackrest', image]
            command([*common, '--stanza=lpg', '--repo1-path=/repo', '--pg1-path=/restore',
                '--set=' + manifest['label'], '--type=immediate', '--target-action=promote',
                '--log-level-console=warn', 'restore'])
            command(['chown', '-R', '100:101', data])
            config_dir = captured / 'config'
            # Compose render only; do not start the saved deployment or bind any live paths.
            model = json.loads(command(['docker', 'compose', '--project-directory', config_dir,
                '--env-file', config_dir / '.env', '-f', config_dir / 'compose.yml', '-f', config_dir / 'compose.vps.yml',
                '--profile', '*', 'config', '--format', 'json']))
            db_name = identity + '-db'
            names.append(db_name)
            env_file = work / 'database.env'
            env_file.write_text('\n'.join(k + '=' + str(v) for k, v in model['services']['db']['environment'].items()) + '\n')
            env_file.chmod(0o600)
            db_config = captured / 'volumes/lpg_db-config'
            command(['docker', 'run', '-d', '--name', db_name, '--network', identity, '--network-alias', 'db',
                '--memory', '768m', '--cpus', '1', '--env-file', env_file,
                '-v', str(data) + ':/var/lib/postgresql/data', '-v', str(repo) + ':/repo:ro',
                '-v', str(db_config) + ':/etc/postgresql-custom', image, 'postgres',
                '-c', 'config_file=/etc/postgresql/postgresql.conf', '-c', 'archive_mode=off',
                '-c', 'cron.launch_active_jobs=off', '-c', 'shared_buffers=64MB', '-c', 'max_connections=40',
                '-c', 'restore_command=pgbackrest --stanza=lpg --repo1-path=/repo archive-get %f "%p"'])
            ready = False
            for _ in range(90):
                try:
                    command(['docker', 'exec', db_name, 'pg_isready', '-U', 'supabase_admin'], timeout=5)
                    ready = True
                    break
                except RuntimeError:
                    time.sleep(2)
            if not ready:
                raise RuntimeError('Isolated physical recovery did not become ready.')
            # Fingerprints are generated independently in the restored cluster. No data is logged.
            sql = """select json_build_object(
                'recovery_finished', not pg_is_in_recovery(),
                'businesses', (select count(*) from public.tenants),
                'auth_users', (select count(*) from auth.users),
                'identities', (select count(*) from auth.identities),
                'storage_objects', (select count(*) from storage.objects),
                'journals', (select count(*) from public.accounting_journals),
                'rls_tables', (select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relrowsecurity),
                'roles', (select count(*) from pg_roles),
                'migrations', (select count(*) from supabase_migrations.schema_migrations),
                'constraints', (select count(*) from pg_constraint where connamespace='public'::regnamespace),
                'journal_imbalance', (select count(*) from (select journal_id from public.accounting_lines group by journal_id having abs(sum(amount))>0.001) x))"""
            result = json.loads(command(['docker', 'exec', db_name, 'psql', '-X', '-U', 'supabase_admin', '-d', 'postgres', '-At', '-v', 'ON_ERROR_STOP=1', '-c', sql]))
            if not result['recovery_finished'] or not result['businesses'] or result['rls_tables'] < 10 or not result['migrations'] or result['journal_imbalance']:
                raise RuntimeError('Isolated database recovery assertions failed.')
            # Bring up restored Auth/REST/Storage inside the private network using saved secrets.
            for service in ['rest', 'auth', 'imgproxy', 'storage']:
                spec = model['services'][service]
                environment = work / (service + '.env')
                environment.write_text('\n'.join(k + '=' + str(v) for k, v in spec.get('environment', {}).items()) + '\n')
                environment.chmod(0o600)
                name = identity + '-' + service
                names.append(name)
                args = ['docker', 'run', '-d', '--name', name, '--network', identity, '--network-alias', service,
                    '--memory', '256m', '--cpus', '0.5', '--env-file', environment]
                if service in ['storage', 'imgproxy']:
                    args += ['-v', str(captured / 'storage') + ':/var/lib/storage']
                args += [spec['image']]
                if service == 'rest':
                    args += spec.get('command', [])
                command(args)
            # wget inside Storage sees only the isolated network; retries never target live services.
            for service, url in [('storage', 'http://127.0.0.1:5000/status'), ('auth', 'http://127.0.0.1:9999/health')]:
                ready = False
                for _ in range(60):
                    try:
                        if service == 'auth':
                            command(['docker', 'exec', identity + '-auth', 'wget', '-qO-', url], timeout=5)
                        else:
                            command(['docker', 'exec', identity + '-storage', 'wget', '-qO-', url], timeout=5)
                        ready = True
                        break
                    except RuntimeError:
                        time.sleep(2)
                if not ready:
                    raise RuntimeError('Restored ' + service + ' did not pass isolated health checks.')
            def address(service, port):
                inspected = json.loads(command(['docker', 'inspect', identity + '-' + service]))[0]
                if set(inspected['NetworkSettings']['Networks']) != {identity} or inspected['HostConfig'].get('PortBindings'):
                    raise RuntimeError('Recovery network isolation failed.')
                return 'http://' + inspected['NetworkSettings']['Networks'][identity]['IPAddress'] + ':' + str(port)

            def http(url, headers, body=None):
                with urllib.request.urlopen(urllib.request.Request(url, data=body, headers=headers), timeout=20) as response:
                    return response.read()

            public_key = model['services']['storage']['environment']['ANON_KEY']
            service_key = model['services']['storage']['environment']['SERVICE_KEY']
            api_headers = {'apikey': public_key, 'Content-Type': 'application/json'}
            rest_url = address('rest', 3000)
            storage_url = address('storage', 5000)
            auth_url = address('auth', 9999)
            acceptance = read(SECRETS / 'acceptance.json')
            if acceptance:
                session = json.loads(http(auth_url + '/token?grant_type=password', api_headers,
                    json.dumps({'email': acceptance['email'], 'password': acceptance['password']}).encode()))
                member_headers = {**api_headers, 'Authorization': 'Bearer ' + session['access_token']}
                context = json.loads(http(rest_url + '/rpc/get_access_context', member_headers, b'{}'))
                tenant = context.get('tenant_id')
                if not tenant or context.get('is_superadmin') or context.get('access_status') != 'active':
                    raise RuntimeError('Restored burner Auth/membership assertions failed.')
                foreign = json.loads(http(rest_url + '/items?select=item_id&tenant_id=neq.' + tenant, member_headers))
                if foreign:
                    raise RuntimeError('Restored tenant RLS returned foreign items.')
            # Validate actual Storage bytes, not just metadata/health. Service key stays internal.
            objects = json.loads(command(['docker', 'exec', db_name, 'psql', '-X', '-U', 'supabase_admin', '-d', 'postgres', '-At', '-c',
                "select coalesce(json_agg(json_build_object('bucket',bucket_id,'name',name)),'[]') from storage.objects"]))
            files_verified = 0
            for obj in objects:
                from urllib.parse import quote
                path = quote(obj['bucket'], safe='') + '/' + quote(obj['name'], safe='/')
                content = http(storage_url + '/object/authenticated/' + path,
                    {**api_headers, 'Authorization': 'Bearer ' + service_key})
                import hashlib
                digest = hashlib.sha256(content).hexdigest()
                if digest not in expected['storage'].values():
                    raise RuntimeError('Restored Storage download does not match the captured object bytes.')
                if acceptance and not obj['name'].startswith(tenant + '/'):
                    try:
                        http(storage_url + '/object/authenticated/' + path, member_headers)
                    except urllib.error.HTTPError as error:
                        if error.code not in (400, 401, 403, 404):
                            raise RuntimeError('Unexpected Storage authorization response.')
                    else:
                        raise RuntimeError('Restored Storage exposed another tenant object.')
                files_verified += 1
            write(STATE / ('local-restore.json' if local_repo else 'restore.json'), {'verified_at': now().isoformat(), 'snapshot_id': snapshot,
                'label': manifest['label'], 'database': result, 'files_verified': True,
                'storage_downloads_verified': files_verified, 'burner_auth_and_rls': bool(acceptance),
                'auth_health': True, 'storage_health': True, 'network': 'isolated; no public ports',
                'limitation': 'Physical restore and internal service health; frontend cutover and external providers require operator acceptance.'})
        finally:
            for name in reversed(names):
                command(['docker', 'rm', '-f', name])
            command(['docker', 'network', 'rm', identity])


if __name__ == '__main__':
    os.umask(0o077)
    parser = argparse.ArgumentParser()
    parser.add_argument('--snapshot', required=True)
    parser.add_argument('--local-repo')
    args = parser.parse_args()
    drill(args.snapshot, args.local_repo)
