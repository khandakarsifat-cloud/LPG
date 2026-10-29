# LPG Manager

LPG Manager is a browser based operations app for LPG dealerships in Bangladesh. It covers sales, cylinder stock, purchases, suppliers, trucks, customers, and employees. The React frontend talks directly to self hosted Supabase: local Docker and the primary VPS at `144.79.249.4`. The published frontend is hosted separately on Cloudflare Workers Static Assets. POS and Purchase transaction integrity use the primary VPS backend and Cloudflare frontend; source and ordered migrations define the current business rules.

This project is in active development. The application on the production VPS infrastructure and Cloudflare frontend remains a development environment; deployment variables still use their established `PRODUCTION_*` names. [AGENTS.md](AGENTS.md) defines development normalization and the compatibility/data-preservation policy that must replace it before production.

## Current status

The main operational screens are implemented. Business profile editing, the low stock exception panel, and attendance integration are unfinished. The `zk-test/` attendance listener is a separate prototype.

The current local deployment uses the root [`compose.yml`](compose.yml) with a static frontend served by Nginx and Supabase services behind an Envoy gateway. A Supabase CLI configuration and SQL migrations remain under [`supabase/`](supabase/). The Compose database and Storage use existing external Docker volumes; a fresh clone alone does not recreate the current dataset or complete stack configuration.

| Area | Current behavior |
| --- | --- |
| Dashboard | Today's completed sales revenue, inventory movement count, active customer count, and sales feed with sale details. Receipt Printer configuration beside Open POS saves one USB printer per business. The stock exceptions panel is a placeholder. |
| POS | Product selection by cylinder mouth size; refill, package, and empty return line types; customer lookup or creation; retail and wholesale pricing locked to the selected customer, with whole-cart repricing on customer selection or draft tier changes; a saved retail/wholesale classification per sale; discounts, exchange costs, notes, and checkout. Refill quantity must match empty returns. Checkout defaults to full Cash Register payment; Advanced Payments supports split/partial payments and customer dues. Received Bottles opens collapsed with count totals, separating product obligations from physical receipts with partial/zero receipt, quantity steppers and aggregate settlement. Cart and receipts show packages, refills, then empty bottles in Settings brand order. Confirm & Print uses the selected browser dialog or USB bridge and a separate 58/80mm layout. Saved sales can be reprinted without creating another sale. |
| Sales | Compact server-paged sales directory with combined money/bottle status, type, date, token search and sorting. Transaction details separate expected and received bottle lists. Bottle collections use a compact searchable, brand-ordered quantity grid with pagination; independent money collections, optional customer settlement costs, recovery and immutable history are preserved. |
| Inventory | Scrollable brand-ordered catalog, compact stock/catalog summaries, Add Item beside them, and brand-ordered products sorted by weight. Owners maintain prices and separate refill/package commission rates with private history. Buying estimates deduct the corresponding manual commission; product details include eight Saturday–Friday history weeks. Brand order is set in Settings. Inventory history has source/product/date-range filters and linked sale/purchase details; commission editing opens a popup from buying estimates. No manual adjustment dialog is exposed. |
| Customers | Paginated retail/wholesale cards, business-wide overview, AND/OR search, monetary sold/due, name and Last Sale sorting with unified date/product/activity filters; creation/editing and customer transaction history. Customers and Inventory share one product picker and a dedicated transaction detail modal. Numeric Bangladesh mobile formats remain `01XXXXXXXXX` and `08801XXXXXXXXX`. |
| Purchases | Server-paged searchable orders and a header-only financial overview, grouped refill-shortage warnings, one-empty-per-refill dispatch, automatic expected-quantity receipt, independent partial/multi-wallet payments, OWNER-confirmed pre-receipt cancellation, and staged partial refunds with preserved transit expenses. Detail modals stay open after saves and payment. |
| Logistics | Truck registry, client/destination transit details, completion/cancellation workflow, editable operating costs until confirmed closure, client refunds and wallet balances. |
| Gas plants | Plant directory with LPG brand association and area officer contacts. |
| Employees | Compact adaptive directory and contextual profiles, dated salary/status revisions, automatic fixed salary months, past/current/future partial payments using one wallet per payment, named bonuses, audited returns and unified activity. Linked driver/helper payouts settle saved Logistics costs once. |
| Settings | LPG brand management. The business profile tab is a placeholder. |
| Finance | Default and custom wallets, audited transfers/adjustments, server-paged searchable ledger, and customer dues with wallet-attributed collections. |

