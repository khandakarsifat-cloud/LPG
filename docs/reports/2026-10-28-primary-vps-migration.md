# Primary VPS migration verification

Verified **2026-10-28, Asia/Dhaka**. The LPG application remains in development; the new VPS is its primary backend on production infrastructure.

## Result and boundaries

- Backend: `144.79.249.4`, `lpgadmin`, `/opt/lpg`, project `lpg`, `compose.yml` + `compose.vps.yml`.
- API and authenticated Studio: `https://api.lpg.144.79.249.4.sslip.io`, Studio `/project/default`.
- Frontend: the unchanged Worker `floral-dew-443b`, `https://floral-dew-443b.khandakarsifat.workers.dev/`.
- Published Worker version: `d4369673-267b-4c97-a058-a53719f99e90`. Published assets embed the new API, and browser traffic reached that origin. Browser sessions now use the full backend host/port; an obsolete Azure session was reproduced, then verified to be ignored after the fix without sending its token to the new API.
- Azure was not accessed or modified during this migration. Its data/accounts/secrets were not transferred. Former private deployment settings are archived locally and excluded from active scripts.
- Local Compose/data and the Windows print bridge remain independent. No physical print, host reboot, provider-console change or payment-provider settlement was performed.

The deployed stack has ten running backend services. Nine configured container health checks pass; Caddy is running and verified through trusted external HTTPS. The certificate hostname/chain verified, with expiration January 26, 2027. HTTP redirects to HTTPS; Caddy manages renewal and persistent TLS state.

## Initialization and deployment workflow

The verified host was initially empty of application containers/volumes. The explicit bootstrap created independent server credentials and persistent volumes, initialized pinned Supabase platform services, then replayed **all 39 immutable application migrations**, through `20261028100855_employee_single_wallet_payments.sql`. Each migration and its history record committed together. Two historical transaction wrappers were omitted only in executed replay; source files were not rewritten.

Final inspection found **39 applied versions, no pending migrations, matching source SHA256 receipts, 40 public tables and zero public tables without RLS**. The normal updater now uses `VPS_*` settings and SSH-agent authentication, rejects other backend targets, and retains exact migration approval, historical-source checks, transaction ownership, backups, deployment locking and mount/image safeguards. New port validation refuses public internal services. Caddy configuration is validated before activation.

`npm run deploy:all` successfully built and published to the existing Worker after backend acceptance. A subsequent configuration update recreated only Caddy and retained its database/configuration recovery files. A deliberately stale approval for an already-applied version was rejected with unchanged container identities. A subsequent no-op backend deployment reported no pending migrations/no affected services and recreated no container.

Supabase MCP tools were unavailable in this session. Database inspection used the independently verified SSH connection and the configured Compose database, rather than treating the local database as deployed evidence.

## Application and platform acceptance

| Check | Result and scope |
| --- | --- |
| Build/lint | TypeScript/Vite build and repository lint passed |
| Local tests | 70 application/printing tests, 10 deployment/PWA JavaScript tests and 16 deployment/bootstrap Python tests passed |
| Real PostgreSQL replay | All migrations, historical-normalization assertions and eleven current SQL suites passed in a newly created disposable database on the VPS; it was removed |
| Concurrency | Checkout/retries/last-stock races, purchase/payment/refund races, transfers, bottle/customer charges, salary revisions/payments/returns and trip closure passed; ledgers reconciled |
| Auth | Dedicated burner form/API login, trusted membership/effective permissions and ES256 user sessions passed; public JWKS exposed only public EC material |
| Redirects | Recovery-link generation honored the exact login redirect and replaced an unapproved external redirect with the configured Site URL; no email sent |
| Authorization | Anonymous denial, invalid-key denial, cross-tenant/capability denial, restricted direct writes and wallet/stock integrity passed through real Auth/PostgREST and SQL suites |
| Studio | Authenticated browser project and Table Editor metadata loaded successfully; direct public metadata/MCP bypasses remained blocked |
| Backend public access | Auth/Storage health and expected PostgREST anonymous denial passed; supplied Worker/API origins allowed, hostile/null origins rejected; public MCP/metadata/function routes returned 404 |
| API keys | New opaque publishable/secret-key translation and separately generated server-role API access passed; privileged values stayed private |
| Storage | A uniquely named private fixture bucket/object passed upload, authenticated server download, signed download, anonymous read/write denial and persistence after restart; fixture removed |
| Realtime | Authenticated disposable-channel WebSocket subscription and self-broadcast round trip passed through public HTTPS; this does not assert application table publication/subscription behavior |
| Published browser | Burner login, all ten feature routes and reload passed without page errors; browser requests used only the new API |
| POS/Sales/printing | Published 320/390/768/1440px flows passed checkout, zero/partial/over bottle receipts, alternate products, settlement charges, payment collection, current receipt previews and retained details; no automatic or physical printing |
| Employees | Published creation/edit, future partial salary, named bonus, audited return, salary revision, Finance navigation and Logistics driver payout/residual closure passed |
| Finance/customers/purchases | Real API suites passed split/partial/zero payments, collections, refunds, retries, wallet transfers, ledger/search/filter/sort/pagination and tenant denial |

