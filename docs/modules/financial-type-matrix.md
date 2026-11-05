# Financial operations and accounting effects

This matrix is the implementation contract for Type + fixed Category + Business.
Positive journal amounts are debits. Every operation retains its original source,
request identity, recognition date and immutable settlement evidence. The five type categories map to internal accounts below; types identify operations and cannot change an account's accounting meaning.

## Fixed type categories

Withdrawal, Expense, Capital, Revenue and Equipment are the five public choices. Their names have no added accounting taglines. A type retains one category and its business allocation.

## Internal journal accounts

| Accounting component | Fixed accounts | Normal effect |
| --- | --- | --- |
| Assets | cash; customer_receivable; transport_receivable; supplier_receivable; bottle_receivable; inventory_lpg; inventory_stove; inventory_transit; vehicles; equipment; other_assets | Debit increases |
| Liabilities | supplier_payable; employee_payable; operating_payable; loan_payable; other_liability | Credit increases; an overpayment is reported as an asset |
| Capital / opening equity | capital; opening_equity; retained_earnings | Credit increases; opening equity includes supported prior net assets |
| Other equity | equity_adjustment; business_allocation_equity | Explicit corrections and business reallocations, never trading profit |
| Revenue | sales_revenue; logistics_revenue; internal_logistics_revenue; other_income; disposal_gain | Credit increases; disposal losses may debit the gain/loss account |
| Expense | cogs; bottle_exchange; inventory_loss; employee_expense; logistics_expense; vehicle_expense; operating_expense; interest_expense; depreciation_expense | Debit increases |
| Withdrawal | withdrawals | Debit reduces equity, never expense |

Assets = Liabilities + Capital + Revenue − Expense − Withdrawal + other equity.
Historical accumulated earnings are revenue less expense already inside equity;
they are never counted twice. An opening retained-earnings amount requires an
explicit supported opening component, rather than invented revenue.

## Discovered system operations

