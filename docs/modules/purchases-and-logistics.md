# Purchases and logistics

[Architecture](../architecture.md) · [Stock rules](sales-and-inventory.md) · [Authorization](../../supabase/authorization.md)

## Purchase workflow

The plant determines the supplying company (`lpg_brands`). Plant/company remain fixed after creation; products must belong to that company. Historical records retain their original lines and billing evidence.

| Action | Inventory and truck | Money and editing |
| --- | --- | --- |
| Create | Plant-only drafts are allowed. No truck reservation or stock movement. | No wallet posting. Truck, products, expected quantities and financials remain editable. |
| Save draft | Check all refill shortages against current stock, grouped by SKU. Saving never reserves empties. | Save changes keeps the detail modal open. A shortage popup lists every affected product with required, available and missing quantities; Okay returns to the unchanged form. |
| Dispatch | Requires an idle truck and valid lines. Deduct one empty per expected refill; new-cylinder lines send none. Create an active transit and reserve the truck. | Transfer the transport fee from dealership to logistics once. Unpaid prices, commission, transport/labour and notes remain editable. Products, truck and quantities lock. |
| Receive | Always receive the saved expected quantities. Add filled cylinders with separate refill/new movement references, complete the transit and release the truck. | No receipt quantity inputs or discrepancy workflow. Receipt does not deduct transit expenses. Unpaid financials remain editable. |
| Full payment | Allowed after dispatch, independently of receipt. No stock/truck effects. | Settle company payable and labour plus any historical transport balance; already transferred transport is counted once. Financials lock. The detail modal stays open. |
| Cancel | Available for Created, In Transit and Received purchases, including Paid. Reverse recorded outgoing empties and incoming filled stock; release the truck and cancel linked transits. Reject atomically if reversal would make stock negative. | Refund actual recorded purchase payments to dealership and reverse logistics transport income once. Preserve incurred transit expenses. Confirmation explains the effects and discards unsaved edits. |

The purchase filter bar shares its slate palette and field styling with inventory history while retaining purchase search, statuses, date range and sorting. Inventory history can open this same purchase modal through a saved movement reference; existing purchase read/manage permissions still apply.

Received + Paid purchases show a read-only summary and activity history, with cancellation available to purchase managers. Cancelled purchases cannot be edited or restarted. Saving, payment, dispatch, receipt and cancellation retain the detail modal. Warning dialogs preserve unsaved values. Inline refill availability becomes red when requested quantity exceeds available empties.

Each SKU can have one refill and one new-cylinder line. Quantities are positive whole numbers. The server derives outgoing empties, checks save/dispatch shortages under ordered item locks and reports every shortage as structured error detail. Dispatch checks again because saving a draft does not reserve stock. Already dispatched historical outgoing quantities remain unchanged.

`subtotal = sum(billed_quantity × unit_price)`; `company_payable = subtotal − commission`; `total_cost = company_payable + transport_cost + labour_cost`. Money must be finite, nonnegative and have at most two decimal places. Commission cannot exceed subtotal. New receipts use expected quantities; historical actual/billed quantities remain readable and are never rewritten. Wallets may go negative under the existing rules.

## Transit workflow

[useLogistics](../../src/hooks/useLogistics.ts) owns gated reads/mutations. Transits have separate operational `status` (Active, Completed, Cancelled) and expense closure (`closed_at`). Neither purchase nor custom transits expose a status dropdown.

Purchase transit status is controlled exclusively by receiving/cancelling its purchase. Client, destination and description are populated from company, plant and purchase notes at dispatch. A custom transit requires a client name and idle truck; destination and description are optional. Its collected client transport fee credits logistics on creation.

- **Save changes:** Save driver, helper, oil, Others and named additional costs. Active and completed costs remain editable until closure. No wallet posting and no modal dismissal.
- **Complete transit:** Custom trips only. Free the truck; leave operating costs open. Purchase trips complete automatically on receipt.
- **Cancel transit:** Custom trips only, before closure. Refund the collected client fee from logistics once and free the truck. Incurred costs remain editable for review/closure. Purchase cancellation performs the corresponding linked-transit action.
- **Close transit:** Completed or Cancelled trips only. Explicit confirmation deducts saved operating costs from logistics once, sets `closed_at` and locks cost editing. Closing an older trip never releases a truck reserved by a newer trip.

