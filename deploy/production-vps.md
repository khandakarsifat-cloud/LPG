# New production VPS: configuration and deployment guide

Use this guide before deploying LPG to **144.79.249.4**. It records the prepared host and the work still required for its first application deployment. **Live configuration verified on 2026-10-22 (Asia/Dhaka); original hardening and controlled reboot verified on 2026-10-20.** Reinspect the host before making changes; versions, resource usage and security counters are snapshots.

## Environment boundaries

| Environment | Identity | Current role |
| --- | --- | --- |
| New production VPS | `144.79.249.4`, hostname `RoyalBengalTiger` | Hardened infrastructure only; no LPG/Supabase stack, application database, images, containers or Docker volumes |
| Existing Azure VPS | `20.40.48.3`; existing API `https://api.lpg.20.40.48.3.sslip.io` | Existing deployed backend, designated development by the owner; preserve its services, data and credentials |
| Existing Cloudflare frontend | Worker `floral-dew-443b`; `https://floral-dew-443b.khandakarsifat.workers.dev` | Existing published frontend; changing its backend target/publication requires the intended cutover scope |

The private `deploy/.env.backend` still targets Azure. Older documentation and variable names use “production” for that existing deployment. They do not establish that the new VPS has an application installed.

This guide is not authorization to deploy. Host preparation and this documentation did not change Azure, Cloudflare, application data, migration state or deployment pipelines. A future deployment must explicitly identify its target, whether it starts empty or performs an approved data migration, and whether frontend/domain cutover is included. Never copy development data or secrets by default.

## Verified host baseline

| Item | Configuration |
| --- | --- |
| OS / kernel | Ubuntu **24.04.5 LTS**, `6.8.0-147-generic` |
| Virtualization / CPU | KVM, 6 vCPUs |
| Memory / storage | About 5.6 GiB usable RAM; 100 GB virtual disk, ext4 root on `/dev/vda1` |
| Idle resource snapshot | About 498 MiB RAM used, 5.2 GiB available, 89 GiB disk available; not an application capacity test |
| Network | Public interface `eth0`, `144.79.249.4/24`, gateway `144.79.249.1`; Docker default bridge `172.17.0.0/16` |
| IPv6 | Loopback/link-local only; no public IPv6 address or externally verified IPv6 service |
| Time | Host timezone UTC; `systemd-timesyncd` active and synchronized. Convert operational timestamps to Asia/Dhaka when reporting to the owner |
| Swap | Added `/swapfile`: 1 GiB, mode `600`, persistent `/swapfile none swap sw 0 0` in `/etc/fstab`; original 128 MiB `/dev/vda2` swap retained |
| Service health | SSH, UFW, Fail2ban, Docker/containerd, rsyslog, time sync, QEMU guest agent and console active; no failed systemd units at inspection |

`/opt/lpg` and `/opt/lpg/deploy` are root-owned mode `750`; `/opt/lpg/backups` is root-owned mode `700`. These are empty preparation directories. There is no production `.env`, Compose installation, TLS setup, database or migration history on this host.

## SSH and administrative permissions

Connect from Windows using the existing SSH Agent and saved host trust:

```powershell
ssh-add -l
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes lpgadmin@144.79.249.4
```

If agent authentication fails, load the owner's existing key privately or use trusted Virtualizor VNC recovery. Do not disable host-key checking, request passwords/private keys in chat, upload a private key, or replace an unexpected host key without trusted verification.

Only `lpgadmin` is allowed over SSH. Its password is locked; its existing authorized public key is installed in `/home/lpgadmin/.ssh/authorized_keys`. Home, `.ssh`, and `authorized_keys` have modes `750`, `700`, and `600` respectively. The root password was retained for console recovery; root SSH is disabled.

The effective settings in `/etc/ssh/sshd_config.d/00-lpg-hardening.conf` are:

```text
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthenticationMethods publickey
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding local
GatewayPorts no
PermitTunnel no
PermitUserEnvironment no
LogLevel VERBOSE
AllowUsers lpgadmin
```

