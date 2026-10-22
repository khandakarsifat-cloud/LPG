# Customers

[Architecture](../architecture.md) · [Finance](finance.md) · [Performance](backend-performance.md)

## Directory scope

`Customers.tsx` sends one filter/sort object through `useCustomerDirectory` to `get_customer_directory`. Search uses whitespace AND terms and comma OR groups across contact, shop, phone, address and tier, including both saved Bangladesh phone forms. Customer type and search narrow customer candidates before transaction aggregation.

Date bounds are inclusive Bangladesh calendar dates, implemented as an inclusive start and exclusive next-day end on completed sale timestamps. Product IDs are OR matches on sold refill/package lines; empty-return lines alone do not qualify a sale. A null selection means all products; an explicit empty selection matches nothing. Repeated product IDs do not multiply results.

The directory query filters sale headers once, groups matching sale lines once, and joins one quantity row back to each header. For those qualifying sales:

- **Total Sold** is the sum of whole saved `total_amount` values, including saved discounts and exchange fees. It is never the sum of just matching lines. `total_sold_amount` carries this monetary value; legacy `total_sold` remains the refill + package quantity for older callers.

- **Total Due** sums current `total_amount - paid_amount` for payment-tracked sales. Later collections reduce the due even when paid outside the selected sale period. Historical sales without tracking retain the existing fully-paid convention. Customer ledger credits/debts unrelated to these sales are not included; the profile's separate customer balance retains its Finance meaning.

- **Last Sale**, transaction count, and refill/package quantities come from the same qualifying headers. Quantities count only selected products when a product selection is active. Voided sales are excluded throughout.

Transaction/refill/package ranges apply to these calculated customer values before counting, sorting and pagination. Any date, product or activity range (including an explicit zero minimum) activates transaction filtering and excludes customers without qualifying sales. Search/type/sort alone preserve the normal directory, including customers who have never bought.

## Ordering and reads

The four choices are Total Sold, Total Due, Name and Last Sale, with an independent arrow controlling ascending/descending direction. Name uses the wholesale shop name when present, otherwise the contact name. Every sort ends in `customer_id` for deterministic ties; missing Last Sale dates sort last in both directions.

Only name sorting without transaction filters can page customer candidates before aggregation. Other reads calculate metrics and thresholds for the entire candidate scope, then return an exact count and requested page. Both paths use the same relational sales scope. Keeping candidates as a joined relation lets PostgreSQL estimate customer and sale counts and choose set-based hash joins for broad scopes. The RPC uses function-local `plan_cache_mode=force_custom_plan`: repeated switching between name pages and broad date/product/metric scopes must not reuse a generic plan estimated for a different scope. The API bounds pages to 100 records; the UI caches 25-record batches and displays three desktop rows or ten phone cards. Input changes reset the page and are debounced for 200 ms; the complete filter/sort object identifies the query cache.

Overview tiles remain business-wide. The customer profile independently loads all-time totals and its own paged transaction history; filtered card metrics are not presented as profile lifetime totals while that read loads. Existing customer, sales-detail and Finance permission boundaries remain in force.

## Authorization and verification

The directory derives tenancy from trusted active membership and requires `customers:view` or `customers:manage`. Every sale/line/customer lookup constrains the trusted tenant. Existing RLS, sale writes and payment writes are unchanged.

Migrations: `20261022165522_unified_customer_filtering.sql` and `20261022173140_customer_directory_custom_plans.sql`. Existing sales tenant/date, completed customer/date, sale-line tenant/sale and tenant/item/sale indexes support these reads. No persisted reporting counters or new write triggers are introduced.

`supabase/tests/customers.sql` verifies search, selected quantities, whole-sale money, later collections, date boundaries, all sort directions, null dates, deterministic pages, permissions and reused IDs across tenants. `customer-performance.sql` rolls back 10,000 customers, 60,000 sales and 180,000 lines across two tenants. Run it with `npm run purchase:db:test -- --replay-module <PGlite package directory> --deployment-batch --performance`, or include `--customer-performance` in the established disposable PostgreSQL runner. Synthetic bulk setup skips foreign-key triggers only in this disposable engine; application constraints remain enabled during query checks. Browser fixture tests cover controls, server payloads, pagination, nested dialogs and compact layouts.

Real Auth/PostgREST and published-browser acceptance: `node supabase/tests/customers-api.mjs --azure --browser-module node_modules/playwright`. It reads the dedicated burner membership, writes only new disposable businesses, verifies all sorting directions and later payments, exercises the published product/date/activity controls and phone/tablet/desktop layouts, then removes its fixtures and compares existing business-data fingerprints. Credentials come from ignored `.env.live-test` or injected variables.

