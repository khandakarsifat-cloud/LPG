# Finance validation

## Current component contract

`20261106203204_canonical_component_inventory.sql` replaces backend physical-state stock with independent Gas/Bottle/Unit quantities and FIFO queues. It requires the explicitly authorized empty development business baseline. The earlier retained core lab was removed by that reset; its ignored credentials/manifests remain historical artifacts, not current acceptance targets. Historical migrations and their owning replay suites remain unchanged.

`npm run accounting:db:test` restores an owned disposable PostgreSQL clone, applies pending forward migrations, and verifies the current contract:

- No Filled/Empty stock fields, paired FIFO positions or obsolete sale-line enum values.
- Separate acquisitions, exact Gas/Bottle COGS, original-layer restoration and mixed commercial lines on the same product.
- Bottle dispatch and unreceived cancellation change only inventory custody, preserving layer dates/values and avoiding cost/finance events.
- Actual cross-product Bottle receipts, immutable price snapshots, partial obligations and consumed-return cancellation guards.
- Backdated acquisitions revalue active issues and exact cancellation costs with source corrections.
- Supplier payments, original retry results, paired transport payment and component capitalization.
- Physical stock plus custody, layer conservation, carrying values and source-journal reconciliation.
- Authenticated/anonymous access, foreign-tenant isolation and private helper denial.
- Competing authenticated sales cannot oversell either component.
- Independent FIFO report pagination, granular capabilities, wallet visibility and actual guarded business deletion with all FKs active.
- Current rebate credit/refund, transport and summarized-action source contracts.

Fixtures roll back or remain only in the owned clone. These checks do not prove published Auth/browser integration. Account/employee/attendance database suites and backup/device acceptance remain separate evidence; the component test does not silently certify every workflow.

## Published acceptance

`npm run accounting:api:test` provisions a uniquely named disposable component business and generated owner using trusted fixture provisioning, while public signup remains disabled. It runs real Auth/PostgREST, published purchase creation/dispatch/receipt and Package checkout, component stock display, Gas/Bottle FIFO filters and the adjustment form at desktop and phone widths. API checks cover partial cross-product returns, exact cancellation, original request retry, supplier payment, custody-only purchase cancellation and independently expected financial positions/COGS. The feature stage also verifies real-wallet transfers, loan principal repayment, equipment depreciation, employee bonuses, service advances/returns/finalization and Stove payment/cancellation/refund, comparing independent expected business/Combined totals. Cleanup removes only that verified fixture and generated identity, preserving admin/burner accounts.

Ignored `.temp/component-acceptance/manifest.json` retains original requests and results. Generated credentials stay in an ignored file until successful cleanup. Failed runs retain their fixture and original request bodies for diagnosis/recovery; never substitute new request IDs for uncertain operations. Normal acceptance does not intercept report responses.

`npm run inventory:test`, `npm run purchase:test`, `npm run build`, `npm run lint` and `npm run deploy:test` cover presentation/business utilities, compilation and deployment safeguards. Deployment uses the established VPS/Cloudflare workflow with reviewed migration versions and backend health before frontend publication.

## Evidence and recovery boundaries

Business-wide deletion uses the explicitly authorized guarded development-baseline workflow with full backup and matching isolated restore. Routine acceptance cleanup is restricted to its exact newly created business/identity. Never repair unexplained differences with invented payments, stock or balancing journals.

Earlier retained-lab, rebate, wallet-visibility and accounting-action results are documented in [the core audit](../audits/lpg-core-overhaul-2026-11-04.md), [rebate acceptance](../audits/purchase-rebate-2026-11-04.md) and [summarized accounting](../audits/summarized-accounting-2026-11-05.md). They describe their executed schema boundary and must not be represented as current component acceptance.

Physical printing, installed Android/PWA behavior, physical attendance devices, provider settlement and full backup recovery require their own acceptance. Browser emulation and balanced journals do not prove them.

The populated volume-audit business (`540b74e7-42b1-493f-8311-e9814688639a`) and ignored `.temp/component-live/` evidence are retained separately. The security-forward migration `20261106215642_current_contract_security.sql` enables deny-by-default RLS on private deletion-control state without opening any client grants. Access tests check granted capabilities rather than assuming role names imply denial. See [the current test catalog](../../supabase/tests/README.md).
