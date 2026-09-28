# LPG Manager

LPG Manager is a browser based operations app for LPG dealerships in Bangladesh. It covers sales, cylinder stock, purchases, suppliers, trucks, customers, and employees. The React frontend talks directly to a local, self hosted Supabase stack. This README describes the repository and the running local database as inspected on **2026-09-28**.

## Current status

The main operational screens are implemented. The financial ledger, business profile editing, low stock exception panel, direct thermal printer support, and attendance integration are unfinished. The `zk-test/` attendance listener is a separate prototype.

The current local deployment uses the root [`compose.yml`](compose.yml) with a static frontend served by Nginx and Supabase services behind an Envoy gateway. A Supabase CLI configuration and SQL migrations remain under [`supabase/`](supabase/). The Compose database and Storage use existing external Docker volumes; a fresh clone alone does not recreate the current dataset or complete stack configuration.

| Area | Current behavior |
| --- | --- |
| Dashboard | Today's completed sales revenue, inventory movement count, active customer count, and sales feed with sale details. The stock exceptions panel is a placeholder. |
| POS | Product selection by cylinder mouth size; refill, package, and empty return line types; customer lookup or creation; retail and wholesale pricing; discounts, exchange fees, notes, and checkout. Refill quantity must match empty returns. A browser generated 80 mm PDF receipt can be opened for printing. |
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
- **Deployment:** `Dockerfile` builds the Vite bundle and serves it with Nginx. `compose.yml` defines the frontend, Envoy API gateway, Auth, PostgREST, Realtime, Storage, Studio, PostgreSQL, Supavisor, and supporting services. [`supabase/docker/README.md`](supabase/docker/README.md) documents the local Compose cutover and volume handling.

The database currently exposes **28 public tables** with RLS enabled, including `tenants`, `user_profiles`, `items`, `inventory_movements`, `customers`, `price_books`, `sales`, `sale_items`, `purchases`, `purchase_items`, `trucks`, `transits`, `wallets`, `gas_plants`, `area_officers`, `lpg_brands`, and five employee tables. The employee phone table is named `employee_phone_numbers`. The inventory movement and employee payment records are intended as ledgers; see the SQL migrations for their exact constraints and triggers.

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

### Migration state

There are seven SQL files in [`supabase/migrations/`](supabase/migrations/). The live database reports the first **six** in `supabase_migrations.schema_migrations`. The seventh file, `20260702164710_employees.sql`, is **not recorded as applied**, although its employee tables and related objects are present in the live database. Reconcile the schema and migration history before using CLI migration or reset commands against this data. The older SQL files in `supabase/migrations_old_broken/` are historical and outside the active migration directory.

## Project layout

| Path | Purpose |
| --- | --- |
| `src/App.tsx` | Route map and query client setup |
| `src/pages/` | Operational screens and authentication pages |
| `src/components/` | Shared layout and feature dialogs, grids, and lists |
| `src/hooks/` | Supabase queries and mutations by domain |
| `src/contexts/AuthContext.tsx` | Session and business profile state |
| `src/lib/` | Supabase client, phone validation, BDT formatting, receipt PDF, and theme helpers |
| `supabase/migrations/` | Active SQL migration files |
| `supabase/docker/` | Self hosted Supabase Compose support files and setup notes |
| `zk-test/test.cjs` | Standalone ZKTeco ADMS HTTP listener prototype on port 8000 |

## Known limitations and checks

- The PDF receipt uses the browser print flow. Direct ESC/POS printer communication is not implemented.
- `zk-test/test.cjs` handles device handshakes and logs pushed attendance records, but it does not persist them or connect them to employees in the app.
- The settings business profile, finance route, and dashboard stock exceptions panel are placeholders. Reporting, staff role management UI, and offline operation are not implemented.
- The current Supabase security advisor reports **71 findings**, including 32 `SECURITY DEFINER` functions callable by `anon`, six functions with mutable search paths, and an RLS enabled `permissions` table without a policy. These are review items; RLS being enabled alone does not prove every function or policy is safe. The performance advisor reports **121 findings**, mainly overlapping permissive policies, unused indexes, unindexed foreign keys, and RLS expression costs.
- On 2026-09-28, `npm run build` passed with a large bundle warning. The root `npm run lint` failed because ESLint traversed `.temp/supabase-official/`, which references an unavailable `eslint-config-supabase/next` package. That temporary checkout is outside the application source.

All currency displays use Bangladeshi Taka formatting. This project is not affiliated with an LPG brand or cylinder manufacturer.
