# Azure self-hosted Supabase backend

The VPS deployment uses `compose.yml` plus `compose.azure.yml`. The frontend is hosted separately. The default VPS services are PostgreSQL, Auth, PostgREST, Realtime, Storage, imgproxy, Envoy, Mailpit, and Caddy. Studio/meta, Edge Functions, Supavisor and the frontend are optional profiles. No Supabase Cloud service is used.

The backend is installed under `/opt/lpg` on `20.40.48.3`. Use SSH with the existing private key path; never copy the key to the VPS. The private VPS `.env` uses `COMPOSE_FILE=compose.yml:compose.azure.yml` and `API_DOMAIN=api.lpg.20.40.48.3.sslip.io`. Only Caddy's ports 80/443 are public; administrative services are loopback or internal. Azure's Network Security Group must allow TCP 80/443. Caddy obtains and renews certificates automatically once those ports are reachable.

Verified on 2026-10-11: all nine backend containers run; all configured health checks pass. The public API at `https://api.lpg.20.40.48.3.sslip.io` has a trusted Let's Encrypt certificate and HTTP redirects to HTTPS. Auth signup/business setup, REST role/tenant boundaries, checkout/stock/receipt/printer configuration, Realtime WebSockets and private Storage upload/download pass through the public HTTPS endpoint. Counts and checksums for all 33 original public/Auth/Storage/migration tables still match the local source after fixture cleanup. Public administration routes return 404. Auth uses `https://floral-dew-443b.khandakarsifat.workers.dev/` as its production Site URL, and exact redirect URLs for that origin; allowed redirects and rejection of an unapproved redirect were tested. Cross-origin Auth preflight/requests from that origin pass. No browser UI or physical printer verification was performed.

```sh
cd /opt/lpg
sudo docker compose ps
sudo docker compose up -d
```

The VPS uses the same pinned Supabase images as local development, named persistent database/Storage/encryption-key volumes, bounded container memory, smaller database pools, two Envoy/Erlang workers, PostgreSQL tuning, and 1 GB of swap on the existing disk. The local `.env`, local Compose services and original local volumes are retained.

## Data and credentials

The initial deployment is a consistent physical PostgreSQL snapshot verified with `pg_verifybackup`, plus Storage and PostgreSQL custom configuration archives. Initial archives and table checksum manifests are kept in `/opt/lpg/backups`; local copies are stored in a private archive outside the repository. The restore script refuses to overwrite nonempty volumes. Do not rerun it on a running deployment. Database, dashboard and S3 protocol passwords are independently generated for the VPS; existing JWT signing and encryption keys are retained to preserve the copied Auth and encrypted data. Keep the VPS `.env` private (mode 600). Do not publish Compose's resolved configuration.

Local and VPS data are independent after the snapshot; this deployment does not synchronize subsequent changes. Backups are on the existing disks, not on a separate disaster recovery service. No additional Azure resources are provisioned.

Mailpit preserves the existing local email sink. It does not deliver password recovery or invitation emails externally. Configure a real SMTP provider before relying on email delivery. Existing email autoconfirm behavior is retained.

## Separately hosted frontend

Build the existing frontend on its own host with:

```dotenv
VITE_SUPABASE_URL=https://api.lpg.20.40.48.3.sslip.io
VITE_SUPABASE_ANON_KEY=<existing anon key from the private environment>
```

Use only the anon key, never a service-role key. Production builds accept a configured HTTPS self-hosted gateway; development keeps its loopback-only guard. The VPS `SITE_URL` is `https://floral-dew-443b.khandakarsifat.workers.dev/`; `ADDITIONAL_REDIRECT_URLS` contains that origin, its root URL and `/#/login`. Future redirect changes require recreating only Auth with `sudo docker compose up -d --no-deps auth`.

The production frontend is hosted on Cloudflare Pages. Set the build variables above, run `npm ci` and `npm run build`, and use `dist` as the output directory. For a dashboard upload, upload the contents of `dist` with `index.html` at the root. Keep the frontend origin aligned with the VPS Auth Site URL, allowed redirects and Windows print bridge origins. Generated bundles and upload archives are not source files and should be stored outside the repository when retained. The frontend is not running on the VPS.

USB printing still runs on the browser's Windows computer. Set `LPG_PRINT_ORIGINS` to the exact HTTPS frontend origin before starting `npm run print:bridge`. The bridge continues listening on `127.0.0.1:17891` and retains origin, Host and client-header checks. Browser local-network permission may be required. No printer bridge is hosted on the VPS.

For the current external frontend, use `LPG_PRINT_ORIGINS=https://floral-dew-443b.khandakarsifat.workers.dev` on the Windows computer. No local bridge configuration was changed during VPS deployment.
