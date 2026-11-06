"""Existing-VPS updater. Standard library only; invoked over SSH, never on import."""
import datetime
import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import urllib.request
import urllib.error

SERVICES = ['db', 'auth', 'rest', 'realtime', 'imgproxy', 'storage', 'meta', 'studio', 'api-gw', 'attendance-receiver', 'account-service', 'caddy']
CORE_SERVICES = set(SERVICES) - {'studio', 'meta', 'attendance-receiver', 'account-service'}
EXCLUDED = ['frontend', 'functions', 'supavisor', 'mailpit']
ACCOUNTING_CUTOVER = '20261105020000'
STOCK_CUTOVERS = {'20261106023012', '20261106023014'}
PURCHASE_CASH_CUTOVER = '20261106113739'


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(args, label, *, data=None, output=None, stdin=None):
    result = subprocess.run(args, input=data, stdout=output or subprocess.PIPE,
                            stdin=stdin, stderr=subprocess.PIPE, env={'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin', 'HOME': '/root'})
    # Raw Compose/SQL output can contain credentials or user data. Never print it.
    require(result.returncode == 0, f'{label} failed (exit {result.returncode}); inspect privately on the VPS.')
    return result.stdout.decode() if output is None else ''


def apply_migration_batch(psql, sql, pending, compose, current, backup):
    """Quiesce reviewed migrations that switch accounting or stock writers.

    The caller already holds the deployment/backup lock and verified all services.
    Keep recovery intent beside the fresh dump; always restore prior cron/runtime
    intent if SQL fails. A process/host interruption needs that recorded recovery.
    """
    if not ({ACCOUNTING_CUTOVER, PURCHASE_CASH_CUTOVER} | STOCK_CUTOVERS).intersection(version for version, _ in pending):
        run(psql + ['--single-transaction', '-f', '-'], 'Approved migrations (entire batch is transactional)', data=sql.encode())
        return
    writers = [name for name in ['rest', 'account-service', 'attendance-receiver'] if name in current]
    jobs = json.loads(run(psql + ['-c', "select coalesce(json_agg(json_build_object('id',jobid,'active',active)),'[]') from cron.job"], 'Capture scheduler intent'))
    intent = backup / 'accounting-cutover.json'
    intent.write_text(json.dumps({'services': writers, 'cron': jobs, 'phase': 'pausing'}, indent=2))
    intent.chmod(0o600)
    print('Pausing transaction writers for the reviewed accounting or stock cutover.', flush=True)
    try:
        for job in jobs:
            if job['active']:
                run(psql + ['-c', f"select cron.alter_job({int(job['id'])},active=>false)"], 'Pause scheduled database writer')
        run(compose + ['stop', '--timeout', '30', *writers], 'Drain application transaction writers')
        for _ in range(30):
            active = int(run(psql + ['-c', "select (select count(*) from pg_stat_activity a where a.datname=current_database() and a.pid<>pg_backend_pid() and ((a.usename='authenticator' and a.backend_type='client backend') or (a.application_name like 'pg_cron%' and a.state='active') or exists(select 1 from cron.job_run_details j where j.job_pid=a.pid and j.end_time is null and j.status in ('starting','running'))))+(select count(*) from cron.job_run_details where end_time is null and (status='starting' or status='running' and job_pid is null))"], 'Drain scheduled database writers').strip())
            if active == 0:
                break
            time.sleep(1)
        else:
            raise RuntimeError('Existing API or scheduled transactions did not drain; migration was not applied.')
        # Capture the exact quiesced source as well as the updater's earlier dump.
        dump = backup / 'quiesced-accounting.dump'
        db_name = psql[psql.index('-d') + 1]
        with dump.open('wb') as output:
            dump.chmod(0o600)
            run(compose + ['exec', '-T', 'db', 'pg_dump', '-U', 'supabase_admin', '-d', db_name, '-Fc'], 'Quiesced accounting recovery point', output=output)
        with dump.open('rb') as source:
            run(compose + ['exec', '-T', 'db', 'pg_restore', '--list'], 'Validate quiesced recovery archive', stdin=source)
        run(psql + ['--single-transaction', '-f', '-'], 'Approved migrations (entire batch is transactional)', data=sql.encode())
    finally:
        errors = []
        try:
            run(compose + ['up', '-d', '--no-deps', '--no-recreate', '--wait', '--wait-timeout', '180', *writers], 'Resume transaction writers')
        except Exception:
            errors.append('transaction writers')
        for job in jobs:
            try:
                run(psql + ['-c', f"select cron.alter_job({int(job['id'])},active=>{'true' if job['active'] else 'false'})"], 'Restore scheduler intent')
            except Exception:
                errors.append('scheduler')
        intent.write_text(json.dumps({'services': writers, 'cron': jobs, 'phase': 'recovery_required' if errors else 'resumed'}, indent=2))
        intent.chmod(0o600)
        require(not errors, 'Accounting cutover runtime restoration failed; recover using private accounting-cutover.json before accepting writes.')


