# Purchases and logistics

[Architecture](../architecture.md) · [Stock rules](sales-and-inventory.md) · [Authorization](../../supabase/authorization.md)

## Lifecycle and ownership

The existing `lpg_brands` catalog represents the supplying company. New purchases derive `brand_id` from an active tenant plant linked to an active company. Plant/company stay fixed after creation. Products must belong to that company; tenant-qualified lookups and catalog-change guards preserve this relationship. Legacy records retain original products even when an older purchase spans companies or its plant has no company.

[usePurchases](../../src/hooks/usePurchases.ts) owns reads/mutations; [purchase components](../../src/components/purchases/) own forms, confirmations and summaries. The forward [enum](../../supabase/migrations/20261014091859_purchase_created_status.sql) and [lifecycle](../../supabase/migrations/20261014091900_purchase_lifecycle.sql) migrations replace the workflow bodies. The enum is replaced transactionally so both migrations work in the existing deployment runner's single transaction; apply in filename order.

The [ownership follow-up](../../supabase/migrations/20261014101635_purchase_function_ownership.sql) keeps new helpers, RPCs, activity and the status type owned by `postgres`, matching established application routines. The platform migration executor may be `supabase_admin`; private helper execution is still denied to browser roles. Ordered replay tests deliberately use the platform executor and assert application ownership so this boundary is covered.

| State/action | Requirements and inventory | Editing/accounting |
| --- | --- | --- |
| Created / `create_purchase(jsonb)` | Only plant and an idempotent request UUID are required. No stock movement, truck reservation, transit or wallet posting. | Truck, products, quantities, notes and financial details can be prepared progressively. Plant/company stay fixed. |
| In Transit / `dispatch_purchase` | Requires an idle truck without an active transit/shipment and at least one valid line. Deducts one empty per expected refill, grouped by SKU; creates the transit and marks truck going. Includes travel and time at the plant until return. | Truck, products, expected quantities and outgoing empties become fixed. Unpaid prices/costs/commission and notes remain editable. |
| Received / `receive_purchase` | Actual quantity required for every line, initially defaulted to expected and editable, including zero; discrepancy notes required if actual differs from expected. Adds actual filled cylinders with distinct new/refill movement references. Finalizes saved transit operating expenses and releases the truck when no other historical shipment uses it. | Inventory, receipt and transit operating costs are finalized. Unpaid purchase financials remain editable. |
| Paid / `pay_purchase` | Full payment allowed In Transit or Received. No stock movement or truck release. | Posts dealership expenses; freezes every price, billed quantity, commission, transport/labour charge and total. Notes may still change while In Transit. |
| Received and Paid | Fully completed. | All edits rejected; UI shows a read-only summary. |

`cancelled` remains readable for historical compatibility; no new cancellation, reversal, refund or partial-payment workflow is exposed. Every creation/transition has an explicit confirmation and operates on saved data; form edits are saved first. RPCs derive actor/tenant and require `purchases:manage`; list/activity reads accept purchase view/manage. Stock/payment operations do not require separate inventory/finance management rights. Direct browser purchase/line/ledger writes remain denied.

## Quantities and billing

Each line retains its `refill`/`package` type and expected `quantity`, recorded `empty_dispatched`, nullable actual `received_quantity`, and financial `billed_quantity`. Created refill lines use one exchange quantity: outgoing empties equal expected refills; new-cylinder lines send none. The backend derives outgoing quantities and rejects contradictory client payloads. There is no separate empty-dispatch input. One product may have a refill and a new-cylinder line; duplicate product/type lines are rejected for new drafts. Quantities are whole nonnegative numbers; expected quantities are positive. New-only shipments send zero empties. Available empty stock is checked atomically at dispatch, allowing drafts to be prepared before stock is available. Already-dispatched purchases retain their saved outgoing quantities even when an earlier plan used independent empties; financial edits and receipt do not reinterpret that history.

Dispatch never adds filled stock. Receipt never returns/refunds empty stock: short deliveries leave all dispatched empties outside the dealership. Actual receipt may exceed or fall short of expected, including zero. Receipt cannot add another product or change its type. Movement rows carry tenant, actor, purchase reference and phase; the existing AFTER INSERT inventory trigger applies each delta once.

- Before receipt, billed quantities equal expected quantities.
- Receipt before payment changes billed quantities to actual quantities and recalculates the bill. Unit prices and commission remain editable until payment.
- Payment before receipt freezes billed quantities and money. Later delivery affects stock only. The summary shows expected, dispatched, actual and billed quantities and explains prepaid discrepancies. No automatic monetary reconciliation or second payment is introduced.
- If commission exceeds the actual subtotal on an unpaid receipt, receipt fails atomically. Adjust commission first and retry.

The forward [refill exchange migration](../../supabase/migrations/20261014183416_purchase_refill_exchange.sql) replaces the existing line-save and dispatch functions without changing RPC signatures, RLS or historical rows. Unequal Created plans must be reopened and saved explicitly before dispatch; the form restores exchange quantities and blocks dispatch until that save. Existing In Transit and Received lines remain locked and preserve their recorded movements.

## Finding purchases

The shell top bar shows the page name and dealership wallet (subject to existing wallet read permissions); the account/sign-out menu lives beneath the business name in the sidebar. Four lightly tinted, separated overview figures sit beside the creation action on desktop and reflow on smaller screens. Cards show the company name, shipment/payment statuses, date, truck, product quantities/specifications and a single Total purchase cost row, without a product-line count label. Plant details and the full financial breakdown remain in the summary opened by clicking a card. The overview counts all accessible purchases; Awaiting Payment and Company Payable exclude Created and Cancelled records. The compact toolbar combines shipment/payment status and an inclusive From–To range on the purchase creation date in Asia/Dhaka. Search uses case-insensitive whitespace-separated AND terms inside comma-separated OR groups, across company, plant, truck, product brand, weight/mouth specifications, line type, statuses, notes, receipt notes and purchase ID. Empty groups are ignored. Date and total-cost sorting, in either direction, applies after filters/search; Clear filters also restores newest-first sorting. Query data is never reordered in place.

