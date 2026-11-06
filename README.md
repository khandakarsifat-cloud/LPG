# LPG Manager

LPG Manager is a browser based operations app for LPG dealerships in Bangladesh. It covers sales, cylinder stock, purchases, suppliers, vehicles, customers, and employees. The React frontend talks directly to self hosted Supabase: local Docker and the primary VPS at `144.79.249.4`. The published frontend is hosted separately on Cloudflare Workers Static Assets. POS and Purchase transaction integrity use the primary VPS backend and Cloudflare frontend; source and ordered migrations define the current business rules.

This project is in active development. The application on the production VPS infrastructure and Cloudflare frontend remains a development environment; deployment variables still use their established `PRODUCTION_*` names. [AGENTS.md](AGENTS.md) defines development normalization and the compatibility/data-preservation policy that must replace it before production.

## Current status

The main operational screens include employee attendance history and estimated presence through an HTTPS ZKTeco ADMS receiver. Business profile settings, configurable employee roles/weights, account appearance and per-product stock alerts are implemented. Physical attendance-device compatibility requires real-machine acceptance; see [attendance](docs/modules/attendance.md).

The current local deployment uses the root [`compose.yml`](compose.yml) with a static frontend served by Nginx and Supabase services behind an Envoy gateway. A Supabase CLI configuration and SQL migrations remain under [`supabase/`](supabase/). The Compose database and Storage use existing external Docker volumes; a fresh clone alone does not recreate the current dataset or complete stack configuration.

| Area | Current behavior |
| --- | --- |
| Dashboard | Four daily cards distinguish recognized revenue, accrued expenses/FIFO COGS, actual customer collections and completed sale counts, with real seven-day trends and yesterday comparisons. The Cash Register indicator excludes other wallets. Compact recent sales, configured LPG weights, stove-type unit totals (including zero-sales types), money/bottle dues, configurable low-stock alerts and paged source-linked business activity use server aggregates. Financial Entry, POS Printer and Open POS reuse their existing workflows. See [Dashboard definitions](docs/modules/dashboard.md). |
| POS | Gas / Stove Business catalog switch using one checkout, customer, sale, wallet, partial/split payment and receipt infrastructure. LPG retains refill/bottle settlement; stove products have no bottle/exchange workflow. Atomic stock and journal posting, recoverable requests, guarded owner cancellation and staged customer refunds are supported. |
| Sales | Compact server-paged sales directory with combined money/bottle status, type, date, token search and sorting. Transaction details separate expected and received bottle lists. Bottle collections use a compact searchable, brand-ordered quantity grid with pagination; independent money collections, optional customer settlement costs, recovery and immutable history are preserved. |
| Inventory | LPG and Stove catalogs, valued capital/loss adjustments and immutable movement history. LPG stores on-hand Gas and Bottle, displayed as Filled and Empty. Separate FIFO acquisitions retain original shell costs and dates through supplier custody, receipt and returns. Customer exchange bottles enter at immutable current received-brand Bottle prices. POS/product views retain Refill, Package and Empty terminology. Manual purchase rebates settle supplier bills without changing prices or FIFO. |
| Customers | Paginated retail/wholesale cards, business-wide overview, AND/OR search, monetary sold/due, name and Last Sale sorting with server-side Payment Due / Bottle Due / Both / None filters and unified date/product/activity filters; creation/editing and customer transaction history. Customers and Inventory share one product picker and a dedicated transaction detail modal. Numeric Bangladesh mobile formats remain `01XXXXXXXXX` and `08801XXXXXXXXX`. |
| Purchases | LPG retains plant, empty dispatch, vehicle transit and receipt workflows. Stove purchases use suppliers with direct receipt or optional internal Logistics delivery. Both reuse credit, partial/multi-wallet payments and source-backed refunds. Quantities and costs freeze at receipt or first payment. Product forms group Gas/Bottle quantities and prices inside separate cards with current Filled/Empty stock; completion also locks the rebate. LPG cancellation remains pre-receipt; received stove cancellation requires reversible stock quantity and original carrying value. |
| Logistics | Vehicle/transit directories include service trips with visible Open/Finalized badges. Custom departures collect the full fee into Cash Register; confirmed completion saves costs, pays remaining crew/operating costs from Cash Register and returns the vehicle Home. Purchase receipt stays independent of cost completion. Owners may take vehicles out of service, restore them or permanently sell/dismantle them. Retirement preserves history, blocks new journeys and recognizes net proceeds less remaining book value. Explicit manual depreciation and vehicle service costs use the journal. |
| Gas plants | Settings section for the plant directory, LPG brands and area officer contacts; purchase destinations stay integrated. |
| Employees | Compact adaptive directory with predefined/custom job titles, effective device links in employee forms, literal calendar-date attendance with a configurable clock-out cutoff, compact earliest-in/latest-out daily records with missing punches left explicit, paginated daily/weekly/monthly attendance and audited corrections, selected salary month inside each profile, one daily attendance/employment/payment/transit/vehicle-assignment activity timeline, dated salary/status revisions, automatic fixed salary months, past/current/future partial payments using one wallet per payment, named bonuses, audited returns and unified activity. Directory cards show Clocked in / Clocked out status with its AM/PM time instead of salary; clocked-out cards also retain the arrival time. Profile attendance headings show clocked-in/out or unlinked status. Transit earnings and assignment histories share the activity timeline; transit payments stay separate from salary and bonus. |
| Settings | Compact category navigation for business profile/attendance, gas plants, LPG brands, employee roles, cylinder weights, financial types and account-specific appearance. Stove product types default to Single Stove, Double Stove, Regulator, Pipe and Others, with custom additions. Financial types select Withdrawal, Expense, Capital, Revenue or Equipment and saved LPG/Stove/Logistics percentages. Expense, withdrawal, revenue, capital and shared equipment entries retain historical allocation snapshots; system types/categories are read-only. Direct ADMS devices have approval, disable/removal and connection/upload status, with no fixed shop IP requirement. Removing a device closes its employee links and permits a fresh registration in another business while preserving history; pre-registration punches are skipped. Serial-only device identification remains an accepted development limitation. |
| Finance | Granular tab/action permissions and independent per-wallet use/balance/history controls. Product performance has shared-date LPG company/weight and Stove category/product reports. The current FIFO browser supports both businesses in one component table with projected margins, distinguishes reused owned bottles from new purchases and combines only consecutive equal-cost customer empty returns while preserving original layers. Summarized journals per financial action, pooled business Cash, real wallet ledger, Financial Entries, compact searchable Accounting Activity, borrowing/lending, assets and obligations. Detailed products, FIFO and actual settlements remain source evidence; historical journals are preserved. Each real wallet has one balance. Transfers move principal once without business reallocations or profit. LPG/Stove/Logistics and Combined tabular opening, movement and closing figures use the same authoritative report. Combined adds the separate business figures, retaining Logistics transport revenue and the buyer’s FIFO transport cost. |