def content(path):
    return path.read_text(encoding='utf-8-sig').replace('\r\n', '\n')


def digest(path):
    return hashlib.sha256(content(path).encode()).hexdigest()


def validate_model(model):
    enabled = {name for name, service in model['services'].items() if not service.get('profiles')}
    require(enabled == set(SERVICES), 'Compose must enable exactly the reviewed backend services.')
    for name in SERVICES:
        service = model['services'][name]
        require(not service.get('build') or (name == 'db' and service['image'] == 'lpg-postgres-backup:17.6.1.140-pgbackrest2.57.0'
                and service['build']['context'].endswith('/deploy/backup') and service['build']['dockerfile'] == 'Dockerfile'), f'Unexpected image build: {name}.')
        require(set(service.get('depends_on', {})) <= set(SERVICES), f'Excluded dependency of {name}.')
        for port in service.get('ports', []):
            if name == 'caddy':
                require(port.get('host_ip') == '0.0.0.0' and port.get('protocol', 'tcp') == 'tcp'
                        and int(port['target']) == int(port['published']) in (80, 443), 'Only Caddy TCP 80/443 may be public.')
            else:
                require(port.get('host_ip') in ('127.0.0.1', '::1'), f'Internal service publicly published: {name}.')
    for key, name in [('lpg_db_data', 'lpg_db_data'), ('lpg_storage_data', 'lpg_storage_data'), ('db-config', 'lpg_db-config')]:
        volume = model['volumes'][key]
        require(volume.get('external') and volume['name'] == name, f'Persistent volume changed: {key}.')


def migration_plan(files, applied, previous, receipts):
    versions = {}
    for path in files:
        match = re.fullmatch(r'(\d{14})_([a-zA-Z0-9_]+)\.sql', path.name)
        require(match is not None, f'Invalid migration filename: {path.name}.')
        version = match[1]
        require(version not in versions, f'Duplicate migration version: {version}.')
        versions[version] = path
    require(set(applied) <= set(versions), 'Production contains migrations absent from this checkout. Use the correct source revision; do not repair history.')
    for version in applied:
        path = versions[version]
        old = previous / path.name
        expected = receipts.get(version)
        if expected:
            require(digest(path) == expected, f'Applied migration changed: {version}. Add a forward migration.')
        else:
            require(old.is_file() and digest(path) == digest(old), f'Applied migration source missing or changed: {version}. Review historical source; do not repair history.')
    pending = sorted(set(versions) - set(applied))
    require(not applied or all(version > max(applied) for version in pending), 'Out-of-order migration refused. Add a new forward version.')
    return [(version, versions[version]) for version in pending]


