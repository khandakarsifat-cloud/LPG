# Canonical development architecture audit

## Result and scope

The repository and configured Azure PostgreSQL 17.6 database were audited together. The initial database had 38 public tables, 108 application functions, all 33 repository migrations, 70 sales and 32 purchases. Source inventory covered every frontend module, hooks/types/utilities, ordered migrations, exposed RPC contracts, grants/RLS, triggers, indexes, deployment and printing boundaries. Dependency and transaction review concentrated on POS, sales, purchases, bottle receipts, inventory, payments, wallets and logistics. Existing uncommitted feature work was preserved.

This is an architectural cleanup, not a claim that every possible defect is excluded. No new security regression was identified by the differential review and verification below. Stock and monetary changes remain high-risk operations and retain their existing database gates and transaction recorders. Supabase MCP tools were unavailable; live inspection used the configured SSH/SQL path after checking the API and deployment target.

Migration: [`20261026070000_canonical_development_model.sql`](../../supabase/migrations/20261026070000_canonical_development_model.sql). Previously applied files are unchanged. No dependencies were added.

## Removed or consolidated

| Finding | Canonical implementation |
| --- | --- |
| Separate old/new sale payment and bottle behaviors | Removed `sales.payment_tracking` and `sales.bottle_tracking`. Every sale uses the same settlement model. Earlier physical returns are normalized once, at their original sale dates, without another inventory posting. |
| Bottle agreement duplicated in sale lines and another table | Removed `sale_bottle_obligations`. Original immutable `sale_items.empty_return` rows supply expected quantities; receipt lines supply actual quantities. Sale-line UPDATE/DELETE protection preserves the agreement. |
| Abandoned expected-to-actual allocation | Removed receipt-line `expected_item_id`, `allow_incompatible` and their dependent index/FK. Actual products, quantities and acknowledgements remain. Existing explicit substitutions become acknowledgements. |
| Duplicated checkout attribution JSON | Removed `sales.checkout_payments`. The settlement API reads immutable checkout-phase `sale_payments`; `paid_at_checkout` retains the original amount. Unattributed paid amounts remain explicit rather than acquiring invented methods or wallet entries. |
| Duplicate product name/weight representations | Removed `items.brand`, `items.cylinder_weight` and the unused weight enum. Required tenant-qualified `brand_id` supplies the name; `size_kg` supplies weight. Older missing brand relationships are resolved once by tenant/name. |
| Shared commission fallback | Materialized missing package rates once, retained attribution/date/rate ID, renamed the refill field to `refill_commission_per_unit`, and required both rates. One latest-row read supplies both rates. |
| Purchase version marker and reader repair | Removed `purchases.legacy_record`, company-guard exemptions and synthesized transit status. Existing statuses/references/received quantities are normalized once. Actual billed and received quantities remain distinct facts. |
| Runtime parsing of old purchase notes | Exact established note formats are linked once to tenant-qualified purchases. Current readers/cancellation use saved references. Ambiguous old receipt kinds use `purchase_history`; no product allocation is guessed. |
| Obsolete exposed APIs | Removed ten routines: `list_purchases()`, `complete_purchase(uuid)`, `pay_purchase(uuid,integer)`, `cancel_purchase(uuid,integer)`, single-rate commission setter, and retired positional create/update purchase, receipt, custom-transit and transit-cost overloads. Current revision/JSON/request-ID contracts remain. None has a frontend runtime caller. |
| Redundant indexes | Removed `idx_items_tenant`, `idx_items_brand_id`, `idx_price_books_tenant_item_tier`, `idx_wallet_transactions_wallet`, `idx_wallets_tenant`; existing primary/unique/composite leading keys cover those lookups. Column/table removal also removes their obsolete dependent indexes. The outstanding-sales index uses the canonical due predicate. |
| Frontend duplicate/obsolete implementations | One polled inventory query/cache serves forms, POS and balances. Removed unused stock hooks/types, the client-side purchase directory implementation, sparse Dashboard retry query/name fallback, retired bottle-status UI, and receipt assumptions that missing payment data means fully paid. |
| Stale tests and documentation | Removed the superseded full-payment/cancellation SQL suite and duplicate client-filter tests. Kept migration-specific historical fixtures. Purchase browser checks now cover draft/dispatch behavior separately from the current payment/refund suite. Updated architecture/module guides and the development policy. |

Twenty-three existing functions were replaced in place, preserving their owner, ACL, permission gates and empty search paths. All 55 literal frontend RPC names were matched to the database inventory; retired endpoints have zero runtime callers. The checkout now saves authoritative sale lines before receiving bottles, then posts sold stock and money in the existing transaction. Stock locks remain ordered and failed operations roll back together.

## Retained intentionally