Transport fees belong to purchase/client funding, while operating costs are logistics expenses. Unpaid purchase transport edits transfer only the difference and synchronize the linked transit fee. A closed transit's fee cannot change. Full payment never credits the fee twice. Historical income/expense evidence is recognized at migration time without posting money. Previously completed transits retain closed costs because the previous workflow already settled them; old received/active transits become completed with open costs and no automatic expense posting.

Cancellation reverses referenced inventory movements, or precisely identified historical purchase movement notes, rather than guessing stock from current expected lines. Refund amounts come from this purchase's recorded wallet transactions. Historical ledger rows, prices, receipt quantities, stock and wallet balances are preserved by migration. Existing spent transit costs are retained even when the purchase is later cancelled.

## Integrity and authorization

All mutations derive actor and tenant on the server. Purchase actions require `purchases:manage`; transit cost/workflow actions require `logistics:manage`. Read permissions remain separate. Direct browser ledger, stock, purchase and transit writes remain denied. New RPCs use the established application owner, empty search paths and explicit grants; private helpers are not browser callable.

Purchase revisions and transit cost revisions reject stale requests. Purchase creation uses tenant/request idempotency. Repeated dispatch, receipt, payment, cancellation and transit closure do not repeat stock or wallet effects. Purchase → truck → transit → ordered items → ordered wallets is the shared lock order where these resources are needed. Truck assignment is serialized; active trips cannot overlap. Cost saves and lifecycle mutations invalidate purchases, inventory, logistics, wallets and Dashboard as appropriate.

Purchase activity records creation, edits, dispatch, expected receipt, payment, cancellation, cost changes and closure with actor/time. The detail modal shows six chronological entries per page in a responsive two-column history, requesting one extra entry to detect the next page. Edit summaries compare recorded purchase values and available earlier product snapshots on that page; saved product quantities/prices remain expandable when earlier values are unavailable. Historical amounts come from the activity record, not today's purchase. Cancellation adds reversal rows; it does not delete original ledger evidence.

## Verification and deployment

The forward `20261015172537_purchase_transit_workflow.sql` migration follows the earlier lifecycle, ownership and refill-exchange migrations. It is deployed to the existing Azure backend with its dependent Cloudflare frontend, verified on 2026-10-15. Cached receipt/status/custom-creation signatures reject writes with refresh guidance.

`npm run purchase:test` covers frontend rules and calculations. `supabase/tests/purchases.sql` covers real RPC behavior using rolled-back fixtures, including all shortages, both receipt/payment orders, staged cancellation/refunds, completion/closure, retries, stock shortage rollback, truck reuse, tenant isolation and capabilities. `npm run purchase:db:test -- --replay-module <PGlite package directory> --deployment-batch` replays the ordered migrations and checks preservation of historical stock/ledger values plus authorization and receipt-printer suites. Disposable replay does not establish real PostgreSQL/PostgREST acceptance.

[Browser scenarios](../../tests/purchase.browser.cjs) use isolated API fixtures to verify retained modals, shortage warnings, receipt confirmation, custom transit workflow, cost editing/closure, list filtering and responsive layouts. They never mutate production business records. Deployment uses [the existing VPS/Worker workflow](../../deploy/README.md), with migration approval and a verified database backup. No local Docker is required: Compose validation runs remotely when the CLI is absent.

Production PostgreSQL 17.6 passed the purchase, authorization and receipt-printer SQL suites. Live Auth/PostgREST acceptance passed transport funding, structured shortages, expected receipt, completed-transit cost edits, closure, purchase/client refunds, concurrent retries and cross-tenant denial. Fixture businesses/accounts were removed; existing stock, wallet balances, purchase lines and ledgers match their pre-deployment hashes. Published HTML and asset hashes match the build. Published modal/layout checks use API fixtures; the real browser login and unauthenticated route protection were checked separately.