def validate_sql(sql):
    # Mask SQL strings, quoted identifiers, comments and dollar-quoted function
    # bodies before looking for top-level transaction control. Future migrations
    # must let this runner own the transaction and cannot execute psql commands.
    require(not re.search(r'^\s*\\', sql, re.M), 'psql meta commands are prohibited in deployment migrations.')
    tokens = re.compile(r"--[^\n]*|/\*|\$(?:[A-Za-z_][A-Za-z0-9_]*)?\$|'|\"")
    index = 0
    visible = []
    while match := tokens.search(sql, index):
        visible.append(sql[index:match.start()])
        marker = match[0]
        index = match.end()
        if marker.startswith('--'):
            continue
        if marker == '/*':
            depth = 1
            while depth:
                comment = re.search(r'/\*|\*/', sql[index:])
                require(comment is not None, 'Unclosed SQL comment.')
                depth += 1 if comment[0] == '/*' else -1
                index += comment.end()
        elif marker in ("'", '"'):
            while True:
                end = sql.find(marker, index)
                require(end >= 0, 'Unclosed SQL string.')
                index = end + 1
                if index < len(sql) and sql[index] == marker:
                    index += 1
                    continue
                break
        else:
            end = sql.find(marker, index)
            require(end >= 0, 'Unclosed dollar-quoted SQL body.')
            index = end + len(marker)
        visible.append(' ')
    visible.append(sql[index:])
    top = ''.join(visible)
    require(not re.search(r'(?:^|;)\s*(BEGIN|COMMIT|END|ROLLBACK|ABORT|START\s+TRANSACTION|PREPARE\s+TRANSACTION)\b', top, re.I),
            'Top-level transaction control is prohibited. Omit BEGIN/COMMIT from new migrations.')
    require(not re.search(r'\b(VACUUM|CONCURRENTLY)\b', top, re.I), 'Nontransactional SQL needs a separate reviewed maintenance procedure.')


def sql_literal(value):
    return "'" + value.replace("'", "''") + "'"


def configure_attendance_token(root, model, write=True):
    # The receiver gets only a role-scoped JWT, never the signing secret or the
    # service role key. Regenerate when the backend signing secret changes.
    secret = model['services']['auth']['environment']['GOTRUE_JWT_SECRET']
    encode = lambda value: base64.urlsafe_b64encode(value).decode().rstrip('=')
    header = encode(b'{"alg":"HS256","typ":"JWT"}')
    claims = encode(b'{"role":"attendance_receiver","iss":"supabase","exp":4102444800}')
    message = header + '.' + claims
    token = message + '.' + encode(hmac.new(secret.encode(), message.encode(), hashlib.sha256).digest()) + '\n'
    target = root / 'deploy/.attendance-token'
    changed = not target.exists() or content(target) != token
    if changed and write:
        temporary = target.with_suffix('.new')
        temporary.write_text(token, encoding='utf-8')
        temporary.chmod(0o400)
        os.chown(temporary, 1000, 1000)
        temporary.replace(target)
    return changed


def validate_proxy(model, source):
    run(['docker', 'run', '--rm', '--pull', 'never', '--network', 'none',
         '-e', 'API_DOMAIN=' + model['services']['caddy']['environment']['API_DOMAIN'],
         '-v', str(source / 'deploy/Caddyfile') + ':/etc/caddy/Caddyfile:ro',
         '--entrypoint', 'caddy', model['services']['caddy']['image'],
         'validate', '--config', '/etc/caddy/Caddyfile'], 'Validate proxy configuration before activation')


def configure_account_service(root, model, write=True):
    gateway = model['services']['api-gw']['environment']
    settings = {'apiURL': 'http://api-gw:8000', 'publicKey': gateway['ANON_KEY'],
                'serviceKey': gateway['SERVICE_ROLE_KEY'],
                'origins': ['https://floral-dew-443b.khandakarsifat.workers.dev',
                            model['services']['api-gw']['environment']['SUPABASE_PUBLIC_URL'].rstrip('/')]}
    target = root / 'deploy/.account-service.json'
    desired = json.dumps(settings, sort_keys=True) + '\n'
    changed = not target.exists() or content(target) != desired
    if changed and write:
        temporary = target.with_suffix('.new')
        temporary.write_text(desired, encoding='utf-8')
        temporary.chmod(0o400)
        os.chown(temporary, 1000, 1000)
        temporary.replace(target)
    return changed


