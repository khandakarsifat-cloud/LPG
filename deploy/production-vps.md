# Primary VPS: infrastructure and access

**144.79.249.4**, hostname `RoyalBengalTiger`, is the primary LPG backend. Cutover and security inspection: **2026-10-28, Asia/Dhaka**. This is production infrastructure running an application that remains in active development. It is not a production-readiness certification.

| Environment | Role |
| --- | --- |
| Primary VPS | Clean backend at `https://api.lpg.144.79.249.4.sslip.io`, independent credentials and current schema |
| Existing Cloudflare Worker | Same frontend at `https://floral-dew-443b.khandakarsifat.workers.dev`, connected to the primary VPS |
| Former Azure VPS `20.40.48.3` | Preserved former deployment; its services, credentials and data were not changed |
| Local Compose | Independent development environment and data |

Private deployment settings now use `VPS_*` and the new server. Previous private deployment settings are retained under ignored `.local-backups/pre-primary-cutover/`. No Azure accounts or data were transferred. Register new app accounts/businesses. [Deployment and recovery](README.md) is the canonical guide for installation, frequent updates, migration approvals and backups.

## Host baseline

Ubuntu 24.04.5 LTS, kernel `6.8.0-147-generic`, KVM, 6 vCPUs, about 5.6 GiB RAM, 100 GB disk. The host uses UTC with synchronized time; report operational dates in Asia/Dhaka. Swap is the retained 128 MiB partition plus persistent 1 GiB `/swapfile` mode 600; `vm.swappiness=10`.

Docker Engine 29.9.1 and Compose 5.6.0 come from Docker's signed Ubuntu repository. AppArmor, cgroup v2 and seccomp remain active. Docker/containerd, UFW, Fail2ban, logging, time sync and QEMU guest agent remain enabled. Vendor/package updates are available; planned maintenance is still needed. Ubuntu security updates are unattended; Docker/application updates are not automatic. No reboot-required marker was present at inspection. No host reboot was performed during migration.

`/opt/lpg` and its `deploy/` directory are root-owned mode 750; `backups/` is mode 700. The server `.env` and backup key are mode 600. `compose.yml` plus `compose.vps.yml` run eleven backend services. Data volumes are `lpg_db_data`, `lpg_storage_data`, `lpg_db-config`, `lpg_caddy-data`, `lpg_caddy-config`. PostgreSQL remains pinned to 17.6.1.140. Memory limits, small connection pools and bounded logs follow the existing backend architecture. No frontend, Mailpit, functions or Supavisor runs here.

## SSH and privileged access

```powershell
ssh-add -l
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes lpgadmin@144.79.249.4
```

Use the owner's existing SSH agent and trusted host key. Never disable host checking, request passwords/private keys in chat, upload a private key or replace an unexpected host key without trusted verification. Use trusted provider VNC for recovery. Only `lpgadmin` is allowed over SSH; its password is locked. Root SSH is disabled, with root password retained for console recovery. `lpgadmin` has unrestricted passwordless sudo via `/etc/sudoers.d/90-lpgadmin` (mode 440); the Docker group has no members. Treat the SSH private key as root authority.

`/etc/ssh/sshd_config.d/00-lpg-hardening.conf` enforces public-key authentication, `PermitRootLogin no`, password/keyboard-interactive authentication disabled, `AuthenticationMethods publickey`, `AllowUsers lpgadmin`, `MaxAuthTries 3`, 30-second grace period, and verbose logs. X11, agent forwarding, tunneling and user environment are disabled. Local TCP forwarding remains enabled, `GatewayPorts no`, PAM and strict modes enabled. `ssh.socket` owns TCP 22. Home/.ssh/authorized_keys have restricted ownership/modes; authorized_keys is 600.

Before access-breaking changes, confirm VNC recovery and a second independent SSH/sudo session, preserve the current session, validate with `sudo sshd -t`, and stage a timed rollback. Retest a fresh login before cancelling rollback. Do not change SSH port or restrict dynamic administrator IPs without this recovery procedure.