## Technical documentation

Start with [the architecture and documentation map](docs/architecture.md) for module responsibilities, data flow, implementation boundaries and links to the sales/inventory, purchases/logistics and employee/payroll guides. Existing authorization, printing, deployment and operations guides remain the references for those subsystems.

The [primary VPS guide](deploy/production-vps.md) records the verified security, Docker, HTTPS and maintenance configuration on `144.79.249.4`. The application is a clean installation with independent credentials; the former Azure backend remains untouched.

## Architecture

- **Frontend:** React 19, TypeScript 6, Vite 8, React Router 7 with `HashRouter`, TanStack Query 5, Lucide icons, and custom CSS. Page code and its styles load on demand; the shared navigation, Auth provider and query cache stay mounted during route loading.
- **Authentication and authorization:** Supabase Auth, PostgREST, PostgreSQL 17, and SQL functions. `src/contexts/AuthContext.tsx` loads the trusted profile and effective RBAC permissions. Routes/navigation use capabilities; database policies and privileged RPCs enforce active membership, trusted tenancy and permission mappings independently of the UI. OWNER and MANAGER have the complete current capability set, with an additional OWNER requirement for inventory price/commission editing and purchase cancellation; SALESMAN has Dashboard, POS and saved receipt access. No platform ADMIN is implemented. See [tenant authorization](supabase/authorization.md).
- **Data access:** Hooks in `src/hooks/` call validated RPCs and tenant-scoped direct reads. Direct browser writes are limited to zero-stock item registration, customer creation and authorized printer configuration. Profiles and RBAC mappings are not browser-writable; stock, ledger, purchase, transit and employee/payroll workflows stay behind gated RPCs. Internal helpers/triggers live in the unexposed `app_private` schema. The browser client in `src/lib/supabase.ts` accepts configured loopback Supabase URLs in development and HTTPS self-hosted URLs in production, and rejects a service role or secret key. Browser sessions are scoped to the full backend host and port, so changing environments does not reuse another backend's cached login.
- **Receipt printing:** A Node.js service in `print-bridge/` runs on the Windows host outside Docker, discovers Windows queues/USB devices, and sends raster ESC/POS receipts through Winspool RAW printing. Printer identity and 80/58 mm settings persist in the tenant-keyed `receipt_printers` table. Receipt content, formatting, discovery, configuration, and byte transport have separate boundaries.
- **Deployment:** `Dockerfile` builds the Vite bundle and serves it with Nginx. `compose.yml` defines the frontend, Envoy API gateway, Auth, PostgREST, Realtime, Storage, Studio, PostgreSQL, Supavisor, and supporting services. [`supabase/docker/README.md`](supabase/docker/README.md) documents the local Compose cutover and volume handling.

The application public tables all have RLS enabled, including `tenants`, `user_profiles`, `items`, `inventory_movements`, `customers`, `price_books`, `product_commission_rates`, `receipt_printers`, `sales`, `sale_items`, `purchases`, `purchase_items`, `purchase_activity`, `trucks`, `transits`, `wallets`, `sale_payments`, `purchase_payments`, `purchase_refund_obligations`, `finance_requests`, `gas_plants`, `area_officers`, `lpg_brands`, and eight employee tables. The employee phone table is named `employee_phone_numbers`. See the SQL migrations for ledger constraints and triggers.

### Routes

Routes use URL hashes, for example `http://127.0.0.1:3001/#/pos`.

The top bar shows the current page name, theme control and combined wallet balance for users with wallet read permissions. The sidebar account beneath the business name opens the sign-out menu and remains available on mobile. Purchases uses page scrolling, four separated overview figures, company-led cards with product lists and one total purchase cost row, token search (spaces AND, commas OR), shipment/payment and inclusive date filters, and date/amount sorting with a reset action. Details remain in the purchase summary. A negative wallet balance is displayed as a deficit. Shared dropdown styling covers pages and modals; date fields include a keyboard-accessible calendar with month/year navigation, Today, Clear and range limits.