def verify_health(model, api_url):
    key = model['services']['api-gw']['environment']['ANON_KEY']
    for path in ['/auth/v1/health', '/rest/v1/items?select=*&limit=0', '/storage/v1/status']:
        request = urllib.request.Request(api_url + path, headers={'apikey': key, 'Authorization': 'Bearer ' + key})
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                require(not path.startswith('/rest/') and response.status == 200, f'Public HTTPS/authorization health check failed: {path}.')
        except urllib.error.HTTPError as error:
            with error:
                require(path.startswith('/rest/') and error.code in (401, 403)
                        and json.load(error).get('code') == '42501', f'Unexpected API error or anonymous authorization response: {path}.')
    # Studio must challenge anonymous visitors and accept only the existing login.
    try:
        with urllib.request.urlopen(api_url + '/', timeout=20):
            raise RuntimeError('Dashboard is reachable without authentication.')
    except urllib.error.HTTPError as error:
        with error:
            require(error.code == 401, 'Dashboard must require HTTP Basic authentication.')
    login = model['services']['api-gw']['environment']
    credentials = (login['DASHBOARD_USERNAME'] + ':' + login['DASHBOARD_PASSWORD']).encode()
    request = urllib.request.Request(api_url + '/project/default', headers={
        'Authorization': 'Basic ' + base64.b64encode(credentials).decode()})
    with urllib.request.urlopen(request, timeout=30) as response:
        require(response.status == 200 and b'/_next/' in response.read(), 'Authenticated Studio page verification failed.')


