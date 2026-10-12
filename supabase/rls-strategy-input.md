# LPG Manager: input for Supabase RLS design

Inspected **2026-10-04 (Asia/Dhaka)**. This is an analysis report, not a policy implementation or final authorization specification.

**Main finding:** enabling RLS on all tables has not secured the whole access surface. The highest risks are mutable profile tenancy, anonymous-callable tenant-parameter helpers, and definer queries that omit tenant keys. Role permissions currently describe intended roles but do not enforce access.

## Evidence and scope

- Application-schema authority: all ten files in [migrations/](migrations/), read in chronological context, plus [migration-audit.md](migration-audit.md). The old broken migration directory is excluded.
- Current source: [AuthContext](../src/contexts/AuthContext.tsx), [ProtectedRoute](../src/components/ProtectedRoute.tsx), [Supabase client](../src/lib/supabase.ts), all [data hooks](../src/hooks/), and their page/component consumers.
- Configuration: [compose.yml](../compose.yml), [.env.example](../.env.example), [config.toml](config.toml), gateway/service configuration, and selected non-secret running-service settings.
- Live verification used the configured Supabase MCP, catalog SELECTs, security advisors, and a read-only anonymous-role transaction. MCP reports `http://127.0.0.1:54321`. Its PostgreSQL system identifier `7657576444866912295` matches the running repository Compose database; both use PostgreSQL 17.6. The frontend's configured localhost/127.0.0.1 gateway is the same deployment.
- Live inventory: **29 public tables, 70 policies, 37 functions (32 SECURITY DEFINER), five user triggers, ten migration-history records**. No public views, materialized views, or sequences. No application tables are published in `supabase_realtime`.
- Current advisors reproduce **71 findings**: 32 anonymous-executable definers, 32 authenticated-executable definers, six mutable search paths, and one RLS table without policies. These are advisory counts, not 71 demonstrated exploits. [Advisor guidance](https://supabase.com/docs/guides/database/database-linter).
- No application code, schema, grants, policies, migration history, or business data was changed. No mutating RPCs, exploit fixtures, browser flows, printing, or frontend build/tests were run. Existing reconciliation-test evidence belongs to the migration audit, not this inspection.

Running Compose settings expose `public,graphql_public` through PostgREST with `anon` as the unsigned-in role and `public` as the extra search path. Email signup is enabled, signup is not disabled, email autoconfirm is on, anonymous Auth users are disabled, and JWT expiry is 3,600 seconds. The browser uses the public/anon key plus the signed-in session token. Gateway bindings are loopback-only. CLI `config.toml` describes a separate CLI workflow; its commented auto-exposure defaults do not override the broad grants already present in this Compose database. No current frontend/business RPC needs direct client access to the `auth` schema.

## 1. Database and tenant structure

### Identity and ownership

`auth.users.id` is the authenticated identity. `user_profiles.user_id` is a primary key, so an account has at most one application profile and one current `tenant_id`. The profile's tenant references `tenants.tenant_id`. **There is no FK from user_profiles.user_id to auth.users.id and no Auth-user bootstrap/delete trigger in the application schema.** The identity relationship is established by `setup_business`, not enforced by that missing FK.

Registration creates an Auth user, signs in, then calls `setup_business`. The RPC creates a tenant, profile, Owner/Manager/Salesman roles, their permission assignments, and the registering user's Owner assignment in one database call. Auth signup and that database call are separate transactions. On failure the frontend only signs out; despite its comment, it does not remove an orphan Auth user. Existing-profile registration fails on the profile primary key; no explicit idempotency or membership-transfer contract exists.

`my_tenant_id()` reads the profile whose `user_id = auth.uid()`. It does not check profile `is_active`, tenant `status`, Auth-user existence, or roles. No operational function/policy enforces profile activation or tenant suspension. Registration also stores `tenant_id` in user-editable `raw_user_meta_data`; current authorization reads the database profile, not that metadata. Keep metadata display-only in the later design. [Supabase RLS guidance](https://supabase.com/docs/guides/database/postgres/row-level-security).

Read-only aggregate checks found zero orphan Auth users/profiles, inactive profiles, non-active tenants, or user-role/profile tenant mismatches **in current data**. That does not substitute for structural enforcement.

### Relationships

Every public table except the global `permissions` catalog contains `tenant_id`; `tenants` is the root. Most entity keys are **(tenant_id, entity_id)**, not globally unique entity IDs. UUID defaults reduce accidental collisions but do not prevent callers inserting an existing ID under another tenant.

| Domain | Relevant relationships and ownership |
| --- | --- |
| Identity/RBAC | Profile → tenant; roles → tenant; role_permissions → (tenant, role) and global permission; user_roles → (tenant, role) and profile by user_id alone. |
| Product/supplier | items and gas_plants → (tenant, brand); area_officers → (tenant, plant). Brands, plants and officers are tenant-specific, not shared global catalogs. |
| Inventory/pricing | inventory_movements and price_books → (tenant, item). Movements also reference a creator profile by user_id alone. |
| Customers/sales | sales → (tenant, customer); sale_items → (tenant, sale) and (tenant, item); customer_transactions → (tenant, customer). Sales/transactions reference creator profiles. |
| Purchases/logistics | purchases → (tenant, truck) and (tenant, plant); purchase_items → (tenant, purchase) and (tenant, item); transits → (tenant, truck). **transits.purchase_id has no FK.** |
| Finance | wallets → tenant, unique (tenant, wallet type); wallet_transactions → (tenant, wallet). Transaction reference_id is untyped and has no parent FK. |
| Employees | employees → tenant and (tenant, employee type); employee_phone_numbers → (tenant, employee); employee_payments → (tenant, employee) and tenant/category/code. The three overlapping payment-category FKs preserved by reconciliation do not authorize callers. |
| Audit/printing | audit_logs owns its tenant directly, with untyped table_name/record_id and performed_by; receipt_printers has tenant_id as its single-row-per-tenant primary/FK key. |

Additional boundaries to preserve:

- `items`, `customers`, and `audit_logs` lack a direct tenant-root FK; some other ledger tables reach the tenant through a parent FK.
- `created_by` FKs in movements, sales, purchases, customer transactions, employees and employee payments constrain existence only, **not creator tenant or current identity**. `audit_logs.performed_by` is unconstrained. Browser payloads must not choose their attribution freely.
- `user_roles` can reference a profile from a different tenant because its user FK is not composite. Tenant-only row checks do not validate the target user's membership.
- Both brand FKs use composite `ON DELETE SET NULL` without a column list, conflicting with NOT NULL `tenant_id` if a referenced brand is deleted. UI uses deactivation; do not infer that hard deletion is supported.
- Customer phone uniqueness and employee phone/type/category uniqueness are tenant-scoped. Phone format checks, positive employee payments, one salary payment per employee/month, and payment immutability are existing business rules.

### Roles and permissions

Database roles `anon` and `authenticated` have no login and no BYPASSRLS. PostgREST's `authenticator` can SET ROLE to either or `service_role`. `postgres`, `supabase_admin`, and `service_role` have BYPASSRLS; all public application tables/functions are owned by `postgres`.

Application roles are rows, separate from these database roles:

| Application role seeded by setup_business | Assignment |
| --- | --- |
| Owner | All permissions present when the tenant is created |
| Manager | All present permissions except settings:manage |
| Salesman | pos:sell, inventory:view, customers:view, logistics:view |

The 14 permission IDs are `settings:manage`, `pos:sell`, and view/manage pairs for `inventory`, `customers`, `logistics`, `purchases`, `gas_plants`, and `finance`. There are **no employee/payroll, audit, printer, sales-history, or role-administration permission IDs**.

No policy, operational RPC, frontend guard, or hook evaluates `user_roles`/`role_permissions`. The protected route requires only a session. An authenticated member currently receives tenant-wide operational access regardless of Owner/Manager/Salesman assignment. Role and permission-assignment tables themselves allow tenant-wide ALL operations. Staff invitation/provisioning and role administration UI are absent. `employees` is an operational staff registry, with no identity link to Auth users or account roles.

## 2. Current RLS state

Every public table has **RLS enabled, FORCE RLS disabled**. All 70 policies are **PERMISSIVE**; applicable policies combine with OR. Unless marked authenticated below, they target PostgreSQL `PUBLIC` (every role), not just signed-in users.

Notation: **T** means row tenant matches `my_tenant_id()`; the older “Tenant isolation…” policies express the same lookup through the current user's profile. **Self** means `user_id = auth.uid()`. Tenant INSERT policies check the new row; tenant UPDATE policies check old and new rows. `receipt_printers` wraps its lookup in a scalar SELECT. For ALL/UPDATE policies omitting an explicit check, PostgreSQL reuses USING; omission alone is not an unrestricted insert/update. [PostgreSQL policy semantics](https://www.postgresql.org/docs/17/sql-createpolicy.html).

**Commands not listed have no applicable policy**, including INSERT/UPDATE/DELETE on permissions. This is default-deny for ordinary row access, not proof that RPCs or table-wide privileges cannot bypass it.

| Public table | RLS / FORCE | Existing policies (command) | Predicate / audience |
| --- | --- | --- | --- |
| `area_officers` | Yes / No | `area_officers_tenant_delete` (DELETE)<br>`area_officers_tenant_insert` (INSERT)<br>`area_officers_tenant_select` (SELECT)<br>`area_officers_tenant_update` (UPDATE) | T; PUBLIC |
| `audit_logs` | Yes / No | `audit_tenant_select` (SELECT) | T; PUBLIC |
| `customer_transactions` | Yes / No | `ct_tenant` (ALL) | T; PUBLIC |
| `customers` | Yes / No | `customers_tenant` (ALL) | T; PUBLIC |
| `employee_payment_categories` | Yes / No | `employee_payment_categories_tenant_insert` (INSERT)<br>`employee_payment_categories_tenant_select` (SELECT)<br>`employee_payment_categories_tenant_update` (UPDATE) | T; PUBLIC |
| `employee_payments` | Yes / No | `employee_payments_tenant_insert` (INSERT)<br>`employee_payments_tenant_select` (SELECT) | T; PUBLIC |
| `employee_phone_numbers` | Yes / No | `employee_phone_numbers_tenant_insert` (INSERT)<br>`employee_phone_numbers_tenant_select` (SELECT)<br>`employee_phone_numbers_tenant_update` (UPDATE) | T; PUBLIC |
| `employee_types` | Yes / No | `employee_types_tenant_insert` (INSERT)<br>`employee_types_tenant_select` (SELECT)<br>`employee_types_tenant_update` (UPDATE) | T; PUBLIC |
| `employees` | Yes / No | `employees_tenant_insert` (INSERT)<br>`employees_tenant_select` (SELECT)<br>`employees_tenant_update` (UPDATE) | T; PUBLIC |
| `gas_plants` | Yes / No | `gas_plants_tenant_delete` (DELETE)<br>`gas_plants_tenant_insert` (INSERT)<br>`gas_plants_tenant_select` (SELECT)<br>`gas_plants_tenant_update` (UPDATE) | T; PUBLIC |
| `inventory_movements` | Yes / No | `movements_tenant_insert` (INSERT)<br>`movements_tenant_select` (SELECT) | T; PUBLIC |
| `items` | Yes / No | `items_tenant_insert` (INSERT)<br>`items_tenant_select` (SELECT) | T; PUBLIC |
| `lpg_brands` | Yes / No | `lpg_brands_tenant_delete` (DELETE)<br>`lpg_brands_tenant_insert` (INSERT)<br>`lpg_brands_tenant_select` (SELECT)<br>`lpg_brands_tenant_update` (UPDATE) | T; PUBLIC |
| `permissions` | Yes / No | None | Default deny |
| `price_books` | Yes / No | `price_books_tenant_insert` (INSERT)<br>`price_books_tenant_select` (SELECT) | T; authenticated |
| `purchase_items` | Yes / No | `purchase_items_tenant_insert` (INSERT)<br>`purchase_items_tenant_select` (SELECT) | T; PUBLIC |
| `purchases` | Yes / No | `purchases_tenant_insert` (INSERT)<br>`purchases_tenant_select` (SELECT)<br>`purchases_tenant_update` (UPDATE) | T; PUBLIC |
| `receipt_printers` | Yes / No | `receipt_printers_insert` (INSERT)<br>`receipt_printers_select` (SELECT)<br>`receipt_printers_update` (UPDATE) | T; authenticated |
| `role_permissions` | Yes / No | `Tenant isolation on role_permissions` (ALL)<br>`rp_tenant` (ALL) | T; PUBLIC |
| `roles` | Yes / No | `Tenant isolation on roles` (ALL)<br>`roles_tenant` (ALL) | T; PUBLIC |
| `sale_items` | Yes / No | `sale_items_tenant_insert` (INSERT)<br>`sale_items_tenant_select` (SELECT) | T; PUBLIC |
| `sales` | Yes / No | `sales_tenant_insert` (INSERT)<br>`sales_tenant_select` (SELECT)<br>`sales_tenant_update` (UPDATE) | T; PUBLIC |
| `tenants` | Yes / No | `Tenant members can view their tenant` (SELECT)<br>`tenant_select` (SELECT) | T; PUBLIC |
| `transits` | Yes / No | `transits_insert` (INSERT)<br>`transits_select` (SELECT)<br>`transits_update` (UPDATE) | T; PUBLIC |
| `trucks` | Yes / No | `trucks_tenant_delete` (DELETE)<br>`trucks_tenant_insert` (INSERT)<br>`trucks_tenant_select` (SELECT)<br>`trucks_tenant_update` (UPDATE) | T; PUBLIC |
| `user_profiles` | Yes / No | `Users can update their own profile` (UPDATE)<br>`Users can view their own profile` (SELECT)<br>`profile_own_update` (UPDATE)<br>`profile_select` (SELECT) | Self S/U; tenant S |
| `user_roles` | Yes / No | `Tenant isolation on user_roles` (ALL)<br>`ur_tenant` (ALL) | T; PUBLIC |
| `wallet_transactions` | Yes / No | `wallet_transactions_select` (SELECT) | T; PUBLIC |
| `wallets` | Yes / No | `wallets_insert` (INSERT)<br>`wallets_select` (SELECT) | T; PUBLIC |

Policy findings:

- **Critical profile loophole:** both self-update policies constrain user_id only. With table-wide UPDATE grants and no column restriction/trigger, a user can keep their user_id and assign their profile to another existing tenant. Future `my_tenant_id()` calls then authorize that tenant. Adding an explicit identical user_id check would not fix this.
- **Duplicate policies:** tenants has two equivalent SELECT policies; roles, role_permissions and user_roles each have two equivalent ALL policies; user_profiles has duplicate self UPDATE policies. Its self SELECT overlaps the broader tenant SELECT, but self SELECT also supports profile loading when tenant lookup is unavailable.
- **Overly broad operations:** tenant-wide ALL on roles/assignment tables enables self-escalation and arbitrary RBAC edits. ALL on customer_transactions permits ledger editing/deletion. Direct INSERT/UPDATE on sales, purchases and transits can bypass RPC accounting/state-transition rules. Employee INSERT/UPDATE policies permit bypassing RPC phone/category/activation validation.
- **Missing policies are mostly intentional access boundaries:** no direct UPDATE policy on items; no UPDATE/DELETE on movements or employee payments; no direct DELETE on employees/phones; no client writes to audit_logs/wallet_transactions. Existing definer flows can still perform required internal writes.
- **permissions has zero policies:** ordinary SELECT is denied; setup_business reads it as a definer. No current frontend lookup requires a new SELECT policy.
- No policy has a blanket true predicate. With no session, `my_tenant_id()` is NULL and tenant comparisons do not pass. A read-only `anon` test returned zero tenants, profiles, items, and permissions. This does **not** protect the unchecked definer helpers below.

## 3. RPC/function security and application usage

### Execution and grants

**All 37 functions have effective EXECUTE for PUBLIC, anon and authenticated.** There are 33 ordinary callable routines and four trigger-returning routines; trigger functions cannot be invoked as ordinary RPCs merely because EXECUTE is granted. All **32 definers run as postgres with BYPASSRLS**. Changing table policies alone will not constrain them. FORCE RLS would not neutralize postgres's BYPASSRLS either. [PostgreSQL RLS boundaries](https://www.postgresql.org/docs/17/ddl-rowsecurity.html).

Thirty-one definers set `search_path=public`. `my_tenant_id` and all five invokers have no pinned search path. Browser roles have schema USAGE but **no CREATE** on public/extensions/auth/graphql_public; they have database TEMP privileges. Later hardening should use qualified objects and a safe path that also handles temporary-schema shadowing; merely pinning public is not the strongest definer configuration. No application function exposes arbitrary SQL/dynamic EXECUTE. [PostgreSQL definer guidance](https://www.postgresql.org/docs/17/sql-createfunction.html).

**28 tables grant ALL to anon and authenticated**, including SELECT/INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER/**MAINTAIN**. `receipt_printers` alone denies anon/PUBLIC and grants authenticated SELECT/INSERT/UPDATE only. Service_role retains ALL on all 29.

RLS does not filter TRUNCATE or REFERENCES. These grants are a database-role bypass/maintenance surface; standard PostgREST table CRUD does not offer a TRUNCATE endpoint, and anon/authenticated cannot log in directly. Do not equate the grant with a proven anonymous HTTP truncate exploit, or leave it in the final least-privilege design.

For **both postgres and supabase_admin**, public-schema default privileges give postgres/anon/authenticated/service_role ALL on future tables, sequence SELECT/UPDATE/USAGE, and function EXECUTE. PostgreSQL's PUBLIC function EXECUTE also applies to existing functions. Reconciliation recorded these defaults without endorsing them. Future hardening must address existing ACLs, PUBLIC execution, and creator-specific defaults; revoking anon alone would leave inherited PUBLIC execution.

### Function contracts and effects

All rows below except explicitly marked invoker are **SECURITY DEFINER**. “User + tenant” means the body checks auth.uid and derives a profile tenant; it does not mean active membership or permission checks. “Tenant lookup” checks non-null my_tenant_id. Lists without a non-null guard return no rows for ordinary anonymous calls.

| Functions | Frontend/internal usage and database operations | Current validation and security considerations |
| --- | --- | --- |
| setup_business | AuthContext after signup/sign-in; INSERT tenants/profiles/roles/role_permissions/user_roles; SELECT permissions/Auth user; UPDATE Auth metadata. | Requires user identity; creates new tenancy. No active/verified-account check or explicit existing-profile guard; PK stops repeat profile creation. |
| my_tenant_id | Policy/function helper; no frontend RPC call. SELECT own profile. | Definer avoids recursive profile RLS; unpinned path; trusts mutable tenant_id and ignores activation/status. |
| ensure_default_employee_payment_categories | Called by employee create/payment/category-list; **no frontend call**. INSERT/UPDATE five category rows. | **No auth or tenant-membership check. Caller supplies any tenant ID; resets names/kinds and reactivates categories. Anonymous cross-tenant write path.** |
| resolve_employee_type | Called by employee create/update; **no frontend call**. INSERT type or reactivate existing type, return its ID. | **No auth or tenant-membership check. Caller supplies tenant/name. Anonymous cross-tenant create/reactivate path.** |
| ensure_tenant_wallets (invoker) | Called by POS/purchase/custom-transit definers; no frontend call. INSERT missing dealership/logistics wallets. | No auth check; direct callers remain subject to wallet grants/RLS. Nested calls inherit definer execution context. Direct authenticated use can create zero-balance wallets in own tenant. |
| create_inventory_movement | useInventory; INSERT movement → trigger UPDATE item. Also nested in purchase workflows. | User + tenant; no explicit item ownership lookup, but composite FK prevents foreign-tenant items. Server sets created_by; no role check, movement-type whitelist, or quantity bounds beyond table constraints. |
| create_pos_sale | usePOS; SELECT/possibly INSERT customer, INSERT sale/lines/movements/customer ledger, UPDATE items/sale/wallets; calls wallet helper. | User + tenant; selected customer scoped to tenant; item reads scoped and line/movement FKs composite. Refill/return count and stock checks exist. Caller chooses prices, discount and fees; no permission checks. |
| create_purchase | usePurchases; INSERT header/lines/transit/movements/wallet transactions; UPDATE stock through trigger, totals/truck/wallet. | User + tenant; parent/line ownership mainly enforced by composite FKs; refill stock read tenant-scoped. Financial inputs and items accepted from caller. |
| update_purchase | usePurchases; SELECT locked own purchase; UPDATE header/lines/wallet, INSERT adjustment movements/wallet transactions. | User check; purchase lookup tenant-scoped and in_transit required; lines tenant-scoped. Wallet UPDATE uses wallet_id alone (composite key issue). |
| complete_purchase | usePurchases; SELECT locked own purchase/lines; INSERT movements/wallet transactions; UPDATE stock/header/wallet. | User check; own purchase required; received/cancelled blocked. Wallet UPDATE uses wallet_id alone. **Does not complete the linked transit or free the truck.** |
| list_purchases | usePurchases; SELECT purchases/trucks/plants/lines/items/brands. | Outer purchase tenant scoped; **child subquery and joins use entity IDs without tenant keys**, allowing cross-tenant reads when IDs are reused. |
| create_custom_transit | useLogistics; INSERT transit/wallet transaction, UPDATE truck/wallet; wallet helper. | User check/profile-derived tenant; composite truck FK. Wallet UPDATE uses wallet_id alone; notes parameter is unused. |
| update_transit_costs | useLogistics; SELECT locked own transit, UPDATE transit/truck/wallet, INSERT wallet expense on completion. | User + tenant and completed lock; **final transit UPDATE filters transit_id alone**, and wallet UPDATE filters wallet_id alone. Reused IDs can affect another tenant despite the initial scoped lookup. |
| create_truck: 5 arguments | useLogistics; INSERT truck → audit trigger. | Tenant lookup; inserts current status/location schema. |
| create_truck: 4 arguments | Legacy overload, no matching frontend call. INSERT truck → audit trigger. | Tenant lookup; still executable; no location argument. |
| update_truck: 7 arguments | useLogistics, including location changes; UPDATE truck → audit trigger. | Tenant lookup; UPDATE includes tenant and truck ID. |
| update_truck: 6 arguments, boolean last | Legacy overload, no frontend call. | Tenant lookup; body targets nonexistent trucks.is_active. Obsolete callable contract; no demonstrated successful mutation. |
| list_trucks | useLogistics; SELECT trucks. | Tenant-filtered; active_only argument is ignored. |
| create_lpg_brand, update_lpg_brand | useBrands in Settings; INSERT/UPDATE brand → audit trigger. | Tenant lookup; UPDATE scoped to tenant/brand. No permission checks or row-found enforcement on UPDATE. |
| list_lpg_brands | useBrands and product/supplier selectors; SELECT brands. | Tenant filter; optional active-only filter. |
| create_gas_plant, update_gas_plant | useGasPlants; INSERT/UPDATE plants. | Tenant lookup; UPDATE scoped to tenant/plant; composite brand FK enforces tenant match. |
| create_area_officer, update_area_officer | useGasPlants; INSERT/UPDATE contacts. | Tenant lookup; create explicitly validates owned plant; update scoped to tenant/officer. |
| list_gas_plants | useGasPlants and purchase selector; SELECT plants/brands/officers. | Outer tenant filter and tenant-qualified joins; active filter supported. Returns officer PII. |
| create_employee, update_employee | useEmployees; INSERT/UPDATE employee, types and phones; update DELETEs/replaces phones; create ensures categories. | User + tenant; update validates owned employee; name/business unit/phone array/exactly-one-primary checks. No role checks. |
| deactivate_employee | RPC hook exported in useEmployees **but not consumed by any current page/component**. UPDATE inactive if paid, otherwise DELETE employee and cascade phones. | User + tenant; scoped to employee. Existing UI activation changes go through update_employee. Decide whether to retain this unused public contract. |
| create_employee_payment | useEmployees; SELECT owned active employee/category; ensure categories; INSERT payment. | User + tenant; positive amount, salary/trips fields, unique monthly salary; no finance/payroll permission. **Does not debit wallets or create wallet transactions.** |
| list_employees | useEmployees; SELECT employees/types/phones/payment count. | Tenant filter and tenant-qualified joins; exposes salary, address, notes and phone data. |
| list_employee_payments | useEmployees, employee ID argument; SELECT payments/employee/category. | Tenant filter and qualified joins; returns payment PII/financial data. No explicit auth guard, anonymous returns no rows. |
| list_employee_payment_categories | useEmployees; **INSERT/UPDATE via helper, then SELECT** categories. | Non-null tenant check; a nominal read RPC resets/reactivates defaults. |
| update_item_inventory (invoker trigger) | AFTER INSERT inventory_movements; UPDATE matching item quantities. | Uses tenant and item ID. Direct client insert cannot update items under current item policies; definer-origin insertion can. |
| audit_lpg_brands, audit_trucks (invoker triggers) | AFTER INSERT/UPDATE/DELETE; INSERT audit_logs. | No audit INSERT policy for direct clients; direct brand/truck mutation can fail. DELETE uses NEW instead of OLD, risking null audit identity. No live mutation tested. |
| employee_payment_immutable (invoker trigger) | BEFORE UPDATE/DELETE employee_payments; raises exception. | Guards row mutation even for postgres-origin writes; **does not guard TRUNCATE**. |

Two integrity facts must be accounted for when tightening access, without redesigning these workflows here:

- POS inserts a movement that fires the stock-update trigger **and also directly applies the same stock delta**. RLS changes must not be mistaken for an accounting fix. This duplicate update is visible in current source/live definitions; no checkout was executed in this inspection.
- Tenant-only policies do not enforce balances, calculated totals, stock bounds, approved state transitions, immutable creator/timestamps, or exactly one primary phone. Several checks live only in RPCs. Permitting alternative direct writes would weaken those checks.

### Actual frontend table access

All operational consumers are under the session-protected layout. Signup/login are public Auth endpoints; setup_business is called after sign-in. None of the frontend paths enforce application roles. Most direct queries omit tenant filters and depend on RLS.

**D** = direct PostgREST table operation; **R** = read/write inside a frontend-invoked RPC; **H** = helper/trigger only; **—** = no current use. The RLS design matrix below records access for every table. Direct UPDATE exists only through the printer upsert; there is **no direct frontend DELETE**.

| Source | Direct tables and embeds; RPC calls |
| --- | --- |
| AuthContext | SELECT own user_profiles with tenants(business_name); signup/sign-in/sign-out/session listener; setup_business. |
| useInventory | SELECT items + lpg_brands; SELECT movements + items/brands + creator user_profiles(email); INSERT items with returning SELECT; create_inventory_movement. |
| useCustomers | SELECT/search/duplicate-check customers; SELECT user_profiles tenant; INSERT customer with returning SELECT. Used on Customers and POS, including saving a customer before checkout. |
| useDashboard | SELECT sales totals/counts, movements count, customers count; sales feed embeds customers/sale_items/items/lpg_brands. |
| usePOS | SELECT price_books; create_pos_sale. Items/customer lookup also use shared hooks. |
| useReceiptPrinter | SELECT printer config; UPSERT (INSERT or UPDATE) with returning SELECT; committed sale receipt SELECT with customers/sale_items/items/brands. Printing bridge has no Supabase credentials. |
| useLogistics | SELECT wallets; SELECT transits with inner trucks embed; list_trucks/create_truck/update_truck/create_custom_transit/update_transit_costs. |
| usePurchases | list_purchases/create_purchase/update_purchase/complete_purchase; modal selectors also use item/truck/plant hooks. |
| useBrands | list_lpg_brands/create_lpg_brand/update_lpg_brand. |
| useGasPlants | list_gas_plants/create_gas_plant/update_gas_plant/create_area_officer/update_area_officer. |
| useEmployees | list_employees/list_employee_payment_categories/list_employee_payments/create_employee/update_employee/create_employee_payment. Unused deactivate_employee hook noted above. |

There are **27 RPC signatures referenced in hooks/context; 26 are consumed by current screens**. Unreferenced functions and unused hooks remain part of the exposed security surface. No frontend use of Storage, Realtime subscriptions, service-role clients, permissions/role administration, audit-log browsing, or financial-ledger browsing was found.

Both item/customer creation query `user_profiles.select('tenant_id').single()` **without user_id filtering**. Current tenant-wide profile SELECT would return multiple profiles in a multi-user tenant and break these flows. Preserve creator-email reads for inventory history while planning a reliable own-profile lookup; a blanket self-only profile policy would hide other staff's attribution.

## 4. RLS design matrix

This is the **minimum access contract observed in the current application**, not final permission assignments. Every browser-facing operation requires an authenticated identity and a trusted own-tenant relationship (**T**); candidate view/manage permission names are not yet enforced and need the decisions in section 5. No business-data anonymous access is required.

Cells separate current use from the safe design boundary:

- **D:T**: retain direct tenant-scoped access for the documented UI operation.
- **R:T**: operation is required through validated RPCs, not a reason to grant direct browser writes.
- **H**: trusted bootstrap/helper/trigger operation only.
- **Deny**: no current browser requirement; default deny. Optional administrative/future access needs an explicit decision.
- INSERT checks apply to new ownership; UPDATE must preserve tenant/identity on old and new rows. Actor fields and calculated values require additional restrictions. Related functions may be grouped by prefix as defined in section 3.
- SELECT through definers still needs equivalent tenant/permission validation **inside those functions**, whether or not direct table SELECT is granted.

| Table | Tenant ownership path | SELECT requirement | INSERT requirement | UPDATE requirement | DELETE requirement | Related RPC/functions | Special considerations |
| --- | --- | --- | --- | --- | --- | --- | --- |
| tenants | Root tenant_id reached from caller profile | D:T, profile business name | H, setup only | Deny | Deny | setup_business, my_tenant_id indirectly | Status not enforced; tenant deletion has cascades/restricting FKs. |
| user_profiles | user_id = Auth identity; tenant FK | D:Self; D:T creator email projection | H, setup only | Deny for current UI; any future self-edit limited to approved non-security fields | Deny | setup_business, my_tenant_id; profile-derived operational RPCs | tenant_id/user_id/is_active must not be self-controlled; no Auth FK. Resolve multi-profile single() calls. |
| roles | tenant FK | H, bootstrap; no frontend read | H, setup | Deny | Deny | setup_business | Current ALL permits role tampering; any administration requires protected authority. |
| permissions | Global permission catalog | H, setup; optional authenticated catalog read only if needed later | Deny | Deny | Deny | setup_business | No tenant column; seeded definitions must not be client-editable. |
| role_permissions | (tenant, role) → roles; global permission FK | H, bootstrap; future authorization lookup | H, setup | Deny | Deny | setup_business | Permission changes must not be ordinary tenant-member writes. |
| user_roles | (tenant, role) → roles; user_id → profile | H, bootstrap; future authorization lookup | H, owner assignment | Deny | Deny | setup_business | Validate target user's tenant; prevent self-grants, owner loss and escalation. |
| items | Own tenant_id; optional (tenant, brand) | D:T inventory/POS/purchase/receipt | D:T item registry only; constrain stock fields | R:T balance changes only | Deny | movement/POS/purchase RPCs, update_item_inventory, list_purchases | Composite PK; no root FK; stock must flow through validated accounting. |
| inventory_movements | (tenant, item) → items | D:T feed/history/count | R:T adjustments, POS/purchases | Deny | Deny | create_inventory_movement, create_pos_sale, purchase RPCs, update_item_inventory | Attribution server-set; row append-only; trigger context matters. |
| customers | Own tenant_id | D:T lookup/count/receipt; R:T POS | D:T customer form/POS save; R:T new POS customer | Deny (no current edit path) | Deny | create_pos_sale | Customer reads serve POS even without management rights; phone tenant-unique; no root FK. |
| customer_transactions | (tenant, customer) → customers | Deny; no current reader | R:T POS charge/receipt | Deny | Deny | create_pos_sale | Current ALL enables ledger tampering; reference_id untyped; creator must match caller. |
| price_books | (tenant, item) → items | D:T POS pricing | Deny; no frontend writer | Deny | Deny | No writing RPC | Define trusted price maintenance if required; current INSERT is unused. |
| sales | (tenant, customer) → customers, tenant FK | D:T dashboard/receipt | R:T POS only | R:T calculated totals during creation only | Deny | create_pos_sale | Avoid header writes bypassing lines/stock/ledger; history/reprint audience unresolved. |
| sale_items | (tenant, sale) and (tenant, item) | D:T sales feed/receipt embeds | R:T POS only | Deny | Deny | create_pos_sale | Parent and item tenant must agree; no mutable completed-line path. |
| purchases | Tenant FK; (tenant, truck/plant) | R:T purchase list | R:T create | R:T edit in_transit, completion transitions | Deny | create/list/update/complete_purchase | Preserve locked/status-dependent accounting; no direct header edits. |
| purchase_items | (tenant, purchase/item) | R:T list_purchases | R:T purchase creation | R:T update_purchase | Deny | create/list/update/complete_purchase | list joins need tenant keys; line mutations and stock movements must stay coupled. |
| trucks | Tenant FK | R:T list/selector; D:T transit embed | R:T create | R:T truck update/purchase/transit workflows | Deny | truck RPCs, create_purchase, custom/transit RPCs, audit_trucks | Audit invoker cannot simply be bypassed by opening direct writes; legacy overloads. |
| transits | Tenant FK; (tenant, truck); purchase_id unvalidated | D:T transit list | R:T create_purchase/custom transit | R:T costs/status | Deny | create_purchase, create_custom_transit, update_transit_costs | Final UPDATE missing tenant; completed lock can be bypassed by direct table UPDATE. |
| wallets | Tenant FK; unique (tenant,type) | D:T Logistics balances; R:T accounting | H, ensure zero-balance wallets | R:T accounting only | Deny | ensure_tenant_wallets, POS/purchase/transit RPCs | No direct creation requirement; never client-chosen initial balance; qualify all updates by tenant. |
| wallet_transactions | (tenant, wallet) → wallets | Deny; no current reader | R:T purchase/transit entries | Deny | Deny | purchase/custom/transit RPCs | POS changes wallet without this ledger entry; reference_id untyped. |
| lpg_brands | Tenant FK | D:T item/receipt embeds; R:T lists | R:T create | R:T edit/deactivate | Deny | brand RPCs, audit_lpg_brands, list_purchases/list_gas_plants | Direct mutation conflicts with audit INSERT boundary; referenced hard deletion problematic. |
| gas_plants | Tenant FK; optional (tenant,brand) | R:T directory/purchase selector | R:T create | R:T edit/deactivate | Deny | gas-plant RPCs, list_purchases | Contacts exposed by list; composite brand FK. |
| area_officers | Tenant FK; (tenant,plant) | R:T plant directory | R:T create | R:T edit | Deny | create/update_area_officer, list_gas_plants | Contact PII, validate owned parent; no UI delete. |
| audit_logs | Own tenant_id; record/actor not FK-bound | Deny; no frontend reader | H, brand/truck triggers | Deny | Deny | audit_lpg_brands, audit_trucks | Trusted attribution and append-only boundary; DELETE-trigger NEW issue. |
| employees | Tenant FK; (tenant,type) | R:T employee list | R:T create | R:T update/activation | Deny direct; unused RPC conditionally deletes unpaid employee | employee RPCs, list_employee_payments | Salary/address/notes PII; no account identity link; employee permission decision required. |
| employee_types | Tenant FK | R:T employee list join | H, resolve type in employee RPC | H, type reactivation | Deny | resolve_employee_type, create/update/list_employees | Arbitrary-tenant helper currently exposed; no standalone management UI. |
| employee_phone_numbers | Tenant FK; (tenant,employee) | R:T list_employees | R:T employee creation/replacement | Deny direct; replacement via RPC | R:T replace phones; unused delete cascade | create/update/list_employees, deactivate_employee | Index ensures at most one primary; RPC ensures exactly one; tenant-unique phone. |
| employee_payment_categories | Tenant FK | R:T category/payment lists | H, default-category ensure | H, default reset/reactivation | Deny | ensure_default_employee_payment_categories, employee/category/payment RPCs | “List” mutates; default categories versus custom maintenance unresolved. |
| employee_payments | (tenant,employee/category/code) | R:T list/payment count | R:T create_payment | Deny | Deny | create/list_employee_payment(s), list_employees, employee_payment_immutable | Salary/payroll sensitive; immutable triggers and monthly uniqueness; no wallet debit. |
| receipt_printers | Single tenant primary/FK key | D:T config | D:T upsert | D:T upsert preserving tenancy | Deny | No RPC; useReceiptPrinter | Retain narrowed grants and returning SELECT; host/queue data; manager versus cashier settings decision. |

## 5. Business-rule decisions required before final policies

Only unresolved authorization choices are listed; tenant isolation, no anonymous business-data access, protected identity/tenant assignments, trusted actor fields, and preserving immutable payment records do not need a new business decision.

1. **Permission contract and dependent reads:** should the seeded Owner/Manager/Salesman model become enforced now, and how do view/manage/pos:sell authorize shared selectors, dashboard totals, sales history and reprints? POS already reads customers/items/prices and can create a customer; purchase forms read trucks/plants/items. Decide whether those actions implicitly include necessary limited reads/creation or require additional grants. Decide the authority for role/member administration, including whether settings:manage covers it and who can grant/manage Owner.
2. **Employee/payroll visibility:** which roles may see salary, notes, addresses, payment history and counts, versus ordinary staff contacts; who may edit staff/payments or use the currently unused deletion RPC? Existing permission IDs and employee types do not answer this. Decide whether business_unit partitions access or only classifies records.
3. **Inactive/suspended access:** what should existing authenticated users retain when profile is_active is false or tenant status is not active—no operational access, read-only history, or another defined subset? Identify which trusted authority changes those fields; self-reactivation must not be allowed.
4. **Registration/member admission:** is self-service business signup intended beyond the current local deployment, must email be verified, and who may provision staff accounts or assign them to a tenant? The current one-profile-per-user schema supports one tenant only; no invitations/membership-transfer workflow exists.
5. **Unimplemented maintenance:** who may maintain price books, inspect audit/financial ledgers, change printer settings, and manage custom employee payment categories? No current price/audit/ledger UI establishes the audience. Category “list” currently resets/reactivates defaults; decide whether categories are fixed system data or tenant-managed data. Printer settings currently allow every tenant member.

No question proposes weakening cross-tenant isolation or enabling anonymous ledger access. Unsupported direct deletes/edits remain denied unless a separately authorized workflow requires them.

## 6. Ranked security priorities

| Rank | Issue and verified basis | Required outcome for the separate design step |
| --- | --- | --- |
| **P0.1** | Own-profile UPDATE can change tenant_id to any existing tenant; all tenant checks trust it. | Make tenancy, identity and activation trusted fields; allow only approved ordinary self-profile columns, if needed. Protect profile bootstrap/administration. |
| **P0.2** | Anonymous/PUBLIC EXECUTE on ensure_default_employee_payment_categories and resolve_employee_type, with unchecked tenant arguments. | Remove unintended client exposure and/or validate callers/tenants; retain safe internal calls without giving clients arbitrary-tenant writes. |
| **P0.3** | list_purchases joins/subqueries and update_transit_costs final UPDATE omit tenant keys; wallet updates in purchase/transit functions also omit them. Composite PKs permit reused IDs. | Qualify every read/write/parent relation by tenant inside privileged routines; test deliberate reused UUIDs across tenants. Closing direct writes alone is insufficient for leaked join keys. |
| **P1.1** | All 32 definers bypass policies; none enforces application permissions, profile active state or tenant status. | Establish an explicit RPC allowlist and enforce the same identity/tenant/permission contract in every authorized definer path, including read functions. Audit nested invoker execution. |
| **P1.2** | Tenant-wide ALL on roles/user_roles/role_permissions allows arbitrary RBAC edits and future permission escalation. | Protect assignment/catalog writes and target membership; solve recursive authorization lookups without trusting editable metadata or opening assignment tables. |
| **P1.3** | Broad table grants plus direct ledger/header/employee writes permit paths outside validated RPC flows. | Keep only necessary direct operations from the matrix; reject spoofed actors/ownership and calculated/security field changes. Preserve atomic business operations. |
| **P1.4** | TRUNCATE/REFERENCES/TRIGGER/MAINTAIN on 28 tables and broad defaults for two creators; inherited PUBLIC function execution. | Minimize existing and future grants. Table-wide grants cannot be repaired by row policies. Keep service/admin credentials outside browser access. |
| **P2.1** | Six mutable function search paths; public-only paths and unqualified references in privileged code. | Use trusted, explicit object resolution; retain the non-recursive tenant helper with a narrow contract. |
| **P2.2** | Duplicate permissive policies and unused legacy RPCs obscure the effective contract. | Consolidate intended policies, target authenticated explicitly, and decide whether legacy/unused overloads stay callable. |
| **P2.3** | Multi-profile single() callers, trigger context, nominally read-only category mutation and missing relational boundaries complicate policy changes. | Check real mounted flows and trigger side effects under non-owner roles; do not add permissive policies just to make failures disappear. |

**Evidence limit:** the catalog/body combinations establish these authorization gaps and reachable grants; destructive writes and cross-tenant exploit payloads were not executed. The anonymous read test verifies only the selected read surfaces.

### Acceptance evidence for the later policy-design/implementation step

Use an isolated database or rollback-only approved fixtures, with two tenants, multiple users per tenant, Owner/Manager/Salesman/no-role identities, inactive profiles, suspended tenants, and deliberate repeated entity UUIDs. Validate both direct REST and each allowed RPC under anon/authenticated—not solely as postgres. Cover profile reassignment/self-reactivation, self role grants, foreign-tenant helper arguments, parent/creator spoofing, ledger/header bypass writes, SELECT/INSERT/UPDATE/DELETE and printer upsert returning SELECT.

Also verify nested stock/audit triggers, staff creator-email embeds, POS customer save/checkout/history/reprint reads, purchase create/edit/receive, transit completion accounting, employee phone replacement and immutable salary records. Treat existing stock double updates, missing wallet-ledger entries and obsolete truck columns as known implementation facts when judging results; they are not fixed by this report.

## Appendix: exact public function signature inventory

Snapshot of all 37 live functions. Every signature below has effective EXECUTE for PUBLIC, anon and authenticated; all owners are postgres. **SD** = definer/BYPASSRLS; **SI** = invoker. Trigger-returning signatures are internal trigger contracts, not ordinary callable RPCs. Full bodies are in the authoritative migrations; section 3 records their security/operation contracts.

| Signature | Execution | Current source consumer |
| --- | --- | --- |
| `audit_lpg_brands()` | SI | Brand trigger |
| `audit_trucks()` | SI | Truck trigger |
| `complete_purchase(uuid)` | SD | usePurchases |
| `create_area_officer(uuid,text,text,text)` | SD | useGasPlants |
| `create_custom_transit(uuid,numeric,text)` | SD | useLogistics |
| `create_employee(text,jsonb,text,numeric,text,text,text)` | SD | useEmployees |
| `create_employee_payment(uuid,uuid,numeric,date,text,integer,integer,integer)` | SD | useEmployees |
| `create_gas_plant(text,uuid,text)` | SD | useGasPlants |
| `create_inventory_movement(uuid,text,integer,integer,text)` | SD | useInventory + purchase RPCs |
| `create_lpg_brand(text,text)` | SD | useBrands |
| `create_pos_sale(character varying,character varying,character varying,text,character varying,numeric,numeric,text,jsonb,uuid)` | SD | usePOS |
| `create_purchase(uuid,uuid,numeric,numeric,text,jsonb)` | SD | usePurchases |
| `create_truck(character varying,character varying,integer,truck_size,character varying)` | SD | useLogistics |
| `create_truck(character varying,character varying,integer,truck_size)` | SD | Legacy; no frontend call |
| `deactivate_employee(uuid)` | SD | Unused useEmployees hook |
| `employee_payment_immutable()` | SI | Payment triggers |
| `ensure_default_employee_payment_categories(uuid)` | SD | Employee/category RPC helper |
| `ensure_tenant_wallets(uuid)` | SI | POS/purchase/transit helper |
| `list_employee_payment_categories()` | SD | useEmployees |
| `list_employee_payments(uuid)` | SD | useEmployees |
| `list_employees()` | SD | useEmployees |
| `list_gas_plants(boolean)` | SD | useGasPlants |
| `list_lpg_brands(boolean)` | SD | useBrands |
| `list_purchases()` | SD | usePurchases |
| `list_trucks(boolean)` | SD | useLogistics |
| `my_tenant_id()` | SD | Policy/RPC helper |
| `resolve_employee_type(uuid,text)` | SD | Employee RPC helper |
| `setup_business(text,text)` | SD | AuthContext |
| `update_area_officer(uuid,text,text,text)` | SD | useGasPlants |
| `update_employee(uuid,text,jsonb,text,numeric,text,text,text,boolean)` | SD | useEmployees |
| `update_gas_plant(uuid,text,uuid,text,boolean)` | SD | useGasPlants |
| `update_item_inventory()` | SI | Inventory trigger |
| `update_lpg_brand(uuid,text,text,boolean)` | SD | useBrands |
| `update_purchase(uuid,numeric,numeric,text,jsonb)` | SD | usePurchases |
| `update_transit_costs(uuid,numeric,numeric,numeric,jsonb,transit_status)` | SD | useLogistics |
| `update_truck(uuid,character varying,character varying,integer,truck_size,boolean)` | SD | Legacy; no frontend call |
| `update_truck(uuid,character varying,character varying,integer,truck_size,truck_status,character varying)` | SD | useLogistics |
