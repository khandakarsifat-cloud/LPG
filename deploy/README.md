# Windows production deployments

For the combined local Docker, development, build and production command guide, see [OPERATIONS.md](../OPERATIONS.md).

The VPS deployment reuses `compose.yml` plus `compose.azure.yml`. Its ten production services are PostgreSQL, Auth, PostgREST, Realtime, Storage, imgproxy, Studio, postgres-meta, Envoy and Caddy. Mailpit, Edge Functions, Supavisor and the frontend are optional profiles and are excluded by the deployment command, including through dependencies. Existing excluded containers are stopped without removing containers or volumes. No Supabase Cloud service is used. Local `compose.yml` behavior is unchanged.

## Production dashboard

Open <https://api.lpg.20.40.48.3.sslip.io/project/default> and enter the existing VPS `DASHBOARD_USERNAME` / `DASHBOARD_PASSWORD`. These administrator credentials are separate from LPG app accounts. Keep them private; the dashboard can inspect and modify production data.

From Windows, copy each login field privately using the existing SSH configuration in `deploy/.env.backend`:

```powershell
npm run dashboard:credentials -- --username
# Paste into the username field, then copy the password:
npm run dashboard:credentials
```

The helper copies only the selected field to the Windows clipboard without displaying or saving it. No credentials are added to source or uploaded. Replace clipboard contents after login.

Caddy forwards dashboard pages/assets/platform requests to Envoy, which enforces its existing HTTP Basic authentication and strips that header before forwarding to Studio. Application API routes retain their API-key/JWT handling. Public `/pg*`, `/mcp*`, `/api/mcp*` and `/functions*` routes remain blocked, including the local MCP bypass. Studio's direct port stays loopback-only and postgres-meta has no public port. The local dashboard remains independent at `http://127.0.0.1:54323`.

Studio and metadata are normal production services with the existing pinned images and memory limits. Backend deployment can add these two services to the earlier eight-service installation, but still requires all core services to be healthy and preserves existing images, mounts, credentials and data. Future deployments keep them running. Health verification checks both the anonymous authentication challenge and authenticated Studio HTML; interactive dashboard actions require separate browser acceptance.

## One-time Windows setup

Install Node.js 22.18 or newer, Docker Desktop with Compose 2.24.4 or newer (for `!override`), Windows OpenSSH (`ssh`), Windows `tar`, and Python 3 for the deployment tests. Run `npm ci`; Wrangler is the sole new development dependency and is pinned in the lockfile. The existing VPS needs Docker Compose, Python 3 and passwordless `sudo -n` for Docker/the updater; these were confirmed by read-only inspection on 2026-10-12. The commands update this existing installation; they do not provision another VPS or restore a database.

Copy these templates **only when the destination does not exist** (the ignored files may already be present):

```powershell
if (!(Test-Path deploy/.env.backend)) { Copy-Item deploy/.env.backend.example deploy/.env.backend }
if (!(Test-Path deploy/.env.frontend)) { Copy-Item deploy/.env.frontend.example deploy/.env.frontend }
```

Populate the ignored files manually. They are parsed as dotenv files; a Windows key path can be written without escaping backslashes. No shell expansion is performed. Unsupported variables and missing values fail before any deployment.

| File | Variables | Purpose |
| --- | --- | --- |
| `deploy/.env.backend` | `AZURE_HOST`, `AZURE_USER`, `AZURE_PORT`, `AZURE_SSH_KEY` | Existing SSH connection; defaults are `20.40.48.3`, `azureuser`, `22`, and `D:\Download\Download\LPG_key.pem`. The private key is never uploaded. |
| `deploy/.env.backend` | `AZURE_PROJECT_DIR`, `AZURE_COMPOSE_PROJECT`, `PRODUCTION_API_URL` | Existing `/opt/lpg`, `lpg` Compose project and `https://api.lpg.20.40.48.3.sslip.io`. |
| `deploy/.env.frontend` | `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_API_TOKEN` | Existing account ID and account-scoped API token. Never put these in Vite variables. |
| `deploy/.env.frontend` | `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY` | Azure HTTPS API and its existing public **anon JWT**, never a service-role or secret key. Copy the anon key privately from the existing VPS configuration. |

