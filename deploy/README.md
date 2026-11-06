# LPG deployment and recovery

The primary backend is **144.79.249.4**, administered as `lpgadmin` under `/opt/lpg`. The application remains in development on production infrastructure. The former Azure server is outside the active deployment workflow; do not alter it or reuse its secrets.

The API is <https://api.lpg.144.79.249.4.sslip.io>. The frontend stays on the existing Cloudflare Worker, <https://floral-dew-443b.khandakarsifat.workers.dev/>. `sslip.io` resolves the embedded IP without domain registration; owning a domain can be arranged before production. Caddy manages trusted TLS and renewals.

## Stack and isolation

`compose.yml` plus `compose.vps.yml` run twelve services: PostgreSQL 17.6, Auth, PostgREST, Realtime, Storage, imgproxy, Studio, postgres-meta, Envoy, the internal attendance receiver, private account service and Caddy. Pinned images, memory limits, bounded logs and reduced pools are retained. Frontend, Mailpit, Edge Functions and Supavisor are excluded profiles. Local Compose and its private `.env` remain independent.

The attendance receiver uses Caddy HTTPS/443 under `/iclock/*`, with no host port. Its 96 MiB ceiling is additional to the existing backend budget. Deployment privately generates the scoped JWT in `deploy/.attendance-token`, owned by UID 1000, mode 400. No signing/service-role credential is copied into the receiver. Registration requires an approved serial; shop IP restrictions have been removed by explicit development policy. Serial-only identification cannot authenticate the physical machine; the attendance guide records this limitation. Public access to its ingestion RPC is blocked. See [attendance security and hardware acceptance](../docs/modules/attendance.md).

Only Caddy explicitly publishes public TCP 80/443. Envoy and Studio bind loopback; PostgreSQL, metadata and the other services have no public ports. UFW and the persistent IPv4/IPv6 Docker ingress guard remain enabled. The only Docker forwarding exceptions match the new VPS IPv4 address and original host ports 80/443. Public `/mcp*`, `/api/mcp*`, `/pg*` and `/functions*` remain blocked. Browser origins are restricted at Caddy to the Worker and API origin; API keys, Auth, RBAC and RLS still enforce authorization.

The account service is reachable only through `/accounts/v1/*` on the existing gateway/proxy. Its generated UID-1000 mode-400 `deploy/.account-service.json` contains server credentials and exact permitted origins; it is never uploaded from the workstation or served as an asset. Normal Auth/RLS checks still authorize every operation. Product image signing and signed-download routes are denied; the application uses authenticated downloads.

## Windows configuration

Use Node.js 22.18+, Python 3, Windows OpenSSH/tar and `npm ci`. A local Docker CLI is optional for deployment; if unavailable, Compose validation runs on the verified VPS. Use the existing SSH agent and trusted host key:

```powershell
ssh-add -l
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes lpgadmin@144.79.249.4
```

Copy `deploy/.env.backend.example` and `deploy/.env.frontend.example` only if their private destinations do not exist. Backend settings are `VPS_HOST`, `VPS_USER`, `VPS_PORT`, optional `VPS_SSH_KEY` (empty uses the agent), `VPS_PROJECT_DIR`, `VPS_COMPOSE_PROJECT` and `PRODUCTION_API_URL`. The updater rejects a host/API outside the primary VPS. Frontend settings are the existing Cloudflare account/token and the new backend URL/public anon JWT. Never put privileged keys in Vite or print resolved Compose configuration.

`/opt/lpg/.env` is root-owned mode 600 and contains separately generated server credentials. Routine deployment never uploads or replaces it. Change backend settings privately there; the updater detects affected service hashes and recreates only those services. Keep the Worker Site URL and exact root/login redirects aligned. The Windows print bridge retains the same frontend origin and loopback address `127.0.0.1:17891`; it stays outside Docker/VPS. No physical print is dispatched by deployment.

## Frequent updates

