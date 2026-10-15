# LPG Manager

LPG Manager is a browser based operations app for LPG dealerships in Bangladesh. It covers sales, cylinder stock, purchases, suppliers, trucks, customers, and employees. The React frontend talks directly to self hosted Supabase: local Docker for development and Azure for production. The production frontend is hosted separately on Cloudflare Workers Static Assets. Production deployment and purchase acceptance were verified on **2026-10-15**; older security advisor snapshots retain their original dates below.

## Current status

The main operational screens are implemented. The financial ledger, business profile editing, low stock exception panel, and attendance integration are unfinished. The `zk-test/` attendance listener is a separate prototype.

The current local deployment uses the root [`compose.yml`](compose.yml) with a static frontend served by Nginx and Supabase services behind an Envoy gateway. A Supabase CLI configuration and SQL migrations remain under [`supabase/`](supabase/). The Compose database and Storage use existing external Docker volumes; a fresh clone alone does not recreate the current dataset or complete stack configuration.

| Area | Current behavior |
| --- | --- |
| Dashboard | Today's completed sales revenue, inventory movement count, active customer count, and sales feed with sale details. Receipt Printer configuration beside Open POS saves one USB printer per business. The stock exceptions panel is a placeholder. |
| POS | Product selection by cylinder mouth size; refill, package, and empty return line types; customer lookup or creation; retail and wholesale pricing; discounts, exchange fees, notes, and checkout. Refill quantity must match empty returns. Confirm & Print sends the completed sale directly to the configured USB ESC/POS printer through a Windows host bridge. Saved sales can be reprinted without creating another sale. |
| Inventory | Item registry, filled and empty balances, stock summaries, recent movement feed, and per item history. No manual adjustment dialog is exposed in the current UI. |
| Customers | Customer list, search, creation, and phone based matching. Customer phone numbers accept numeric Bangladesh mobile formats `01XXXXXXXXX` and `08801XXXXXXXXX`. |
| Purchases | Compact searchable Created orders, one-empty-per-refill dispatch to In Transit, editable expected-default receipt quantities and independent full payment. Commission reduces company payable; money locks on payment and Received + Paid purchases show a read-only summary and activity history. |
| Logistics | Truck registry, status and location changes, transits, cost breakdowns, and wallet balance display. |
| Gas plants | Plant directory with LPG brand association and area officer contacts. |
| Employees | Employee profiles, multiple phone numbers, employee types, business units, activation status, payment categories, and payment history. |
| Settings | LPG brand management. The business profile tab is a placeholder. |
| Finance | Route and placeholder screen only. |

## Technical documentation

Start with [the architecture and documentation map](docs/architecture.md) for module responsibilities, data flow, implementation boundaries and links to the sales/inventory, purchases/logistics and employee/payroll guides. Existing authorization, printing, deployment and operations guides remain the references for those subsystems.

## Architecture

- **Frontend:** React 19, TypeScript 6, Vite 8, React Router 7 with `HashRouter`, TanStack Query 5, Lucide icons, and custom CSS.
- **Authentication and authorization:** Supabase Auth, PostgREST, PostgreSQL 17, and SQL functions. `src/contexts/AuthContext.tsx` loads the trusted profile and effective RBAC permissions. Routes/navigation use capabilities; database policies and privileged RPCs enforce active membership, trusted tenancy and permission mappings independently of the UI. OWNER and MANAGER have the complete current permission set; SALESMAN has Dashboard, POS and saved receipt access. No platform ADMIN is implemented. See [tenant authorization](supabase/authorization.md).
- **Data access:** Hooks in `src/hooks/` call validated RPCs and tenant-scoped direct reads. Direct browser writes are limited to zero-stock item registration, customer creation and authorized printer configuration. Profiles and RBAC mappings are not browser-writable; stock, ledger, purchase, transit and employee/payroll workflows stay behind gated RPCs. Internal helpers/triggers live in the unexposed `app_private` schema. The browser client in `src/lib/supabase.ts` accepts configured loopback Supabase URLs in development and HTTPS self-hosted URLs in production, and rejects a service role or secret key.
- **Receipt printing:** A Node.js service in `print-bridge/` runs on the Windows host outside Docker, discovers Windows queues/USB devices, and sends raster ESC/POS receipts through Winspool RAW printing. Printer identity and 80/58 mm settings persist in the tenant-keyed `receipt_printers` table. Receipt content, formatting, discovery, configuration, and byte transport have separate boundaries.
- **Deployment:** `Dockerfile` builds the Vite bundle and serves it with Nginx. `compose.yml` defines the frontend, Envoy API gateway, Auth, PostgREST, Realtime, Storage, Studio, PostgreSQL, Supavisor, and supporting services. [`supabase/docker/README.md`](supabase/docker/README.md) documents the local Compose cutover and volume handling.