| Type / operation | Debits | Credits | Business and source |
| --- | --- | --- | --- |
| Product invoice / invoice correction / cancellation | Customer receivable (or original reversal) | Sales revenue (or original reversal) | Sale's LPG/Stove; sale |
| POS payment | Cash | Customer receivable | Sale; immutable sale payment |
| Later customer collection | Cash | Customer receivable | Sale; collection payment; no new revenue |
| Customer refund | Customer receivable | Cash | Original sale; staged refund |
| Additional bottle settlement charge | Customer receivable | Sales revenue | LPG; original sale and collection |
| Purchase invoice / correction / cancellation | Inventory in transit | Supplier payable | Purchase LPG/Stove; separate Gas/Bottle source components |
| New company rebate applied | Supplier payable | Other income | Purchasing business; immutable purchase rebate event; no wallet movement |
| Cancelled rebate application | Supplier receivable / company credit | Supplier payable | Same company/business; retains confirmed award; no cash refund |
| Existing company credit applied | Supplier payable | Supplier receivable / company credit | Later purchase; no second income recognition |
| Rebate correction | Original debit/credit adjustment | Original credit/debit adjustment | Dated event; gross acquisition and FIFO remain unchanged |
| Purchase company payment | Supplier payable | Cash | Purchase; payment |
| Purchase labour payment | Supplier payable | Cash | Purchase; payment; acquisition labour capitalized once at recognition |
| Purchase refund | Cash | Supplier payable | Original purchase and refund obligation |
| Purchase receipt | Inventory | Inventory in transit | Actual receipt and FIFO acquisition layer |
| Empty-shell dispatch | Inventory in transit | Empty inventory | LPG; original dispatch movement |
| Dispatch cancellation | Empty inventory | Inventory in transit | Original dispatched shell layers |
| FIFO sale issue | COGS | Inventory | Sale product's business; original consumed layers |
| Refill shell retained by customer | Bottle receivable | COGS | LPG; actual issued shell basis |
| Bottle physically returned | Received-brand empty at captured current Bottle reference | Historical bottle replacement claim; signed exchange variance | LPG; actual receipt, original outgoing shell basis and immutable incoming snapshot |
| Verified excess bottles / stock gain | Inventory | Other income | Product's business; valued movement |
| Sale stock return | Inventory / reversal of original bottle asset | Original COGS | Original consumed FIFO layers and age |
| Opening inventory contribution | Inventory | Capital | Product business; explicit Gas/Bottle valuation |
| Inventory capital contribution | Inventory | Capital | Product's business; explicit valuation |
| Stock loss / stolen / damaged | Inventory loss | Inventory | Product's business; actual FIFO consumption |
| External transport invoice / correction | Transport receivable | Logistics revenue | Logistics; transit |
| External transit collection / refund | Cash / transport receivable | Transport receivable / cash | Logistics; original transit |
| Internal purchase transport | Buyer inventory in transit; Logistics business allocation equity | Buyer business allocation equity; internal Logistics revenue | Noncash purchase/transit allocation; retained in additive Combined |
| Internal transport receipt / FIFO issue / return | Inventory / COGS / original reversal | Transit inventory / inventory / original reversal | Same FIFO layers; buyer Supplies/COGS includes historical transport |
| Diesel / toll / other transit operating cost | Logistics expense | Operating payable | Logistics; incurred cost event |
| Driver/helper earnings | Employee expense or Logistics expense | Employee payable | Logistics; transit and crew snapshots |
| Transit cost payment / returned funds | Operating payable / cash | Cash / operating payable | Logistics; original incurred event; completion posts nothing |
| Vehicle service incurred | Vehicle expense | Operating payable | Logistics; service trip |
| Vehicle service payment / returned funds | Operating payable / cash | Cash / operating payable | Logistics; service trip |
| Contract salary accrual / revision | Employee expense | Employee payable | Configured payroll business allocation; employee/month |
| Salary payout / advance | Employee payable | Cash | Payroll allocation snapshot; advance is asset until accrued |
| Named bonus / bonus reversal | Employee expense / reversal | Employee payable / reversal | Payroll allocation; bonus source |
| Bonus payout / trip payout / returned funds | Employee payable / cash | Cash / employee payable | Original employee payment and entry |
| Opening cash | Cash | Opening equity | Explicit business allocation; wallet movement |
| Owner investment | Cash or contributed asset | Capital | Explicit business allocation; source operation |
| Wallet correction | Cash or equity adjustment | Equity adjustment or cash | Explicit business; mandatory reason |
| Real wallet transfer | Destination real-wallet ledger | Source real-wallet ledger | Two principal legs; no business allocation or profit journals |
| Loan receipt / opening principal | Cash / opening equity | Loan payable | Loan allocation snapshot; loan register |
| Principal repayment | Loan payable | Cash | Original loan; bounded outstanding; no expense |
| Interest paid | Interest expense | Cash | Configured type allocation; never principal |
| Opening receivable/payable | Asset / opening equity | Opening equity / liability | Explicit business allocation; obligation |
| Unpaid operating expense | Operating expense | Liability | Explicit allocation; obligation |
| Obligation collection/payment | Cash / liability | Receivable / cash | Original obligation allocation; no new recognition |
| Vehicle/equipment acquisition | Identifiable asset | Cash / payable / capital / opening equity | Vehicle always Logistics; other asset's retained ownership allocation |
| Asset depreciation | Depreciation expense | Asset | Original asset ownership; dated and limited to remaining book value |
| Asset improvement | Identifiable asset | Cash / payable | Same asset and business ownership; qualifying cost, no immediate expense |
| Asset disposal | Cash; depreciation/disposal loss as applicable | Remaining asset / disposal gain as applicable | Original asset; vehicle retirement linked once |

## Architecture and audit decisions

