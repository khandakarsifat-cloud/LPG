# Sales and inventory

[Architecture and documentation map](../architecture.md) · [Authorization](../../supabase/authorization.md) · [Printing](../../print-bridge/README.md)

## Ownership and source of truth

[useInventory](../../src/hooks/useInventory.ts) reads item balances and movement history; item creation registers zero-stock SKUs. The baseline's `items_unique_sku` key is `(tenant_id, brand_id, size_kg, mouth_size)`; retain both the brand relationship and legacy display fields when changing product reads. [POS](../../src/pages/POS.tsx) owns the cart, and [usePOS](../../src/hooks/usePOS.ts) calls `create_pos_sale`.

The current checkout, stock recorder and movement-trigger definitions are in the [authorization migration](../../supabase/migrations/20261004192158_tenant_permission_authorization.sql). The [baseline](../../supabase/migrations/20260627000000_cloud_baseline.sql) creates `trg_update_item_inventory`, an AFTER INSERT trigger on `inventory_movements`; later SQL moves/redefines its function in `app_private`.

## Customer and price rules

- A sale requires a customer phone. With `p_customer_id`, SQL loads the saved tenant customer and leaves their details unchanged. Without an ID, an already-saved exact phone is rejected with instructions to select that customer; otherwise the customer is created inside checkout, with a blank name becoming `Unknown`.
- [bdPhone.ts](../../src/lib/bdPhone.ts) and the [final customer-phone migration](../../supabase/migrations/20260702155154_numeric_customer_phone_lengths.sql) accept `01[3-9]` followed by eight digits or the same number prefixed by `088`. Search considers both representations, but exact stored strings are tenant-unique; they are not canonicalized to one identity. Preserve this distinction when changing lookup/deduplication.
- [POSItemsGrid](../../src/components/pos/POSItemsGrid.tsx) uses [getSellingPrice](../../src/lib/productPricing.ts) to select the latest active price-book row by item/tier/line type, respecting inclusive `effective_from` and exclusive `effective_to`. Missing wholesale prices fall back to retail; missing prices become zero. Prices enter the cart when a line is added; changing customer tier does not reprice existing cart lines.
- These are UI price defaults. SQL validates nonnegative submitted unit prices and calculates totals; it does not resolve/enforce a price-book price. Empty returns default to zero in the UI, but SQL does not require zero for that type.

## Product details and pricing

The [inventory migration](../../supabase/migrations/20261018101202_inventory_product_details.sql) is required for the redesigned product dialog. `price_books.price` remains the selling price; nullable `mrp` is reference information only and never enters cart totals, discounts or receipt data. Receipts label the saved `unit_price` as **Price**. Existing prices are preserved with no invented MRP; the price-book key includes line type so refill/package can share an effective timestamp.

`save_product_prices` requires `inventory:manage`, derives the tenant, locks the exact item and atomically versions both prices for the selected retail/wholesale tier. It validates money, checks loaded effective timestamps to reject conflicting edits, closes old active windows and preserves future scheduled prices. Dialog drafts survive polling and failed saves; **Reload saved prices** explicitly discards the draft. A successful save stays in the dialog and invalidates inventory and POS pricing queries. Already-added cart lines and saved sales keep their captured prices.

`get_product_inventory` requires `inventory:view` or `inventory:manage` and returns only the exact item's prices, estimated buying costs and weekly quantities. It does not grant general sales or purchase-table access. Balances and overview use the same polled query. The overview counts low (1–5 units) and out-of-stock (zero units) products independently for filled and empty stocks.

For each purchase type, the buying estimate selects the latest **Received**, non-cancelled purchase containing the exact `item_id` (including its mouth size). It divides that product/type's billed line total by received units, adds `(transport + labour) / all units received in that purchase`, and subtracts commission allocated proportionally to line value. Historical billed/received discrepancies therefore affect the estimate. Refill/package can come from different receipts; dates and the cost breakdown are shown. This uses current saved purchase financials and does not include extra transit operating expenses or pretend to be inventory valuation.