The deployed database exposes **30 public tables**, all with RLS enabled, including `tenants`, `user_profiles`, `items`, `inventory_movements`, `customers`, `price_books`, `receipt_printers`, `sales`, `sale_items`, `purchases`, `purchase_items`, `purchase_activity`, `trucks`, `transits`, `wallets`, `gas_plants`, `area_officers`, `lpg_brands`, and five employee tables. The employee phone table is named `employee_phone_numbers`. See the SQL migrations for ledger constraints and triggers.

### Routes

Routes use URL hashes, for example `http://127.0.0.1:3001/#/pos`.

The top bar shows the current page name, theme control and dealership wallet for users with wallet read permissions. The sidebar account beneath the business name opens the sign-out menu and remains available on mobile. Purchases uses page scrolling, four separated overview figures, company-led cards with product lists and one total purchase cost row, token search (spaces AND, commas OR), shipment/payment and inclusive date filters, and date/amount sorting with a reset action. Details remain in the purchase summary. A negative wallet balance is displayed as a deficit. Shared dropdown styling covers pages and modals; date fields include a keyboard-accessible calendar with month/year navigation, Today, Clear and range limits.

| Route | Screen |
| --- | --- |
| `#/` | Dashboard |
| `#/pos` | Point of sale |
| `#/inventory` | Inventory |
| `#/customers` | Customers |
| `#/purchases` | Purchases |
| `#/logistics` | Trucks and transits |
| `#/gas-plants` | Gas plants and area officers |
| `#/employees` | Employees and payments |
| `#/settings` | Business profile placeholder and LPG brands |
| `#/finance` | Financial ledger placeholder |
| `#/login`, `#/register` | Authentication and business registration |

## Local setup

Use [OPERATIONS.md](OPERATIONS.md) as the single command guide for choosing local Docker/development/build actions, Azure/Cloudflare deployments, configuration, tests, printing and recovery.

### Existing Compose deployment

The current machine has the required external volumes `lpg_db_data` and `lpg_storage_data` and a private root `.env`. The app and local Supabase stack can be started from the repository root with:

```powershell
docker compose up -d
docker compose ps
```

The frontend is on <http://127.0.0.1:3001>, the API gateway on <http://127.0.0.1:54321>, Studio on <http://127.0.0.1:54323>, and Mailpit on <http://127.0.0.1:54324>. The database and pooler are exposed locally on ports `54322` and `54329`. These bindings are loopback only.

The root [`.env.example`](.env.example) lists the Compose variables but contains placeholders. A usable `.env` needs valid local database, Auth, API, Storage, and gateway secrets. Keep that file private. The Vite build receives `VITE_SUPABASE_URL` and the **anon** key as build arguments; the service role and secret keys belong only in the server configuration. Existing database and Storage data live in external volumes, so `docker compose down` does not remove them. See the [Compose setup notes](supabase/docker/README.md) before restoring or replacing volumes.

### Azure backend deployment