## Technical documentation

Start with [the documentation index](documentation.md) or [the architecture and documentation map](docs/architecture.md) for module responsibilities, data flow, implementation boundaries and links to the sales/inventory, purchases/logistics and employee/payroll guides. Existing authorization, printing, deployment and operations guides remain the references for those subsystems.

Financial commands collect equivalent effects and post once per action/date; detailed product/FIFO evidence remains at its source. The [Finance guide](docs/modules/finance.md) defines this contract, and the [verification record](docs/audits/summarized-accounting-2026-11-05.md) records storage reclamation, measured journal reductions and preservation checks. Existing historical journals are unchanged.

The [primary VPS guide](deploy/production-vps.md) records the verified security, Docker, HTTPS and maintenance configuration on `144.79.249.4`. The application is a clean installation with independent credentials; the former Azure backend remains untouched.

## Architecture

- **Frontend:** React 19, TypeScript 6, Vite 8, React Router 7 with `HashRouter`, TanStack Query 5, Lucide icons, and custom CSS. Shared colour tokens and surface styles provide readable text, visible control boundaries and distinct page/dialog sections in both themes. Page code and its styles load on demand; the shared navigation, Auth provider and query cache stay mounted during route loading.
- **Authentication and authorization:** Supabase Auth, PostgREST, PostgreSQL 17, and SQL functions. `src/contexts/AuthContext.tsx` loads the trusted profile and effective RBAC permissions. Routes/navigation use capabilities; database policies and privileged RPCs enforce active membership, trusted tenancy and permission mappings independently of the UI. OWNER always has full business permissions. MANAGER and SALESMAN retain role defaults with individually configurable action permissions; selling prices, MRP, buying references, valued adjustments, cancellations, capital and loans/assets have explicit delegable capabilities. Account administration remains protected. A separate platform superadmin uses session-scoped business entry with the same effective permissions as OWNER and real administrator audit identity. Public signup is disabled. See [tenant authorization](supabase/authorization.md).
- **Account administration:** A private Node service behind `/accounts/v1/*` uses GoTrue administration for authorized account creation and password resets. Privileged credentials stay server-side. Public `setup_business` and self-service registration are removed; the one-time platform bootstrap is stdin-only and requires a first-login password change. See [account and tenant authorization](supabase/authorization.md).
- **Business deletion:** Platform Admin previews record/file/account impact, verifies the administrator password and requires a separate typed DELETE. A resumable private worker fences the business, verifies a fresh full cloud backup through isolated restoration, removes files through Storage, purges tenant records transactionally with constraints enabled, and deletes dedicated Auth logins. Shared identities/infrastructure and a minimal global deletion audit remain. Failed jobs stay blocked for an explicit confirmed retry; no ordinary business is deleted by deployment.
- **Data access:** Hooks in `src/hooks/` call validated RPCs and tenant-scoped direct reads. Direct browser writes are limited to zero-stock item registration, customer creation and authorized printer configuration. Profiles and RBAC mappings are not browser-writable; stock, ledger, purchase, transit and employee/payroll workflows stay behind gated RPCs. Internal helpers/triggers live in the unexposed `app_private` schema. The browser client in `src/lib/supabase.ts` accepts configured loopback Supabase URLs in development and HTTPS self-hosted URLs in production, and rejects a service role or secret key. Browser sessions are scoped to the full backend host and port, so changing environments does not reuse another backend's cached login.
- **Receipt printing:** The standalone Windows application in `print-bridge/` embeds the existing Node bridge/runtime, installs a silent Automatic Windows service with crash recovery, and needs no separate Node/npm installation. It discovers Windows USB queues and bounded local TCP endpoints, sends Unicode raster ESC/POS through Winspool RAW or Ethernet TCP, and retains request deduplication across updates. One preferred printer and 80/58 mm settings persist per tenant. Android/PWA can use a paired LAN bridge with trusted HTTPS, or browser/system printing. No LAN receipt traffic traverses the VPS. See [bridge setup](print-bridge/README.md).
- **Deployment:** `Dockerfile` builds the Vite bundle and serves it with Nginx. `compose.yml` defines the frontend, Envoy API gateway, Auth, PostgREST, Realtime, Storage, Studio, PostgreSQL, Supavisor, and supporting services. [`supabase/docker/README.md`](supabase/docker/README.md) documents the local Compose cutover and volume handling.