`UsePAM yes` and `StrictModes yes` remain enabled. Local TCP forwarding is retained for authorized loopback administration. SSH uses enabled `ssh.socket` on TCP 22; an inactive `ssh.service` before the first connection can be normal with socket activation.

`/etc/sudoers.d/90-lpgadmin`, root-owned mode `440`, grants `lpgadmin ALL=(ALL:ALL) NOPASSWD: ALL`. This is a fully privileged administrator when using `sudo`, not a restricted deployment account. The Docker group has no members; the Docker Unix socket is `root:docker`, mode `660`. Use explicit `sudo` for Docker and privileged files.

Before access-breaking changes, obtain approval, confirm VNC recovery and a second independent SSH/sudo login, preserve the current session, validate with `sudo /usr/sbin/sshd -t`, and stage a timed rollback. Retest a new login before cancelling rollback. Do not change SSH port or whitelist a dynamic administrator IP without a recovery plan.

## Firewall and network exposure

UFW is enabled at boot, with low-level logging, **deny incoming**, **allow outgoing**, and **deny routed** defaults. Its only user allow rule is **TCP 22 from anywhere**, for IPv4 and IPv6.

| Port / traffic | Current state | Future purpose |
| --- | --- | --- |
| TCP 22 | Allowed; SSH is the only TCP listener | Key-authenticated administration |
| TCP 80 / 443 | Blocked; no reverse proxy running | Open deliberately for the approved API domain, certificate validation and HTTPS |
| TCP 2375 / 2376 | Blocked; no Docker TCP API | Keep closed; use the local Unix socket |
| PostgreSQL / pooler, including 5432 / 54322 / 54329 | Blocked; no database installed | Keep internal or explicitly loopback-bound |
| Gateway / Studio / service ports, including 54321 / 54323 / 8000 / 8080 | Blocked | Keep internal or loopback-bound behind the approved gateway/proxy |

Standard UFW connection tracking/ICMP rules still apply; “SSH only” refers to unsolicited service access. Outbound DNS, NTP, package downloads and future application dependencies are not restricted to a custom destination allowlist.

On 2026-10-22, external TCP connection tests reached 22 and failed for 80, 443, 2375, 2376, 5432, 54321, 54322, 54323, 54329, 8000 and 8080. On 2026-10-20, a temporary host listener responded locally but was blocked externally; disposable Docker probes also proved filtering of an explicitly public published port before/after Docker restart and reboot. Diagnostic resources were removed.

The owner reported no firewall facility in the Virtualizor panel; no provider firewall was configured or independently inspected. SSH reached independent probes in Bangladesh, Singapore, Germany and the US on 2026-10-20. This does not certify BDIX peering, throughput, DDoS protection, future port 80/443 reachability, SMTP availability or provider quotas. Confirm provider-controlled restrictions before launch. VNC recovery was confirmed by the owner; its control plane was not reconfigured.

### Docker protection beyond UFW

Docker forwarding can bypass ordinary UFW INPUT rules. Preserve the additional IPv4 **and** IPv6 `DOCKER-USER` protection. `/usr/local/sbin/lpg-docker-firewall` installs this rule ahead of Docker forwarding:

```text
-A DOCKER-USER -i eth0 -m conntrack ! --ctstate RELATED,ESTABLISHED -m comment --comment lpg-block-public-container-ingress -j DROP
```

The script ensures `FORWARD` jumps to `DOCKER-USER` and refuses to start unguarded Docker if `eth0` is missing. `/etc/systemd/system/docker.service.d/20-lpg-firewall.conf` runs it in both `ExecStartPre` and `ExecStartPost`. Existing responses to container-initiated outbound connections continue to work. The guard survived UFW reload, Docker restart and the controlled reboot.