## Access audit findings

One distinct ED25519 administrator key was found, matching this workstation and agent: fingerprint `SHA256:ffFq+0L1gDd7Af6iN/sl69UlwO8aWe6dWrgNpoC3scM`. It appears once for `lpgadmin` and twice in root's authorized_keys; root SSH remains disabled. No unexpected administrator account, successful SSH login, alternate authorized-key command or user crontab was found in retained evidence. Successful recent logins used that key. The owner confirmed root setup sessions on October 20 from `103.153.66.187` and `202.134.14.135` as their own.

This does not prove nobody else has a copy of the key, rule out erased logs/advanced compromise, or establish perfect security. Provider/Virtualizor/VNC administration is a separate access path. Provider MFA, console password strength and provider staff access were not independently verified. Console credentials were not rotated. Protect those accounts independently.

## Firewall and Docker networking

UFW retains deny incoming, allow outgoing, deny routed defaults and boot persistence. User rules allow TCP **22, 80, 443** only, for IPv4/IPv6. The host has no public IPv6 address. Only Caddy explicitly publishes public IPv4 80/443; Envoy 54321 and Studio 54323 are loopback. PostgreSQL, metadata, Storage, Auth, REST and Realtime have no public host bindings. Pooler and Docker TCP API remain absent/closed.

Docker can bypass ordinary UFW INPUT rules. Preserve `/usr/local/sbin/lpg-docker-firewall` and `/etc/systemd/system/docker.service.d/20-lpg-firewall.conf` (ExecStartPre/ExecStartPost). The managed source is `deploy/docker-firewall.sh`. Both IPv4 and IPv6 `DOCKER-USER` chains drop new public `eth0` ingress by default. Only IPv4 TCP traffic whose conntrack original destination is **144.79.249.4**, port **80 or 443**, returns to Docker's normal publication filtering. The exceptions do not blanket-accept other forwarded traffic. Established outbound responses remain allowed. The original guard is saved privately under `/opt/lpg/backups/pre-bootstrap-docker-firewall.sh`.

