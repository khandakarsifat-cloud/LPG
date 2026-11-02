"""Explicit, resumable first installation on the empty primary VPS. No resets."""
import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import sys
import tempfile
import time

from backend import SERVICES, content, digest, require, run, sql_literal, validate_model, validate_proxy, validate_sql, verify_health, configure_attendance_token, configure_account_service

API = 'https://api.lpg.144.79.249.4.sslip.io'
WORKER = 'https://floral-dew-443b.khandakarsifat.workers.dev'


def b64(value):
    return base64.urlsafe_b64encode(value).decode().rstrip('=')


def auth_keys(secret):
    pem = run(['openssl', 'genpkey', '-algorithm', 'EC', '-pkeyopt', 'ec_paramgen_curve:P-256'], 'Generate independent Auth signing key')
    text = run(['openssl', 'pkey', '-text', '-noout'], 'Read Auth key components', data=pem.encode())
    private = bytes.fromhex(''.join(text.split('priv:')[1].split('pub:')[0].split()).replace(':', ''))
    public = bytes.fromhex(''.join(text.split('pub:')[1].split('ASN1 OID:')[0].split()).replace(':', ''))
    require(len(private) == 32 and len(public) == 65 and public[0] == 4, 'Unexpected P-256 key encoding.')
    ec = {'kty': 'EC', 'crv': 'P-256', 'x': b64(public[1:33]), 'y': b64(public[33:]),
          'kid': secrets.token_hex(16), 'alg': 'ES256', 'use': 'sig', 'key_ops': ['verify']}
    symmetric = {'kty': 'oct', 'k': b64(secret.encode()), 'alg': 'HS256'}
    result = {'JWT_KEYS': json.dumps([{**ec, 'd': b64(private), 'key_ops': ['sign', 'verify']}, symmetric], separators=(',', ':')),
              'JWT_JWKS': json.dumps({'keys': [ec, symmetric]}, separators=(',', ':'))}
    with tempfile.TemporaryDirectory(prefix='lpg-auth-key-') as temporary:
        key = Path(temporary) / 'key.pem'
        key.write_text(pem)
        key.chmod(0o600)
        for variable, role in [('ANON_KEY_ASYMMETRIC', 'anon'), ('SERVICE_ROLE_KEY_ASYMMETRIC', 'service_role')]:
            token = b64(json.dumps({'alg': 'ES256', 'typ': 'JWT', 'kid': ec['kid']}, separators=(',', ':')).encode()) + '.'
            token += b64(json.dumps({'role': role, 'iss': 'supabase', 'iat': int(time.time()), 'exp': int(time.time()) + 10 * 365 * 86400}, separators=(',', ':')).encode())
            # OpenSSL emits ASN.1 DER ECDSA signatures; JWT uses fixed-width r||s.
            import subprocess
            signed = subprocess.run(['openssl', 'dgst', '-sha256', '-sign', str(key)], input=token.encode(), capture_output=True)
            require(signed.returncode == 0, 'Sign internal API token failed.')
            der = signed.stdout
            require(der[0] == 0x30 and der[2] == 2, 'Unexpected ECDSA signature.')
            size = der[3]
            r = int.from_bytes(der[4:4 + size], 'big').to_bytes(32, 'big')
            index = 4 + size
            require(der[index] == 2, 'Unexpected ECDSA signature integer.')
            s = int.from_bytes(der[index + 2:index + 2 + der[index + 1]], 'big').to_bytes(32, 'big')
            result[variable] = token + '.' + b64(r + s)
    return result