Pages grow within one scrolling workspace, with local horizontal scrolling for wide tables. Shared container-aware grids use compact gaps, bounded widths and consistent card heights by listing type. Sales and Purchases share aligned card sections and a bounded product preview that fades only when it overflows; all statuses and financial totals stay visible, with complete products in details. POS columns follow product space without a fixed column ceiling; checkout stacks when the workspace is at most 52rem wide. Desktop checkout retains its bounded height, bottom action and scrolling cart. Inventory, POS and product/bottle pickers start each brand on a new row in Settings order. Amount editors use left-aligned plain decimals without inserting grouping separators while editing.

Customers, Purchases and Sales display three measured rows, or at least ten records in narrow containers rounded to whole rows, while independently caching backend batches of 25. Cards and page/range indicators update together after required batches load; the previous complete page stays visible during navigation. Resizing preserves the record anchor and reuses cached batches. Gas plants, brands and transit groups share measured display pagination. Compact product/bottle pickers use two to four rows, account for brand row boundaries, and preserve selections across pages/searches. Employee/fleet tables retain twelve desktop/four phone pages; local catalogs read bounded server ranges without silently truncating at the API limit. Server histories retain bounded limits. Purchase activity combines lifecycle events, payments and refunds chronologically, with each wallet ledger entry shown once. Inventory and POS catalogs scroll without pagination. See [adaptive layout](docs/modules/adaptive-layout.md).

Phone layouts use compact headers, in-page dropdowns on supporting browsers and labeled employee/fleet records with actions in view. Summary values retain their numeric hierarchy, and Inventory groups four small summary boxes inside one toolbar. Login and registration keep their forms near the top on phones. Layouts use dynamic viewport units and container queries; native installed-PWA behavior still requires device acceptance.

| Route | Screen |
| --- | --- |
| `#/` | Dashboard |
| `#/pos` | Point of sale |
| `#/sales` | Sales and money/bottle settlement |
| `#/inventory` | Inventory |
| `#/customers` | Customers |
| `#/purchases` | Purchases |
| `#/logistics` | Trucks and transits |
| `#/gas-plants` | Gas plants and area officers |
| `#/employees` | Employees and payments |
| `#/settings` | Business profile placeholder and LPG brands |
| `#/finance` | Wallets, unified ledger and customer dues |
| `#/login`, `#/register` | Authentication and business registration |

## Local setup

Use the commands below for development and checks, [deployment and recovery](deploy/README.md) for VPS/Cloudflare, and [printing](print-bridge/README.md) for Windows setup.

### Existing Compose deployment

The current machine has the required external volumes `lpg_db_data` and `lpg_storage_data` and a private root `.env`. The app and local Supabase stack can be started from the repository root with:

```powershell
docker compose up -d
docker compose ps
```

The frontend is on <http://127.0.0.1:3001>, the API gateway on <http://127.0.0.1:54321>, Studio on <http://127.0.0.1:54323>, and Mailpit on <http://127.0.0.1:54324>. The database and pooler are exposed locally on ports `54322` and `54329`. These bindings are loopback only.

The root [`.env.example`](.env.example) lists the Compose variables but contains placeholders. A usable `.env` needs valid local database, Auth, API, Storage, and gateway secrets. Keep that file private. The Vite build receives `VITE_SUPABASE_URL` and the **anon** key as build arguments; the service role and secret keys belong only in the server configuration. Existing database and Storage data live in external volumes, so `docker compose down` does not remove them. See the [Compose setup notes](supabase/docker/README.md) before restoring or replacing volumes.

### Primary VPS backend deployment

The backend-only VPS configuration is [`compose.vps.yml`](compose.vps.yml), layered over the local Compose file using a separate private VPS environment. The frontend is hosted separately. See [`deploy/README.md`](deploy/README.md) for resource limits, HTTPS, data preservation, optional services, frontend build variables and Auth redirect configuration. Local Compose and local data remain independent and functional.

The API is available at <https://api.lpg.144.79.249.4.sslip.io> with trusted HTTPS, verified on **2026-10-28**. Auth redirects were configured for <https://floral-dew-443b.khandakarsifat.workers.dev/> for this primary backend. No frontend container runs on the VPS.

The deployed development Supabase dashboard is available at <https://api.lpg.144.79.249.4.sslip.io/project/default>. It requires the VPS `DASHBOARD_USERNAME` / `DASHBOARD_PASSWORD` login and administers development data. Studio and its metadata service are retained by backend deployments; see [dashboard access](deploy/README.md#production-dashboard).

