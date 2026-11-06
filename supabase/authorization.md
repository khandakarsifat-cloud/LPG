# Account, platform and tenant authorization

The browser uses the public key and a normal Supabase Auth session. PostgreSQL is
the authority for account status, business status, platform identity and effective
permissions. User-editable Auth metadata, route visibility and client tenant IDs
never grant access. Application authorization roles are unrelated to employee job
titles in `employee_types`.

## Identity and sessions

- `user_profiles`, `user_roles`, `roles`, `permissions` and `role_permissions`
  retain the existing single-business membership model. Each member has exactly
  one OWNER, MANAGER or SALESMAN application role.
- `app_private.platform_superadmins` is a separate platform identity registry.
  A superadmin has no fabricated business membership or OWNER assignment.
- `app_private.session_valid` requires the signed JWT's `session_id` to belong to
  its actual Auth user, still exist in `auth.sessions`, remain unexpired and not
  belong to a banned or anonymous identity. Missing/revoked sessions fail closed.
- `account_security` gates first-login password changes and incomplete password
  resets. Existing valid accounts are initialized without a forced reset.
- `current_tenant_id()` requires a ready account and an active business/profile.
  Superadmin tenancy comes exclusively from `admin_workspace_sessions`, keyed by
  the verified Auth session. Browser headers and arbitrary tenant IDs cannot
  select a workspace. The administrator may select only an active business.
- Suspension deletes member sessions and any selected administrator workspace.
  Deactivation deletes the affected member's sessions. Every subsequent RLS/RPC
  request rechecks database state; reactivation never revives revoked tokens.

`get_access_context()` returns the caller's own account state and effective
workspace. The frontend polls it every 15 seconds and on focus, clears domain
caches when scope or permissions change, and broadcasts workspace switches to
other tabs. The database enforces revocations independently of this UI interval.
Previously downloaded information cannot be recalled from a user's device.

## Effective capabilities

OWNER always has the complete current permission catalog, even if its historical
role mappings are incomplete. Owner-only capabilities cannot be delegated.
Existing business owners are preserved; migration does not infer ownership from
email, Auth metadata or employee records.

MANAGER defaults to all delegable capabilities. SALESMAN defaults to Dashboard,
POS, saved sales, receipt printing and personal preferences. An OWNER may replace
an individual staff member's role defaults with an explicit permission allowlist
in `user_permission_sets`. Changing a role or permission set takes effect for
existing JWTs on the next database request.

The catalog includes module/view permissions and action capabilities:

| Area | Delegable actions | Additional protected actions |
| --- | --- | --- |
| Sales | POS checkout, saved sales/receipts, bottle collection, money collection | Cancellation and customer refunds require their explicit capabilities |
| Inventory | Product registration, product/photo edits, stock alerts | Selling prices, MRP, buying overrides and valued stock adjustments have independent capabilities; product commission rates are removed |
| Purchases | Create, edit, dispatch, receive, payments, supplier refunds | Cancellation and manual company rebate entry/corrections require their explicit capabilities; rebate settlement also requires purchase edit/manage/pay capabilities |
| Customers | View, create, edit; POS includes checkout customer creation | All operations stay within trusted membership |
| Logistics | Vehicle edits, transits, incurred costs, operating payments, service trips | Vehicle acquisition accounting, retirement and availability use explicit capabilities |
| Employees | Create/edit profiles and dated terms; device links/attendance corrections | Job titles never affect application permissions |
| Payroll | Read balances/history, pay, return/correct payments | Linked transit payments also require Logistics management |
| Finance | Separate history, own/all entries, stock/FIFO, accounting activity and loan read scopes; entry creation/returns and wallet configuration/transfers | Loans/assets/capital/opening operations and balance corrections use explicit capabilities |
| Reports | Financial Analysis, breakdowns and reports | Requires Finance view |
| Settings | Business profile, catalogs, financial types, brands, plants and printers | Configuration changes never rewrite historical accounting recognition |
| Access | None for staff | Account creation, status, roles, permissions and resets require OWNER or superadmin |

