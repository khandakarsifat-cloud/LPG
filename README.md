# LPG Manager

LPG Manager is a browser based operations app for LPG dealerships in Bangladesh. It covers sales, cylinder stock, purchases, suppliers, trucks, customers, and employees. The React frontend talks directly to a local, self hosted Supabase stack. This README describes the repository and the running local database as inspected on **2026-10-02**.

## Current status

The main operational screens are implemented. The financial ledger, business profile editing, low stock exception panel, and attendance integration are unfinished. The `zk-test/` attendance listener is a separate prototype.

The current local deployment uses the root [`compose.yml`](compose.yml) with a static frontend served by Nginx and Supabase services behind an Envoy gateway. A Supabase CLI configuration and SQL migrations remain under [`supabase/`](supabase/). The Compose database and Storage use existing external Docker volumes; a fresh clone alone does not recreate the current dataset or complete stack configuration.

| Area | Current behavior |
| --- | --- |
| Dashboard | Today's completed sales revenue, inventory movement count, active customer count, and sales feed with sale details. Receipt Printer configuration beside Open POS saves one USB printer per business. The stock exceptions panel is a placeholder. |
| POS | Product selection by cylinder mouth size; refill, package, and empty return line types; customer lookup or creation; retail and wholesale pricing; discounts, exchange fees, notes, and checkout. Refill quantity must match empty returns. Confirm & Print sends the completed sale directly to the configured USB ESC/POS printer through a Windows host bridge. Saved sales can be reprinted without creating another sale. |
| Inventory | Item registry, filled and empty balances, stock summaries, manual adjustments, recent movement feed, and per item history. |
| Customers | Customer list, search, creation, and phone based matching. Customer phone numbers accept numeric Bangladesh mobile formats `01XXXXXXXXX` and `08801XXXXXXXXX`. |
| Purchases | Draft purchase creation and editing, truck and gas plant association, item and cost entry, and completion that updates inventory. |
| Logistics | Truck registry, status and location changes, transits, cost breakdowns, and wallet balance display. |
| Gas plants | Plant directory with LPG brand association and area officer contacts. |
| Employees | Employee profiles, multiple phone numbers, employee types, business units, activation status, payment categories, and payment history. |
| Settings | LPG brand management. The business profile tab is a placeholder. |
| Finance | Route and placeholder screen only. |

## Architecture

- **Frontend:** React 19, TypeScript 6, Vite 8, React Router 7 with `HashRouter`, TanStack Query 5, Lucide icons, custom CSS, and jsPDF.
- **Authentication and data:** Supabase Auth, PostgREST, PostgreSQL 17, and SQL functions. `src/contexts/AuthContext.tsx` handles email/password sign in, business signup, and tenant profile loading. A protected layout guards the operational routes.
- **Data access:** Hooks in `src/hooks/` call a mix of Supabase RPCs and direct table queries or mutations. Tenant identity is associated with `user_profiles` and enforced through database policies and function logic. The browser client in `src/lib/supabase.ts` accepts only configured loopback Supabase URLs and rejects a service role or secret key.
- **Receipt printing:** A Node.js service in `print-bridge/` runs on the Windows host outside Docker, discovers Windows queues/USB devices, and sends raster ESC/POS receipts through Winspool RAW printing. Printer identity and 80/58 mm settings persist in the tenant-keyed `receipt_printers` table. Receipt content, formatting, discovery, configuration, and byte transport have separate boundaries.
- **Deployment:** `Dockerfile` builds the Vite bundle and serves it with Nginx. `compose.yml` defines the frontend, Envoy API gateway, Auth, PostgREST, Realtime, Storage, Studio, PostgreSQL, Supavisor, and supporting services. [`supabase/docker/README.md`](supabase/docker/README.md) documents the local Compose cutover and volume handling.

The database currently exposes **29 public tables** with RLS enabled, including `tenants`, `user_profiles`, `items`, `inventory_movements`, `customers`, `price_books`, `receipt_printers`, `sales`, `sale_items`, `purchases`, `purchase_items`, `trucks`, `transits`, `wallets`, `gas_plants`, `area_officers`, `lpg_brands`, and five employee tables. The employee phone table is named `employee_phone_numbers`. The inventory movement and employee payment records are intended as ledgers; see the SQL migrations for their exact constraints and triggers.

