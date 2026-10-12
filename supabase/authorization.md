# Tenant authorization

Implemented and inspected on **2026-10-05 (Asia/Dhaka)**. The earlier
[RLS strategy input](rls-strategy-input.md) records the findings that led to this
implementation; it describes the pre-authorization database.

## Authority and roles

`roles`, `permissions`, `role_permissions` and `user_roles` are the authorization
source of truth. Policies, operational RPCs and frontend guards check capabilities,
never role names. The initial mappings are:

| Role | Initial capabilities |
| --- | --- |
| OWNER | All 23 current tenant capabilities |
| MANAGER | The same complete set, in its own role mapping |
| SALESMAN | `dashboard:view`, `pos:sell`, `sales:view`, `receipts:print` |

The original view/manage pairs for inventory, customers, purchases, logistics,
gas plants and finance remain, together with `settings:manage` and `pos:sell`.
New capabilities cover Dashboard, sales history, printing, printer configuration,
employees, payroll and audit reading. There is no platform ADMIN implementation.

Changing a trusted RBAC mapping immediately changes database access, including
for existing access tokens. Adding a capability to the catalog also requires
deliberately mapping it to existing roles. New-business setup copies the current
catalog to OWNER/MANAGER and the four supported capabilities to SALESMAN.
The browser refreshes effective permissions and its profile every 30 seconds
and on query focus; the database remains authoritative between UI refreshes.

Membership admission, role/mapping administration, activation and tenant status
changes are trusted database/server operations. No invitation, role-management,
price-maintenance or activation UI/API is introduced. Browser roles cannot write
any RBAC table or profile field, including their own tenant, identity or status.

## Trusted membership and helpers

The unexposed `app_private` schema contains:

- `current_tenant_id()`: resolves the caller's database profile, requires its
  Auth identity to exist, excludes anonymous Auth accounts, and requires an active
  profile and an `active` tenant.
- `has_permission(text)` and `has_any_permission(text[])`: join the caller's
  assignments, tenant roles, permission mappings and catalog using tenant keys.
- `require_permission(text)` and `require_any_permission(text[])`: reject
  missing identity, inactive membership and missing capabilities with SQLSTATE
  `42501`, and return the trusted tenant.

Only the three read helpers needed by RLS are executable by `authenticated`;
schema USAGE does not expose the schema through PostgREST. Permission gates,
inventory recording, wallet/category/type helpers and trigger functions are
unavailable to browser callers. Public `get_my_permissions()` returns only
the current caller's effective capabilities. An account without assignments has
no operational permissions.

Auth user metadata is display data, never membership or permission authority.
Profile identities reference Auth users. Role assignments and creator/actor
relationships use composite tenant/profile foreign keys. Items, customers and
audit records have tenant-root foreign keys; transit purchases are tenant-qualified
parents. Reused entity UUIDs in different tenants are supported and isolated.

## Browser access and workflow boundaries

Every business read requires active trusted membership and a capability, except
the caller's own profile/business identity needed to load the workspace.

| Capability / flow | Authorized access |
| --- | --- |
| Dashboard | `dashboard:view` gates `get_dashboard_stats`; the RPC returns totals/counts without opening inventory history or finance. The daily feed and receipts use tenant-scoped sales/line reads. |
| POS | `pos:sell` supports product, brand and price reads, customer lookup/creation, and validated `create_pos_sale`. It gives no inventory adjustment, purchase, logistics, employee or finance management rights. |
| Sales / printing | `sales:view` and `receipts:print` support saved sale details and their product/customer embeds; printing can read saved printer configuration. SALESMAN can read/reprint tenant sales. |
| Printer settings | `printers:manage` gates configuration INSERT/UPDATE; configuration SELECT also allows `receipts:print`. PostgREST upserts can assign the tenant column, but old and new ownership must both match the trusted tenant. |
| Inventory | View/manage capabilities permit registry/history reads and same-tenant creator attribution. Only `inventory:manage` allows registering zero-stock items and calling inventory adjustments. |
| Customers | Customer view/manage allows reads; management or POS allows form creation. No direct update/delete path is exposed. |
| Purchases | Purchase view/manage gates lists and supporting product/truck/plant selectors. Create/edit/complete requires `purchases:manage`; internal stock and wallet writes need no separate inventory/finance management grant. |
| Logistics | Logistics view/manage gates truck/transit/wallet reads; truck/custom-transit/cost mutations require `logistics:manage`. |
| Brands / plants | `settings:manage` gates brand mutations. Plant/officer mutations require `gas_plants:manage`; plant view and purchase selectors retain their supporting reads. |
| Employees | Employee view/manage gates profile/phone/payment-count lists; employee mutations require `employees:manage`. |
| Payroll | Payroll view/pay gates payment/category lists; `payroll:pay` gates payment recording. Payments retain their existing immutability and monthly salary uniqueness. |
| Finance / audit | Finance view/manage allows same-tenant ledger/wallet reads; `audit:view` allows audit reads. Browser ledger/audit writes remain denied. |