The application public tables all have RLS enabled, including `tenants`, `user_profiles`, `items`, `inventory_movements`, `customers`, `price_books`, `receipt_printers`, `sales`, `sale_items`, `purchases`, `purchase_items`, `purchase_activity`, `vehicles`, `vehicle_assignments`, `transits`, `wallets`, `financial_types`, `financial_entries`, `sale_payments`, `purchase_payments`, `purchase_refund_obligations`, `finance_requests`, `gas_plants`, `area_officers`, `lpg_brands`, and employee/attendance tables. The employee phone table is named `employee_phone_numbers`. See the SQL migrations for ledger constraints and triggers.

### Routes

Routes use URL hashes, for example `http://127.0.0.1:3001/#/pos`.

The top bar shows the current page name and combined wallet balance for users with wallet read permissions. The sidebar account beneath the business name opens the sign-out menu and remains available on mobile. Purchases uses page scrolling, four separated overview figures, company-led cards with product lists and one total purchase cost row, token search (spaces AND, commas OR), shipment/payment and inclusive date filters, and purchase date/cost/due/supplier sorting with Customers' separate direction button and a reset action. Sales and Purchases filter LPG, Stove or both before pagination; Purchases scopes its overview to that selection. Details remain in the purchase summary. A negative wallet balance is displayed as a deficit. Shared dropdown styling covers pages and modals; date fields include a keyboard-accessible calendar with month/year navigation, Today, Clear and range limits.