The backend-only VPS configuration is [`compose.azure.yml`](compose.azure.yml), layered over the local Compose file using a separate private VPS environment. The frontend is hosted separately. See [`deploy/README.md`](deploy/README.md) for resource limits, HTTPS, data preservation, optional services, frontend build variables and Auth redirect configuration. Local Compose and local data remain independent and functional.

The API is available at <https://api.lpg.20.40.48.3.sslip.io> with trusted HTTPS, verified on **2026-10-11**. Auth redirects were configured for <https://floral-dew-443b.khandakarsifat.workers.dev/> during that deployment. No frontend container runs on the VPS.

The production Supabase dashboard is available at <https://api.lpg.20.40.48.3.sslip.io/project/default>. It requires the VPS `DASHBOARD_USERNAME` / `DASHBOARD_PASSWORD` login and administers production data. Studio and its metadata service are retained by backend deployments; see [dashboard access](deploy/README.md#production-dashboard).

For repeatable Windows deployments, configure the ignored `deploy/.env.backend` and `deploy/.env.frontend` files from their example templates. Run `npm run deploy:backend`, `npm run deploy:frontend`, or `npm run deploy:all` (backend health must pass before frontend publication). Add `-- --check` for local validation without SSH or publication. The VPS environment is never uploaded or replaced; pending database migrations require explicit version approval. The frontend command builds `dist` with isolated production settings and publishes to the existing Worker using the pinned Wrangler CLI. See [deployment setup and recovery](deploy/README.md).

### Frontend development

With the local Supabase gateway already running, install dependencies and start Vite:

```powershell
npm ci
npm run dev
```

Configure `.env.local` with `VITE_SUPABASE_URL=http://127.0.0.1:54321` and the matching local `VITE_SUPABASE_ANON_KEY`. Vite normally serves on <http://localhost:5173>. The client also accepts `http://localhost:54321` and `http://127.0.0.1:55421`; cloud Supabase URLs are rejected by the current client configuration.

Other scripts:

```powershell
npm run build
npm run lint
npm run preview
npm run auth:test
npm run purchase:test
npm run purchase:db:test
npm run auth:db:test
npm run auth:api:test
```

### Direct USB receipt printing

Install the printer's Windows USB driver and Node.js 22.18 or newer on the host. With dependencies installed, run `npm run print:bridge` from the repository root and leave it running. The bridge listens only on `http://127.0.0.1:17891`; it is separate from Docker and uses no Supabase credentials. In Dashboard, open **Receipt Printer** to select the queue/device, paper width, printable dots, and optional cutter. **Refresh** rescans Windows without closing the modal. Disconnected configuration is retained.

Discovery reads installed Windows queues independently of saved configuration and bypasses browser caching. USB/port metadata failures show warnings while retaining the queue list; Windows queue enumeration errors are reported separately from having no printers. If the bridge stops, start it again and Refresh. Temporary diagnostics are available through `LPG_PRINT_DIAGNOSTICS=1`.

Use **Confirm & Print** at checkout, **Reprint Last Sale** in POS, or **Print Receipt Again** from a Dashboard sale. Printing failure leaves the completed sale saved. See the [Windows bridge setup and verification notes](print-bridge/README.md) for origin configuration, device matching, printer compatibility, job feedback, and tests.

### Migration state

All **sixteen** repository migrations match production history, verified on **2026-10-15**. The purchase migrations add Created status, independent payment, commission, actual receipt, activity and atomic stock/shipment/settlement rules; the ownership migration aligns helpers and RPCs with the existing `postgres` application owner. `20261014183416_purchase_refill_exchange.sql` restores one empty per expected refill on Created plans while retaining recorded quantities on existing dispatched shipments. The compact Purchases frontend is published to the existing Cloudflare Worker. Existing stock balances, inventory movements, wallet balances and transactions were unchanged by deployment and live acceptance testing; fixture accounts and businesses were removed. The [purchase workflow](docs/modules/purchases-and-logistics.md) explains billing and compatibility. The [migration audit](supabase/migration-audit.md) is an older snapshot; [authorization](supabase/authorization.md) documents permission gates and platform-superuser requirements.

