"""Idempotent non-destructive host setup, called by the existing deployer."""
import os
from pathlib import Path
import secrets
import shutil

from core import ROOT, SECRETS, STATE, command, pg, read, write


def configure():
    if os.geteuid() != 0 or ROOT != Path('/opt/lpg'):
        raise RuntimeError('Root and the established VPS project are required.')
    SECRETS.mkdir(mode=0o700, exist_ok=True)
    STATE.mkdir(parents=True, mode=0o700, exist_ok=True)
    os.chown(STATE, 0, 101)
    STATE.chmod(0o710)
    if not shutil.which('restic') or not shutil.which('rclone'):
        command(['apt-get', 'update'])
        command(['apt-get', 'install', '-y', '--no-install-recommends', 'restic=0.16.4-2ubuntu0.24.04.3', 'rclone=1.60.1+dfsg-3ubuntu0.24.04.6'], env={'DEBIAN_FRONTEND': 'noninteractive'})
    repository = STATE / 'repository'
    repository.mkdir(mode=0o700, exist_ok=True)
    os.chown(repository, 100, 101)
    lock = STATE / 'repo.lock'
    lock.touch(exist_ok=True)
    lock.chmod(0o600)
    os.chown(lock, 100, 101)
    password = SECRETS / 'restic-password'
    if not password.exists():
        password.write_text(secrets.token_urlsafe(48) + '\n')
        password.chmod(0o600)
    socket_dir = Path('/run/lpg-backup')
    socket_dir.mkdir(mode=0o750, exist_ok=True)
    os.chown(socket_dir, 0, 1000)
    socket_dir.chmod(0o750)
    units = {
        'lpg-backup-control.service': '''[Unit]
Description=LPG private backup control socket
After=docker.service
Requires=docker.service
[Service]
Type=simple
UMask=0077
RuntimeDirectory=lpg-backup
RuntimeDirectoryMode=0750
RuntimeDirectoryPreserve=yes
ExecStartPre=/usr/bin/python3 -B /opt/lpg/deploy/backup/worker.py --resume-storage --if-idle
ExecStart=/usr/bin/python3 -B /opt/lpg/deploy/backup/control.py
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/opt/lpg/backups/cloud /opt/lpg/deploy/backup-secrets /run/lpg-backup /opt/lpg/deploy/.deployment.lock
MemoryMax=128M
TasksMax=32
[Install]
WantedBy=multi-user.target
''',
        'lpg-backup.service': '''[Unit]
Description=LPG encrypted whole-system Google Drive recovery point
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target
[Service]
Type=oneshot
UMask=0077
ExecStart=/usr/bin/python3 -B /opt/lpg/deploy/backup.py
ExecStopPost=/usr/bin/python3 -B /opt/lpg/deploy/backup/worker.py --resume-storage
Nice=15
IOSchedulingClass=idle
CPUQuota=100%
MemoryMax=768M
Environment=GOMAXPROCS=2
TimeoutStartSec=infinity
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/opt/lpg/backups /opt/lpg/deploy /var/lib/docker/volumes
''',
        'lpg-backup.timer': '''[Unit]
Description=Nightly LPG cloud backup at 02:00 Asia/Dhaka
[Timer]
OnCalendar=*-*-* 02:00:00 Asia/Dhaka
AccuracySec=1s
Persistent=false
Unit=lpg-backup.service
[Install]
WantedBy=timers.target
'''}
    units['lpg-backup-manual.service'] = units['lpg-backup.service'].replace(
        'Description=LPG encrypted whole-system Google Drive recovery point',
        'Description=LPG administrator-requested immediate full backup').replace(
        'ExecStart=/usr/bin/python3 -B /opt/lpg/deploy/backup.py',
        'ExecStart=/usr/bin/python3 -B /opt/lpg/deploy/backup/worker.py --manual-full')
    changed = False
    for name, value in units.items():
        path = Path('/etc/systemd/system') / name
        if not path.exists() or path.read_text() != value:
            path.write_text(value)
            path.chmod(0o644)
            changed = True
    if changed:
        command(['systemctl', 'daemon-reload'])
    command(['systemctl', 'enable', 'lpg-backup-control.service', 'lpg-backup.timer'])
    command(['systemctl', 'restart', 'lpg-backup-control.service'])
    command(['systemctl', 'stop' if read(STATE / 'core-baseline.json', {}).get('active') else 'restart', 'lpg-backup.timer'])


if __name__ == '__main__':
    configure()
