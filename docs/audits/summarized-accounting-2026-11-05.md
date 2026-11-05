# Summarized accounting: implementation and verification

Primary development VPS: `144.79.249.4`; existing Cloudflare frontend. Original business history, credentials and retained acceptance records are preserved.

## Storage gate completed first

[Physical compaction evidence](storage-compaction-2026-11-05.md) records the restored backup, explicit four-row orphan-test cleanup approval, write pause and exact preservation gate. Database allocation fell from **4,643,802,259 to 36,662,419 bytes**, reclaiming **4,607,139,840 bytes**. The 137 captured tables, 377 indexes and 596 constraints matched after maintenance. Retained gate/recovery files occupied 16,321,191 bytes at that check, separately from database allocation and existing WAL/cloud backups.

The event-accounting migration was not started until that gate, actual Auth checks and the existing clone lifecycle/concurrency suite passed.

Final verification after deployment and fixture cleanup measured **37,399,699 database bytes**. The entire retained local backup directory separately occupied **1,563,168,768 allocated bytes**, including **1,372,581,888 bytes** in the local cloud-backup/WAL working directory. Existing backups were retained; these sizes are not part of the reclaimed database figure.

## Posting contract

`20261105020000` introduces one transaction-local collector/final posting step. All 27 public financial command boundaries and private payroll synchronization retain their original gated implementations and owners. Nested calls remain part of the parent action. Each financial action/date posts once; employee/month salary recognition keeps its own historical date. No persistent duplicate event store was added.

Equivalent account/business/type/necessary counterparty or real-wallet lines net together. Product, Gas/Bottle, actual-return, acquisition and FIFO detail remains at its source. Checkout incorporates historical transport into COGS; buyer Supplies/COGS and Logistics revenue remain separately recognized, with additive Combined reporting. Nonfinancial changes and real-wallet transfers post no financial journal; transfers retain their two principal wallet legs.

Immediate bonuses, external collections, crew/operating settlement and asset purchases remove zero-net clearing effects. Later payments/refunds/returns remain separate actions. Custom type snapshots, cumulative returned-fund allocations, source locks, request/revision guards, classifications and per-wallet permissions remain intact. Future replay targets omit redundant empty/null metadata and duplicate equal amounts.

Product reconciliation now follows source/FIFO evidence and checks both external and full carrying-value inventory controls. Internal layer/shell consumption is conserved. Cash classifications use immutable wallet legs, independent of journal header shape. Existing journals and request rows are not rewritten.

`20261105021335` adds tenant-qualified current source labels to activity rows. `20261105024016` preserves independent POS/Finance request namespaces in derived journal identities; old retries still recover their original saved results. The namespace regression was reproduced failing before its fix and passed afterward.

## Measured examples

Same rolled-back source operations on the same PostgreSQL engine, before and after the redesign:

| Action | Headers before → after | Lines before → after |
| --- | ---: | ---: |
| 12-product checkout, three wallets, partial actual bottle returns | 70 → 1 | 146 → 9 |
| One-product checkout, three wallets, bottles still due | 9 → 1 | 18 → 8 |
| 12-product purchase dispatch | 14 → 1 | 30 → 8 |
| 12-product purchase receipt | 24 → 1 | 48 → 2 |
| Three-wallet supplier payment | 3 → 1 | 6 → 4 |
| Bonus recognized and immediately paid | 2 → 1 | 4 → 2 |
| External delivery recognized and collected | 2 → 1 | 4 → 2 |
| Crew/fuel costs recognized and immediately paid | 4 → 1 | 8 → 4 |
| Equipment acquired from wallet | 2 → 1 | 4 → 2 |
| Direct Stove receipt | 2 → 1 | 4 → 2 |

The large checkout's journal/header tuple bytes fell **29,162 → 1,245** (95.7%). Its maintained replay-state bytes fell **39,248 → 32,584**. These are logical tuple measurements, excluding indexes, WAL, backups and unchanged detailed source/FIFO records. They are not a claim of 95.7% savings for the whole database or event.

Single engine samples were 320.628 → 301.517 ms for the large checkout and 173.068 → 158.544 ms for its purchase receipt. They show no observed regression in those samples, not a sustained-load/latency guarantee. Simple two-line actions already near their minimum remain two-line actions.