Docker daemon settings retain loopback publication defaults, live restore, userland proxy disabled, iptables/ip6tables enabled, and bounded local logs. `compose.vps.yml` deliberately uses `0.0.0.0:80:80` and `0.0.0.0:443:443` for Caddy. Do not delete the guard, disable Docker's iptables handling or open internal service ports. Conntrack filtering follows [Docker's firewall guidance](https://docs.docker.com/engine/network/firewall-iptables/). No provider firewall facility was available during preparation; provider controls were not changed.

Caddy obtains/renews trusted TLS for the IP-based sslip.io hostname and redirects HTTP. The domain pattern requires no registration but depends on that DNS service. Studio remains behind independent Basic Auth. `/mcp*`, `/api/mcp*`, `/pg*`, `/functions*` are publicly blocked. Supplied browser origins are restricted to the unchanged Worker and API origin; authentication, trusted membership, capabilities and RLS remain the data boundary. Services retain their shared Compose bridge; public port isolation does not imply service-by-service network segmentation.

## Maintenance and recovery

Fail2ban's sshd jail uses the journal/UFW, five failures in ten minutes and a one-hour ban. Daily unattended Ubuntu security upgrades retain automatic reboot/kernel removal disabled. Journals are persistent/compressed with 256 MiB system and 64 MiB runtime limits, fourteen-day retention. rsyslog/UFW/Fail2ban logs rotate weekly or at 50 MiB checks, four retained rotations; hourly logrotate checks and sysstat collection remain enabled.

`lpg-resource-check.timer` runs after boot and every fifteen minutes. Its hardened unprivileged service warns locally at disk/inode usage 80%, available memory below 300 MiB or reboot required. No external notifications/uptime monitor is configured. `lpg-backup.timer` starts pgBackRest/Restic/rclone whole-system backups at 02:00 Asia/Dhaka, with no daytime catch-up. The root-only control service is reachable through a Unix socket mounted only into the existing account service, with current superadmin Auth checks. Database binaries remain 17.6.1.140; the derived image adds pgBackRest 2.57.0 and local WAL archival. The root-only secret directory is `/opt/lpg/deploy/backup-secrets`; keep the separately exported recovery kit outside this VPS. See [whole-system cloud recovery](backup/recovery.md) for retention, Storage pause, integrity/drill checks and new-VPS cutover. Legacy bundles remain preserved and are not bulk-pruned.

```sh
sudo sshd -t
sudo sshd -T
sudo ufw status verbose
sudo iptables -S DOCKER-USER
sudo ip6tables -S DOCKER-USER
sudo ss -lntup
sudo docker compose --project-directory /opt/lpg --env-file /opt/lpg/.env -p lpg -f /opt/lpg/compose.yml -f /opt/lpg/compose.vps.yml ps
sudo systemctl --failed
sudo systemctl list-timers --all
sudo journalctl -u lpg-backup.service --since '-1 day'
sudo fail2ban-client status sshd
free -h
df -h /
```

Do not print server environments, private keys, tokens or resolved Compose configuration. PowerShell scripts piped over SSH need carriage returns stripped before Bash execution. Controlled reboots require explicit approval.

The root-only `/root/vps-prep-20261020/` archive preserves pre-hardening configuration and sensitive host material. Its `rollback-access.sh` deliberately weakens access controls and disables UFW; use only in an explicitly approved access emergency through trusted VNC. Do not restore that entire archive over the current host; restore selected reviewed files and reapply security afterward.

Before production business use: configure SMTP, verify automatic cloud recovery and arrange external monitoring; review package updates, provider MFA/console recovery credentials, workload capacity, stable domain ownership and the application's production data-preservation policy. Physical printing and Android/PWA behavior remain separate acceptance boundaries.

## Memory budget for the 6-core / 6 GB VPS

Attendance adds a non-root internal receiver with a **96 MiB** memory ceiling, half CPU ceiling, bounded logs and no published port. Total configured backend ceilings become **4,896 MiB**, leaving about **886 MiB** outside ceilings on the recorded host. Caddy routes `/iclock/*` over existing HTTPS/443 and blocks the internal ingestion RPC. Backups include attendance data, source and scoped-token recovery configuration. See [attendance and physical-device acceptance](../docs/modules/attendance.md).

Before attendance, the backend memory ceilings totaled **4,800 MiB** (4.69 GiB), leaving approximately **982 MiB** outside container ceilings on the verified host. These are ceilings, not reserved allocations; Linux also uses available RAM for reclaimable filesystem cache. PostgreSQL has a **2,560 MiB** cap, **640 MiB shared buffers**, **768 MiB shared-memory limit**, **1,920 MiB effective cache estimate**, **4 MiB work memory**, **64 MiB maintenance memory**, and **2 GiB max WAL size**. The latter is a soft checkpoint target, not an absolute WAL disk limit. The existing eighty-connection database ceiling and ten-connection PostgREST pool remain bounded. Studio and Realtime have 384 MiB ceilings; imgproxy has 128 MiB. Other existing service ceilings are retained.

This budget follows measured cache/read pressure under the former 1 GiB database cap. The untuned capacity report remains a baseline, not a capacity claim for this configuration. Tuned concurrency testing starts at eighty independent businesses and narrows the passing/failing bracket, with host memory/disk reserves and correctness checks active. Allocate additional query concurrency only after checking actual CPU, cache, memory and I/O behavior; do not assign all physical RAM to PostgreSQL.

`effective_cache_size` is a planner estimate and allocates no RAM. `work_mem` can
be consumed by several operations in each concurrent query; it is not one fixed
allocation per connection. See PostgreSQL 17's [cache estimate](https://www.postgresql.org/docs/17/runtime-config-query.html#GUC-EFFECTIVE-CACHE-SIZE)
and [memory settings](https://www.postgresql.org/docs/17/runtime-config-resource.html#GUC-WORK-MEM).