def environment(template):
    values = dict(re.findall(r'^([A-Z][A-Z0-9_]*)=(.*)$', template, re.M))
    for name, value in list(values.items()):
        if 'replace-with' in value:
            values[name] = secrets.token_hex(32)
    secret = values['JWT_SECRET']
    def jwt(role):
        head = b64(b'{"alg":"HS256","typ":"JWT"}')
        body = b64(json.dumps({'role': role, 'iss': 'supabase', 'iat': int(time.time()),
                               'exp': int(time.time()) + 10 * 365 * 86400}, separators=(',', ':')).encode())
        return head + '.' + body + '.' + b64(hmac.new(secret.encode(), (head + '.' + body).encode(), hashlib.sha256).digest())
    values.update(COMPOSE_FILE='compose.yml:compose.vps.yml', API_DOMAIN=API.removeprefix('https://'),
                  SUPABASE_PUBLIC_URL=API, API_EXTERNAL_URL=API + '/auth/v1',
                  SITE_URL=WORKER + '/', ADDITIONAL_REDIRECT_URLS=','.join([WORKER, WORKER + '/', WORKER + '/#/login']),
                  ANON_KEY=jwt('anon'), SERVICE_ROLE_KEY=jwt('service_role'),
                  SUPABASE_PUBLISHABLE_KEY='sb_publishable_' + secrets.token_urlsafe(32),
                  SUPABASE_SECRET_KEY='sb_secret_' + secrets.token_urlsafe(32),
                  DASHBOARD_USERNAME='lpgadmin',
                  REALTIME_DB_ENC_KEY=secrets.token_hex(8), SECRET_KEY_BASE=secrets.token_hex(48),
                  VAULT_ENC_KEY=secrets.token_hex(16), STUDIO_DEFAULT_ORGANIZATION='LPG Development',
                  POOLER_TENANT_ID='lpg-primary', STORAGE_TENANT_ID='lpg-primary',
                  SMTP_HOST='', SMTP_PORT='587', SMTP_ADMIN_EMAIL='', SMTP_SENDER_NAME='LPG',
                  VITE_SUPABASE_URL=API)
    values['VITE_SUPABASE_ANON_KEY'] = values['ANON_KEY']
    values.update(auth_keys(secret))
    return ''.join(name + "='" + value.strip('"\r') + "'\n" for name, value in values.items())


def replay_sql(path):
    source = content(path)
    # Two immutable historical migrations own their original transaction. Only
    # their outer wrappers are omitted during first replay, so SQL + history
    # remain atomic in the runner's transaction. Files/checksums stay unchanged.
    if path.name in {'20260701130553_enforce_customers_phone_format.sql', '20261004165315_reconcile_live_schema.sql'}:
        source, begins = re.subn(r'^begin;\s*$', '', source, flags=re.M | re.I)
        source, commits = re.subn(r'^commit;\s*$', '', source, flags=re.M | re.I)
        require(begins == commits == 1, 'Historical transaction wrapper changed.')
    validate_sql(source)
    return source