```powershell
npm run deploy:test
npm run deploy:backend -- --check
npm run deploy:frontend -- --check
npm run deploy:all
```

`--check` is local validation, with no SSH/publication. Backend checks validate service closure and persistent volume names where Docker is available. Frontend checks isolate Vite from local dotenv/server secrets, build TypeScript/assets, validate PWA metadata and run Wrangler dry-run.

`deploy:all` builds first, verifies the existing Cloudflare account/Worker, updates the backend and checks public health, then publishes to the same Worker. It never creates a second Worker or hosts the frontend on the VPS. Backend failure blocks publication; frontend failure leaves the healthy backend running. Rerun `deploy:frontend` after correcting its error.

At each update, applied database versions must exist in source and retain their recorded normalized SHA256. Out-of-order versions, edited history, changed database images or remapped mounts/volumes stop deployment. An exclusive deployment lock also excludes scheduled backups. Any pending migration stops before synchronization or runtime changes and prints its versions. Review the exact SQL, then supply the complete ordered list:

```powershell
npm run deploy:all -- --approve-migrations=20261029000000,20261029000100
```

Those example versions must be replaced by the actual pending versions. Standing authorization covers routine non-destructive migrations; destructive operations need explicit scope. New migrations must omit top-level transactions/psql commands and nontransactional operations. The runner owns one transaction for the approved batch and history inserts, with timeouts and PostgREST reload. Failed batches roll back. There is no reset, history repair, prune, volume deletion, database upgrade or automatic rollback.

Before runtime/SQL changes the updater validates a full custom-format database dump and retains roles plus replaced files in private `/opt/lpg/backups/deployment-<UTC>/`. Bind-file changes recreate the affected service. A pending-service record supports interrupted retries. No-op deployments verify health without restarting services. Health requires authenticated Auth/Storage success, PostgREST's expected anonymous permission denial, a Studio challenge and authenticated Studio HTML.

The reviewed accounting cutover `20261105020000` Gas/Bottle cutover `20261106023012,20261106023014` and purchase cash cutover `20261106113739` pause application transaction writers and database schedules after preflight, capture a fresh quiesced dump and apply the batch transactionally. The updater restores the previous service/scheduler intent before health checks. Private `accounting-cutover.json` beside the recovery dump records the original intent. If the updater process or host is interrupted, restore that recorded runtime and scheduler state before another deployment. Failed SQL rolls back the whole migration and resumes the original runtime.

## First installation

The primary server has already been initialized. **Do not rerun bootstrap on this installation.** For an explicitly authorized replacement of this same target, `npm run deploy:backend -- --bootstrap --approve-migrations=<all ordered versions>` invokes the first-install path. It checks the host address, exact project/API, absent environment/LPG volumes/containers, and exact migration approvals before creating resources. Independently generated secrets stay on the server. It initializes Supabase platform services before replaying every application migration, recording each migration atomically. Two immutable historical outer transaction wrappers are omitted only in the executed replay; source files/checksums stay unchanged.

A private bootstrap marker allows retrying an interrupted installation and refuses a completed install. Never delete the marker, environment or volumes to bypass a failure. Diagnose the failed phase privately. First installation opens only the reviewed proxy ports after the schema is ready. Subsequent changes use the normal updater.

## Production dashboard

Open <https://api.lpg.144.79.249.4.sslip.io/project/default>. Envoy requires the independent dashboard Basic Auth login; app accounts do not grant dashboard access. Studio/meta remain normal backend services, with direct ports private. Copy dashboard fields privately on Windows:

```powershell
npm run dashboard:credentials -- --username
npm run dashboard:credentials
```

The helper copies one field to the clipboard without printing/saving it. Replace clipboard contents afterward. Dashboard administration is powerful; public MCP/metadata bypasses remain blocked.

## One-time platform account