Management capabilities are prerequisites for their action permissions; they do
not substitute for the finer action gates. Catalog dependencies are validated
server-side. The permission editor selects prerequisites and removes dependent
permissions together. Unknown capabilities, missing dependencies, owner-only
grants and staff promotion to OWNER are rejected. Owners cannot modify or disable
their own account through staff administration. A business must retain an active
OWNER; suspend the business to block everyone.

Supporting selector reads remain deliberate: POS can read product/price/customer
identities, Purchases can read its products/plants/vehicles, and payment workflows
can read active wallet destination names through `get_payment_wallets` without
balances. Inventory view includes inventory valuation; purchase/logistics views
include their own costs and settlements. Dashboard permission exposes bounded
summary/feed RPCs, not direct full sales/payment tables. Wallet balances require
Finance view/manage. Employee-only readers do not receive payroll balances.

## Platform administration and audit identity

`#/admin` contains platform totals, paged businesses/accounts, suspension and
reactivation, storage measurement and access audit. Business entry gives the
administrator exactly the target OWNER's effective capabilities. The account
menu returns to the panel without signing in as another person.

Canonical business writes still use `auth.uid()`. Actor foreign keys now refer
to the tenant-qualified private `tenant_actors` registry, populated from real
memberships or an authenticated superadmin entry. It retains full name/email
attribution without assigning the administrator a business role. Membership
foreign keys remain attached to actual `user_profiles`. Existing journal, FIFO,
stock, request and source locks are unchanged.

`access_audit` records bootstrap, workspace entry/exit, business/account status,
role/permission changes, provisioning/reset requests and completions, email and
password changes. Only the platform administrator or the relevant business OWNER
can read its paged RPC. Credentials and tokens never enter audit payloads.
Normal module activity retains its original source records and actual actor IDs.

The backup panel uses `/backups/v1/*` through the private account service and a root-owned Unix-socket controller. Every management request revalidates GoTrue identity and the current `get_access_context` superadmin/session gate; OWNER alone is insufficient. OAuth state is single use, session-bound and short lived, with PKCE and a fixed HTTPS callback. Credentials/refresh tokens remain root-only on the VPS. Routine reads use cached status; only explicit connection actions and nightly jobs access Google. Recovery is an isolated operator procedure, never a browser-triggered restore. See [cloud recovery](../deploy/backup/recovery.md).

## Auth administration service

`account-service/server.mjs` is a small private-network Node HTTP service behind
`/accounts/v1/*`. It validates the real bearer through GoTrue and then the current
database account/session. It uses a bounded JSON body, fixed upstream paths,
timeouts, verified-identity rate limits, an exact origin allowlist and no request
or credential logging. There are no client-controlled upstream URLs or Auth
administration attributes.

The server-held service key is used only for official GoTrue administration and
service-only provisioning/bootstrap database functions. On the VPS it is in the UID-1000, mode-400
generated `deploy/.account-service.json` mount; this ignored file is never bundled
into the frontend or uploaded from the workstation. Local Compose supplies it
only to the server environment from the existing private `.env`.

Provisioning is a retryable two-phase workflow:

1. `prepare_account_operation` authorizes the real actor and trusted target,
   validates an exact noncredential payload and reserves a request/Auth UUID.
2. The service creates that UUID through GoTrue with a temporary password. It
   never adopts an existing account by email. A retry finds the reserved Auth
   UUID rather than creating another account or silently changing its password.
3. `complete_account_operation`, executable only by `service_role`, revalidates
   the original actor/session before committing the business/profile/role and
   first-login restriction. No unfinished Auth identity has business access.

The UI keeps only the request ID and noncredential operation in session storage
for recovery; it never saves the temporary password. Retry an uncertain operation
with its original request ID. A pending password reset blocks the target until
completion. The initiating account can retry the original request, or another
authorized administrator can start a new reset. A new reset supersedes the older
generation, and delayed older password writes are rejected even after the new
reset completes.

Owners may create only MANAGER/SALESMAN accounts in their own business and reset
only those accounts. Superadmin alone creates businesses and their initial OWNER
and may reset business owners. The service checks current authorization again at
completion, including if permission or status changed during an Auth request.