The canonical journals, immutable source deltas, source locks, FIFO layers,
trusted tenant authorization and resumable savepoints
remain the foundation. Explicit LPG/Stove/Logistics allocations replace stored
`shared` amounts. Every line retains a valid type; one real balance per wallet reconciles with its ledger and pooled canonical Cash.

Catalog-driven filters replace the mixture of obsolete and current hardcoded
ledger names. Components aggregate fixed account, type and business; individual
source records belong in paged Historical Activity with permission-checked links.

Internal delivery for LPG or Stove records buyer FIFO cost and Logistics revenue
once at dispatch. Combined is the exact additive total of the independent
businesses, including that revenue and the matching buyer inventory/subsequent
COGS. Private external-cost evidence supports reconciliation; it does not introduce
a consolidation adjustment in reports. Physical wallet transfers change no business
equity; noncash internal allocations create no inter-business debt.

The rows above describe economic effects, not separate journal headers. A financial
action collects its effects and posts once, netting equivalent account/business/type
and necessary counterparty lines. Product/FIFO detail stays at its owning source.
Immediate settlement removes zero-net clearing lines; later settlement is its own
action. Original historical journals and meaningful custom type snapshots remain
unchanged.

Supported custom recognition is Expense, Withdrawal, Revenue, Capital and Equipment. Loans, stock and counterparty settlements retain their source
workflows. Settings owns default allocations; ordinary entry keeps revision,
name, category and exact allocation snapshots. Deactivation blocks new entries
without hiding history. Actual partial returns restore original cents and source
ownership even after editing defaults.

## Verification

[Finance validation](finance-validation.md) contains the independent source
calculations, retained datasets, migration/deployment results, regression coverage,
performance measurements and unverified physical/provider boundaries.

## Deployed system-type catalog

The system types below are read-only. Their account effects and automatic
source attribution follow the operation matrix above; LPG/Stove product types
inherit their product business rather than a hardcoded catalog default.

| Code | Operation name |
| --- | --- |
| `asset_depreciate` | Asset depreciation |
| `asset_disposal_expense` | Asset disposal cost |
| `asset_dispose` | Asset disposal |
| `asset_improve` | Asset improvement |
| `asset_proceeds` | Asset disposal proceeds |
| `asset_purchase` | Asset payment |
| `asset_register` | Asset acquisition |
| `balance_adjustment` | Wallet correction |
| `bonus` | Named employee bonus |
| `bottle_obligation` | Customer shell asset |
| `bottle_return` | Bottle collection |
| `capital` | Capital contribution |
| `customer_collection` | Customer collection |
| `expense_accrue` | Unpaid operating expense |
| `internal_cogs` | Internal transport FIFO cost |
| `internal_inventory` | Internal transport in FIFO stock |
| `internal_transport` | Internal purchase transport |
| `internal_transport_payment` | Internal transport payment |
| `internal_transport_receipt` | Internal transport received |
| `internal_transport_return` | Internal transport returned |
| `inventory_capital` | Contributed stock |
| `inventory_gain` | Stock gain |
| `inventory_loss` | Stock loss / damage |
| `inventory_opening` | Opening stock |
| `inventory_return` | FIFO sale return |
| `inventory_sale` | FIFO sale cost |
| `loan_create` | Loan recognition |
| `loan_receipt` | Loan receipt |
| `loan_repayment` | Loan principal repayment |
| `obligation_settlement` | Recorded balance settlement |
| `opening` | Opening balances |
| `opening_cash` | Opening cash |
| `opening_entry` | Opening asset / liability |
| `operating_cost` | Transit operating cost |
| `owner_capital` | Owner investment |
| `owner_withdrawal` | Owner withdrawal |
| `payroll_bonus` | Bonus payment |
| `payroll_reversal` | Employee funds returned |
| `payroll_salary` | Salary payment / advance |
| `payroll_trips` | Driver / helper payment |
| `pos_sale_income` | POS payment |
| `purchase` | Purchase invoice / correction |
| `purchase_cancellation` | Purchase dispatch return |
| `purchase_dispatch` | Empty-shell dispatch |
| `purchase_payment` | Purchase payment |
| `purchase_payment_company` | New company rebate applied | Supplier payable | Other income | Purchasing business; immutable purchase rebate event; no wallet movement |
| Cancelled rebate application | Supplier receivable / company credit | Supplier payable | Same company/business; retains confirmed award; no cash refund |
| Existing company credit applied | Supplier payable | Supplier receivable / company credit | Later purchase; no second income recognition |
| Rebate correction | Original debit/credit adjustment | Original credit/debit adjustment | Dated event; gross acquisition and FIFO remain unchanged |
| Purchase company payment |
| `purchase_payment_labour` | Purchase labour payment |
| `purchase_receipt` | FIFO purchase receipt |
| `purchase_refund` | Purchase refund |
| `salary_accrual` | Contract salary |
| `sale` | Product invoice / correction |
| `sale_refund` | Customer refund |
| `sale_reversal` | Sale cancellation |
| `stove_purchase_cancellation` | Stove purchase return |
| `transit_client_receipt` | External transport collection |
| `transit_client_refund` | External transport refund |
| `transit_diesel` | Transit diesel |
| `transit_driver` | Transit driver earnings |
| `transit_expense` | Transit expense payment |
| `transit_expense_return` | Transit expense returned |
| `transit_helper` | Transit helper earnings |
| `transit_revenue` | External transport invoice |
| `vehicle_service` | Vehicle service incurred |
| `vehicle_service_expense` | Vehicle service payment |
| `vehicle_service_expense_return` | Vehicle service funds returned |
| `wallet_transfer` | Real wallet transfer |

