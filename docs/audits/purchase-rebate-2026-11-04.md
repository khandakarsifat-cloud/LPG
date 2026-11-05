# Manual purchase rebate acceptance

## Current contract

`20261104030000_purchase_rebate_settlement.sql` adds a single owner-entered purchase rebate and immutable private settlement evidence. `20261104073500_purchase_rebate_source_links.sql` connects every rebate journal activity row to its purchase, including pooled company-credit movements. The applied statements were checked against the local files; neither applied migration was rewritten.

This is the explicitly selected management-reporting policy: gross acquisition costs and sale-level COGS remain unchanged, while a confirmed new rebate reduces supplier payable and recognizes Other Income. A draft creates no rebate income. Existing company credit is consumed before recognizing an additional award. Cancellation releases the applied amount into company credit; refund obligations contain actual wallet payments only. Monthly/product/component commission rates and eligibility remain removed. The purchase and finance module guides define the complete operational rules and the IAS 2 distinction for formal accounts.

## Executed verification

- TypeScript/Vite build, lint and 49 source tests passed.
- The primary PostgreSQL engine was cloned into a guarded disposable database. Current core lifecycle, permissions, historical FIFO, source restoration, treasury and snapshot/concurrency suites passed with both forward migrations.
- Dedicated rebate SQL cases checked gross prices, actual component FIFO/COGS, buying-reference history, partial cash settlement, correction, stale revisions, changed request intent, cancellation credit, cash-only refunds and subsequent credit use.
- Concurrent tests covered eight identical rebate retries, conflicting corrections, different-company isolation and two new purchases competing for the same released credit. Both dimensions stayed balanced and savepoint-backed balances equalled full journal recomputation.
- Published authenticated browser checks at 1440px and 390px exercised the field, late rebate amendment, net payment, real purchase/dispatch/receipt, Finance opening/movement/closing tables, rebate-income drilldowns and source purchase links. Actual commit followed by an intentionally discarded HTTP response recovered under the original request after page reload. Transport interception was confined to that failure scenario.
- Actual Auth/PostgREST tests covered owner/manager/anonymous/foreign-tenant boundaries and source-based financial reconciliation. Product prices, current buying references and FIFO valuations were compared before and after the browser rebate correction.
- `npm run rebate:api:test` then passed again from a fresh fixture, including setup, browser operations, independent verification and scoped cleanup. Only the explicitly created businesses/users were removed, and their generated credentials were discarded. Ignored evidence remains under `.temp/purchase-rebate-live/` and `.temp/purchase-rebate-history/`.

## Independent closing sample

The disposable operation sequence—not report arithmetic—established these expected consolidated positions:

| Component | Tk |
| --- | ---: |
| Cash / actual real wallets | 68,000.00 |
| Accounts receivable | 5,000.00 |
| LPG FIFO inventory | 33,270.00 |
| Stove FIFO inventory | 2,000.00 |
| Contributed vehicle | 1,000.00 |
| Total assets | 109,270.00 |
| Liabilities | 0.00 |
| Capital | 101,000.00 |
| Revenue: sale 5,000 + rebate income 6,300 | 11,300.00 |
| Historical external COGS | 3,030.00 |
| Equation difference | 0.00 |

Every wallet equalled its ledger and canonical Cash. Physical LPG stock was 11 filled cylinders. All four LPG/Stove/Logistics/Combined equations and both journal dimensions reconciled. Released credit was consumed once and was never another wallet receipt or duplicate income.

## Preservation and review boundary

No business reset was performed. Existing purchases defaulted to zero rebate. The retained core business already contained additional operator activity from earlier that day, outside its original fixed scenario manifest; that verifier's old receipt count therefore no longer matched. The original evidence and later activity were preserved rather than forcing the old totals. The current validation guide explains this boundary.

The retained inventory/wallet/canonical-line fingerprint was `206467c1699fa6ed5c5895d8572b8df7` before and after all new fixture testing. Read-only checks found zero wallet mismatches, stock/projection mismatches or unbalanced journals, and zero unintended rebates. Cleanup left the original business and original platform administrator intact. VPS/Cloudflare deployment completed with both forward migrations and public health checks. Existing backup infrastructure, authentication configuration and wallet allocations were preserved.

This verifies application accounting and authenticated browser/API behavior. It does not certify statutory rebate classification, external company statements, payment-provider settlement or physical Android devices. Original dated overhaul evidence remains in the separate schema-106 audit.

Final publication: Worker `382c78d9-73f3-4326-98c4-13992f0900b0`, 108 applied migrations through `20261104073500`, no pending versions, twelve backend services verified healthy and no additional asset changes after browser acceptance. Private rebate tables have RLS and no browser read privilege; the rebate RPC permits authenticated calls and rejects anonymous execution.
