# Finance and wallet accounting

[Architecture](../architecture.md) · [Sales](sales-and-inventory.md) · [Purchases](purchases-and-logistics.md) · [Printing](../../print-bridge/README.md)

## Ownership and migration

The existing `wallets` and `wallet_transactions` remain authoritative. Every tenant receives Cash Register, bKash, Nagad and Primary Bank Account. The protected Logistics wallet remains because purchases and transits already use it. The internal `dealership` key identifies Primary Bank Account; its UUID, signed balance and historical relationships are preserved in place. No historical POS payments or income are invented.

`opening_balance = balance − sum(historical wallet entries)` captures incomplete historic ledger coverage at migration time. It is a reconciliation baseline, not new money. Historical entries receive a balance-after value from that baseline and their original chronological order. A wallet reconciles as `balance = opening_balance + sum(entries)` after transition. New opening funds use an attributed balance adjustment with a reason. Payroll remains outside wallet accounting.

Default wallets stay active and cannot be deleted through the API. Finance managers may rename wallets and edit details; method/category and system identity remain fixed. Custom wallets may be archived only at zero balance. Archived wallets retain their ledger but are excluded from payment selectors. Wallet edits use revisions and audit records; payment records preserve the wallet name and method captured when paid. Wallet ledger entries also carry name/method snapshots, including purchase funding and refunds; earlier labels are snapshotted at transition when original labels are unavailable.

## One posting model

`app_private.post_wallet_entry` applies every new wallet entry to its tenant-qualified wallet under a row lock and stores the actual balance afterward. POS, collections, adjustments, transfers, purchases and logistics insert ledger evidence; they do not separately update balances. Historical money and stock are never recalculated from incomplete evidence.

`sale_payments` records received amounts, wallet, method, checkout/collection phase, reference and actor. Checkout inserts one negative customer invoice charge. Each received payment inserts one payment record, one wallet credit and one positive customer receipt, linked by payment ID. `sales.paid_amount` is the current settlement; `paid_at_checkout` and `checkout_payments` preserve the initial snapshot. An invoice's outstanding amount is `total_amount − paid_amount`; customer outstanding is the negative customer-ledger sum. Unreceived amounts create no wallet entry.

Default checkout sends null/omits `p_payments` for full Cash Register payment. An explicit array supports at most 20 positive finite entries with at most two decimals; an empty array records no initial payment. A zero-total sale creates no payment. Collections target one new tracked sale and cannot exceed its remaining balance. Legacy sales retain their previous fully-paid meaning and have no invented wallet attribution.

Transfers append equal opposite entries with one operation ID and counterparty links. Finance transfers require available source funds; existing purchase/transit deficit policies remain unchanged. Adjustments append a signed entry and mandatory reason. Correct a manual balance entry by recording an opposite adjustment referencing it. Purchase payments and refunds use `purchase_payments`, immutable source-backed obligations and the same Finance request/ledger architecture. Cancellation is OWNER-only and operational; wallet refunds and transport-funding reversals are settled separately, while truck operating expenses remain intact. See the purchase lifecycle guide. No sale void/refund or payment-deletion workflow is introduced.

## Atomicity, authorization and recovery

Checkout preserves server price validation, ordered stock locks, tenant/request serialization, stored request payload/results, and atomic rollback. Payments participate in that same database transaction. A retried key returns its original result and rejects changed payment details. Pre-transition checkout requests with omitted payments remain recoverable.

Collection locks the sale before wallets, preventing competing requests from overpaying. Multi-wallet operations lock participating wallets in UUID order, consistent with purchases. `finance_requests` serializes finance request IDs and saves the original payload/result. Client session storage retains uncertain writes per tenant/user/tab and exposes recovery before another transaction. A lost HTTP response never requires a new payment key. Wallet ledger/customer payment history is append-only; explicit browser writes remain denied.

RLS uses trusted active membership and tenant-qualified foreign keys. `finance:view` or `finance:manage` permits wallet/ledger reads; `finance:manage` gates wallet editing, transfers, adjustments and collections. POS can read payment destinations through `get_payment_wallets`, which exposes names/methods without balances or account details. Existing sales/receipt permissions permit reading persisted sale payments. Purchase managers can read eligible destination names without Finance balances, and purchase view/manage permissions gate the bounded purchase settlement API. Customer permissions expose an aggregate customer balance without opening the financial ledger.

## Frontend and query boundaries

[Finance](../../src/pages/Finance.tsx), [useFinance](../../src/hooks/useFinance.ts), shared payment entries and saved-sale payment panels use TanStack Query invalidation across Finance, wallets, customers and sales. Purchase/logistics mutations also invalidate Finance. The topbar displays combined wallet funds, including Logistics.

The ledger filters on the server before sorting/pagination, using 25-row pages (RPC maximum 100), tenant/wallet/date/type/amount indexes and narrow matching rows before fetching page details. A `pg_trgm` GIN index searches an immutable document captured with each entry (description, wallet label, payment reference and customer identity). Search follows the project's space-AND/comma-OR convention; token parsing happens once, literals are quoted/escaped, and tenant/filter parameters stay bound. Very short search terms and count/amount aggregates can still scan matching history. Inclusive date filters use `Asia/Dhaka`; minimum/maximum compare absolute entry amounts. Running balances are stored per wallet and do not change when filters/sorts change. Received/paid-out totals describe matching money movements, including both sides of transfers; they are not revenue/profit reports. No full ledger is downloaded by the browser.

Customer dues are server-paged. Saved payment history is ten rows per page; receipts aggregate persisted payments by wallet snapshot/method/phase and identify later collections. Reprints show current persisted settlement and never rerun checkout. Both receipt widths use the same content formatter as previews; 58mm uses stacked product lines, 80mm uses amount-aligned product headings. USB paper width is explicit in its printer configuration because Windows queue names are not reliable width detection. Browser width is remembered per tenant/browser; choose matching media in the OS print dialog.

## Verification

`finance-legacy.before.sql`/`finance-legacy.after.sql` exercise migration preservation. `finance.sql` rolls back wallet, payment, retry, rollback, ledger-filter and authorization fixtures. `run-transaction-concurrency.py` replays all migrations/suites in a disposable PostgreSQL database, then races checkout, stock, purchases, collections and transfers; `--performance` adds `finance-performance.sql` with 20,000 entries. `finance-api.mjs --azure` explicitly uses the configured production endpoint with newly created, cleaned-up Auth/business fixtures. `tests/finance.browser.cjs` verifies responsive Finance/POS interactions with intercepted APIs; `tests/payments.test.ts` and bridge suites cover calculations, layouts and rendering. These do not prove physical paper output or real payment-provider settlement; payments record funds received outside the app.

Purchase settlement adds `purchase-wallets.sql` and pre/post migration preservation fixtures. `purchase-wallets-api.mjs --azure --browser` verifies real payments/refunds, OWNER/receipt restrictions, ledger reconciliation and isolated browser acceptance. The purchase guide documents the cancellation and transport-funding boundaries.