For repeatable Windows deployments, configure the ignored `deploy/.env.backend` and `deploy/.env.frontend` files from their example templates. Run `npm run deploy:backend`, `npm run deploy:frontend`, or `npm run deploy:all` (backend health must pass before frontend publication). Add `-- --check` for local validation without SSH or publication. Routine updates never upload or replace the VPS environment; first installation generates independent credentials on the verified empty server. pending database migrations require explicit version approval. The frontend command builds `dist` with isolated production settings and publishes to the existing Worker using the pinned Wrangler CLI. See [deployment setup and recovery](deploy/README.md).

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

### Installed Android app

Install the published site from Chrome's **Install app** menu. [The manifest](public/manifest.webmanifest) requests standalone display, with a stable `/` identity, launch URL and scope. Hash routes, login and reloads stay on the same origin within that scope. Keep the manifest URL and identity stable across deployments; the deployment build validates the manifest and its 192/512 px install icons before publication.

An older installation created without a manifest may retain Chrome's browser-style header. Close and reopen it after visiting the updated site; if the header remains, remove that installed app/shortcut and install again from the published root URL. A shortcut's stored browser mode cannot reliably be upgraded by page code. You may need to sign in again; server business records are unaffected. This app requires a network connection and has no service worker or offline cache. Android installation and browser chrome still require physical-device acceptance.

### Receipt printing

Choose **Browser printing (Chrome/system dialog)** alongside the USB printer in Dashboard printer settings, checkout, or reprint controls. It needs no bridge and opens a receipt-only print dialog with the browser's installed printers and Save as PDF. The output method is remembered per business in this browser; shared USB configuration is retained. With no USB configuration, printing defaults to the browser dialog.

For direct USB printing, install the printer's Windows USB driver and Node.js 22.18 or newer on the host. With dependencies installed, run `npm run print:bridge` from the repository root and leave it running. The bridge listens only on `http://127.0.0.1:17891`; it is separate from Docker and uses no Supabase credentials. Its default origin allowlist includes the existing Cloudflare frontend. In Dashboard, open **Receipt Printer** to select the queue/device, paper width, printable dots, and optional cutter. **Refresh** rescans Windows without closing the modal. Disconnected configuration is retained.

Discovery reads installed Windows queues independently of saved configuration and bypasses browser caching. USB/port metadata failures show warnings while retaining the queue list; Windows queue enumeration errors are reported separately from having no printers. If the bridge stops, start it again and Refresh. Temporary diagnostics are available through `LPG_PRINT_DIAGNOSTICS=1`.

Use **Confirm & Print** at checkout, **Reprint Last Sale** in POS, or **Print receipt** in saved sale details on Dashboard or Sales. Saved-sale printing first opens printer selection and the slip preview; only the print button inside that dialog dispatches a job. Printing failure leaves the completed sale saved. See the [Windows bridge setup and verification notes](print-bridge/README.md) for origin configuration, device matching, printer compatibility, job feedback, and tests.

### Migration state

The repository contains **39** migrations through `20261028100855_employee_single_wallet_payments.sql`. Employees use dated salary/status revisions, automatically established monthly salaries, direct payments for past/current/future months, named bonuses and linked trip allocations. Preparation, bulk payroll, advances and adjustment workflows have been removed. Historical employee payments retain their financial evidence without invented arrears or wallet postings. Already-applied migrations remain unchanged. The canonical development normalization removes retired RPC overloads, tracking/version flags, duplicated bottle expectations, duplicated product brand/weight storage and covered indexes. Original empty returns are converted once to physical receipt records without reposting stock or money. Product identity uses required `brand_id`, `size_kg` and mouth size; commission rows contain explicit refill and package rates.

All sales use the same payment and aggregate bottle model. Original immutable `empty_return` sale lines define expectations; immutable receipt lines identify actual products and quantities. Settlement is total expected minus total actually received, clamped at zero for each sale. Unexpected/excess products require acknowledgement. Additional Settlement Cost adds customer liability; only independently collected money credits wallets. Unattributed previously paid amounts remain explicit in settlement/receipts, without invented payment methods or wallet credits. Original invoices, actual purchase quantities, wallet opening balances and financial evidence remain intact. See the [audit and verification report](docs/reports/2026-10-26-canonical-development-audit.md) and [module guides](docs/architecture.md).

