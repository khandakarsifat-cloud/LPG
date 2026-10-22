# LPG Manager

LPG Manager is a browser based operations app for LPG dealerships in Bangladesh. It covers sales, cylinder stock, purchases, suppliers, trucks, customers, and employees. The React frontend talks directly to self hosted Supabase: local Docker for development and the existing Azure backend. The published frontend is hosted separately on Cloudflare Workers Static Assets. POS and Purchase transaction integrity use the existing Azure backend and Cloudflare frontend; source and ordered migrations define the current business rules.

## Current status

The main operational screens are implemented. Business profile editing, the low stock exception panel, and attendance integration are unfinished. The `zk-test/` attendance listener is a separate prototype.

The current local deployment uses the root [`compose.yml`](compose.yml) with a static frontend served by Nginx and Supabase services behind an Envoy gateway. A Supabase CLI configuration and SQL migrations remain under [`supabase/`](supabase/). The Compose database and Storage use existing external Docker volumes; a fresh clone alone does not recreate the current dataset or complete stack configuration.

| Area | Current behavior |
| --- | --- |
| Dashboard | Today's completed sales revenue, inventory movement count, active customer count, and sales feed with sale details. Receipt Printer configuration beside Open POS saves one USB printer per business. The stock exceptions panel is a placeholder. |
| POS | Product selection by cylinder mouth size; refill, package, and empty return line types; customer lookup or creation; retail and wholesale pricing locked to the selected customer, with whole-cart repricing on customer selection or draft tier changes; a saved retail/wholesale classification per sale; discounts, exchange fees, notes, and checkout. Refill quantity must match empty returns. Checkout defaults to full Cash Register payment; Advanced Payments supports split/partial payments and customer dues. Confirm & Print uses the selected browser dialog or USB bridge and a separate 58/80mm layout. Saved sales can be reprinted without creating another sale. |
| Inventory | Scrollable brand-grouped catalog, compact stock/catalog summaries, Add Item beside them, and brand-grouped products sorted by weight. Owners maintain prices and separate refill/package commission rates with private history. Buying estimates deduct the corresponding manual commission; product details include eight Saturday–Friday history weeks. Brand order is set in Settings. Inventory history has source/product/date-range filters and linked sale/purchase details; commission editing opens a popup from buying estimates. No manual adjustment dialog is exposed. |
| Customers | Paginated retail/wholesale cards, business-wide overview, AND/OR search, monetary sold/due, name and Last Sale sorting with unified date/product/activity filters; creation/editing and customer transaction history. Customers and Inventory share one product picker and a dedicated transaction detail modal. Numeric Bangladesh mobile formats remain `01XXXXXXXXX` and `08801XXXXXXXXX`. |
| Purchases | Server-paged searchable orders and a header-only financial overview, grouped refill-shortage warnings, one-empty-per-refill dispatch, automatic expected-quantity receipt, independent partial/multi-wallet payments, OWNER-confirmed pre-receipt cancellation, and staged partial refunds with preserved transit expenses. Detail modals stay open after saves and payment. |
| Logistics | Truck registry, client/destination transit details, completion/cancellation workflow, editable operating costs until confirmed closure, client refunds and wallet balances. |
| Gas plants | Plant directory with LPG brand association and area officer contacts. |
| Employees | Employee profiles, multiple phone numbers, employee types, business units, activation status, payment categories, and payment history. |
| Settings | LPG brand management. The business profile tab is a placeholder. |
| Finance | Default and custom wallets, audited transfers/adjustments, server-paged searchable ledger, and customer dues with wallet-attributed collections. |

## Technical documentation

Start with [the architecture and documentation map](docs/architecture.md) for module responsibilities, data flow, implementation boundaries and links to the sales/inventory, purchases/logistics and employee/payroll guides. Existing authorization, printing, deployment and operations guides remain the references for those subsystems.

The [new production VPS guide](deploy/production-vps.md) records the verified firewall, SSH, Docker and maintenance configuration on `144.79.249.4`, plus the prerequisites for its first controlled deployment. That VPS currently has no application stack; the existing Azure/Cloudflare updater does not bootstrap it.

## Architecture