The burner account was newly registered using its ignored local test credentials. Its clearly labeled disposable development business remains for future acceptance. Other fixture businesses/accounts were removed with preservation checks. Final database counts were one Auth user, one tenant, zero sales, zero purchases, zero Storage objects and no verification/restore databases.

## Persistence, backups and recovery

Docker was restarted to exercise its persistent firewall hook. All ten backend services were then restarted and returned healthy. Fingerprints for every public table remained unchanged; database volumes and TLS state persisted. The private Storage fixture remained readable afterward. No host reboot was performed.

`lpg-backup.timer` is enabled for 21:00 UTC / 03:00 Asia/Dhaka with up to five minutes jitter. An actual systemd backup completed successfully. It shares the deployment lock, briefly quiesces Storage, validates the database archive, captures database/roles, objects, encryption/TLS volumes and configuration, then restarts Storage. Final bundles are encrypted and authenticated; the recovery key is excluded from each bundle.

- Initial rehearsal: `recovery-20261028T134353Z.tar.gz.enc` restored successfully into a new isolated database. The restored history had 39 migrations and 40 protected public tables. The private Storage fixture's actual bytes were verified in the volume archive and its metadata matched in the restored database.
- Final clean-state backup: `recovery-20261028T135711Z.tar.gz.enc`, also restored successfully into an isolated database. Both rehearsal databases were removed. No live application database was overwritten and no global roles were changed by rehearsal.
- A modified ciphertext fixture failed HMAC validation before decryption/database creation; it was removed.
- The final encrypted archive/HMAC were copied to `.local-backups/primary-vps-recovery/` and verified on Windows. Its separate recovery key is under `%LOCALAPPDATA%\LPG\Recovery\primary-vps-backup-key`; both locations have restricted ACLs.

This proves the recorded logical restore and Storage archive/metadata checks on the pinned platform. It is not a full independent-host disaster-recovery simulation or a test of restoring global roles over another server. The [recovery guide](../../deploy/README.md#backup-and-recovery) records that operational boundary. Daily bundles remain on the VPS; the workstation copy is manual. Automatic managed offsite backup, external failure alerts and a retention policy need an operator-selected destination/provider.

## Access and security audit

The effective SSH configuration allows only `lpgadmin` with public-key authentication; root SSH, password/keyboard-interactive authentication, agent forwarding and public TCP forwarding remain disabled. The single distinct authorized ED25519 key matches the workstation/agent. Root's authorized_keys contains two copies of that same key, but root SSH is disabled. No alternate key command/CA/principals source was configured. `root` and `lpgadmin` were the only interactive host accounts; no additional sudo/Docker-group member or user crontab was found.

All successful SSH login groups in the retained journal used the owner's confirmed setup addresses or the current owner connection. The owner confirmed the October 20 sessions from `103.153.66.187` and `202.134.14.135`. No unexplained successful SSH login or active session was found. This evidence cannot identify other holders of the private key, prove an absence of erased evidence or rule out advanced compromise.

UFW retains deny incoming/deny routed defaults, allowing only TCP 22/80/443. The persistent IPv4/IPv6 Docker guard remains enabled; only original-destination IPv4 ports 80/443 on this VPS return to Docker's publication rules. A temporary container listener on public port 18080 returned HTTP 200 from the host but was blocked from the workstation, proving actual filtering rather than an absent listener; it was removed. After restart, external checks reached only 22/80/443 among the tested ports; Docker API, PostgreSQL/pooler, gateway/Studio and internal service ports were unreachable. No failed systemd unit remained.

Security is not perfect or fully provable. `lpgadmin` has unrestricted passwordless sudo, so its private key grants root authority. Provider/Virtualizor/VNC access and console credentials form a separate control plane; provider MFA, console password strength and provider staff access were not independently audited or changed. Vendor/package updates are available for planned maintenance. Ubuntu automatic security updates, Fail2ban, AppArmor, bounded logging and local resource monitoring remain enabled.

Before production business use, configure real SMTP, automatic independent offsite backup and external monitoring; review provider recovery/MFA, pending package updates, workload capacity and the application's production preservation policy. The application deliberately retains development email autoconfirm. Physical printers, Android installation and provider settlement remain separate acceptance boundaries.

Implementation references: [Supabase self-hosting](https://supabase.com/docs/guides/self-hosting/docker), [self-hosted signing keys](https://supabase.com/docs/guides/self-hosting/self-hosted-auth-keys), [Docker firewall behavior](https://docs.docker.com/engine/network/firewall-iptables/) and [Caddy matcher ordering](https://caddyserver.com/docs/caddyfile/matchers).