Pages grow within one scrolling workspace, with local horizontal scrolling for wide tables. Shared container-aware grids use compact gaps, bounded widths and consistent card heights by listing type. Sales and Purchases share compact content-sized identity/status sections and a bounded product preview that fades only when it overflows; all statuses and financial totals stay visible, with complete products in details. POS columns follow product space without a fixed column ceiling; checkout stacks when the workspace is at most 52rem wide. Desktop checkout retains its bounded height, bottom action and scrolling cart. Inventory, POS and product/bottle pickers start each brand on a new row in Settings order. Amount editors use left-aligned plain decimals without inserting grouping separators while editing.

Customers, Purchases and Sales display three measured rows, or at least ten records in narrow containers rounded to whole rows, while independently caching backend batches of 25. Cards and page/range indicators update together after required batches load; the previous complete page stays visible during navigation. Resizing preserves the record anchor and reuses cached batches. Gas plants, brands and the transit directory share measured display pagination. Compact product/bottle pickers use two to four rows, account for brand row boundaries, and preserve selections across pages/searches. Fleet cards retain twelve desktop/four phone pages; fleet/transit/assignment histories filter and paginate on the server; local catalogs read bounded server ranges without silently truncating at the API limit. Server histories retain bounded limits. Purchase activity combines lifecycle events, payments and refunds chronologically, with each wallet ledger entry shown once. Inventory and POS catalogs scroll without pagination. See [adaptive layout](docs/modules/adaptive-layout.md).

Phone layouts use compact headers, in-page dropdowns on supporting browsers and labeled employee/fleet records with actions in view. Summary values retain their numeric hierarchy, and Inventory groups four small summary boxes inside one toolbar. Sign-in and password forms stay near the top on phones. Layouts use dynamic viewport units and container queries; native installed-PWA behavior still requires device acceptance.

| Route | Screen |
| --- | --- |
| `#/` | Dashboard |
| `#/pos` | Point of sale |
| `#/sales` | Sales and money/bottle settlement |
| `#/inventory` | Inventory |
| `#/customers` | Customers |
| `#/purchases` | Purchases |
| `#/logistics` | Vehicles, transits and crew earnings |
| `#/employees` | Employees and payments |
| `#/settings` | Business profile/attendance, gas plants, LPG brands, employee roles, cylinder weights, financial types and appearance |
| `#/finance` | Analysis, Wallet Ledger, Financial Entries, Accounting Activity and Loans & Lending; classified Adjust Balance and financial entry |
| `#/login`, `#/account` | Sign-in, mandatory first-login password change and personal password settings |
| `#/users` | OWNER User & Access Management |
| `#/admin` | Platform businesses, accounts, storage, audit and encrypted cloud Backup Management |

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

For direct USB/Ethernet printing, run **LPG Print Bridge Setup.exe** on the Windows x64 host. No separate Node.js/npm installation is required. It installs a silent service that starts before login and restarts after crashes; **Restart LPG Print Bridge.exe** provides manual recovery. USB uses machine-installed Windows drivers/queues accessible to SYSTEM; Ethernet connects directly to the private printer IP/port. The default endpoint remains `http://127.0.0.1:17891`, outside Docker, with the existing Cloudflare origin allowed. ProgramData retains settings and the migrated job journal across updates. In Dashboard, open **POS Printer** to configure the printer, paper width, printable dots and cutter. **Refresh** rescans without closing the modal; disconnected configuration is retained. Build deliverables with `npm run print:package`; see [installation and updates](print-bridge/README.md).

POS Printer separates Browser, USB and Ethernet setup, shows discovered network endpoints inline, and groups paper/cutter settings with an explicit test action. Auto-cut defaults on for new printers; saved choices are retained and printers without cutters can switch it off. Discovery reads installed Windows queues independently of saved configuration and bypasses browser caching. USB/port metadata failures show warnings while retaining the queue list; Windows queue enumeration errors are reported separately from having no printers. If the bridge stops, start it again and Refresh. Temporary diagnostics are available through `LPG_PRINT_DIAGNOSTICS=1`.

Use **Confirm & Print** at checkout, **Reprint Last Sale** in POS, or **Print receipt** in saved sale details on Dashboard or Sales. Saved-sale printing first opens printer selection and the slip preview; only the print button inside that dialog dispatches a job. Printing failure leaves the completed sale saved. See the [Windows bridge setup and verification notes](print-bridge/README.md) for origin configuration, device matching, printer compatibility, job feedback, and tests.

