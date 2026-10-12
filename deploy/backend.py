"""Existing-VPS updater. Standard library only; invoked over SSH, never on import."""
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import urllib.request
import urllib.error

SERVICES = ['db', 'auth', 'rest', 'realtime', 'imgproxy', 'storage', 'api-gw', 'caddy']
EXCLUDED = ['frontend', 'studio', 'meta', 'functions', 'supavisor', 'mailpit']


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(args, label, *, data=None, output=None, stdin=None):
    result = subprocess.run(args, input=data, stdout=output or subprocess.PIPE,
                            stdin=stdin, stderr=subprocess.PIPE, env={'PATH': os.defpath, 'HOME': '/root'})
    # Raw Compose/SQL output can contain credentials or user data. Never print it.
    require(result.returncode == 0, f'{label} failed (exit {result.returncode}); inspect privately on the VPS.')
    return result.stdout.decode() if output is None else ''


def content(path):
    return path.read_text(encoding='utf-8-sig').replace('\r\n', '\n')


def digest(path):
    return hashlib.sha256(content(path).encode()).hexdigest()


def validate_model(model):
    enabled = {name for name, service in model['services'].items() if not service.get('profiles')}
    require(enabled == set(SERVICES), 'Compose must enable exactly the eight production services.')
    for name in SERVICES:
        service = model['services'][name]
        require(not service.get('build'), f'Unexpected image build: {name}.')
        require(set(service.get('depends_on', {})) <= set(SERVICES), f'Excluded dependency of {name}.')
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
    require(not re.search(r'\b(BEGIN|COMMIT|END|ROLLBACK|ABORT|START\s+TRANSACTION|PREPARE\s+TRANSACTION)\b', top, re.I),
            'Top-level transaction control is prohibited. Omit BEGIN/COMMIT from new migrations.')
    require(not re.search(r'\b(VACUUM|CONCURRENTLY)\b', top, re.I), 'Nontransactional SQL needs a separate reviewed maintenance procedure.')


def sql_literal(value):
    return "'" + value.replace("'", "''") + "'"


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


def deploy(root, stage, project, api_url, approval):
    import fcntl
    require(root.is_dir() and root.resolve() == root, 'Existing VPS project directory required.')
    require(stage.is_dir() and stage.resolve() == stage and str(stage).startswith('/tmp/lpg-deploy.'), 'Invalid staging directory.')
    env_file = root / '.env'
    require(env_file.is_file() and not env_file.is_symlink(), 'Existing production .env required; never upload a development environment.')
    require(env_file.stat().st_mode & 0o077 == 0, 'Production .env must be private (chmod 600).')
    require(all((root / file).is_file() for file in ['compose.yml', 'compose.azure.yml']), 'This command updates an existing Azure installation only.')
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
                '-f', str(source / 'compose.yml'), '-f', str(source / 'compose.azure.yml')]

    old_cmd, candidate_cmd = compose(root), compose(stage)
    old = json.loads(run(old_cmd + ['config', '--format', 'json'], 'Existing production Compose validation'))
    candidate = json.loads(run(candidate_cmd + ['config', '--format', 'json'], 'Candidate production Compose validation'))
    validate_model(candidate)
    require(candidate['services']['api-gw']['environment']['SUPABASE_PUBLIC_URL'].rstrip('/') == api_url, 'VPS API URL differs from deployment configuration.')
    require(candidate['services']['auth']['environment']['GOTRUE_SITE_URL'].rstrip('/') == 'https://floral-dew-443b.khandakarsifat.workers.dev', 'VPS Auth Site URL does not match the existing Worker.')
    # Refuse database image upgrades and all volume remapping, including Caddy TLS.
    require(old['volumes'] == candidate['volumes'], 'Compose volume definitions changed. Separate review required.')
    for name in SERVICES:
        before, after = old['services'][name], candidate['services'][name]
        require(before.get('volumes') == after.get('volumes'), f'{name} mount definitions changed. Separate review required.')
    require(old['services']['db']['image'] == candidate['services']['db']['image'], 'PostgreSQL image upgrade refused; use a reviewed upgrade procedure.')

    ids = run(old_cmd + ['ps', '-q', *SERVICES], 'Container discovery').split()
    require(len(ids) == len(SERVICES), 'All eight existing production containers must be running. Check project name and recover the stack first.')
    containers = json.loads(run(['docker', 'inspect', *ids], 'Existing container inspection'))
    current = {container['Config']['Labels']['com.docker.compose.service']: container for container in containers}
    require(set(current) == set(SERVICES), 'Container service/project identity mismatch.')
    for name in SERVICES:
        container = current[name]
        require(container['Config']['Labels']['com.docker.compose.project'] == project, 'Compose project identity mismatch.')
        require(container['State']['Running'] and container['State'].get('Health', {}).get('Status', 'healthy') == 'healthy', f'Existing {name} is unhealthy; recover before deployment.')
    for name, destination, expected in [('db', '/var/lib/postgresql/data', 'lpg_db_data'), ('db', '/etc/postgresql-custom', 'lpg_db-config'), ('storage', '/var/lib/storage', 'lpg_storage_data')]:
        require(any(mount.get('Name') == expected and mount['Destination'] == destination for mount in current[name]['Mounts']), f'Unexpected existing {name} data volume.')
        run(['docker', 'volume', 'inspect', expected], 'External volume existence check')
    require(current['db']['Config']['Image'] == candidate['services']['db']['image'], 'Running database image differs; automatic database upgrade refused.')
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
        if (old['services'][name] != candidate['services'][name]
                or current[name]['Config']['Image'] != candidate['services'][name]['image']
                or current[name]['Config']['Labels'].get('com.docker.compose.config-hash') != desired_hashes[name]):
            affected.add(name)
        for volume in candidate['services'][name].get('volumes', []):
            if volume['type'] == 'bind' and any(str(root / relative) == volume['source'] for relative in changed):
                affected.add(name)
    excluded_ids = run(old_cmd + ['ps', '-q', *EXCLUDED], 'Excluded service discovery').split()
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
            run(candidate_cmd + ['pull', name], f'Image availability for {name}')
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

    if pending:
        sql = 'SET lock_timeout = \'10s\'; SET statement_timeout = \'5min\';\nLOCK TABLE supabase_migrations.schema_migrations IN EXCLUSIVE MODE;\n'
        for version, path in pending:
            source = content(path)
            name = path.stem[15:]
            sql += source + '\n;\n'
            sql += 'INSERT INTO supabase_migrations.schema_migrations(version, name, statements) VALUES (' + ', '.join([sql_literal(version), sql_literal(name), 'ARRAY[' + sql_literal(source) + ']']) + ');\n'
        sql += "NOTIFY pgrst, 'reload schema';\n"
        run(psql + ['--single-transaction', '-f', '-'], 'Approved migrations (entire batch is transactional)', data=sql.encode())
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
    pending_file.unlink(missing_ok=True)
    print('Eight production services verified; data volumes and VPS environment preserved.', flush=True)


if __name__ == '__main__':
    os.umask(0o077)
    try:
        require(len(sys.argv) == 6, 'Invalid backend deployment arguments.')
        deploy(Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5])
    except Exception as error:
        # URL errors can include a public URL, but never headers/SQL/Compose env.
        print(f'Backend deployment error: {error}', file=sys.stderr, flush=True)
        sys.exit(1)