**Opening UFW 80/443 alone will not expose a future containerized reverse proxy.** During an approved deployment, review the persistent guard script to permit only the intended reverse-proxy TCP host ports 80/443 before its general ingress drop, retaining all other drops. Docker has already performed DNAT at this chain; match the original public destination/host port with conntrack when appropriate, not an assumed container port. Keep explicit public bindings limited to the proxy and verify exposure externally. Do not delete the guard, disable Docker's iptables handling or replace it with a permissive forwarding policy. See [Docker firewall guidance](https://docs.docker.com/engine/network/firewall-iptables/).

## Docker configuration

Engine **29.9.1** and Compose **5.6.0** are installed from Docker's signed `noble/stable` APT repository. Its source is `/etc/apt/sources.list.d/docker.sources`, with key `/etc/apt/keyrings/docker.asc`. Docker/containerd are enabled at boot. Storage uses `overlayfs` with cgroup v2; AppArmor and built-in seccomp are active.

Current `/etc/docker/daemon.json`:

```json
{
  "log-driver": "local",
  "log-opts": {"max-size": "10m", "max-file": "3"},
  "live-restore": true,
  "ip": "127.0.0.1",
  "default-network-opts": {
    "bridge": {"com.docker.network.bridge.host_binding_ipv4": "127.0.0.1"}
  },
  "userland-proxy": false,
  "iptables": true,
  "ip6tables": true
}
```

Both the default bridge and newly created bridge networks default published ports to loopback. Thus the existing `compose.azure.yml` shorthand `80:80` / `443:443` does **not** establish public proxy access on this host: a reviewed production configuration must explicitly bind the chosen public address and satisfy both firewall layers. Individual Compose logging settings override daemon defaults; the Azure reference uses separately bounded `json-file` logs.

Container DNS/outbound HTTP, isolation between separate bridges, an `--internal` network with no public egress, default loopback publication and explicit-public-port blocking were tested during preparation. Actual future Supabase network separation, resource limits and service health must be verified against its deployed Compose model. No application capacity or database performance claim follows from host preparation.

## Updates, logs, monitoring and reduced attack surface

| Configuration file / unit | Effective configuration |
| --- | --- |
| `/etc/fail2ban/jail.d/60-lpg-sshd.local` | Enabled `sshd` jail; systemd journal backend; UFW ban action; 5 failures in 10 minutes cause a 1-hour ban; loopback ignored |
| `/etc/apt/apt.conf.d/99-lpg-security-updates` | Daily package-list refresh and unattended upgrades; APT autoclean every 7 days; automatic reboot and unused-kernel removal disabled |
| Ubuntu unattended-upgrade origins | Ubuntu base/security and configured ESM security origins; this is not automatic Docker-vendor or application deployment |
| `/etc/systemd/journald.conf.d/60-lpg-limits.conf` | Persistent compressed journal; 256 MiB system / 64 MiB runtime caps; 1 GiB system free-space target; 14-day retention |
| `/etc/logrotate.d/rsyslog`, `ufw`, `fail2ban` | Weekly rotation or 50 MiB maximum size at a rotation check; 4 rotations, compressed with delaycompress |
| `/etc/systemd/system/logrotate.timer.d/60-lpg-hourly.conf` | Hourly checks with up to 5 minutes jitter; log size may exceed the threshold between checks |
| `/etc/default/sysstat`, `/etc/sysstat/sysstat` | Collection enabled; 14-day history, compression after 7 days; disk statistics included; collection/summary timers enabled |
| `/etc/sysctl.d/60-lpg-host.conf` | `vm.swappiness=10`, `kernel.kptr_restrict=2` |
| `/etc/sysctl.d/61-lpg-network.conf` | IPv4 accept/send redirects and source routing disabled for `all`, `default`, `eth0`; IPv6 accept redirects/source routing disabled for the same scopes |

The local monitor is `/usr/local/sbin/lpg-resource-check`, invoked by `lpg-resource-check.service` and `.timer` under `/etc/systemd/system/`. It runs 5 minutes after boot and every 15 minutes with up to 30 seconds jitter. It warns at root disk/inode usage of 80%, available memory below 300 MiB, or a pending reboot. Its service uses a dynamic unprivileged user, read-only system protection, private temporary storage, no new privileges, and Unix-only address families.