All purchase entity and fixed-option fields use shared styled native selects with keyboard selection; supported browsers also render the custom option menus. Date filters use the shared calendar with month/year navigation, Today/Clear, keyboard selection and inclusive range limits. Free-text search stays in the search input. Product controls share a desktop row and wrap on narrow screens; receipt opens with all expected quantities populated and retains explicit discrepancy notes and actual-quantity validation.

## Financial and logistics boundaries

`subtotal = sum(billed_quantity × unit_price)`; `company_payable = subtotal − commission`; `total_cost = company_payable + transport_cost + labour_cost`. Amounts must be finite, nonnegative and have at most two decimal places; commission cannot exceed subtotal. Database calculations use numeric values; UI calculations use integer cents and existing BDT formatting.

Full payment writes separate dealership transactions for company payable (`purchase_company_payment`) and combined transport/labour charges (`purchase_logistics_payment`), debiting the dealership once by total cost. The settled transport fee credits logistics once (`purchase_transport_settlement`). Created/dispatch/edit actions for new purchases do not post provisional wallet income. Wallets retain their existing ability to go negative; no new sufficient-funds rule is imposed.

Transit driver/helper/oil/additional costs are internal logistics expenses, distinct from purchase transport/labour charges. [useLogistics](../../src/hooks/useLogistics.ts) reads gated `list_transits()` and uses the existing `update_transit_costs` RPC. New purchase transits stay active until receipt; Logistics cannot complete/cancel them independently or manually idle their trucks while In Transit. Receipt posts saved operating expenses against logistics and completes the transit in the inventory transaction. Received transit operating costs are locked. Unpaid purchase transport-price edits synchronize `transport_fee` without changing operating expenses.

Custom transits keep their own creation/completion and wallet behavior. Truck allocation is serialized; a new transit cannot overlap an active transit. Older received purchases may still have active transits because receipt did not finish them. `legacy_completion` allows such a transit's costs to be finalized once in Logistics. Migration itself never posts these missing expenses.

## Atomicity, retries and history

Mutations lock the purchase and use a revision to reject stale saves/confirmations (`40001`). Shipment operations acquire truck/transit and ordered SKU locks before stock changes. Dispatch checks available empties under those locks; any failing line rolls back header, movements, truck and transit together. Payment locks wallets and posts settled values in one transaction. Concurrent requests serialize on purchase/truck/wallet locks.

Creation uses a tenant/request UUID, transaction advisory lock and unique index. Repeated dispatch/payment returns the existing state without posting again. Identical repeated receipt succeeds; conflicting actual quantities are rejected. Phase-specific movement and settlement indexes prevent duplicates. Old create/edit/complete signatures reject requests with refresh guidance so cached clients cannot bypass the separated inventory/payment actions.

`purchase_activity` records creation, update snapshots, dispatch, receipt, payment and logistics-cost changes with timestamp and database actor. History is tenant/capability gated and rejects edits/deletion. Client mutations refresh purchases/activity, inventory registry/balances/history, logistics trucks/transits/wallets and Dashboard; failures refresh authoritative data while preserving the failed form.

## Historical migration compatibility

Existing purchases become `legacy_record`; all stock balances, movements, wallet balances and transactions remain intact. Received records become Paid because old completion already posted the dealership expense. Pending records remain In Transit/Unpaid and cannot dispatch again. Saved expected quantities become initial billed quantities; received quantities and outgoing refill empties are inferred from the old workflow. Dates use available header evidence and are identified as historical, not reconstructed event history.

Legacy transport income was posted at creation/editing. Legacy transport-price edits keep that difference-posting behavior; later payment does not credit the fee again. Completed transits never post operating costs twice. Malformed/mixed legacy line sets are retained; quantities remain locked and unsettled financial amounts can be corrected through permitted edits. Privileged remediation may be needed for inconsistent historical evidence; migration does not invent reversals.

## Verification and deployment

See [Operations](../../OPERATIONS.md#10-checks-and-tests). `npm run purchase:test` checks calculations/UI action rules; `npm run purchase:db:test` tests real RPCs/permissions on the migrated local Compose database with rolled-back fixtures. Optional disposable PostgreSQL replay tests all migrations, historical compatibility, pre-change exchange plans and existing authorization/receipt suites without touching a running database. [Browser scenarios](../../tests/purchase.browser.cjs) use API fixtures to check styled native selections, calendar selection/range limits, sidebar account access, compact cards, AND/OR search/filter combinations, all sort directions, progressive editing, confirmations, failure recovery, expected receipt defaults, payment/receipt, summaries and mobile layout.

Disposable engine/browser fixtures alone do not establish production acceptance. The 2026-10-15 deployment additionally passed SQL suites on VPS PostgreSQL 17.6 and real Auth/PostgREST tests for concurrent creation, dispatch, payment, receipt, truck exclusivity, both billing orders and tenant isolation. Test businesses/accounts were removed and pre-existing stock/ledger hashes were unchanged. The restored exchange rule and rejection of independent outgoing quantities passed real API tests. Published asset hashes and browser login/route protection were verified; purchase modal/search/filter scenarios across five viewport widths use API fixtures against the published frontend.

Apply the original three purchase migrations, then the refill exchange migration before serving the redesigned frontend. The exchange migration and dependent frontend are deployed to production, verified on 2026-10-15. Existing deployment approval and backup requirements still apply. Building the frontend never applies migrations or publishes the site.