POS defaults to full Cash Register payment. Advanced Payments supports split and partial payments (including zero initial payment); only received funds credit wallets. Finance and saved-sale details support subsequent collections. A ledger trigger applies every wallet balance change atomically with its business operation. See [Finance](docs/modules/finance.md) for migration, accounting and permission rules. Checkout enforces active selling prices, wholesale fallback, finite two-decimal amounts, zero-priced empty returns and discounts no greater than subtotal. Selecting a saved customer locks retail/wholesale pricing to that customer's type; checkout rejects a mismatched type. Clearing the selection restores draft tier choice. Both POS and purchase creation retain an uncertain request in this browser tab for safe recovery across reloads. See [sales/inventory](docs/modules/sales-and-inventory.md) and [purchases/logistics](docs/modules/purchases-and-logistics.md).

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

- This is a fresh backend: Azure accounts and business data were not transferred. Register a new app account/business. Development email autoconfirm remains enabled; recovery/invitation email needs an SMTP provider. Daily encrypted backups and a private workstation recovery copy are configured, but independent managed offsite backup and external monitoring remain prerequisites for production use.

- The untuned 1 GiB database baseline passed a mixed-workload **11-active-business** 30-minute endurance test, with **10** the measured comfortable point and **12** failing the read-latency target under the existing 1 GiB database cap. Each fixture had 2,000 customers and 20,000 historical invoices. See the [BDIX capacity report](docs/reports/2026-10-29-bdix-vps-capacity.md) for workload, thresholds, resource evidence and limits. The [Azure customer-reporting benchmark](docs/reports/2026-10-23-customer-load-test.md) used a different read-only workload and is not directly comparable.
- Business profile editing, Dashboard stock exceptions and attendance integration remain unfinished. Employee salaries use fixed monthly amounts and wallet-attributed payments; historical payments retain explicit unknown wallet attribution.
- POS supports partial payments and subsequent collections. No saved-sale void/refund workflow is implemented. Cancelling checkout before submission has no business effects. Purchases support partial and multi-wallet payments after dispatch, independently of receiving. Only OWNER can cancel Created/In Transit purchases with exact `CANCEL`; Received purchases never cancel. Cancellation reverses dispatch operations immediately and leaves source-backed refunds pending until fully settled. Incurred transit expenses remain payable independently.
- `npm run build`, `npm run lint`, `node --test tests/*.test.ts`, `npm run print:test` and `npm run deploy:test` check different boundaries. SQL suites roll back their fixtures; `npm run purchase:db:test -- --replay-module <PGlite package directory> --deployment-batch` verifies the complete migration replay and eleven current SQL suites plus migration-normalization checks in a disposable engine.
- `python supabase/tests/run-transaction-concurrency.py` requires the configured Docker database and creates/removes only a new verification database. It exercises all eleven suites plus concurrent checkout, stock contention, purchase creation/dispatch/payment/receipt/cancellation and duplicate/competing collections, wallet transfers, aggregate bottle/customer-charge races, historical preservation and balance consistency. Add `--vps --root /opt/lpg` only when intentionally running on the established VPS checkout.
- `node supabase/tests/backend-api.mjs --vps` checks public health, CORS, private-route blocking, safe JWKS, ES256 Auth and a disposable Realtime WebSocket channel.
- `node supabase/tests/bottles-api.mjs --vps --browser` verifies real Auth/PostgREST and the published Sales/collection workflow on disposable businesses, checks the burner membership read-only, and compares existing business-data fingerprints after fixture cleanup. `tests/bottles.browser.cjs` covers responsive checkout/collection, optional notes and required product acknowledgements, same-request recovery after response loss and retained details.
- `node supabase/tests/employees-api.mjs --vps --browser` verifies real employee Auth/PostgREST and published employee/Logistics workflows in disposable businesses; `tests/employees.browser.cjs` covers responsive employee management and same-request recovery.
- Browser fixture suites cover desktop/phone layouts, tier changes, printing, purchase lifecycle and response-loss recovery. Fixture success does not establish production Auth/API behavior, physical printing or device keyboard/PWA acceptance.

All currency displays use Bangladeshi Taka formatting. This project is not affiliated with an LPG brand or cylinder manufacturer.