## Project layout

| Path | Purpose |
| --- | --- |
| `src/App.tsx` | Route map and query client setup |
| `src/pages/` | Operational screens and authentication pages |
| `src/components/` | Shared layout and feature dialogs, grids, and lists |
| `src/hooks/` | Supabase queries and mutations by domain |
| `src/contexts/AuthContext.tsx` | Session and business profile state |
| `src/lib/` | Supabase client, phone validation, BDT formatting, receipt/printing helpers, and theme helpers |
| `print-bridge/` | Windows host discovery, ESC/POS receipt formatting/rendering, RAW transport, localhost API, and print-job deduplication |
| `supabase/migrations/` | Active SQL migration files |
| `supabase/docker/` | Self hosted Supabase Compose support files and setup notes |
| `zk-test/test.cjs` | Standalone ZKTeco ADMS HTTP listener prototype on port 8000 |

## Known limitations and checks

- Direct printing requires a running bridge on the browser's Windows computer, an installed USB queue/device, and compatible ESC/POS raster commands. Ethernet transport and automatic bridge startup are not implemented. Windows job acceptance cannot guarantee physical completion for every driver; uncertain jobs must be checked before explicit reprinting.
- `zk-test/test.cjs` handles device handshakes and logs pushed attendance records, but it does not persist them or connect them to employees in the app.
- The settings business profile, finance route, and dashboard stock exceptions panel are placeholders. Reporting, staff role management UI, and offline operation are not implemented.
- The 2026-10-05 security advisor reports 29 authenticated definer RPC warnings and 13 informational RLS-without-policy entries for internal/RPC-only tables. These reflect intentional gated workflows; anonymous function execution and mutable function-path findings are removed. The database has 20 capability-based policies, 29 public RPCs and 13 private helpers/triggers. Staff membership/role administration remains a trusted server/database operation without a browser management API.
- On 2026-10-05, authorization SQL suites and REST integration tests passed for all three roles, cross-tenant access, reused entity UUIDs, escalation/profile reassignment denial, mapping-driven permission changes, active membership, internal execution restrictions and legitimate workflows. Real REST signup/setup, checkout, receipt/creator embeds and printer upserts passed. Frontend build, focused lint, three route-permission tests, bridge typecheck and twelve bridge/checkout tests passed. No physical print jobs were sent. Full browser UI checkout/reprint remains unverified; the existing bundle-size warning remains.
- On 2026-10-02, the frontend and Docker builds, bridge typecheck, focused changed-file lint, and twelve bridge/checkout tests passed. Live discovery returned the USB printer after bridge startup/restart; repeated discovery requests succeeded and saved configuration remained unchanged. The user confirmed the modal/refresh checks and a marked diagnostic receipt with readable Bengali and working cutting. Tests cover queue renames, disconnected hardware, enumeration failures, and print/reprint deduplication. Full POS checkout/reprint browser flows remain unverified by the agent because no browser was connected. The build retains its large bundle warning. The root `npm run lint` failed because ESLint traversed `.temp/supabase-official/`, which references an unavailable `eslint-config-supabase/next` package. That temporary checkout is outside the application source.

All currency displays use Bangladeshi Taka formatting. This project is not affiliated with an LPG brand or cylinder manufacturer.
- Purchase SQL, authorization and receipt suites pass on VPS PostgreSQL 17.6 with rolled-back fixtures. Real Auth/PostgREST acceptance covers concurrent creation, dispatch, full payment, receipt and truck allocation, both payment orderings, operating costs and tenant isolation. Fixture businesses/accounts were removed. Published HTML/asset hashes and browser login/route protection match the production build; full purchase UI scenarios were verified with browser API fixtures. Deployment safety tests, build and focused lint pass; the existing bundle-size warning remains.