Warnings go to the local journal/syslog; **no external alerts, uptime monitoring or automatic backup job are configured**. No Docker prune, database cleanup or automatic application deployment was added.

The preparation explicitly masked unused ModemManager, multipath service/socket, udisks2, upower, fwupd/refresh timer, VMware tools/vgauth, and iSCSI service/socket units. Keep networking, SSH, console getty, QEMU guest agent, AppArmor, logging and time sync intact. Other masks may originate from the provider image; do not unmask everything or assume all masked units were changed during hardening.

Password/root SSH attempts are rejected. Fail2ban reduces repeated attempts; it does not make public port 22 invisible or prevent distributed probes. Synthetic ban insertion/removal and detection of a real rejected login were verified during preparation. Inspect live counters rather than treating old bot/ban counts as current state.

## First application deployment: required sequence

1. **Reconfirm authorization, recovery and identity.** Obtain the intended production deployment/data/cutover scope. Verify `144.79.249.4`, `lpgadmin` SSH/sudo, trusted host key, VNC access, available disk and health. Get approval for destructive or potentially access-breaking operations; retain independent access and rollback. Check for drift from this guide.
2. **Prepare a separate production target.** Read [existing deployment internals](README.md), `deploy/deploy.mjs`, `deploy/backend.py`, `compose.yml`, `compose.azure.yml`, `deploy/Caddyfile`, and [the platform setup notes](../supabase/docker/README.md). Reuse their architecture and safeguards, but implement/review an explicit new-host bootstrap and isolated configuration. Do not overwrite Azure's private deployment configuration or relax target checks globally.
3. **Resolve tooling limitations before execution.** `deploy/deploy.mjs` currently accepts only the Azure API URL and uses the Azure private-key configuration. `deploy/backend.py` requires an existing private `.env`, existing Compose files, healthy core containers and matching volumes. Neither provisions this empty VPS. `npm run deploy:backend`, `deploy:frontend`, and `deploy:all` are **not commands for bootstrapping this host**; even `--check` validates the existing target, not readiness of this new server. Do not run `restore-fresh-vps.sh` as an installer: it restores named backup archives and starts PostgreSQL.
4. **Establish domain, credentials and recovery storage.** Choose the API domain, DNS/TLS approach, allowed frontend origin/redirects, real SMTP, production ownership and backup destination. A fresh installation needs independently generated production secrets in a root-protected VPS `.env` (mode `600`), not a development `.env` upload. An explicitly approved Auth/encrypted-data migration needs a separate key-retention/rotation plan. Arrange encrypted offsite backups, retention and a restore test before business use; the local backup directory alone is not disaster recovery.
5. **Review the production Compose model and bootstrap database.** Preserve pinned image compatibility, bounded memory/logging and the existing backend-only service selection: `db`, `auth`, `rest`, `realtime`, `imgproxy`, `storage`, `meta`, `studio`, `api-gw`, `caddy`. Exclude frontend, Mailpit, functions and pooler unless explicitly needed. The reference expects `lpg_db_data`, `lpg_storage_data` and `lpg_db-config` external volumes; none exist here. Create/initialize only the approved new-host resources. Supabase roles/Auth schemas/extensions/platform configuration must exist before application SQL. Keep PostgreSQL/Studio/gateway loopback or internal and metadata unexposed; restrict service networks where compatible.
6. **Apply reviewed migrations to the verified production database.** There is currently no production DB or applied-migration baseline. Discover the actual ordered repository migrations and target state at deployment time; do not copy an old count/version list. Verify any Supabase MCP connection belongs to this VPS before using it as production evidence. Review first-install SQL and exact migration approvals; use the existing transaction/history/backup safeguards where applicable. Never repair history, restore or reset data to bypass a failed check. For a later update, apply pending migrations before the dependent frontend.
7. **Activate only the public reverse proxy.** Deliberately adapt explicit proxy bindings, the persistent Docker guard and UFW for TCP 80/443; confirm any provider restriction. Preserve the private-route blocks and Studio authentication in `deploy/Caddyfile`/Envoy. No public database, Docker management or internal Supabase ports. Verify trusted HTTPS, renewal prerequisites and HTTP-to-HTTPS behavior before publishing the frontend against it.
8. **Verify backend, then perform only the approved frontend cutover.** Test all service health, authenticated Auth/Storage probes, anonymous REST denial, Studio's authentication challenge and authorized metadata access, tenant/role boundaries, Realtime and Storage as applicable. Use the dedicated burner and isolated disposable businesses per `AGENTS.md`; never genuine business data. Keep the frontend URL and public anon key aligned with this backend; privileged keys never enter Vite. Existing Cloudflare publication/cutover must be separately targeted and verified after backend acceptance.
9. **Prove operational readiness and update this guide.** Retest external exposure with an actual listening proxy, Docker isolation, SSH, security controls, log bounds, backups/restore and alerts. Verify persistence after approved service restarts/reboot when needed. Record the installed production domain, selected Compose files/services/volumes, migration baseline and verification date without secrets. Leave Azure independent; no automatic application deployment is implied.

