"""Whole-system backup policy and private IO. No third-party Python dependencies."""
import datetime as dt
import json
import os
from pathlib import Path
import subprocess
import secrets
import time
from zoneinfo import ZoneInfo

ROOT = Path('/opt/lpg')
STATE = ROOT / 'backups/cloud'
SECRETS = ROOT / 'deploy/backup-secrets'
DHAKA = ZoneInfo('Asia/Dhaka')
API = 'https://api.lpg.144.79.249.4.sslip.io'
FRONTEND = 'https://floral-dew-443b.khandakarsifat.workers.dev'
CALLBACK = API + '/backups/v1/oauth/callback'
REMOTE = 'lpg-drive:LPG-System-Recovery/restic'


def now():
    return dt.datetime.now(dt.timezone.utc)


def read(path, default=None):
    return json.loads(path.read_text()) if path.exists() else default


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temp = path.with_name(path.name + '.' + secrets.token_hex(6) + '.new')
    temp.write_text(json.dumps(value, indent=2) + '\n')
    temp.chmod(0o600)
    temp.replace(path)


def command(args, *, env=None, timeout=7200):
    # Never reflect raw SQL/tool output, which may contain records or credentials.
    result = subprocess.run([str(a) for a in args], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            env={**os.environ, **(env or {})}, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f'{Path(str(args[0])).name} {args[1] if len(args)>1 else ""} failed (exit {result.returncode}). Check connectivity, credentials, quota and local free space; retry in the next nightly window.')
    return result.stdout.decode()


def compose(*args):
    return command(['docker', 'compose', '--project-directory', ROOT, '--env-file', ROOT / '.env', '-p', 'lpg',
                    '-f', ROOT / 'compose.yml', '-f', ROOT / 'compose.vps.yml', *args])


def pg(*args):
    return compose('exec', '-T', '--user', 'postgres', 'db', 'pgbackrest', '--stanza=lpg', *args)


def next_run(clock=None):
    local = (clock or now()).astimezone(DHAKA)
    target = local.replace(hour=2, minute=0, second=0, microsecond=0)
    if target <= local:
        target += dt.timedelta(days=1)
    return target.isoformat()


def window(clock=None):
    local = (clock or now()).astimezone(DHAKA)
    return local.hour == 2 and local.minute < 15


def retain_ids(snapshots, clock=None):
    """30 Dhaka calendar dates + latest 12 *monthly full* points. Never guess chains."""
    cutoff = (clock or now()).astimezone(DHAKA).date() - dt.timedelta(days=29)
    days, months = {}, {}
    for point in sorted(snapshots, key=lambda p: p['time']):
        if 'lpg-system' not in point.get('tags', []):
            continue
        date = dt.datetime.fromisoformat(point['time'].replace('Z', '+00:00')).astimezone(DHAKA).date()
        if date >= cutoff:
            days[date.isoformat()] = point['id']
        if 'monthly-full' in point.get('tags', []):
            months[date.strftime('%Y-%m')] = point['id']
    return set(days.values()) | {months[k] for k in sorted(months)[-12:]}


def restic(*args):
    return command(['restic', '--repo', 'rclone:' + REMOTE, '--password-file', SECRETS / 'restic-password',
                    '--cache-dir', STATE / 'cache', '--compression', 'auto', '--limit-upload', '8192', '--limit-download', '8192',
                    '-o', 'rclone.connections=2', '-o',
                    'rclone.args=serve restic --stdio --config=' + str(SECRETS / 'rclone.conf') + ' --drive-use-trash=false --transfers=2 --checkers=2 --tpslimit=4 --retries=5 --low-level-retries=10',
                    *args], env={'GOMAXPROCS': '2'}, timeout=86400)


def event(action, actor=None):
    # Bounded, noncredential local audit; cloud copy in the following configuration capture.
    path = STATE / 'audit.json'
    with Lock(STATE / '.audit.lock', blocking=True):
        records = read(path, [])
        write(path, ([{'time': now().isoformat(), 'action': action, 'actor': actor}] + records)[:1000])


class Lock:
    def __init__(self, path, blocking=False):
        self.path = path
        self.blocking = blocking

    def __enter__(self):
        import fcntl
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.file = self.path.open('a')
        try:
            fcntl.flock(self.file, fcntl.LOCK_EX | (0 if self.blocking else fcntl.LOCK_NB))
        except Exception:
            self.file.close()
            raise
        return self

    def __exit__(self, *args):
        self.file.close()


def retry(function, attempts=3):
    for attempt in range(attempts):
        try:
            return function()
        except (RuntimeError, subprocess.TimeoutExpired):
            if attempt == attempts - 1:
                raise
            time.sleep(30 * (attempt + 1))