Eight entries, including zero-activity weeks, run Saturday 00:00 through the following Saturday exclusively in `Asia/Dhaka`; the displayed end date is Friday. Shared column headings group sold refill/package as negative quantities and incoming empties/package/refill as positive quantities; zero activity stays neutral. Completed sale headers supply sale dates and line types for sold refill, sold package and empty return counts. Received purchase headers supply receipt dates and actual received quantities for bought refill/package; cancelled and unreceived purchases are excluded. These are activity summaries, not opening/closing balances or all manual adjustments. The separate Movement History tab retains the stock ledger.

## Atomic checkout

`create_pos_sale` requires `pos:sell`, a nonempty JSON array, supported line types, positive integer quantities, nonnegative prices/discount/exchange fee, and a nonnegative final total. Total refill quantity must equal total empty-return quantity **across the cart**, not per SKU/brand/mouth size.

| Line type, quantity `q` | Filled delta | Empty delta |
| --- | --- | --- |
| `refill` | `-q` | `0` |
| `package` | `-q` | `-q` |
| `empty_return` | `0` | `+q` |

The package empty deduction is implemented behavior; do not silently replace it with an assumed cylinder model. The UI checks filled availability, while SQL locks each tenant item, applies movement deltas through the trigger, and rejects negative final filled/empty balances. A late failure rolls back the customer insertion, sale, lines, movements and accounting together. Never update item balances again alongside movement insertion.

The transaction stores a `completed` sale and line totals, calculates `subtotal - discount + exchange fee`, writes paired customer transactions (`invoice_charge = -total`, `payment_receipt = +total`), and increments the dealership wallet. Thus current checkout records full payment, with no credit-sale flow. It does **not** insert a matching sale-income `wallet_transactions` row. Wallet history alone is therefore not a complete revenue ledger.

The UI prevents overlapping checkout submissions with a ref lock. The sale RPC has no request-id/idempotency contract; this is not duplicate protection across network uncertainty or independent calls.

## Commit, refresh and receipt handoff

[completeSale](../../src/lib/completeSale.ts) waits for checkout, commits UI success/clears the cart, then optionally prints. Printing failure returns separately and never reruns checkout. [useReceiptPrinter](../../src/hooks/useReceiptPrinter.ts) reloads the completed sale and latest tenant configuration for checkout printing and reprints. Amounts/lines are saved, but names/brand/business identity come from current related records rather than a full receipt snapshot. Device matching and persistent print-request deduplication are documented in the [printing guide](../../print-bridge/README.md).

Checkout and reprint controls offer browser printing alongside the configured USB queue. The method is remembered per tenant in this browser and does not replace shared USB settings. Browser printing needs no bridge or saved USB configuration; it uses the same receipt formatting and reads the committed sale. Cancelling the browser dialog leaves the sale saved. USB failures never trigger an automatic browser fallback because a job may already have printed.

Sale success invalidates inventory, customers, logistics/wallets and Dashboard families, plus the sales/movements prefixes in `usePOS`. Keep downstream refreshes when modifying accounting or receipt data. Inventory balances/history also poll; Dashboard totals/feed use browser-local day boundaries as described in [architecture](../architecture.md#workspace-lifecycle-and-cache-behavior).

Manual adjustment is available through `create_inventory_movement`/`useCreateMovement`, gated by `inventory:manage`, but has no current UI dialog. The private recorder locks the item and rejects negative resulting stock; purchase workflows use it under their own gate. Browser callers cannot update/delete movements or set balances directly. There is no implemented sale void/refund/reversal flow.

## Checks to preserve

[receipt_printers.sql](../../supabase/tests/receipt_printers.sql) checks real checkout and once-only stock deltas. [authorization.sql](../../supabase/tests/authorization.sql) checks tenant/capability boundaries and reused IDs. [printing.test.ts](../../print-bridge/printing.test.ts) covers checkout/printing separation without physical dispatch. Use [Operations](../../OPERATIONS.md#10-checks-and-tests) for execution prerequisites; these suites do not establish browser or hardware acceptance.

[inventory.sql](../../supabase/tests/inventory.sql) runs in the disposable purchase migration replay and rolls back all fixtures. It covers effective price windows, atomic/conflicting saves, shared purchase costs, actual received quantities, Saturday boundaries and tenant/capability isolation. `node --test tests/inventory.test.ts` checks selling-price resolution and receipt separation; [inventory.browser.cjs](../../tests/inventory.browser.cjs) verifies the dialog, summary counts, POS price, failure recovery and responsive layouts with isolated API fixtures.