- Wallet `opening_balance`, running balances, ledger name/method/search snapshots and payment attribution serve reconciliation, immutable evidence and bounded queries. They are not duplicate mutable accounting systems.
- Original invoices, sale tiers, `paid_at_checkout`, actual/billed purchase quantities, prior customer charges and recorded business expenses remain. Development permission does not justify inventing missing attribution or rewriting legitimate financial activity.
- Historical ledger event categories still describe their recorded economic events. For example, an old labour-plus-trip debit cannot honestly be relabeled as a precisely allocated labour payment. Source-backed refunds continue to use recorded evidence. These are accounting classifications, not version-dependent write workflows.
- Completed request payloads/results and Finance request records remain for idempotent recovery. Missing checkout-payload keys are normalized once; changed requests still reject. Unsupported new bottle fields reject instead of silently changing their meaning.
- Wholesale-to-retail price fallback, empty-return/refill parity, package empty-stock deduction, partial/multi-wallet payments, aggregate bottle settlement, OWNER cancellation, immutable refunds and separate transit-cost closure are current business rules.
- Trusted tenancy, capability mappings, composite foreign keys, RLS and private workflow helpers remain authoritative. Platform JWT/API-key and gateway compatibility required by the pinned Supabase stack was retained.
- Payroll's independent payment history, incomplete business-profile/stock-exception features and the isolated attendance prototype remain as documented. They were not treated as obsolete merely because they are unfinished.

## Verification

| Boundary | Evidence |
| --- | --- |
| Local source | Build/type checks, lint, print type check, and 64 unit/print tests passed. Deployment tooling tests passed (JavaScript plus 12 Python checks). |
| Ordered migration replay | All 34 migrations, historical before/after fixtures, canonical normalization assertions and ten current SQL suites passed on disposable PostgreSQL 17.6. Temporary fixture helpers are restricted to `pg_temp`, never application schemas. |
| Financial/transaction integrity | Concurrent matching checkout, reversed carts, last-stock contention, purchase creation/dispatch/payment/receipt, cancellation/refund races, duplicate/competing collections, transfers and bottle/cost/payment races passed. Wallet balances reconcile to opening baseline plus ledger. |
| Actual development records | An isolated copy of real business data passed rollback and commit of the migration. Stock quantities, wallets, complete wallet/customer ledgers and payment rows were unchanged. Every one of the 70 existing sales loaded through the gated current receipt API and reconciled payment provenance and aggregate bottles. Password hashes/sessions were not copied. |
| Performance fixtures | Current ledger and customer performance suites passed, including 20,000 ledger entries and 10,000 customers / 60,000 sales / 180,000 lines across two tenants. These are synthetic correctness/query-plan checks, not a new capacity guarantee. |
| Intercepted browser fixtures | Bottle recovery/layouts, inventory, inventory history, printing, Finance, customers, purchase draft/dispatch, purchase settlement and purchase creation recovery passed. Responsive checks include 320–1440px and 58/80mm receipts. Printing is intercepted. |
| Security review | All initial public tables have RLS; no public SECURITY DEFINER routine was executable by `anon`. Authorization suites cover inactive/anonymous membership, roles, reused IDs and cross-tenant denial. No new browser grants or public helper access were introduced. Receipt validation cannot be bypassed with the retired tracking flag. |
| Deployment/live acceptance | Migration `20261026070000` applied through the established updater; all ten backend services and public HTTPS health passed. Cloudflare version `3a175d47-a7fd-4ed0-9e00-248a09b66549` is published. Real Auth/PostgREST and published-browser acceptance passed on cleaned-up fixture businesses; existing business fingerprints were unchanged and the burner was retained. |

The migration created 37 normalized checkout receipt headers from previously recorded returns, with no new stock or money entries. The deployed database retains all 70 sales, 32 purchases, 190 wallet entries and 66 sale payment records. Post-cleanup checks found zero negative stocks, invalid sale/purchase totals, wallet reconciliation errors or differences between customer ledger balances and outstanding sale totals. All 37 remaining public tables have RLS, existing routine ownership/ACLs are unchanged, and the complete 34-version migration history matches the repository with no pending versions.

Live acceptance used `bottles-api.mjs --azure --browser`, `purchase-wallets-api.mjs --azure --browser`, `finance-api.mjs --azure` and `customers-api.mjs --azure`. These exercised actual signup/Auth, business initialization, price-validated cash/split/zero checkout, bottle/cost/payment recovery, transfers, source-backed partial refunds, financial calculations, reporting filters and tenant/capability denial. Browser checks also used the burner's normal form login and read-only existing membership/details. No genuine business was repurposed.

The verified pre-migration recovery backup is `/opt/lpg/backups/deployment-20261026T064829458074Z`. Refresh already-open app tabs to load the coordinated development contract. A running older host print bridge must be restarted before USB use.

Physical paper output, payment-provider settlement, Android installation and device keyboard behavior are separate acceptance boundaries. This audit does not certify them. Local Docker was unavailable; the established VPS updater validated Compose and backend health remotely. The separate new production VPS was not changed.

## Before production

[`AGENTS.md`](../../AGENTS.md) now explicitly identifies both configured application environments as development. Clean forward migrations and canonical contracts take precedence over obsolete development formats. Before production, revise that policy to require backward compatibility, staged safe migrations and preservation of historical business records. Security, tenant isolation and transactional/database correctness are mandatory in both phases.
