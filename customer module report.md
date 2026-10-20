# Customers

The customer directory shares saved customer identities with POS. It supports retail and wholesale customers, customer editing, completed-sale history, quantity reporting and product/date/activity filtering. Phone numbers retain the existing numeric Bangladesh mobile formats `01XXXXXXXXX` and `08801XXXXXXXXX`.

## Implementation map

| Area | Source |
| --- | --- |
| Directory, overview, search and sort | `src/pages/Customers.tsx` |
| Reporting queries, profile/history, editing | `src/hooks/useCustomerDirectory.ts`, `src/types/customer.ts` |
| POS contact lookup and customer creation | `src/hooks/useCustomers.ts`, `src/components/pos/CustomerSelection.tsx` |
| Add/edit, activity filters, customer details | `src/components/customers/` |
| Shared product selector | `src/components/inventory/InventoryProductPicker.tsx`, `BalancesGrid.tsx` |
| Transaction inspection | `src/components/transactions/TransactionDetailsModal.tsx` |
| Shared page controls and selection-preserving list state | `src/components/ui/Pagination.tsx`, `src/hooks/useListPage.ts` |
| Server contracts and permissions | `supabase/migrations/20261019054521_customer_directory_activity.sql` |

## Directory and reporting rules

- Wholesale cards lead with the saved shop name when present and retain the contact name. Retail cards lead with the customer name. Cards show number, address, total sold, refill/package quantities and last completed sale.
- Total sold is refill quantity plus package quantity from completed sales. Empty returns do not increase it. Quantities are not currency values.
- Spaces combine search terms with AND. Commas separate OR groups. Matching is case insensitive and treats punctuation literally. The searchable identity includes customer/shop name, phone, address and tier, with the existing `01`/`08801` phone alternatives.
- The server applies search, customer type, date/product restrictions and minimum/maximum transaction/refill/package counts before sorting and pagination. Sort options are display name and total sold in both directions, with customer UUID as the stable tie-breaker.
- Date ranges include both dates in `Asia/Dhaka`. Quantities and total-sold sorting use the same date/product scope. Each completed sale counts once; with selected products it must contain a matching refill/package line. An explicit empty product selection gives no directory results.
- The directory caches backend batches of 25 per filter/sort scope. Displayed pages contain three grid rows on desktop and ten cards on phones; column changes preserve the first visible record within the new page. Cached batches are sliced for display, and only missing batches are fetched when navigating or changing column count. Equal grid columns preserve card widths on partial final pages. Filters and sorting reset the page and select a separate cache. Counts come from the complete filtered result. Existing customer/POS mutations invalidate cached batches; active reads retain the 30-second refresh.
- Overview figures stay business-wide: total retail/wholesale, new customers since Saturday 00:00 in Bangladesh, and customers with no completed sale since the date two calendar months ago. Older customers who have never bought are inactive; newer never-buyers are not yet two-month inactive.

## Customer forms and details

Opening a card shows its already-loaded contact identity immediately, while the profile and transaction requests run in parallel. Profile totals wait for the unfiltered profile response so a filtered directory row cannot be mistaken for all-time totals. The profile has a 30-second freshness window and existing customer mutations invalidate its cache.

Unscoped name-sorted directory reads count/filter customer identities first and aggregate sales only for customers on the requested page. Date/product/activity-filtered and quantity-sorted directories retain the complete aggregation path, so filters and rankings remain correct. Transaction history counts matching sale headers before paging and computes refill/package quantities and product descriptions only for the displayed transactions. Exact counts and numbered pages remain; deep offsets and scoped reports still cost more as history grows. See [backend performance](docs/modules/backend-performance.md).

Creation retains the existing INSERT policy, phone uniqueness and POS integration. The type toggle is inside the Add customer form. Wholesale requires a shop name. Text fields are trimmed; a missing personal name uses `Unknown`. Successful creation clears directory filters and opens the new customer's profile so a prior search cannot hide the saved result.

Editing calls `update_customer_details`. It derives the active tenant and actor from trusted membership, requires `customers:manage`, locks the selected tenant/customer row, validates type/phone/shop, and preserves the database's tenant/phone uniqueness. It never rewrites saved sales, sale pricing tiers, stock, ledger rows or balances. Customer and affected embedded-name query caches invalidate after saving. No customer delete or credit/receivables workflow is introduced.

Customer details show lifetime quantities and a separate paginated transaction history. History search, dates and products affect its rows and display their scope. Detailed history requires the existing `sales:view`, `receipts:print` or `dashboard:view` capability in addition to customer access. Customer-only readers can inspect customer identity and unit summaries without gaining detailed sale amounts or stock-balance access.

Opening a transaction retains the customer dialog and its history page. The new transaction detail modal is also used by Inventory history. It reads the exact saved sale under existing sales RLS, shows saved prices/amounts/tier, and pages long product lists while retaining whole-sale totals. It has no POS printing controls. POS and Dashboard receipt previews remain separate; POS shows every receipt line in its scrollable preview and printing retains every saved line.

## Shared selection and pagination

Customers extends the existing Inventory product picker. Both entry points share catalog grouping, configured brand order, ascending weights, search, staged multi-selection, Select all, Clear, Cancel and page controls. Selection survives page changes. The customer catalog RPC returns only tenant-scoped product identity and brand order; stock quantities are not included or displayed there. Inventory retains its stock counts.

Shared page controls also bound growing purchase, product-picker, employee/payment/phone, plant, truck/transit and brand collections. POS products, cart lines, customer suggestions and POS receipt previews use their existing scroll areas without pagination. The main Inventory catalog also shows every product without pagination. Editable lists retain all values, validation and totals in parent state across pages; Add product/phone/cost opens the page containing the new row. Brand reordering still uses the full tenant order and original stale-list check. Existing inventory and purchase-history server pagination is retained. Dashboard reads successive daily-sale pages instead of silently stopping at 50. POS contact/catalog reads use bounded server batches so complete scrolling lists do not lose records beyond a server limit.

## Authorization and verification

All identities and joins remain tenant-qualified. New public reporting/update functions have pinned empty search paths, are owned by the existing `postgres` application owner, revoke anonymous/PUBLIC execution, and check their specific capabilities. Unexposed helpers have no authenticated execution grant. Reporting does not widen direct table policies.

`supabase/tests/customers.sql` covers full-result pagination, search, inclusive Dhaka dates, combined product/range filters, overview boundaries, duplicate phones, update integrity, reused UUIDs, anonymous/private grants, view/manage/sale separation and inactive membership. It rolls back its fixtures. It runs in disposable migration replay and can run against PostgreSQL 17 through the established SQL runner.

`tests/customers.browser.cjs` verifies real React controls and query contracts with isolated API fixtures: filters, selection across pages, creation, edit failures/retries, nested transaction navigation, whole-sale totals, permissions and responsive light/dark layouts. `tests/customer.test.ts` checks calendar presets, identity and complete batched reads. These fixture checks do not by themselves establish live service or physical printing acceptance.