Only item/customer registration and printer configuration have direct browser
writes. Item INSERT grants exclude initial balances and timestamps. All other
stock, ledger, purchase, transit, employee, phone and payment writes remain behind
their existing validated RPCs. Actor fields come from `auth.uid()`; callers cannot
choose their attribution.

Privileged routines use permission gates and tenant-qualified reads, joins,
subqueries and writes. Public inventory adjustments gate `inventory:manage`;
purchases use an unexposed stock recorder under their own validated workflow.
POS applies stock changes through the movement trigger exactly once, locks each
item, rejects invalid lines/negative totals and rolls back insufficient stock.
Existing historical stock balances are not recalculated.

The obsolete four-argument truck-create and activation-boolean truck-update
overloads and public `my_tenant_id` contract are removed. Current hook contracts,
including the ten-argument POS customer-selection contract, remain.

## Grants and deployment

The migration removes overlapping policies and all existing PUBLIC/anon/browser
table privileges, then grants only documented SELECTs and three direct-write
paths. No browser TRUNCATE, REFERENCES, TRIGGER or MAINTAIN privileges remain.
All PUBLIC/anon function execution is revoked; browser RPC execution is an
explicit allowlist. Function paths are pinned to `pg_catalog, public, pg_temp`
and application table references are qualified. Browser CREATE on public is
denied. Internal trigger functions retain their trusted invocation paths.

Future table/sequence/function browser defaults are revoked for both `postgres`
and `supabase_admin`, including global PUBLIC function execution. Creating a
future object does not automatically expose it.

Authorization is recorded by:

1. `20261004192158_tenant_permission_authorization.sql`
2. `20261004194235_receipt_printer_upsert_authorization.sql`

Apply the authorization migration transactionally as `supabase_admin` or an
equivalent platform superuser because it revokes that creator's default grants.
Application functions remain owned by `postgres`. Apply the printer follow-up
afterward. Do not reset existing data or repair historical migration records to
deploy these changes.

Both migrations are applied to the repository's local Compose database and
recorded with their actual SQL. All twelve migrations replayed against schema-only
Supabase platform dependencies in a network-disabled scratch database; its
`public`/`app_private` schema matches live. Historical application migrations
run as `postgres`; the reconciliation/authorization defaults need the platform
superuser. This validates application migration reproducibility against those
dependencies, not provisioning a fresh complete Supabase stack.

## Verification

```powershell
npm run auth:test
npm run auth:db:test
npm run auth:api:test
```

Database tests use real `authenticated`/`anon` roles and roll back all fixtures.
They exercise OWNER/MANAGER access, SALESMAN allow/deny paths, mapping-driven
grant/revocation, membership/status rejection, escalation denial, internal
execution restrictions, future-object defaults, direct-write denial and real
POS/purchase/transit/employee/payment/printer workflows. Reused UUID tests include
forcing a newly generated sale UUID to collide with another tenant's saved sale.
The receipt suite asserts that stock changes are applied once.

The API suite needs the running local Compose stack and the root private `.env`
with its local public/anon key. It creates disposable Auth accounts/businesses
and cleans only those generated fixtures, using trusted database access for staff
fixture membership and cleanup. It verifies real signup/setup, profile/receipt/
inventory embeds, customer creation, checkout, printer upserts, all three roles,
and metadata spoofing denial. It never contacts the printer bridge.

Security advisors currently report 29 authenticated definer RPC warnings and
13 informational RLS-without-policy entries for tables intentionally accessible
only through trusted workflows/helpers. Anonymous definer execution and mutable
function-path findings are gone. These remaining diagnostics do not override
the explicit RPC gates or justify adding browser policies to internal tables.

Frontend build, focused changed-file lint, authorization tests, bridge typecheck
and all twelve existing bridge/checkout tests pass. Browser UI interaction and
physical printing are not part of these authorization tests; no physical print
job was sent.