## Complete internal journal account catalog

| Code | Fixed category | Name |
| --- | --- | --- |
| `bottle_receivable` | asset | Returnable cylinders with customers |
| `cash` | asset | Wallet cash |
| `customer_receivable` | asset | Customer receivables |
| `equipment` | asset | Equipment |
| `inventory_lpg` | asset | LPG inventory |
| `inventory_stove` | asset | Stove inventory |
| `inventory_transit` | asset | Inventory in transit |
| `other_assets` | asset | Other assets |
| `supplier_receivable` | asset | Supplier refunds / advances |
| `transport_receivable` | asset | Transport receivables |
| `vehicles` | asset | Vehicles |
| `business_allocation_equity` | equity | Business allocation of equity |
| `capital` | equity | Additional capital |
| `equity_adjustment` | equity | Other equity adjustments |
| `opening_equity` | equity | Opening equity |
| `retained_earnings` | equity | Supported opening accumulated earnings |
| `withdrawals` | equity | Owner withdrawals |
| `cogs` | expense | Cost of goods sold |
| `depreciation_expense` | expense | Depreciation |
| `employee_expense` | expense | Employee costs |
| `interest_expense` | expense | Interest paid |
| `inventory_loss` | expense | Inventory losses |
| `bottle_exchange` | expense | Signed incoming/outgoing Bottle valuation difference |
| `logistics_expense` | expense | Logistics costs |
| `operating_expense` | expense | Operating expenses |
| `vehicle_expense` | expense | Vehicle maintenance |
| `disposal_gain` | income | Asset disposal gain / loss |
| `internal_logistics_revenue` | income | Internal transport revenue |
| `logistics_revenue` | income | External logistics revenue |
| `other_income` | income | Other income |
| `sales_revenue` | income | Product revenue |
| `employee_payable` | liability | Employee salaries and earnings |
| `loan_payable` | liability | Loans |
| `operating_payable` | liability | Operating obligations / advances |
| `other_liability` | liability | Other liabilities |
| `supplier_payable` | liability | Supplier payables |



New wallet/stock contributions use Capital for initial and later owner investment. Real wallet transfers have two legs and no business equity or profit effect. Source allocations retain exact cents; internal Logistics allocation is noncash.