Self password changes reauthenticate the current password and require a different
12–128-character password with uppercase, lowercase and a number. The
`auth.users` password-change trigger clears a first-login restriction only after
a real hash change, preserves incomplete administrative reset restrictions,
audits the change and atomically revokes all sessions. Direct public Auth account
writes (PUT/PATCH/DELETE) are denied by the public proxy and by Envoy unless they
carry the server-only service key. New/reset users must make
that change before any business or platform access. SMTP is not configured;
temporary credentials must be delivered securely outside the app, and automated
recovery/invitation email is unavailable.

Password writes also require a private, single-use transaction marker. The
self-change nonce is issued only for a valid active account/session; resets use
their current private operation generation. The service supplies the marker
through GoTrue's server-only admin `role` parameter. A BEFORE trigger converts it
to a transaction-local setting while preserving the actual Auth role unchanged;
the password trigger consumes/checks it in that same transaction. No nonce role
is ever stored, granted or used in a JWT, and no user-editable metadata authorizes
a password write. This deliberately relies on the pinned GoTrue v2.196.0
`adminUserUpdate` ordering (`SetRole` before `UpdatePassword`). Review that source
and rerun the real API suite before upgrading GoTrue. A stale reset cannot consume
a newer self-change nonce or overwrite a completed newer reset.

`initialize-platform.mjs` is a one-time stdin-only, server-side CLI, never an HTTP
endpoint. Its preflight and permanently consumed `platform_bootstrap` record
prevent another bootstrap. Do not save temporary credentials in code, migrations,
shell arguments or tracked documentation. This is separate from VPS installation
bootstrap; do not rerun the VPS bootstrap on an existing server.

## Public registration, RLS, grants and Storage

Public signup is disabled by literal `GOTRUE_DISABLE_SIGNUP=true` in Compose and
disabled in Supabase CLI configuration. The registration form/Auth signup action
and public `setup_business` RPC are removed. `#/register` redirects to login.
Neither a public Auth endpoint nor an authenticated ordinary user can provision
a business. Existing legitimate memberships and ownership are preserved.

All public and private application tables have RLS. Direct browser writes remain
limited to zero-stock product registration, permitted customer creation and
printer configuration. RBAC/profile/auth/accounting/inventory-history writes are
RPC/server-only. Public/anon function execution and future browser object grants
remain revoked. Definer functions have pinned paths and trusted tenant gates;
unexposed internal helpers are not browser-executable except the read predicates
and pure constraint helpers required by RLS/direct registration.

Product images remain in a private tenant-prefixed bucket. The browser uses
authenticated downloads and releases local object URLs on scope changes. Both
Envoy and the public proxy deny signed-download/signing routes, including existing
signed URLs, so a signed token cannot outlive membership/session suspension.
Upload/delete policies derive trusted tenancy and product permissions; deletion
still rejects images referenced by a product. Storage totals count actual stored
object byte sizes. Per-business database figures are explicitly row-payload
estimates, excluding indexes, free space and shared platform overhead; the overall
database total uses `pg_database_size`.

## Verification and migration

The forward migration is `20261102084622_platform_account_access.sql`. Applied
migrations and their original replay boundaries are not rewritten.

```powershell
npm run auth:test
npm run auth:db:test
npm run auth:api:test
```

The database suite restores the primary database into a named disposable copy,
applies pending migrations, verifies original stock/journal/business evidence,
probes every authenticated application RPC under a revoked identity, checks RLS
and grants, and exercises owner/staff/platform isolation and attribution. It also
runs twelve existing current-state accounting/FIFO/dashboard regression suites
using temporary trusted fixture provisioning and real session rows. Historical
signup-era fixtures remain at their original replay boundary.

The API suite starts isolated GoTrue/PostgREST containers against another
disposable copy and runs the actual account service. It covers disabled signup,
one-time bootstrap, first password change, metadata spoofing, both Auth-creation
and completion retries, normal roles, individual capabilities, cross-business
and direct-write denial, session/refresh revocation, reset, suspension,
reactivation, workspace switching, audit and storage reports. It never changes
the primary application's existing businesses or retained acceptance labs.