- **Frontend:** React 19, TypeScript 6, Vite 8, React Router 7 with `HashRouter`, TanStack Query 5, Lucide icons, and custom CSS. Page code and its styles load on demand; the shared navigation, Auth provider and query cache stay mounted during route loading.
- **Authentication and authorization:** Supabase Auth, PostgREST, PostgreSQL 17, and SQL functions. `src/contexts/AuthContext.tsx` loads the trusted profile and effective RBAC permissions. Routes/navigation use capabilities; database policies and privileged RPCs enforce active membership, trusted tenancy and permission mappings independently of the UI. OWNER and MANAGER have the complete current capability set, with an additional OWNER requirement for inventory price/commission editing and purchase cancellation; SALESMAN has Dashboard, POS and saved receipt access. No platform ADMIN is implemented. See [tenant authorization](supabase/authorization.md).
- **Data access:** Hooks in `src/hooks/` call validated RPCs and tenant-scoped direct reads. Direct browser writes are limited to zero-stock item registration, customer creation and authorized printer configuration. Profiles and RBAC mappings are not browser-writable; stock, ledger, purchase, transit and employee/payroll workflows stay behind gated RPCs. Internal helpers/triggers live in the unexposed `app_private` schema. The browser client in `src/lib/supabase.ts` accepts configured loopback Supabase URLs in development and HTTPS self-hosted URLs in production, and rejects a service role or secret key.
- **Receipt printing:** A Node.js service in `print-bridge/` runs on the Windows host outside Docker, discovers Windows queues/USB devices, and sends raster ESC/POS receipts through Winspool RAW printing. Printer identity and 80/58 mm settings persist in the tenant-keyed `receipt_printers` table. Receipt content, formatting, discovery, configuration, and byte transport have separate boundaries.
- **Deployment:** `Dockerfile` builds the Vite bundle and serves it with Nginx. `compose.yml` defines the frontend, Envoy API gateway, Auth, PostgREST, Realtime, Storage, Studio, PostgreSQL, Supavisor, and supporting services. [`supabase/docker/README.md`](supabase/docker/README.md) documents the local Compose cutover and volume handling.

The application public tables all have RLS enabled, including `tenants`, `user_profiles`, `items`, `inventory_movements`, `customers`, `price_books`, `product_commission_rates`, `receipt_printers`, `sales`, `sale_items`, `purchases`, `purchase_items`, `purchase_activity`, `trucks`, `transits`, `wallets`, `sale_payments`, `purchase_payments`, `purchase_refund_obligations`, `finance_requests`, `gas_plants`, `area_officers`, `lpg_brands`, and five employee tables. The employee phone table is named `employee_phone_numbers`. See the SQL migrations for ledger constraints and triggers.

### Routes

Routes use URL hashes, for example `http://127.0.0.1:3001/#/pos`.

The top bar shows the current page name, theme control and combined wallet balance for users with wallet read permissions. The sidebar account beneath the business name opens the sign-out menu and remains available on mobile. Purchases uses page scrolling, four separated overview figures, company-led cards with product lists and one total purchase cost row, token search (spaces AND, commas OR), shipment/payment and inclusive date filters, and date/amount sorting with a reset action. Details remain in the purchase summary. A negative wallet balance is displayed as a deficit. Shared dropdown styling covers pages and modals; date fields include a keyboard-accessible calendar with month/year navigation, Today, Clear and range limits.

Pages grow within one scrolling workspace, with local horizontal scrolling for wide tables. POS shows one product per row on phones and two on tablets, with checkout below both. Desktop layouts fit up to four columns in the space left by navigation and checkout. Product cards have bounded widths, and stacked layouts offer checkout/products shortcuts. The desktop checkout sidebar fills the available workspace height even when empty, with its checkout action at the bottom. All cart lines share one scrollable list without pagination; short windows allow the cart body to scroll while retaining checkout. Purchase and customer directories cache backend batches of 25 independently of displayed pages. Desktop pages show three rows using the current grid column count, while phone pages show ten cards; page scrolling reaches all rows without resizing the cards. Navigation fetches only missing batches. Inventory history reads ten movements per page. Layouts use dynamic viewport units and container queries; native installed-PWA behavior still requires device acceptance.