### Migration state

The component baseline is `20261103175450_core_component_inventory_and_shared_treasury.sql`; `20261104011500_remove_retired_financial_archive.sql` completes removal of empty pre-core compatibility paths. `20261104015000_product_receipt_history.sql` aligns weekly empty receipts with completed sales. Forward migrations preserve historical replay files while replacing current contracts. The [release audit](docs/audits/lpg-core-overhaul-2026-11-04.md) records current acceptance and recovery evidence. LPG purchases use Gas/Bottle quantities and prices; monthly/product commission engines and wallet business sub-balances are removed. `20261104030000_purchase_rebate_settlement.sql` adds owner-entered noncash company rebates with separate income and reusable cancellation credit; `20261104073500_purchase_rebate_source_links.sql` preserves purchase drilldown links. All acquisition and selling prices remain independent. Sales retain Refill/Package and physical Filled/Empty states. Schema replay requires the guarded, explicitly authorized development business reset; it never deletes admin credentials or system configuration itself.

All sales use the same payment and aggregate bottle model. Original immutable `empty_return` sale lines define expectations; immutable receipt lines identify actual products and quantities. Settlement is total expected minus total actually received, clamped at zero for each sale. Unexpected/excess products require acknowledgement. Additional Settlement Cost adds customer liability; only independently collected money credits wallets. Unattributed previously paid amounts remain explicit in settlement/receipts, without invented payment methods or wallet credits. Original invoices, actual purchase quantities, wallet opening balances and financial evidence remain intact. See the [module guides](docs/architecture.md).

POS defaults to full Cash Register payment. Advanced Payments supports split and partial payments (including zero initial payment); only received funds credit wallets. Finance and saved-sale details support subsequent collections. A ledger trigger applies every real-wallet balance change atomically with its business operation. Purchase transport is a noncash internal allocation: retained in individual and additive Combined reports, first in Supplies and then in COGS as the related stock is sold. See [Finance](docs/modules/finance.md) for migration, accounting and permission rules. Checkout enforces active selling prices, wholesale fallback, finite two-decimal amounts, zero-priced empty returns and discounts no greater than subtotal. Selecting a saved customer locks retail/wholesale pricing to that customer's type; checkout rejects a mismatched type. Clearing the selection restores draft tier choice. Both POS and purchase creation retain an uncertain request in this browser tab for safe recovery across reloads. See [sales/inventory](docs/modules/sales-and-inventory.md) and [purchases/logistics](docs/modules/purchases-and-logistics.md).

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
| `attendance-receiver/server.mjs` | Internal bounded ADMS receiver behind Caddy HTTPS/443 with scoped database ingestion |

## Known limitations and checks

- This is a fresh backend: Azure accounts and business data were not transferred. Admins create business accounts. Development email autoconfirm remains enabled; recovery/invitation email needs an SMTP provider. Central pgBackRest/Restic/rclone backups and superadmin Web OAuth are configured for Google Drive at 02:00 Asia/Dhaka, with 30 daily dates and 12 monthly full points. A separate recovery kit is required; see [whole-system recovery](deploy/backup/recovery.md). Successful nightly cloud recovery verification and external monitoring remain prerequisites for production use.