After the account-access migration, run `account-service/initialize-platform.mjs` inside the account-service container with the authorized email/temporary password supplied as JSON on stdin. It is not a public endpoint and does not accept credentials in command-line arguments. The database permanently consumes the bootstrap and requires a password change before administrative access. Do not rerun VPS installation bootstrap. The superadmin Backup Management section controls the centralized encrypted cloud backup system. See [authorization](../supabase/authorization.md).

## Backup and recovery

The [whole-system recovery guide](backup/recovery.md) is the canonical backup procedure. pgBackRest backs up the complete PostgreSQL 17 cluster (including Auth, roles, all tenants and Storage metadata), with full backups at 02:00 Asia/Dhaka on the 1st and incrementals on other nights. Storage and essential configuration accompany every sealed point. Restic repository v2 encrypts, compresses and deduplicates these captures directly through rclone to one Google Drive account; active repositories are never synchronized.

`lpg-backup.timer` starts daily at **02:00 Asia/Dhaka**, without daytime catch-up or jitter. A job must begin in the 02:00–02:14 window and may finish later. Manual requests queue for the next nightly window. Local WAL archiving continues as required; Drive is contacted only by the nightly job or explicit superadmin authorization actions. Cloud retention preserves 30 daily calendar days and 12 monthly full points with their dependencies. Nightly checks and monthly isolated physical restore drills are automatic. A failure never advances the verified-backup indicator.

Web OAuth connection, reconnect/disconnect, cached account/quota/usage, history, health, scheduling and queued requests are in `#/admin` → Backups. Credentials and refresh tokens live only in root-owned `deploy/backup-secrets`; the Node account service proxies a Unix socket into the root-owned controller, which independently validates the current Auth and platform session. It has no public host listener or browser-held privileged key.

The pinned PostgreSQL image is extended only with pgBackRest 2.57.0; its PostgreSQL binaries/version and existing persistent mounts are preserved. The deployment guard allows exactly that derivation and the reviewed backup/socket mounts, and continues to reject arbitrary image/mount changes. The legacy OpenSSL bundles and `.backup-key` remain preserved; `restore-check.py` reads those older bundles only. Their former daily timer is replaced, and they are not automatically pruned.

Run `node deploy/backup-kit.mjs` after connecting/reconnecting Drive to save the password, OAuth recovery configuration and exact guide outside the VPS in an ACL-restricted Windows directory. Keep a second secure copy. The random Restic password is excluded from cloud captures; restoring must not depend on access to the lost VPS. The guide contains commands for an empty replacement VPS, restored credentials/volumes, PostgreSQL physical recovery, isolated service validation, new-IP firewall/DNS review and frontend cutover. Do not bootstrap or replay migrations over the recovered database.

Use private backup files to restore specific changed configuration after a failed update, then recreate only the affected service and rerun deployment. A committed migration remains applied even if later health checks fail; add a forward corrective migration. For frontend rollback use the existing Worker's reviewed version with Wrangler; keep URL/anon credentials aligned.

## Inspection and limitations

```sh
sudo docker compose --project-directory /opt/lpg --env-file /opt/lpg/.env -p lpg -f /opt/lpg/compose.yml -f /opt/lpg/compose.vps.yml ps
sudo systemctl status lpg-backup.timer lpg-resource-check.timer
sudo journalctl -u lpg-backup.service --since '-1 day'
sudo ufw status verbose
sudo iptables -S DOCKER-USER
sudo ip6tables -S DOCKER-USER
```

Never print `.env`, full Docker inspect/config, raw SQL errors containing records, tokens or keys. Inspect service logs privately. [The VPS guide](production-vps.md) records access and hardening boundaries.

Azure accounts/business data were not migrated. Users need new app accounts/businesses. Saved browser sessions are scoped to the full backend host/port; obsolete first-label sessions are ignored, so cutover starts at login. Development email autoconfirm is enabled; no SMTP provider has been supplied, so recovery/invitation email is unavailable. External monitoring, verified nightly cloud recovery, production email, owned-domain planning and a production policy review remain before real production use. Physical printing, physical Android/PWA behavior and payment-provider settlement are separate acceptance boundaries.
