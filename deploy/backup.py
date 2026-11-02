"""Private encrypted recovery bundle; daily via lpg-backup.timer or manually."""
import datetime
import fcntl
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import sys
import tarfile
import tempfile

from backend import require, run


def configure_backup(root):
    units = {
        'lpg-backup.service': '[Unit]\nDescription=LPG encrypted database and Storage backup\nAfter=docker.service\nRequires=docker.service\n\n[Service]\nType=oneshot\nUMask=0077\nExecStart=/usr/bin/python3 -B /opt/lpg/deploy/backup.py /opt/lpg\nNice=10\nIOSchedulingClass=idle\nNoNewPrivileges=true\nPrivateTmp=true\nProtectHome=true\nProtectSystem=strict\nReadWritePaths=/opt/lpg/backups /opt/lpg/deploy\n',
        'lpg-backup.timer': '[Unit]\nDescription=Daily LPG recovery backup\n\n[Timer]\nOnCalendar=*-*-* 21:00:00 UTC\nRandomizedDelaySec=300\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n',
    }
    changed = False
    for name, text in units.items():
        path = Path('/etc/systemd/system') / name
        if not path.exists() or path.read_text() != text:
            path.write_text(text)
            path.chmod(0o644)
            changed = True
    if changed:
        run(['systemctl', 'daemon-reload'], 'Reload backup scheduling')
    run(['systemctl', 'enable', '--now', 'lpg-backup.timer'], 'Enable daily backup timer')


def backup(root):
    require(root == Path('/opt/lpg') and os.geteuid() == 0, 'Run as root for /opt/lpg only.')
    with (root / 'deploy/.deployment.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        folder = root / 'backups'
        folder.mkdir(mode=0o700, exist_ok=True)
        key = root / 'deploy/.backup-key'
        if not key.exists():
            key.write_text(secrets.token_hex(64) + '\n')
            key.chmod(0o600)
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
        cmd = ['docker', 'compose', '--project-directory', str(root), '--env-file', str(root / '.env'), '-p', 'lpg', '-f', str(root / 'compose.yml'), '-f', str(root / 'compose.vps.yml')]
        model = json.loads(run(cmd + ['config', '--format', 'json'], 'Backup Compose identity'))
        require(model['services']['api-gw']['environment']['SUPABASE_PUBLIC_URL'] == 'https://api.lpg.144.79.249.4.sslip.io', 'Backup target mismatch.')
        with tempfile.TemporaryDirectory(prefix='.backup-', dir=folder) as temporary:
            work = Path(temporary)
            # A short Storage maintenance window keeps its metadata and files
            # consistent. Application transactions remain online in pg_dump.
            try:
                run(cmd + ['stop', 'storage'], 'Quiesce Storage for coherent backup')
                for name, args in [('database.dump', ['pg_dump', '-U', 'supabase_admin', '-d', 'postgres', '-Fc']), ('roles.sql', ['pg_dumpall', '-U', 'supabase_admin', '--globals-only'])]:
                    with (work / name).open('wb') as output:
                        run(cmd + ['exec', '-T', 'db', *args], 'Database recovery dump', output=output)
                with (work / 'database.dump').open('rb') as source:
                    run(cmd + ['exec', '-T', 'db', 'pg_restore', '--list'], 'Validate recovery archive', stdin=source)
                with tarfile.open(work / 'volumes.tar.gz', 'w:gz') as archive:
                    for volume in ['lpg_storage_data', 'lpg_db-config', 'lpg_caddy-data', 'lpg_caddy-config']:
                        info = json.loads(run(['docker', 'volume', 'inspect', volume], 'Recovery volume identity'))[0]
                        archive.add(info['Mountpoint'], arcname=volume)
            finally:
                run(cmd + ['up', '-d', '--no-deps', '--wait', '--wait-timeout', '180', 'storage'], 'Restore Storage availability')
            with tarfile.open(work / 'recovery.tar.gz', 'w:gz') as archive:
                for name in ['database.dump', 'roles.sql', 'volumes.tar.gz']:
                    archive.add(work / name, arcname=name)
                archive.add(root / '.env', arcname='config/.env')
                for name in ['compose.yml', 'compose.vps.yml', 'deploy', 'supabase', 'attendance-receiver', 'account-service']:
                    archive.add(root / name, arcname='config/' + name,
                                filter=lambda info: None if info.name.endswith(('.backup-key', '.deployment.lock')) or '__pycache__' in info.name else info)
            encrypted = folder / ('recovery-' + stamp + '.tar.gz.enc')
            run(['openssl', 'enc', '-aes-256-cbc', '-pbkdf2', '-iter', '200000', '-salt', '-pass', 'file:' + str(key), '-in', str(work / 'recovery.tar.gz'), '-out', str(encrypted)], 'Encrypt recovery bundle')
            signature = hmac.new(key.read_bytes(), digestmod=hashlib.sha256)
            with encrypted.open('rb') as source:
                while block := source.read(1024 * 1024):
                    signature.update(block)
            encrypted.with_suffix(encrypted.suffix + '.hmac').write_text(signature.hexdigest() + '\n')
            encrypted.chmod(0o600)
            print('Encrypted recovery bundle: ' + str(encrypted), flush=True)
        # No automatic deletion: retention/offload is an explicit operator task.


if __name__ == '__main__':
    os.umask(0o077)
    try:
        require(len(sys.argv) == 2, 'Usage: backup.py /opt/lpg | --configure')
        if sys.argv[1] == '--configure':
            require(os.geteuid() == 0, 'Root required.')
            configure_backup(Path('/opt/lpg'))
        else:
            backup(Path(sys.argv[1]))
    except Exception as error:
        print('Backup failed: ' + str(error), file=sys.stderr)
        sys.exit(1)
