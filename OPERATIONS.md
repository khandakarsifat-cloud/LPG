# LPG Manager: setup, development, builds and deployment

Use this guide to choose an action and copy the commands for it. Unless a block says **inside the Azure SSH session**, run it in **Windows PowerShell** from the project folder:

```powershell
cd D:\Programming\Projects\LPG
```

## 1. Choose what you want to do

| I want to… | Command or section | What it affects |
| --- | --- | --- |
| Install dependencies after cloning or a lockfile change | `npm ci` | Local `node_modules` |
| Start the local Docker app and Supabase | [Local Docker](#3-local-docker) | Local containers and existing local volumes |
| Rebuild the local Docker frontend after editing React/CSS | [Update only the local Docker frontend](#update-only-the-local-docker-frontend) | Local frontend container |
| Develop with automatic browser refresh | `npm run dev` after starting local Supabase | Local Vite server; usually port 5173 |
| Compile the app without publishing | `npm run build` | Local `dist`; uses normal Vite environment loading |
| Preview the bundle currently in `dist` | `npm run preview` | Local preview server; API target comes from the bundle |
| Build the production frontend without uploading it | `npm run deploy:frontend -- --check` | Local `dist`, built for Azure; Wrangler dry run |
| Check the Azure deployment configuration locally | `npm run deploy:backend -- --check` | Local checks; no SSH or production changes |
| Check both production workflows locally | `npm run deploy:all -- --check` | Local checks/build; no publishing |
| Publish React/CSS/assets changes online | `npm run deploy:frontend` | Existing Cloudflare Worker |
| Update backend configuration or approved migrations online | `npm run deploy:backend` | Existing Azure backend |
| Update backend, then frontend | `npm run deploy:all` | Azure first; Cloudflare after backend health passes |
| Review pending database migrations | [Database migrations](#7-database-migrations) | No SQL executes until versions are explicitly approved |
| See service status/logs or recover from an error | [Status and troubleshooting](#9-status-and-troubleshooting) | Read-only inspection; recovery actions are labeled |
| Enable USB receipt printing | [Windows print bridge](#8-windows-print-bridge) | Bridge on the browser's Windows PC |
| Run checks/tests | [Checks and tests](#10-checks-and-tests) | Mostly local files; database tests are labeled |

**Which online deployment should I choose?** React components, hooks, TypeScript, CSS and frontend assets go through `deploy:frontend`. Compose, Envoy, Caddy and backend SQL changes go through `deploy:backend`. If one release changes both the database/API contract and frontend behavior, choose `deploy:all` after reviewing the migrations.

Deployment publishes your current working files; it does not require a Git push. Review your changes before deploying. These commands do not copy local business data to Azure.

## 2. Tools and environment files

### Required tools

Use Node.js 22.18 or newer, npm, Docker Desktop with Compose 2.24.4 or newer, Windows OpenSSH and Windows `tar`. Python 3 is needed on Windows for `deploy:test`. The existing Azure installation uses Docker Compose, Python 3 and passwordless `sudo` for the updater. Wrangler is already a pinned development dependency in `package.json`.

To inspect your installed versions:

```powershell
node --version
npm --version
docker compose version
ssh -V
tar --version
python --version
```

Install the repository's locked dependencies when setting up the checkout or after `package-lock.json` changes:

```powershell
npm ci
```

### Keep these environments separate

| File | Used by | What belongs there |
| --- | --- | --- |
| Root `.env` | Local Docker Compose and existing local test scripts | Existing local Supabase credentials, local gateway and Compose settings |
| Root `.env.local` | Normal Vite development/build | Local API URL and matching public anon key |
| `deploy/.env.backend` | Azure deployment command on Windows | Existing SSH connection, VPS directory/project and production API URL |
| `deploy/.env.frontend` | Cloudflare deployment command on Windows | Cloudflare account/token, Azure API URL and Azure public anon key |
| Azure `/opt/lpg/.env` | Production backend on the VPS | Existing production database/Auth/Storage settings and server credentials |

Keep the existing root `.env` intact. The example templates contain placeholders, not replacement credentials for a working installation. A fresh clone also needs the existing local data volumes or a separately approved restore procedure before starting Docker.

Normal Vite development should use these values in `.env.local`:

```dotenv
VITE_SUPABASE_URL=http://127.0.0.1:54321
VITE_SUPABASE_ANON_KEY=<matching local ANON_KEY>
```

The placeholder above must be replaced privately. Do not put production values into the local development files.

Create deployment files only if they are missing:

```powershell
if (!(Test-Path deploy/.env.backend)) { Copy-Item deploy/.env.backend.example deploy/.env.backend }
if (!(Test-Path deploy/.env.frontend)) { Copy-Item deploy/.env.frontend.example deploy/.env.frontend }
```

The deployment files and local environment files are Git-ignored. Keep their values out of screenshots, chat, source code and shared logs.

### Azure deployment configuration

Review `deploy/.env.backend`. The existing installation uses:

```dotenv
AZURE_HOST=20.40.48.3
AZURE_USER=azureuser
AZURE_PORT=22
AZURE_SSH_KEY=D:\Download\Download\LPG_key.pem
AZURE_PROJECT_DIR=/opt/lpg
AZURE_COMPOSE_PROJECT=lpg
PRODUCTION_API_URL=https://api.lpg.20.40.48.3.sslip.io
```

The key stays on your PC. Backend deployment reads the existing VPS `.env`; it never uploads or replaces it with your local `.env`.

SSH host trust must already be configured in Windows `known_hosts`. If SSH reports an unknown or changed host key, verify its fingerprint through a trusted channel. Do not disable host-key checking. Keep the private key's Windows permissions restrictive.

### Cloudflare deployment configuration

Populate `deploy/.env.frontend` privately:

```dotenv
CLOUDFLARE_ACCOUNT_ID=<existing account ID>
CLOUDFLARE_API_TOKEN=<Workers deployment API token>
VITE_SUPABASE_URL=https://api.lpg.20.40.48.3.sslip.io
VITE_SUPABASE_ANON_KEY=<existing Azure ANON_KEY>
```

The API token needs **Workers Scripts / Edit** and **Account Settings / Read** on the existing account. Future deployments use this token without dashboard interaction. R2 Access Key ID, Secret Access Key and S3 endpoint are not used by this workflow.

The frontend anon key is the `ANON_KEY` entry in Azure `/opt/lpg/.env`. If you need to copy it again, this PowerShell command copies only that entry to your clipboard:

```powershell
ssh -i "D:\Download\Download\LPG_key.pem" azureuser@20.40.48.3 "sudo -n sed -n 's/^ANON_KEY=//p' /opt/lpg/.env" | Set-Clipboard
```

Paste it into `VITE_SUPABASE_ANON_KEY` in `deploy/.env.frontend`. Never substitute `SERVICE_ROLE_KEY`, `SUPABASE_SECRET_KEY`, a database password or an encryption/signing secret.

## 3. Local Docker

These commands explicitly select the local `.env` and base `compose.yml` so the Azure overlay is not selected accidentally. Docker Desktop must be running.

### Start the local stack

```powershell
docker compose --env-file .env -f compose.yml up -d
docker compose --env-file .env -f compose.yml ps
```

This starts the local app/Supabase services. Compose builds the frontend if its image is missing; it does not automatically rebuild an existing image for every React source edit.

To build the frontend and start/update the whole local stack:

```powershell
docker compose --env-file .env -f compose.yml up -d --build
```

Local addresses with the repository's default ports:

| Service | Address |
| --- | --- |
| Docker frontend | http://127.0.0.1:3001 |
| Supabase API | http://127.0.0.1:54321 |
| Supabase Studio | http://127.0.0.1:54323 |
| Mailpit | http://127.0.0.1:54324 |
| Database through local pooler | `127.0.0.1:54322` |
| Transaction pooler | `127.0.0.1:54329` |

The root `.env` can override ports. Local business data and Azure business data are independent.

### Update only the local Docker frontend

Use this after changing React, TypeScript, CSS or assets. Start the local backend first.

```powershell
docker compose --env-file .env -f compose.yml build frontend
```

If that build succeeds, replace/start only the frontend:

```powershell
docker compose --env-file .env -f compose.yml up -d --no-deps frontend
```

Refresh http://127.0.0.1:3001 afterward. This uses local Compose build arguments; it does not publish to Cloudflare or update Azure.

### Build the Docker image without starting it

```powershell
docker compose --env-file .env -f compose.yml build frontend
```

### Stop and resume local containers

Stop them while retaining their containers and volumes:

```powershell
docker compose --env-file .env -f compose.yml stop
```

Resume/apply the current local configuration:

```powershell
docker compose --env-file .env -f compose.yml up -d
```

For a simple frontend process restart, without rebuilding source or applying changed environment settings:

```powershell
docker compose --env-file .env -f compose.yml restart frontend
```

If you need to remove the local containers/network while retaining data, use:

```powershell
docker compose --env-file .env -f compose.yml down
```

The database/Storage volumes are external and retained; ordinary Compose named volumes are also retained without volume-removal flags. Use `stop` for a routine pause. Do not add volume-removal flags or run reset/prune/restore operations as an update procedure.

## 4. Local development, build and preview

### Develop with hot reload

Start the local Docker stack first, then run in another PowerShell terminal:

```powershell
npm run dev
```

Open the URL Vite prints, usually http://localhost:5173. Leave the terminal open. Source edits refresh the development frontend without rebuilding Docker. Press **Ctrl+C** to stop Vite; Docker keeps running.

### Build without deploying

```powershell
npm run build
```

This runs TypeScript and Vite and writes the bundle to `dist`. It starts no server and publishes nothing. Normal Vite environment files/shell variables determine its embedded API URL/key. With your maintained local configuration, the bundle connects to local Supabase.

### Preview the current build

```powershell
npm run preview
```

Open the printed URL, usually http://localhost:4173. Press **Ctrl+C** to stop. Preview serves whichever bundle currently exists in `dist`; it does not change that bundle's API target.

**Preview after a deployment check:** `deploy:frontend -- --check` and `deploy:all -- --check` overwrite `dist` with an Azure-connected production bundle. Previewing that bundle on localhost still connects to production, and app actions can write production data. To return to a local preview, verify the normal Vite configuration is local and run `npm run build` again before previewing. Use the Docker frontend or Vite development server for ordinary local business-flow testing.

## 5. Cloudflare frontend

**Run from Windows. The publishing command changes production.**

Existing frontend: https://floral-dew-443b.khandakarsifat.workers.dev/

Existing Worker: `floral-dew-443b`. `wrangler.json` uses Workers Static Assets from `dist`. The command checks the existing account/Worker before publishing and does not create another Worker.

### Build/check without publication

```powershell
npm run deploy:frontend -- --check
```

This validates required values, runs TypeScript, builds `dist` for Azure with isolated public variables, and runs Wrangler in dry-run mode. It does not contact the Cloudflare API or Azure. A passing check confirms local configuration/build validity; live token permissions, account ownership and service health are checked during deployment.

### Publish frontend changes

After the check passes and you are ready to publish:

```powershell
npm run deploy:frontend
```

The command rebuilds `dist`, verifies account/Worker and public API access, and publishes through the installed official Wrangler CLI. You do not need to run `npm run build`, upload files through the dashboard or push to GitHub first. Do not deploy `public` or upload a bundle built for localhost.

After success, open the existing URL and check login, dashboard and the screen you changed. Browser/business-flow acceptance is separate from the command's service/HTML checks.

## 6. Azure backend and combined deployment

**Run these npm commands from Windows. Publishing changes production services; approved migrations also change the production database.**

### Validate backend locally

```powershell
npm run deploy:backend -- --check
```

This checks local SSH configuration/key-file existence and the production Compose service/volume rules using example placeholders. It does not SSH into Azure, test actual production credentials or apply migrations.

### Deploy backend

```powershell
npm run deploy:backend
```

The updater connects to the existing VPS, checks its current configuration/history and updates affected production services. It preserves the existing `.env`, credentials and database/Storage/encryption/TLS volume attachments. The production service set is `db`, `auth`, `rest`, `realtime`, `imgproxy`, `storage`, `api-gw` and `caddy`. Mailpit, Studio/meta, frontend, functions and pooler are excluded; existing excluded containers can be stopped during deployment.

Runtime changes have private database/configuration backups and health checks. Pending application migrations stop the command until approved. PostgreSQL image upgrades and volume/mount remapping are refused and need a separate reviewed procedure. This is an updater for the existing VPS, not a fresh-server installer.

### Validate both targets locally

```powershell
npm run deploy:test
npm run deploy:all -- --check
```

### Deploy backend, then frontend

After both checks pass and you are ready to publish:

```powershell
npm run deploy:all
```

The command prepares the frontend, verifies Cloudflare ownership, updates the backend and requires backend health to pass before frontend publication. A backend failure prevents frontend publication. A later frontend failure leaves the backend in place; correct the frontend problem and rerun `deploy:frontend`.

The API is https://api.lpg.20.40.48.3.sslip.io. Caddy handles HTTPS. Azure NSG/firewall must permit ports 80/443. No frontend or Windows printer bridge is deployed to the VPS.

## 7. Database migrations

Application schema/policy/function changes belong in new versioned SQL files under `supabase/migrations/`. Preserve applied historical SQL and tenant/RLS/RBAC boundaries. Use the existing Supabase CLI workflow (`supabase migration new <name>`) to create a new version when preparing a database change.

Starting/rebuilding Docker is not an application migration command for an existing populated database. `npm run build` and frontend deployment also do not apply database migrations. The backend updater reads production history and applies only explicitly approved pending versions.

### Approve reviewed production migrations

First review/test the SQL and let backend deployment report its pending version list. Ordinary backend deployment stops before applying pending SQL. Only after explicit approval of the exact SQL and its effects, including any destructive effects, use an approval command.

**Examples only: replace these timestamps with the actual approved pending versions, in the order reported.**

```powershell
npm run deploy:backend -- --approve-migrations=20261012000000
```

For a release that also publishes the frontend:

```powershell
npm run deploy:all -- --approve-migrations=20261012000000,20261012000100
```

Supply the complete pending list. Approval is not persistent and cannot be combined with `--check`. The updater refuses edited/missing historical versions and out-of-order additions. New SQL must let the runner own the transaction: omit top-level transaction wrappers, psql meta commands and nontransactional operations such as `VACUUM` or concurrent index creation. The approved batch and its history inserts commit together; failure rolls back the batch.

There is no general local migration-apply npm command in this repository. The authorization test runner tests specific authorization migrations, not arbitrary new migration files. Test new SQL against the intended local instance with a reviewed migration procedure; do not point it at Azure, reset the database or repair history to bypass a failure.

If SQL committed but a later service check failed, the migration remains applied. Fix it with a reviewed forward migration. A database restore is a separate destructive recovery operation requiring explicit approval.

## 8. Windows print bridge

The bridge runs on the same Windows PC as the browser and USB printer, outside Docker. Docker/deployment commands do not start it.

### Use the local app

In a separate terminal:

```powershell
npm run print:bridge
```

### Use the online Cloudflare app

In the terminal that will run the bridge:

```powershell
$env:LPG_PRINT_ORIGINS = 'https://floral-dew-443b.khandakarsifat.workers.dev'
npm run print:bridge
```

Leave it running at http://127.0.0.1:17891. Open Dashboard → Receipt Printer and refresh/select the installed USB queue. Allow browser local-network access if prompted. Press **Ctrl+C** to stop the bridge. An environment assignment above applies to that terminal session; set it again in a new terminal.

Starting the bridge/discovering queues does not itself print a receipt. Use the app's print actions only when ready to send a physical job. An uncertain printing result should be checked at the printer before explicitly reprinting.

## 9. Status and troubleshooting

### Local Docker status and logs

```powershell
docker compose --env-file .env -f compose.yml ps
docker compose --env-file .env -f compose.yml logs --tail 80 frontend
docker compose --env-file .env -f compose.yml logs --tail 80 api-gw auth rest
```

To follow local frontend logs until **Ctrl+C**:

```powershell
docker compose --env-file .env -f compose.yml logs -f --tail 80 frontend
```

### Azure status and logs

Connect from Windows:

```powershell
ssh -i "D:\Download\Download\LPG_key.pem" -p 22 azureuser@20.40.48.3
```

**Inside the Azure SSH session**, run these read-only commands:

```sh
cd /opt/lpg
sudo docker compose --env-file .env -p lpg -f compose.yml -f compose.azure.yml ps
sudo docker compose --env-file .env -p lpg -f compose.yml -f compose.azure.yml logs --tail 80 api-gw auth rest storage caddy
```

Inspect logs privately. Do not share server credentials or dump resolved Compose environment settings. Type `exit` to return to Windows. Use the Windows npm deployment command for routine updates.

### What should I do after an error?

| Error/situation | Next action |
| --- | --- |
| Missing environment value | Edit the named ignored deployment file and rerun its `--check`. |
| Cloudflare token/account/Worker mismatch | Correct token permissions/account for the existing Worker; rerun frontend deployment when ready. |
| SSH trust/key/permission failure | Verify host fingerprint and the existing key/ACLs; keep strict host-key checking enabled. |
| Pending migrations | Review/test the reported SQL; approve its exact versions only when authorized. |
| Historical migration mismatch | Use the matching source revision or a reviewed forward migration; do not reset/repair history. |
| Backend service/health failure | Inspect Azure status/private logs and recover the affected service before retrying. |
| Backend succeeded, frontend failed | Fix the frontend issue and rerun `npm run deploy:frontend`. |
| Local Docker frontend shows old code | Rebuild `frontend`, then run its `up -d --no-deps` command. |
| Vite build is fine but Docker still shows old code | `npm run build` changes `dist`; the Docker image needs its own Compose build. |
| Local preview connects to Azure | Rebuild with verified local Vite settings, or use the local Docker/dev frontend. |
| Windows sees a printer but the app does not | Start the host bridge, check the allowed origin and refresh Receipt Printer. |
| Recovery/invitation email does not arrive | Configure real SMTP manually in the VPS environment; excluded Mailpit does not deliver external email. |
| Backup/disk-space failure | Inspect/offload private backups deliberately; deployment stops on backup failure. |

For an interrupted backend update, preserve `/opt/lpg/deploy/.pending-services.json` until a successful updater run. If the affected service was left stopped, recover only that reviewed service before retrying. For example, **inside Azure**, this changes production by starting/updating only Auth:

```sh
sudo docker compose --env-file .env -p lpg -f compose.yml -f compose.azure.yml up -d --no-deps auth
```

Use the actual affected service from the error, not an arbitrary whole-stack restart. Configuration recovery copies are under `/opt/lpg/backups/deployment-<timestamp>/files/`. Restore only the reviewed affected files and recreate their services. Database backups are `database.dump` plus `roles.sql`; their archive structure is checked, but a full restore drill is separate. These are online logical database backups, not Storage-object archives. Keep the original verified physical/Storage backups and independent recovery copies. Backups are not automatically deleted.

Frontend rollback requires selecting/reviewing the previous existing Worker version with Wrangler's rollback workflow. Do not create a second Worker as a recovery shortcut.

## 10. Checks and tests

Run checks relevant to the change; you do not need to run every database/integration suite for a CSS edit.

| Command | What it checks | Requirements/effects |
| --- | --- | --- |
| `npm run build` | TypeScript and normal Vite bundle | Writes `dist`; no publication |
| `npm run lint` | Repository ESLint checks | Local; existing temporary checkouts can cause unrelated lint failures |
| `npm run auth:test` | Route/permission unit tests | Local tests |
| `npm run deploy:test` | Deployment configuration/migration safety tests | Node and Python; simulated deployment calls, no live deployment |
| `npm run print:check` | Print bridge TypeScript | Local checks |
| `npm run print:test` | Print/checkout unit tests | Local tests; no physical print jobs |
| `npm run auth:db:test` | Authorization and printer SQL suites | Local Docker DB required; transaction fixtures roll back |
| `npm run auth:api:test` | Real Auth/REST business-flow authorization tests | Local Docker API/DB required; creates then cleans up its own test accounts/tenants/data |

Basic frontend checks:

```powershell
npm run build
npm run lint
npm run auth:test
```

Deployment checks:

```powershell
npm run deploy:test
npm run deploy:all -- --check
```

Printing code checks:

```powershell
npm run print:check
npm run print:test
```

For authorization/database changes, with the local stack running and the root `.env` still local:

```powershell
npm run auth:db:test
npm run auth:api:test
```

The API suite is not a read-only check: it creates fixture data and performs fixture cleanup. Its API URL is restricted to the local gateway. Use these integration tests only against the intended local environment; do not run them inside an Azure SSH session.

## 11. Everyday workflows

### I changed a screen and want to try it locally

Start local Docker, then use `npm run dev` for hot reload. To test the Docker-served app instead, build `frontend` and run its `up -d --no-deps frontend` command. Open the corresponding local URL and check the changed flow.

### My frontend change is ready for online use

Run `npm run deploy:frontend -- --check`. After it passes, run `npm run deploy:frontend` when ready to publish. Open the existing Cloudflare URL and check the changed flow.

### I changed gateway/backend configuration only

Run `npm run deploy:test` and `npm run deploy:backend -- --check`. Review the backend files and run `npm run deploy:backend` when ready to change production. Inspect reported health/status afterward.

### I changed frontend behavior and database SQL together

Prepare a new forward migration, test/review it locally, then run deployment tests and `npm run deploy:all -- --check`. Run `npm run deploy:all` when ready; it stops if SQL approval is needed. After explicit approval of the reported SQL/effects, rerun with the exact pending version list. Verify the online business flow after deployment.

### I only want to build/check today

Use `npm run build` for the normal Vite bundle, or `npm run deploy:frontend -- --check` for the Azure-connected production bundle. Neither publishes. Avoid the three deployment commands without `--check` until you intend to change production.

Additional implementation details are in [deployment notes](deploy/README.md), [local Compose notes](supabase/docker/README.md) and [printer notes](print-bridge/README.md). This guide is the common command reference; those files describe the underlying components.