def deploy(root, stage, project, api_url, approval):
    import fcntl
    require(root.is_dir() and root.resolve() == root, 'Existing VPS project directory required.')
    require(stage.is_dir() and stage.resolve() == stage and str(stage).startswith('/tmp/lpg-deploy.'), 'Invalid staging directory.')
    env_file = root / '.env'
    require(env_file.is_file() and not env_file.is_symlink(), 'Existing production .env required; never upload a development environment.')
    require(env_file.stat().st_mode & 0o077 == 0, 'Production .env must be private (chmod 600).')
    require(all((root / file).is_file() for file in ['compose.yml', 'compose.vps.yml']), 'This command updates an existing VPS installation only.')
    (root / 'deploy').mkdir(exist_ok=True)
    with (root / 'deploy/.deployment.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('Another backend deployment is in progress.')
        update(root, stage, project, api_url, approval)


def update(root, stage, project, api_url, approval):
    def compose(source):
        return ['docker', 'compose', '--project-directory', str(root), '--env-file', str(root / '.env'), '-p', project,
                '-f', str(source / 'compose.yml'), '-f', str(source / 'compose.vps.yml')]

    old_cmd, candidate_cmd = compose(root), compose(stage)
    # Inspect disabled definitions too when promoting Studio/meta into production.
    # This activates profiles only for config rendering, not service startup.
    old = json.loads(run(old_cmd + ['--profile', '*', 'config', '--format', 'json'], 'Existing production Compose validation'))
    candidate = json.loads(run(candidate_cmd + ['--profile', '*', 'config', '--format', 'json'], 'Candidate production Compose validation'))
    validate_model(candidate)
    require(candidate['services']['api-gw']['environment']['SUPABASE_PUBLIC_URL'].rstrip('/') == api_url, 'VPS API URL differs from deployment configuration.')
    require(candidate['services']['auth']['environment']['GOTRUE_SITE_URL'].rstrip('/') == 'https://floral-dew-443b.khandakarsifat.workers.dev', 'VPS Auth Site URL does not match the existing Worker.')
    dashboard = candidate['services']['api-gw']['environment']
    require(bool(dashboard.get('DASHBOARD_USERNAME')) and len(dashboard.get('DASHBOARD_PASSWORD', '')) >= 12
            and dashboard['DASHBOARD_PASSWORD'] not in ('replace-with-existing-or-generated-value', 'this_password_is_insecure'),
            'A configured strong dashboard login is required before exposing Studio.')
    # Refuse database image upgrades and all volume remapping, including Caddy TLS.
    require(old['volumes'] == candidate['volumes'], 'Compose volume definitions changed. Separate review required.')
    for name in SERVICES:
        if name not in old['services']:
            require(name in ('attendance-receiver', 'account-service'), 'Unexpected new backend service.')
            continue
        before, after = old['services'][name], candidate['services'][name]
        # Only these backup additions are allowed. Existing data mounts cannot change.
        additions = {'db': {'/etc/pgbackrest/pgbackrest.conf': str(root / 'deploy/backup/pgbackrest.conf'),
                            '/var/lib/lpg-backup': str(root / 'backups/cloud')},
                     'account-service': {'/run/lpg-backup': '/run/lpg-backup'}}.get(name, {})
        filtered = [mount for mount in after.get('volumes', []) if not (mount['type'] == 'bind'
                    and additions.get(mount['target']) == mount['source']
                    and (mount['target'] == '/var/lib/lpg-backup' or mount.get('read_only')))]
        previous = [mount for mount in before.get('volumes', []) if not (mount['type'] == 'bind'
                    and additions.get(mount['target']) == mount['source']
                    and (mount['target'] == '/var/lib/lpg-backup' or mount.get('read_only')))]
        require(before.get('volumes') == after.get('volumes') or previous == filtered, f'{name} mount definitions changed. Separate review required.')
    backup_image = 'lpg-postgres-backup:17.6.1.140-pgbackrest2.57.0'
    original_image = 'public.ecr.aws/supabase/postgres:17.6.1.140'
    adding_backup = old['services']['db']['image'] == original_image and candidate['services']['db']['image'] == backup_image
    require(old['services']['db']['image'] == candidate['services']['db']['image'] or adding_backup, 'PostgreSQL image upgrade refused; use a reviewed upgrade procedure.')

    ids = run(old_cmd + ['--profile', '*', 'ps', '-q', *[s for s in SERVICES if s in old['services']]], 'Container discovery').split()
    require(len(CORE_SERVICES) <= len(ids) <= len(SERVICES), 'All eight core backend containers must be running; only reviewed supporting services may be added.')
    containers = json.loads(run(['docker', 'inspect', *ids], 'Existing container inspection'))
    current = {container['Config']['Labels']['com.docker.compose.service']: container for container in containers}
    require(CORE_SERVICES <= set(current) <= set(SERVICES) and len(current) == len(containers), 'Container service/project identity mismatch.')
    for name, container in current.items():
        require(container['Config']['Labels']['com.docker.compose.project'] == project, 'Compose project identity mismatch.')
        require(container['State']['Running'] and container['State'].get('Health', {}).get('Status', 'healthy') == 'healthy', f'Existing {name} is unhealthy; recover before deployment.')
    for name, destination, expected in [('db', '/var/lib/postgresql/data', 'lpg_db_data'), ('db', '/etc/postgresql-custom', 'lpg_db-config'), ('storage', '/var/lib/storage', 'lpg_storage_data')]:
        require(any(mount.get('Name') == expected and mount['Destination'] == destination for mount in current[name]['Mounts']), f'Unexpected existing {name} data volume.')
        run(['docker', 'volume', 'inspect', expected], 'External volume existence check')
    require(current['db']['Config']['Image'] == candidate['services']['db']['image'] or (adding_backup and current['db']['Config']['Image'] == original_image), 'Running database image differs; automatic database upgrade refused.')
    db_name = old['services']['db']['environment']['POSTGRES_DB']
    psql = old_cmd + ['exec', '-T', 'db', 'psql', '-X', '-U', 'supabase_admin', '-d', db_name, '-v', 'ON_ERROR_STOP=1', '-q', '-A', '-t']
    applied = run(psql + ['-c', 'select version from supabase_migrations.schema_migrations order by version'], 'Migration history inspection').split()
    receipt_file = root / 'deploy/.migration-checksums.json'
    receipts = json.loads(receipt_file.read_text()) if receipt_file.exists() else {}
    files = sorted((stage / 'supabase/migrations').glob('*.sql'))
    pending = migration_plan(files, applied, root / 'supabase/migrations', receipts)
    print('Pending migrations: ' + (', '.join(version for version, _ in pending) or 'none'), flush=True)
    approved = approval.split(',') if approval else []
    require(approved == [version for version, _ in pending], 'Review pending SQL, then explicitly approve exactly these versions with --approve-migrations=version,... (including any destructive effects). No services or data were changed.')
    for _, path in pending:
        validate_sql(content(path))

    uploaded = sorted(path for path in stage.rglob('*') if path.is_file())
    require(all(not path.is_symlink() for path in uploaded), 'Symlinks are prohibited in the deployment bundle.')
    changed = []
    for path in uploaded:
        relative = path.relative_to(stage)
        target = root / relative
        require(not target.is_symlink() and target.resolve().is_relative_to(root), 'Unsafe deployment destination.')
        if not target.exists() or digest(path) != digest(target):
            require(not str(relative).startswith('supabase/docker/volumes/db/'), 'Database initialization SQL changed; use a forward application migration instead.')
            changed.append(relative)
    affected = set()
    desired_hashes = dict(line.split() for line in run(candidate_cmd + ['config', '--hash', '*'], 'Desired service configuration hashes').splitlines())
    pending_file = root / 'deploy/.pending-services.json'
    if pending_file.exists():
        affected.update(json.loads(pending_file.read_text()))
        require(affected <= set(SERVICES), 'Invalid pending deployment service list.')
    for name in SERVICES:
        if (name not in current or old['services'][name] != candidate['services'][name]
                or current[name]['Config']['Image'] != candidate['services'][name]['image']
                or current[name]['Config']['Labels'].get('com.docker.compose.config-hash') != desired_hashes[name]):
            affected.add(name)
        for volume in candidate['services'][name].get('volumes', []):
            if volume['type'] == 'bind' and any(str(root / relative) == volume['source'] for relative in changed):
                affected.add(name)
    if configure_attendance_token(root, candidate, write=False):
        affected.add('attendance-receiver')
    if configure_account_service(root, candidate, write=False):
        affected.add('account-service')
    excluded_ids = run(old_cmd + ['--profile', '*', 'ps', '-q', *EXCLUDED], 'Excluded service discovery').split()
    changes_runtime = bool(affected or pending or excluded_ids)
    print('Affected services: ' + (', '.join(name for name in SERVICES if name in affected) or 'none'), flush=True)
    smtp = candidate['services']['auth']['environment']
    if smtp.get('GOTRUE_SMTP_HOST') == 'mailpit':
        require(smtp.get('GOTRUE_MAILER_AUTOCONFIRM') == 'true', 'Configure real SMTP in the VPS .env before excluding Mailpit: email confirmation currently requires it.')
        print('Mailpit excluded. Existing autoconfirm remains enabled; recovery/invitation emails require real VPS SMTP.', flush=True)

    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    backup = root / 'backups' / ('deployment-' + stamp)
    if changed or changes_runtime:
        backup.mkdir(parents=True, mode=0o700)
        for relative in changed:
            source = root / relative
            if source.is_file():
                destination = backup / 'files' / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, destination)
        if changes_runtime:
            with (backup / 'database.dump').open('wb') as output:
                run(old_cmd + ['exec', '-T', 'db', 'pg_dump', '-U', 'supabase_admin', '-d', db_name, '-Fc'], 'Pre-deployment database backup', output=output)
            with (backup / 'roles.sql').open('wb') as output:
                run(old_cmd + ['exec', '-T', 'db', 'pg_dumpall', '-U', 'supabase_admin', '--globals-only'], 'Database role backup', output=output)
            with (backup / 'database.dump').open('rb') as source:
                run(['docker', 'exec', '-i', current['db']['Id'], 'pg_restore', '--list'], 'Database backup archive validation', stdin=source)
        print(f'Private recovery files: {backup}', flush=True)

    # Only explicit runtime services/images are pulled; no dev dependencies.
    for name in SERVICES:
        if name in affected:
            if name == 'db' and candidate['services'][name].get('build'):
                run(['docker', 'build', '-t', candidate['services']['db']['image'], str(stage / 'deploy/backup')], 'Build backup client on unchanged PostgreSQL image')
            else:
                run(candidate_cmd + ['pull', name], f'Image availability for {name}')
    if 'caddy' in affected:
        validate_proxy(candidate, stage)
    configure_attendance_token(root, candidate)
    configure_account_service(root, candidate)
    # Persist affected services before replacing bind files so an interrupted
    # deployment can retry them even when source files already match next time.
    if affected:
        temporary = pending_file.with_suffix('.new')
        temporary.write_text(json.dumps(sorted(affected)) + '\n')
        temporary.replace(pending_file)
    for relative in changed:
        target = root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        temporary = target.with_name(target.name + '.deploy-new')
        temporary.write_text(content(stage / relative), encoding='utf-8', newline='\n')
        temporary.chmod(target.stat().st_mode & 0o777 if target.exists() else 0o644)
        temporary.replace(target)

    source_files = {str(path.relative_to(stage)): digest(path) for path in uploaded}
    source_version = {'backend_sha256': hashlib.sha256(json.dumps(source_files, sort_keys=True).encode()).hexdigest(),
                      'files': source_files, 'deployed_at': stamp}
    (root / 'deploy/.source-version.json').write_text(json.dumps(source_version, indent=2) + '\n')
    (root / 'deploy/.source-version.json').chmod(0o600)

    if candidate['services']['db']['image'] == backup_image:
        # Create mount sources and private control service before recreation.
        run(['python3', '-B', str(root / 'deploy/backup/install.py')], 'Configure private cloud backup control and nightly timer')

    if pending:
        sql = 'SET lock_timeout = \'10s\'; SET statement_timeout = \'5min\';\nLOCK TABLE supabase_migrations.schema_migrations IN EXCLUSIVE MODE;\n'
        for version, path in pending:
            source = content(path)
            name = path.stem[15:]
            sql += source + '\n;\n'
            sql += 'INSERT INTO supabase_migrations.schema_migrations(version, name, statements) VALUES (' + ', '.join([sql_literal(version), sql_literal(name), 'ARRAY[' + sql_literal(source) + ']']) + ');\n'
        sql += "NOTIFY pgrst, 'reload schema';\n"
        apply_migration_batch(psql, sql, pending, old_cmd, current, backup)
    # Record applied source hashes even if a subsequent health check fails.
    receipts.update({path.name[:14]: digest(path) for path in files})
    temporary = receipt_file.with_suffix('.new')
    temporary.write_text(json.dumps(receipts, indent=2) + '\n')
    temporary.chmod(0o600)
    temporary.replace(receipt_file)
    for name in SERVICES:
        if name in affected:
            # Bind-mounted config content is not part of Compose's config hash.
            run(old_cmd + ['up', '-d', '--no-deps', '--no-build', '--pull', 'never', '--force-recreate', '--wait', '--wait-timeout', '180', name], f'Update and health check for {name}')
    if excluded_ids:
        run(['docker', 'stop', *excluded_ids], 'Stop excluded development/optional services (no volumes removed)')
    run(old_cmd + ['up', '-d', '--no-deps', '--no-build', '--pull', 'never', '--no-recreate', '--wait', '--wait-timeout', '180', *SERVICES], 'Final health verification (no recreation)')
    verify_health(candidate, api_url)
    if candidate['services']['db']['image'] == backup_image:
        run(old_cmd + ['exec', '-T', '--user', 'postgres', 'db', 'pgbackrest', '--stanza=lpg', 'stanza-create'], 'Initialize physical backup stanza')
        run(old_cmd + ['exec', '-T', '--user', 'postgres', 'db', 'pgbackrest', '--stanza=lpg', 'check'], 'Verify local WAL archiving')
    pending_file.unlink(missing_ok=True)
    print('Twelve backend services verified; data volumes and VPS environment preserved.', flush=True)


if __name__ == '__main__':
    os.umask(0o077)
    try:
        require(len(sys.argv) == 6, 'Invalid backend deployment arguments.')
        deploy(Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5])
    except Exception as error:
        # URL errors can include a public URL, but never headers/SQL/Compose env.
        print(f'Backend deployment error: {error}', file=sys.stderr, flush=True)
        sys.exit(1)