The nine-line example retains three real wallets, customer dues, revenue, inventory, COGS, an outstanding bottle claim and an exchange difference. Those distinct effects cannot be removed while retaining the required identities and accounting evidence.

## Additional correctness fixes

- Principal settlements propose original percentages, cap them to each business's remaining original principal cents and distribute any rounding remainder only to outstanding shares. Two-business `100.01 = 40.01 + 60` and three-business `100.05 = 100.04 + 0.01` cases close every business exactly for borrowing and lending. Strict global sign/cents validation remains unchanged; inconsistent historical ownership blocks further settlement for source reconciliation.
- Historical amount bounds apply after action aggregation. A 100.01 action split across businesses remains searchable with Minimum amount 80. Component bounds keep balance semantics.
- Cash-flow reports no longer require separate wallet headers. Opening/closing figures, totals, acquisitions, cash classifications, independent business positions and daily trends matched the previous model exactly on the comparison fixture.
- Mixed old product-attributed inventory lines and new control lines normalize to the same inventory asset when classifying positions/trends; no phantom liability is introduced.

## Deployment and preservation

The primary posting cutover used the established deployment lock, exact migration approval and backup workflow. Transaction writers and database jobs paused; remaining Authenticator sessions and starting/running cron work drained before a fresh quiesced dump and transactional migration. Original service/scheduler intent was restored before health verification. The cutover's success/failure/drain/restoration paths have deployment tests.

An isolated restore of `/opt/lpg/backups/deployment-20261105T020607369618Z/quiesced-accounting.dump` was compared with the deployed original tenants: **88 source tables matched exactly and original credential fields matched**. New disposable fixtures were excluded; derived scheduler/savepoint/reconciliation work was not misrepresented as immutable history. Private fingerprint evidence is retained beside that dump. Local `.env.core-test` and the original core manifest remain untouched.

## Verification

- `npm run accounting:db:test`: forward-upgrade preservation; original lifecycle, rebates, mixed/delayed/cross-company returns, historical FIFO/cancellation, treasury, payroll/advances/returned bonuses, assets, lending/borrowing, source controls, wallet visibility/tenancy, fault rollback and concurrency. The action-storage fixture also checks exact action counts, source/company search, amount bounds, request namespaces and complete before/after reports.
- `npm run deploy:test`: deployment/backup suite, including cutover restoration after SQL failure, jobs that fail to drain and a runtime restoration failure.
- `node supabase/tests/core-security-api.mjs --vps`: actual Auth/PostgREST cross-tenant/role denials, private boundaries and preserved original stock.
- The dedicated published-browser/API fixture exercises a seven-line checkout, split wallets, partial/final collections and a delayed acknowledged different-company bottle. Sequential original FIFO rounding is retained: COGS **2,850.01**, of which external cost is **2,816.67**, rather than recosting two different issues as one quantity. It also exercises exact three-business final-cent settlements and independent request namespaces through normal Auth.
- `npm run accounting:actions:live:test` passed against the published Worker at 1440, 768, 390 and 375 pixels, including light/dark themes, compact row-height checks, one seven-line expansion, reachable final Debit/Credit amounts without phone horizontal scrolling, source dialogs, advanced filters and components. Both old saved retries and fresh independent POS/Finance request namespaces passed through actual Auth. All generated fixture businesses/users were removed with normal Auth cascades enabled.
- Build, lint and deployment tests passed. All three forward migrations are applied; twelve backend services are running, scheduled-job flags match their pre-cutover state, indexes are valid and no business journal is unbalanced. Final retained counts remain **128 headers / 295 lines**, exactly the original records rather than fixture residue.

The final phone/desktop screenshots were inspected after the automated checks. Compact rows show current source identities and short cash/due effects; expanded phone lines keep account, related record, type, business and explicit Debit/Credit values readable. No final blocker remains in the exercised scope.

[Differential security review](summarized-accounting-security-review-2026-11-05.md) records resolved findings, reviewed boundaries and limits. Browser viewports are not physical-device/provider settlement or a host-crash recovery drill.