The VPS `/opt/lpg/.env` remains the sole source of backend settings and credentials. Keep it mode 600. No production environment is generated from the local `.env`; no environment file is in the SSH upload. This deployment system does not change passwords, JWT/encryption keys, SMTP settings, URLs, database/Storage volumes, or migration history records that are already applied. Database initialization SQL/configuration is not synchronized to the existing VPS.

For Cloudflare, use an API token scoped to the existing account with **Account / Workers Scripts / Edit**. Add **Account / Account Settings / Read** for account/subdomain discovery. The API checks must be able to read account subdomain and existing Worker settings. Set `CLOUDFLARE_ACCOUNT_ID` to that account, not a zone ID. The saved private deployment configuration supplies these credentials without dashboard interaction or `wrangler login`; account ownership must pass read-only API checks each time.

SSH uses `BatchMode=yes` and `StrictHostKeyChecking=yes`. Before first use, ensure the VPS host key is in Windows `known_hosts` and verify its fingerprint through a trusted channel if it is new. Use the existing private key and its restrictive Windows ACLs; do not disable host-key verification. No new key or backend environment is required.

## Commands and local validation

```powershell
npm run deploy:test
npm run deploy:backend -- --check
npm run deploy:frontend -- --check
npm run deploy:all -- --check

# Publishing commands: run only when ready to change production.
npm run deploy:backend
npm run deploy:frontend
npm run deploy:all
```

`--check` requires the corresponding environment values, validates them locally, and never contacts Azure or the Cloudflare API. Backend checks render only `.env.example` placeholders and validate the service/dependency closure and external volume names. Frontend checks run TypeScript, the production Vite build and `wrangler deploy --dry-run`. They write only ignored `dist`/Wrangler artifacts. Tests exercise configuration isolation, privileged-key rejection, dependency/volume safety, immutable migration history and transaction ownership.

`deploy:all` validates both targets and builds/packages the frontend before changing the backend. It verifies the existing Cloudflare Worker/account, deploys the backend and checks container/public HTTPS health, then checks the frontend anon key through the public API and publishes the frontend. Backend failure prevents frontend publication. Frontend failure leaves the healthy backend in place; fix the error and rerun `deploy:frontend`.

Public health checks require Auth/Storage success and a zero-row `items` REST request returning the existing anonymous permission denial (`401/403`, PostgreSQL code `42501`). This proves the request reached PostgREST without fetching business rows and keeps anonymous access blocked. Invalid-key errors and Envoy's generic denial are failures. The REST OpenAPI root is intentionally gateway-protected and is not a service-health endpoint.

Auth/Storage health requests require the public anon API key too; a bare Auth health request receives the gateway's authentication challenge. The VPS updater validates all public endpoints with its existing anon key. Frontend/all deployment repeats those checks from Windows using the frontend's configured public key before publishing.

## Backend update and migration safety

The updater transfers only Compose files, gateway configuration, Caddy configuration, the updater and application migrations. It compares normalized file contents before writing, preserves existing file permissions, and leaves unrelated VPS files alone. It validates candidates against the **existing VPS `.env`**, checks project/container identity and external volume attachments, and refuses PostgreSQL image upgrades or any volume/mount remapping. Changed bind-mounted gateway/Caddy files recreate their owning service because Compose cannot detect their contents. Compose configuration hashes detect changed runtime settings. Unchanged services are not recreated. Only affected production images are pulled, and service updates use `--no-deps`; profiles and optional services cannot be pulled in indirectly. There is no `down`, reset, volume deletion, prune, history repair or automatic rollback.

The existing twelve versions were confirmed in both the configured local MCP instance and the VPS on 2026-10-12. The MCP URL is local (`127.0.0.1:54321`); it is not used as production evidence. At every deployment the updater reads **VPS** `supabase_migrations.schema_migrations` using the existing database container and platform superuser, with no database password on the command line. Applied versions missing from the checkout, changed historical SQL, duplicates and out-of-order additions stop deployment. Existing VPS migration files provide the initial source-hash baseline; successful migrations also retain hashes in a private deployment receipt. Historical files are never replayed or repaired.

New migrations belong in `supabase/migrations/`, using the existing timestamp/name convention (`supabase migration new <name>`). Test and review them locally, especially any removal or modification of data, RLS/RBAC policies or privileged functions. By default, **any pending migration stops deployment before file synchronization, backup, service changes or SQL execution** and lists the pending versions. After explicit review/approval of the SQL and its effects, pass exactly the complete pending list, in order:

```powershell
# Example only: substitute the actual reviewed pending version(s).
npm run deploy:backend -- --approve-migrations=20261012000000
# Or include multiple approved versions with deploy:all:
npm run deploy:all -- --approve-migrations=20261012000000,20261012000100
```

Version approval authorizes that SQL, including destructive effects if present; never supply it without explicit approval of such effects. No migration executes just because `deploy:backend` was requested. There is no persistent automatic approval setting. The runner owns a single transaction for the entire approved batch and its migration-history inserts, with `ON_ERROR_STOP`, lock/statement timeouts and PostgREST schema reload. New SQL must omit top-level `BEGIN`/`COMMIT`, psql meta commands and nontransactional operations such as `VACUUM`/`CONCURRENTLY`; these require a separately reviewed maintenance procedure. Historical migrations with transaction wrappers remain intact and are not replayed. Failed batches roll back together.

Before runtime changes or approved SQL, the updater creates a private `/opt/lpg/backups/deployment-<UTC timestamp>/` directory with a full database custom-format dump, global roles and copies of affected existing configuration/source files. It checks the dump archive with `pg_restore --list` and aborts on failure. A configuration-only source synchronization also keeps replaced files. Database and Storage/encryption/TLS volumes stay attached. This is an online logical database backup, **not** a new physical snapshot or Storage-object archive; keep the initial verified backups and your independent recovery copies. No automatic backup deletion is performed, so check VPS disk space and retain/offload backups deliberately.

The updater uses an exclusive deployment lock. A private pending-service record makes interruptions after file synchronization retryable even when the files already match. Health failures are reported without printing resolved Compose configuration, SQL errors or credentials. As with any deployment to one small VPS, affected services may have brief downtime. PostgreSQL changes require a separate upgrade procedure; this workflow does not guess how to upgrade data files.

## Recovery

Configuration/preflight failures leave services and data untouched (SSH staging and the deployment lock can be created). Correct missing values, SSH host trust/ACLs, token permissions or source/history mismatch and retry. Never use migration repair/reset to bypass a failure. A failing command returns a nonzero exit code; successful commands report health checks.

For backend errors after updates begin, connect to the existing VPS and inspect privately:

```sh
cd /opt/lpg
sudo docker compose --env-file .env -p lpg -f compose.yml -f compose.azure.yml ps
sudo docker compose --env-file .env -p lpg -f compose.yml -f compose.azure.yml logs --tail 80 SERVICE
```

Fix the affected service/configuration first. If an interrupted update left that service stopped, start only that reviewed service with the same explicit Compose arguments and `up -d --no-deps SERVICE`, then rerun `deploy:backend`. Preserve the private `.pending-services.json` record until the updater succeeds. If configuration rollback is required, restore the specific files from the printed backup path and recreate only their affected services. Do not restore `.env` from your PC. A committed database migration stays applied even if a later service check fails; add a reviewed forward corrective migration. Database restore is a separate destructive recovery operation requiring explicit approval and a maintenance plan.

If Cloudflare publication fails, the backend remains independent. Fix token/configuration and rerun `deploy:frontend`. Cloudflare keeps Worker deployment versions; use the official `wrangler rollback` after reviewing its target/version if a frontend rollback is required. Keep production URLs and the anon key aligned with that backend. Do not create or rename a Worker to solve an account mismatch.

## Existing Azure installation

The backend is installed under `/opt/lpg` on `20.40.48.3`. Use SSH with the existing private key path; never copy the key to the VPS. The private VPS `.env` uses `COMPOSE_FILE=compose.yml:compose.azure.yml` and `API_DOMAIN=api.lpg.20.40.48.3.sslip.io`. Only Caddy's ports 80/443 are public; administrative services are loopback or internal. Azure's Network Security Group must allow TCP 80/443. Caddy obtains and renews certificates automatically once those ports are reachable.

Verified on 2026-10-11, before dashboard enablement: all nine backend containers run; all configured health checks pass. The public API at `https://api.lpg.20.40.48.3.sslip.io` has a trusted Let's Encrypt certificate and HTTP redirects to HTTPS. Auth signup/business setup, REST role/tenant boundaries, checkout/stock/receipt/printer configuration, Realtime WebSockets and private Storage upload/download pass through the public HTTPS endpoint. Counts and checksums for all 33 original public/Auth/Storage/migration tables still match the local source after fixture cleanup. Public administration routes return 404. Auth uses `https://floral-dew-443b.khandakarsifat.workers.dev/` as its production Site URL, and exact redirect URLs for that origin; allowed redirects and rejection of an unapproved redirect were tested. Cross-origin Auth preflight/requests from that origin pass. No browser UI or physical printer verification was performed.