`tests/account-access.browser.cjs` covers intercepted desktop/phone light/dark
flows separately from real authenticated acceptance.
`node tests/account-access-live.browser.mjs --vps` exercises the published Worker,
normal Auth/PostgREST and private Storage using uniquely named disposable
businesses and identities. It preserves the actual bootstrap account's forced
password change and verifies original business records before and after cleanup.
Its trusted SSH helper is fixture arrangement only and is never deployed.
Physical Android behavior,
physical printing and payment-provider settlement are separate checks. The
application remains in development under `AGENTS.md`; this account system does
not certify the rest of the infrastructure for production.

## Per-wallet access

`app_private.user_wallet_access` stores tenant/user/wallet overrides for Use, Balance and History. `wallets:use`, `wallets:balances` and `wallets:ledger` supply defaults where no override exists. `manage_business_user` saves capabilities, account status and optional wallet overrides atomically under the existing revision lock and access audit. An empty override array restores defaults. Foreign-tenant wallet IDs, duplicates and malformed scope flags are rejected. New SALESMAN accounts can use wallets for authorized operations without seeing their balances; MANAGER defaults retain delegable read/action capabilities. OWNER remains unrestricted.

The canonical wallet posting trigger enforces Use, including automatic Cash Register operations and both transfer legs. `get_payment_wallets` and trip selectors return only usable wallets. Browser SELECT on raw wallets/transactions is revoked; `get_finance_wallets` and `get_wallet_ledger` enforce visibility server-side and redact hidden balance fields. General Finance access is only workspace access. `finance:entries:view` reads own records; `finance:entries:all` permits other staff records; returns require read scope and the separate return action. `finance:loans` gates the loan register/history. Analysis, accounting activity and audit capabilities are ineffective unless every wallet balance is visible, preventing aggregate and audit-snapshot disclosure. The access-context revision invalidates cached data even when the capability list itself stays unchanged.

### Delegated operational controls

The permission catalogue exposes independent selling-price (`inventory:prices`), MRP (`inventory:mrp`) and approximate buying-reference (`inventory:buying_prices`) controls. The price RPC checks changed fields under its existing product lock and revision guard. POS prices must match the saved price book; there is no checkout-price override. `sales:discount` separately authorizes nonzero checkout discounts. Existing `pos:sell` grants retain their previous discount ability through explicit migrated grants.

Stock adjustments, sale cancellation/refunds, purchase cancellation/rebates, vehicle retirement and wallet corrections are explicit capabilities. Accounting operations use `finance:capital`, `finance:opening`, `finance:loans:manage`, `finance:assets:manage` and `finance:obligations:manage` with Finance management dependencies; loan viewing remains separate. Opening/capital funding also checks its corresponding permission, and disposing of a vehicle additionally requires vehicle retirement. The retired `finance:owner` bundle is normalized into these leaves without expanding unrelated grants. Owners and the platform administrator retain full access. Only they may grant permissions or manage accounts; staff account administration is not delegated. Access-context permission fingerprints invalidate cached reads when effective scopes change.

### Business deletion

Only an active platform administrator can start deletion through the private root controller. The UI previews record/file/account impact, then requires the current password and a separate exact `DELETE` confirmation. Hashed, actor/target/action-bound proofs expire after five minutes and are single use. Root-only SQL functions have no PUBLIC, anonymous, authenticated or service-role grants.

The server fences and suspends the tenant, drains existing writes and revokes business sessions/workspace entry. A fresh full encrypted recovery point must pass the existing isolated cloud restore verification before any files or records are removed; it is protected from retention until the job completes. Storage deletion uses its API; the database purge keeps constraints enabled and removes child tables before parents in one transaction. Narrow immutable-delete guards authorize only the root session and exact active deletion job. New tenant tables must install the same write guard; preview fails closed when a guard is missing. The purge discovers tenant tables through `tenant_id`; an unsupported dependency cycle stops cleanup rather than disabling constraints. Dedicated Auth identities are removed through GoTrue after business records, with exact-ID cleanup of remaining login flow, refresh and Auth audit records. Shared/protected identities remain. Failed/interrupted jobs stay fenced and can resume with renewed password/text confirmation. Minimal global deletion audit and normal historical backups remain; shared schemas/tables/indexes are never dropped.