### Routes

Routes use URL hashes, for example `http://127.0.0.1:3001/#/pos`.

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

### Existing Compose deployment

The current machine has the required external volumes `lpg_db_data` and `lpg_storage_data` and a private root `.env`. The app and local Supabase stack can be started from the repository root with:

```powershell
docker compose up -d
docker compose ps
```

The frontend is on <http://127.0.0.1:3001>, the API gateway on <http://127.0.0.1:54321>, Studio on <http://127.0.0.1:54323>, and Mailpit on <http://127.0.0.1:54324>. The database and pooler are exposed locally on ports `54322` and `54329`. These bindings are loopback only.

The root [`.env.example`](.env.example) lists the Compose variables but contains placeholders. A usable `.env` needs valid local database, Auth, API, Storage, and gateway secrets. Keep that file private. The Vite build receives `VITE_SUPABASE_URL` and the **anon** key as build arguments; the service role and secret keys belong only in the server configuration. Existing database and Storage data live in external volumes, so `docker compose down` does not remove them. See the [Compose setup notes](supabase/docker/README.md) before restoring or replacing volumes.

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
```

### Direct USB receipt printing

Install the printer's Windows USB driver and Node.js 22.18 or newer on the host. With dependencies installed, run `npm run print:bridge` from the repository root and leave it running. The bridge listens only on `http://127.0.0.1:17891`; it is separate from Docker and uses no Supabase credentials. In Dashboard, open **Receipt Printer** to select the queue/device, paper width, printable dots, and optional cutter. **Refresh** rescans Windows without closing the modal. Disconnected configuration is retained.

Discovery reads installed Windows queues independently of saved configuration and bypasses browser caching. USB/port metadata failures show warnings while retaining the queue list; Windows queue enumeration errors are reported separately from having no printers. If the bridge stops, start it again and Refresh. Temporary diagnostics are available through `LPG_PRINT_DIAGNOSTICS=1`.

Use **Confirm & Print** at checkout, **Reprint Last Sale** in POS, or **Print Receipt Again** from a Dashboard sale. Printing failure leaves the completed sale saved. See the [Windows bridge setup and verification notes](print-bridge/README.md) for origin configuration, device matching, printer compatibility, job feedback, and tests.

### Migration state

There are nine SQL files in [`supabase/migrations/`](supabase/migrations/). The live database reports the first **six** plus both receipt-printer migrations (**eight** records total) in `supabase_migrations.schema_migrations`. The seventh file, `20260702164710_employees.sql`, is **not recorded as applied**, although its employee tables and related objects are present in the live database. Reconcile the schema and migration history before using CLI migration or reset commands against this data. The two receipt-printer migrations add the tenant configuration table and restrict its default privileges to reads and upserts. The older SQL files in `supabase/migrations_old_broken/` are historical and outside the active migration directory.

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
- The 2026-09-28 Supabase security advisor reported **71 findings**, including 32 `SECURITY DEFINER` functions callable by `anon`, six functions with mutable search paths, and an RLS enabled `permissions` table without a policy. These are review items; RLS being enabled alone does not prove every function or policy is safe. The performance advisor at that inspection reported **121 findings**, mainly overlapping permissive policies, unused indexes, unindexed foreign keys, and RLS expression costs.
- On 2026-10-02, the frontend and Docker builds, bridge typecheck, focused changed-file lint, and twelve bridge/checkout tests passed. Live discovery returned the USB printer after bridge startup/restart; repeated discovery requests succeeded and saved configuration remained unchanged. The user confirmed the modal/refresh checks and a marked diagnostic receipt with readable Bengali and working cutting. Tests cover queue renames, disconnected hardware, enumeration failures, and print/reprint deduplication. Full POS checkout/reprint browser flows remain unverified by the agent because no browser was connected. The build retains its large bundle warning. The root `npm run lint` failed because ESLint traversed `.temp/supabase-official/`, which references an unavailable `eslint-config-supabase/next` package. That temporary checkout is outside the application source.

All currency displays use Bangladeshi Taka formatting. This project is not affiliated with an LPG brand or cylinder manufacturer.