```sh
cd /opt/lpg
sudo docker compose ps
sudo docker compose up -d
```

The VPS uses the same pinned Supabase images as local development, named persistent database/Storage/encryption-key volumes, bounded container memory, smaller database pools, two Envoy/Erlang workers, PostgreSQL tuning, and 1 GB of swap on the existing disk. The local `.env`, local Compose services and original local volumes are retained.

## Data and credentials

The initial deployment is a consistent physical PostgreSQL snapshot verified with `pg_verifybackup`, plus Storage and PostgreSQL custom configuration archives. Initial archives and table checksum manifests are kept in `/opt/lpg/backups`; local copies are stored in a private archive outside the repository. The restore script refuses to overwrite nonempty volumes. Do not rerun it on a running deployment. Database, dashboard and S3 protocol passwords are independently generated for the VPS; existing JWT signing and encryption keys are retained to preserve the copied Auth and encrypted data. Keep the VPS `.env` private (mode 600). Do not publish Compose's resolved configuration.

Local and VPS data are independent after the snapshot; this deployment does not synchronize subsequent changes. Backups are on the existing disks, not on a separate disaster recovery service. No additional Azure resources are provisioned.

Mailpit is excluded from production updates. Configure a real SMTP provider **on the VPS** before relying on recovery or invitation emails. If existing `SMTP_HOST=mailpit` and autoconfirm is enabled, deployment reports this limitation and retains Auth settings; if confirmation requires that sink, deployment stops until real SMTP is configured. Local Mailpit and local email behavior remain unchanged. SMTP credential changes are manual; the next backend deployment detects and updates only Auth.

## Separately hosted frontend

Build the existing frontend on its own host with:

```dotenv
VITE_SUPABASE_URL=https://api.lpg.20.40.48.3.sslip.io
VITE_SUPABASE_ANON_KEY=<existing anon key from the private environment>
```

Use only the anon key, never a service-role key. Production builds accept a configured HTTPS self-hosted gateway; development keeps its loopback-only guard. The VPS `SITE_URL` is `https://floral-dew-443b.khandakarsifat.workers.dev/`; `ADDITIONAL_REDIRECT_URLS` contains that origin, its root URL and `/#/login`. Future redirect changes require recreating only Auth with `sudo docker compose up -d --no-deps auth`.

The frontend is the existing Cloudflare Worker **`floral-dew-443b`**, at `https://floral-dew-443b.khandakarsifat.workers.dev/`. There was no Wrangler configuration in the checkout; [`../wrangler.json`](../wrangler.json) records that existing name and Workers Static Assets `./dist` directory, with SPA fallback for the React app. No `public`-directory deployment, Pages project, Worker source function or second Worker is created. Before publication, read-only Cloudflare API checks verify the existing account subdomain, Worker availability and its settings; unexpected non-static bindings stop publication for review. Existing text variables/secrets are retained. This configuration intentionally owns this Worker's static frontend deployment.

`deploy:frontend` invokes the isolated Vite build with `envDir: false` and only the two approved public Vite variables. Neither local `.env*` files nor arbitrary shell `VITE_*`/server secrets enter the build. The configured anon JWT must have the `anon` role and must pass the Azure API check before publication; this prevents using a key from another instance. Build output is `dist`, not `public`. Wrangler uses the configured account/token in its own child process, not the Vite build. Keep the frontend origin aligned with the VPS Auth Site URL, allowed redirects and Windows print bridge origins. The frontend is not running on the VPS.

USB printing still runs on the browser's Windows computer. Set `LPG_PRINT_ORIGINS` to the exact HTTPS frontend origin before starting `npm run print:bridge`. The bridge continues listening on `127.0.0.1:17891` and retains origin, Host and client-header checks. Browser local-network permission may be required. No printer bridge is hosted on the VPS.

For the current external frontend, use `LPG_PRINT_ORIGINS=https://floral-dew-443b.khandakarsifat.workers.dev` on the Windows computer. No local bridge configuration was changed during VPS deployment.