def install(root, stage, project, api, approval):
    import fcntl
    require(os.geteuid() == 0 and root == Path('/opt/lpg') and project == 'lpg' and api == API, 'Bootstrap target mismatch.')
    require(stage.resolve() == stage and str(stage).startswith('/tmp/lpg-deploy.'), 'Invalid stage.')
    addresses = run(['ip', '-4', '-o', 'addr', 'show', 'dev', 'eth0'], 'Host identity')
    require('144.79.249.4/24' in addresses, 'Wrong VPS: first installation refused.')
    files = sorted((stage / 'supabase/migrations').glob('*.sql'))
    require(approval.split(',') == [p.name[:14] for p in files], 'Approve exactly every reviewed first-install migration.')
    for path in files:
        replay_sql(path)
    root.mkdir(mode=0o750, exist_ok=True)
    (root / 'deploy').mkdir(mode=0o750, exist_ok=True)
    with (root / 'deploy/.deployment.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        marker = root / 'deploy/.bootstrap.json'
        if not marker.exists():
            require(not (root / '.env').exists(), 'Existing environment: use the updater, never bootstrap.')
            volumes = run(['docker', 'volume', 'ls', '--format', '{{.Name}}'], 'Empty-host volume inspection').split()
            require(not set(volumes) & {'lpg_db_data', 'lpg_storage_data', 'lpg_db-config', 'lpg_caddy-data', 'lpg_caddy-config'}, 'Existing volumes: bootstrap refused.')
            require(not run(['docker', 'ps', '-aq', '--filter', 'label=com.docker.compose.project=lpg'], 'Empty-project inspection').strip(), 'Existing LPG containers: bootstrap refused.')
            marker.write_text(json.dumps({'api': api, 'complete': False}) + '\n')
        state = json.loads(marker.read_text())
        require(state == {'api': api, 'complete': False}, 'Bootstrap already completed or invalid marker; use deploy:backend.')
        for path in stage.rglob('*'):
            if not path.is_file():
                continue
            require(not path.is_symlink(), 'Symlink in bootstrap bundle.')
            target = root / path.relative_to(stage)
            require(target.resolve().is_relative_to(root) and not target.is_symlink(), 'Unsafe bootstrap destination.')
            target.parent.mkdir(parents=True, exist_ok=True)
            # Interrupted installs retain already synchronized source; source
            # replacement must use the updater after bootstrap completes.
            immutable = str(path.relative_to(stage)).startswith(('supabase/migrations/', 'supabase/docker/volumes/db/'))
            require(not immutable or not target.exists() or digest(target) == digest(path), 'Immutable bootstrap source changed during an incomplete installation.')
            target.write_text(content(path), encoding='utf-8', newline='\n')
            target.chmod(0o644)
        if not (root / '.env').exists():
            (root / '.env').write_text(environment(content(stage / '.env.example')))
            (root / '.env').chmod(0o600)
        cmd = ['docker', 'compose', '--project-directory', str(root), '--env-file', str(root / '.env'), '-p', project,
               '-f', str(root / 'compose.yml'), '-f', str(root / 'compose.vps.yml')]
        model = json.loads(run(cmd + ['config', '--format', 'json'], 'Bootstrap Compose validation'))
        validate_model(model)
        for name in ['lpg_db_data', 'lpg_storage_data', 'lpg_db-config']:
            run(['docker', 'volume', 'create', name], 'Create persistent volume')
        print('Pulling the pinned backend images; secrets generated privately on the VPS.', flush=True)
        run(cmd + ['pull', *SERVICES], 'Pinned backend image pull')
        validate_proxy(model, root)
        # Platform migrations run before application migrations. No public proxy
        # is started until the complete application schema is in place.
        run(cmd + ['up', '-d', '--wait', '--wait-timeout', '240', *[s for s in SERVICES if s not in {'caddy', 'api-gw', 'attendance-receiver', 'account-service'}]], 'Platform initialization')
        psql = cmd + ['exec', '-T', 'db', 'psql', '-X', '-U', 'supabase_admin', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-qAt']
        run(psql + ['-c', 'CREATE SCHEMA IF NOT EXISTS supabase_migrations; CREATE TABLE IF NOT EXISTS supabase_migrations.schema_migrations(version text PRIMARY KEY, statements text[], name text);'], 'Migration history initialization')
        applied = run(psql + ['-c', 'select version from supabase_migrations.schema_migrations order by version'], 'Bootstrap history').split()
        require(applied == [p.name[:14] for p in files[:len(applied)]], 'Unexpected bootstrap migration history.')
        for path in files[len(applied):]:
            source = replay_sql(path)
            sql = 'SET search_path=public,extensions; SET check_function_bodies=on; SET row_security=on;\n' + source + '\n;\n'
            sql += 'INSERT INTO supabase_migrations.schema_migrations(version,name,statements) VALUES (' + ','.join([
                sql_literal(path.name[:14]), sql_literal(path.stem[15:]), 'ARRAY[' + sql_literal(content(path)) + ']']) + ');'
            run(psql + ['--single-transaction', '-f', '-'], 'First-install migration ' + path.name[:14], data=sql.encode())
            print('Applied migration ' + path.name[:14], flush=True)
        receipt = root / 'deploy/.migration-checksums.json'
        receipt.write_text(json.dumps({p.name[:14]: digest(p) for p in files}, indent=2) + '\n')
        receipt.chmod(0o600)
        run(psql + ['-c', "NOTIFY pgrst, 'reload schema';"], 'Reload PostgREST schema')
        # Preserve the original hardening script for inspection/recovery.
        guard = Path('/usr/local/sbin/lpg-docker-firewall')
        original = root / 'backups/pre-bootstrap-docker-firewall.sh'
        original.parent.mkdir(mode=0o700, exist_ok=True)
        if not original.exists():
            shutil.copy2(guard, original)
        shutil.copyfile(root / 'deploy/docker-firewall.sh', guard)
        guard.chmod(0o750)
        run([str(guard)], 'Narrow Caddy firewall exceptions')
        for port in ['80/tcp', '443/tcp']:
            run(['ufw', 'allow', port], 'Allow public HTTPS proxy')
        configure_attendance_token(root, model)
        configure_account_service(root, model)
        run(cmd + ['up', '-d', '--wait', '--wait-timeout', '240', *SERVICES], 'Backend startup')
        for attempt in range(24):
            try:
                verify_health(model, api)
                break
            except Exception:
                if attempt == 23:
                    raise
                time.sleep(5)
        from backup import configure_backup
        configure_backup(root)
        marker.write_text(json.dumps({'api': api, 'complete': True}) + '\n')
        print('Fresh backend initialized; migration history and HTTPS health verified.', flush=True)


if __name__ == '__main__':
    os.umask(0o077)
    try:
        require(len(sys.argv) == 6, 'Invalid bootstrap arguments.')
        install(Path(sys.argv[1]), Path(sys.argv[2]), *sys.argv[3:])
    except Exception as error:
        print('Bootstrap error: ' + str(error), file=sys.stderr, flush=True)
        sys.exit(1)