## Read-only inspection and maintenance entry points

Run the following **inside the SSH session on the new production VPS**, not in local PowerShell. They inspect the host without deploying services or changing firewall rules:

```sh
hostname
ip -4 -br address show dev eth0
uname -r
sudo /usr/sbin/sshd -t
sudo /usr/sbin/sshd -T
sudo ufw status verbose
sudo iptables -nvL DOCKER-USER
sudo ip6tables -nvL DOCKER-USER
sudo fail2ban-client status sshd
sudo ss -lntup
sudo docker version
sudo docker compose version
sudo docker ps -a
sudo docker network ls
sudo docker volume ls
sudo systemctl --failed
sudo systemctl list-timers --all
timedatectl
free -h
df -h /
swapon --show
sudo journalctl -u lpg-resource-check.service --since '-1 day'
sudo journalctl -t lpg-resource-check --since '-1 day'
sudo journalctl -u ssh.service --since '-1 hour'
sudo journalctl -u fail2ban.service --since '-1 day'
```

Do not print `.env`, private keys, tokens or fully resolved Compose configuration. Inspect secrets privately; use quiet Compose validation where appropriate. In PowerShell scripts piped over SSH, strip carriage returns before Bash execution (`tr -d "\015"`) as needed. Routine updates still need version/health checks; controlled reboots require approval. Kernel/package updates can briefly interrupt SSH or the D-Bus watcher: reconnect independently and inspect the real package/systemd state before retrying an operation.

## Emergency recovery and remaining work

The root-only directory `/root/vps-prep-20261020/` (mode `700`) contains `original-config.tar` (mode `600`) and `rollback-access.sh` (mode `700`). The archive is a pre-hardening configuration snapshot, including sensitive SSH host material; it is not an application/database backup and must never be committed or published. Inspect and selectively restore reviewed files, not the entire archive over a live system.

**The access rollback script weakens security deliberately:** it removes the SSH hardening drop-in, validates/reloads SSH, and disables UFW. It does not undo Docker's forwarding guard or all host changes. Use only for an approved access emergency through trusted VNC; repair the cause and restore hardened access/firewall immediately afterward. No rollback timer is intended to remain armed in normal operation. The prior kernel was retained during preparation; inspect available boot entries before relying on kernel fallback.

Still required before business launch: a reviewed new-host bootstrap/update workflow; approved data initialization/migration; production domain and trusted TLS; production secrets/SMTP; narrowly enabled proxy ports; encrypted offsite backups and a recovery drill; external availability/security/resource alerts; and actual application acceptance/capacity verification. Preparation tested the empty host, not a deployed LPG system. Recheck VNC access and privately rotate an unchanged provider-issued recovery password if applicable.
