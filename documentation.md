# Project documentation

[README](README.md) describes the current app and setup. [AGENTS.md](AGENTS.md) defines development, security, testing and deployment rules. [Architecture](docs/architecture.md) maps module responsibilities and dependencies.

| Area | Authoritative guide |
| --- | --- |
| Purchases, company rebates, dispatch and supplier settlement | [Purchases and Logistics](docs/modules/purchases-and-logistics.md) |
| Gas/Bottle FIFO, physical cylinders, sales and exchanges | [Sales and Inventory](docs/modules/sales-and-inventory.md) |
| Wallets, journals, business allocations and obligations | [Finance](docs/modules/finance.md) |
| Tabular reporting, additive business totals and historical positions | [Financial Analysis](docs/modules/financial-analysis.md) |
| Operation-to-account/category mappings | [Financial Type Matrix](docs/modules/financial-type-matrix.md) |
| Independent reconciliation and retained test labs | [Finance Validation](docs/modules/finance-validation.md) |
| Customers and Dashboard | [Customers](docs/modules/customers.md), [Dashboard](docs/modules/dashboard.md) |
| Employees, payroll and attendance | [Employees](docs/modules/employees-and-payroll.md), [Attendance](docs/modules/attendance.md) |
| Authorization and account administration | [Tenant Authorization](supabase/authorization.md) |
| VPS and Cloudflare publication | [Deployment](deploy/README.md), [Primary VPS](deploy/production-vps.md) |
| Scheduled/manual full backups and recovery | [Recovery](deploy/backup/recovery.md) |
| Printing and responsive layouts | [Windows Print Bridge](print-bridge/README.md), [Adaptive Layout](docs/modules/adaptive-layout.md) |

React feature components live under `src/components/`, routes under `src/pages/`, data access under `src/hooks/`, shared contracts under `src/types/`, and formatting/domain utilities under `src/lib/`. PostgreSQL business operations, atomic journal posting and permissions live in ordered `supabase/migrations/`; database acceptance lives in `supabase/tests/`, browser/source checks in `tests/`. Supporting services remain in `account-service/`, `attendance-receiver/`, `print-bridge/` and `deploy/`.

The [manual rebate acceptance record](docs/audits/purchase-rebate-2026-11-04.md) documents current rebate verification.

The [summarized-accounting verification record](docs/audits/summarized-accounting-2026-11-05.md) records storage reclamation, action-level posting, preservation checks and measured journal reductions. The Finance guide owns the current posting contract.

Source and forward migrations are authoritative. Current purchase rebates are manual noncash settlement and separate income; they do not restore the retired monthly/product commission engine or change product prices, inventory acquisition costs or COGS. Dated audit documents preserve their original release boundary and are not the current module contract. Keep credentials, private fixture manifests and recovery keys outside tracked documentation.

Finance wallet visibility, tab/action scopes, received-quantity performance and projected FIFO margins are documented in [Finance](docs/modules/finance.md); the server-enforced permission contract is in [authorization](supabase/authorization.md). These reports preserve the additive standalone-business analysis and do not alter financial recognition.