Phone layouts use compact headers, in-page dropdowns on supporting browsers and labeled employee/fleet records with actions in view. Employee, truck, transit-group, gas-plant and brand directories show four entries per phone page; inventory shows its full catalog without pagination. Summary values retain their numeric hierarchy, and Inventory groups four small summary boxes inside one toolbar. Login and registration keep their forms near the top on phones.

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
| `#/finance` | Wallets, unified ledger and customer dues |
| `#/login`, `#/register` | Authentication and business registration |

## Local setup

Use the commands below for development and checks, [deployment and recovery](deploy/README.md) for Azure/Cloudflare, and [printing](print-bridge/README.md) for Windows setup.

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

### Receipt printing

Choose **Browser printing (Chrome/system dialog)** alongside the USB printer in Dashboard printer settings, checkout, or reprint controls. It needs no bridge and opens a receipt-only print dialog with the browser's installed printers and Save as PDF. The output method is remembered per business in this browser; shared USB configuration is retained. With no USB configuration, printing defaults to the browser dialog.

For direct USB printing, install the printer's Windows USB driver and Node.js 22.18 or newer on the host. With dependencies installed, run `npm run print:bridge` from the repository root and leave it running. The bridge listens only on `http://127.0.0.1:17891`; it is separate from Docker and uses no Supabase credentials. Its default origin allowlist includes the existing Cloudflare frontend. In Dashboard, open **Receipt Printer** to select the queue/device, paper width, printable dots, and optional cutter. **Refresh** rescans Windows without closing the modal. Disconnected configuration is retained.

Discovery reads installed Windows queues independently of saved configuration and bypasses browser caching. USB/port metadata failures show warnings while retaining the queue list; Windows queue enumeration errors are reported separately from having no printers. If the bridge stops, start it again and Refresh. Temporary diagnostics are available through `LPG_PRINT_DIAGNOSTICS=1`.

Use **Confirm & Print** at checkout, **Reprint Last Sale** in POS, or **Print Receipt Again** from a Dashboard sale. Printing failure leaves the completed sale saved. See the [Windows bridge setup and verification notes](print-bridge/README.md) for origin configuration, device matching, printer compatibility, job feedback, and tests.

### Migration state

The repository contains **30** migrations through `20261022181704_nonretryable_stale_edit_errors.sql`. Customer reporting leaves historical business records and balances untouched. Stale business edits use normal validation errors instead of custom serialization failures that PostgREST 14 can retry indefinitely. Apply pending migrations before the dependent frontend. Older POS checkout clients must still refresh to send a request ID. The deployment runner verifies the live history and requires exact approval for pending versions.

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

- Broad customer reporting can saturate the current development VPS under concurrent use. See the [640-business load report](docs/reports/2026-10-23-customer-load-test.md) for the measured request mix, dataset, latency, timeouts and scope; these are customer-reporting measurements rather than whole-application capacity guarantees.
- Business profile editing, Dashboard stock exceptions and attendance integration remain unfinished. Employee/payroll behavior is unchanged; payroll payments do not post to wallets.
- POS supports partial payments and subsequent collections. No saved-sale void/refund workflow is implemented. Cancelling checkout before submission has no business effects. Purchases support partial and multi-wallet payments after dispatch, independently of receiving. Only OWNER can cancel Created/In Transit purchases with exact `CANCEL`; Received purchases never cancel. Cancellation reverses dispatch operations immediately and leaves source-backed refunds pending until fully settled. Incurred transit expenses remain payable independently.
- `npm run build`, `npm run lint`, `node --test tests/*.test.ts`, `npm run print:test` and `npm run deploy:test` check different boundaries. SQL suites roll back their fixtures; `npm run purchase:db:test -- --replay-module <PGlite package directory> --deployment-batch` verifies the complete migration replay and nine SQL suites in a disposable engine.
- `python supabase/tests/run-transaction-concurrency.py` requires the configured Docker database and creates/removes only a new verification database. It exercises all nine suites plus concurrent checkout, stock contention, purchase creation/dispatch/payment/receipt/cancellation and duplicate/competing collections, wallet transfers and balance consistency. Add `--azure --root /opt/lpg` only when intentionally running on the established VPS checkout.
- Browser fixture suites cover desktop/phone layouts, tier changes, printing, purchase lifecycle and response-loss recovery. Fixture success does not establish production Auth/API behavior, physical printing or device keyboard/PWA acceptance.

All currency displays use Bangladeshi Taka formatting. This project is not affiliated with an LPG brand or cylinder manufacturer.