- The untuned 1 GiB database baseline passed a mixed-workload **11-active-business** 30-minute endurance test, with **10** the measured comfortable point and **12** failing the read-latency target under the existing 1 GiB database cap. Each fixture had 2,000 customers and 20,000 historical invoices. Reusable testing harnesses remain under `supabase/tests/vps-capacity/`.
- Dashboard stock exceptions remain unfinished. Attendance estimates require physical-device acceptance. Salaries use fixed monthly amounts and wallet-attributed payments; historical payments retain explicit unknown wallet attribution.
- POS supports partial payments and subsequent collections. Owners may cancel supported saved sales and settle their refunds separately. Cancelling checkout before submission has no business effects. Purchases support partial and multi-wallet payments after dispatch, independently of receiving. Only OWNER can cancel Created/In Transit purchases with exact `CANCEL`; Received LPG purchases never cancel; stove cancellation additionally requires reversible original stock quantity and carrying value. Cancellation reverses dispatch operations immediately and leaves source-backed refunds pending until fully settled. Incurred transit expenses remain payable independently.
- `npm run build`, `npm run lint`, `node --test tests/*.test.ts`, `npm run print:test` and `npm run deploy:test` check different boundaries. SQL suites roll back their fixtures; `npm run purchase:db:test -- --replay-module <PGlite package directory> --deployment-batch` verifies the complete migration replay and eleven current SQL suites plus migration-normalization checks in a disposable engine.
- `python supabase/tests/run-transaction-concurrency.py` requires the configured Docker database and creates/removes only a new verification database. It exercises all eleven suites plus concurrent checkout, stock contention, purchase creation/dispatch/payment/receipt/cancellation and duplicate/competing collections, wallet transfers, aggregate bottle/customer-charge races, historical preservation and balance consistency. Add `--vps --root /opt/lpg` only when intentionally running on the established VPS checkout.
- `node supabase/tests/backend-api.mjs --vps` checks public health, CORS, private-route blocking, safe JWKS, ES256 Auth and a disposable Realtime WebSocket channel.
- `node supabase/tests/bottles-api.mjs --vps --browser` verifies real Auth/PostgREST and the published Sales/collection workflow on disposable businesses, checks the burner membership read-only, and compares existing business-data fingerprints after fixture cleanup. `tests/bottles.browser.cjs` covers responsive checkout/collection, optional notes and required product acknowledgements, same-request recovery after response loss and retained details.
- `node supabase/tests/employees-api.mjs --vps --browser` verifies real employee Auth/PostgREST and published employee/Logistics workflows in disposable businesses; `tests/employees.browser.cjs` covers responsive employee management and same-request recovery.
- `node supabase/tests/run-logistics.mjs --vps --with-migrations` restores a read-only VPS dump into a uniquely named disposable database, applies pending migrations there, and verifies Logistics/spending workflows, ledger reconciliation, preservation, concurrency, authorization, Employee and Purchase regressions. It removes only that disposable database.
- `node supabase/tests/run-simple-transits.mjs --vps` checks automatic Cash Register collection/completion, source preservation, failure rollback, permissions, competing completions and purchase/FIFO/report regressions on a disposable VPS copy. `node supabase/tests/simple-transits-api.mjs --vps` verifies the published API/browser flows, service filters, status colors and phone/desktop layouts with isolated fixture businesses and checked cleanup.
- `node supabase/tests/spending-api.mjs --vps --browser` verifies real spending/withdrawal Auth/API and published Dashboard/Finance/Settings flows, category snapshots, retry safety, role-only crew dropdowns and save confirmations. `node supabase/tests/logistics-api.mjs --vps --browser` checks purchase/custom transits and employee payments. Both use isolated fixture businesses and verify original data after cleanup.
- Browser fixture suites cover desktop/phone layouts, tier changes, printing, purchase lifecycle and response-loss recovery. Fixture success does not establish production Auth/API behavior, physical printing or device keyboard/PWA acceptance.

All currency displays use Bangladeshi Taka formatting. This project is not affiliated with an LPG brand or cylinder manufacturer.

Financial definitions and internal allocation rules are documented in [financial analysis](docs/modules/financial-analysis.md). Buying references remain distinct from actual historical FIFO. A newer receipt updates acquired Gas/Bottle references, including earlier manual values; backdated receipts cannot replace newer references. Historical exchange receipt values remain fixed.

## Accounting coverage

The [unified accounting guide](docs/modules/financial-analysis.md) defines recognition, component FIFO, ownership, loans, assets and reconciliation. New businesses start at zero with explicit valued contributions. No estimated historical profit or arbitrary balancing entries are inserted.

Approximate buying prices never replace historical acquisition costs. Gas/Bottle price edits and new receipts affect current operational references; original cost evidence and dated accounting adjustments preserve financial traceability.

Current verification: `node supabase/tests/run-unified-accounting.mjs --vps --performance`, `npm run accounting:api:test`, and `node tests/unified-accounting.browser.mjs` (local intercepted UI). Historical contract suites run at their migration boundary during disposable replay. Physical printing and external bank/mobile-provider settlement remain separate acceptance boundaries.

Current component-core source-operation reconciliation, test boundaries and verification limits are documented in [Finance validation](docs/modules/finance-validation.md). Empty schema replay uses `--schema-only`; obsolete migration fixtures are a separate historical-contract mode.
