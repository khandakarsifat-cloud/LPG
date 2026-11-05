# Summarized accounting: differential review

Review date: 2026-11-05 Asia/Dhaka. Scope: the unapplied `20261105020000_summarized_business_actions.sql`, `deploy/compact-storage.py`, their immediate accounting/read dependencies and affected activity UI contracts. Other existing working-tree changes were excluded.

## Result

No unresolved authorization, tenant-isolation or financial-integrity blocker was found in the reviewed revision. Proceed through the planned deployment and real Auth/API/browser acceptance gates; those live checks remain pending at this review point.

| Severity | Open | Resolved during review |
| --- | ---: | ---: |
| Critical / High | 0 | 0 |
| Medium | 0 | 4 |

The change remains **high risk by scope**: 27 public financial-command boundaries plus private payroll synchronization feed the shared posting path. The baseline catalog contained five direct `post_journal` producer callers and five `sync_journal` callers, with further trigger/FIFO dependencies.

## Resolved findings

### Medium: cumulative percentage rounding could block final principal settlement

The first repayment implementation subtracted two calls to the existing boundary-rounded allocator. That allocator is not monotonic for the middle of three businesses. For principal `100.05` allocated as Logistics `33.33%`, LPG `33.33%`, Stove `33.34%`, a cumulative payment of `100.04` allocated `33.34 / 33.35 / 33.35`; at `100.05` the target became `33.35 / 33.34 / 33.36`. The final `0.01` therefore required a negative LPG component, correctly rejected by the existing same-sign validator. This was a legitimate operation failure, not a privilege escalation or an unbalanced committed transaction. The arithmetic was independently reproduced using exact decimal rounding, without database mutation.

The final `loan_settlement_amounts` implementation caps each proposed payment share at its original remaining principal, redistributes only the remainder among still-outstanding shares, verifies actual prior settlements and retains strict global sign/cents checks. It acquires the original loan lock before wallet posting. See migration lines 780–813 and 839–841. Tests cover two-business `100.01` repaid as `40.01 + 60`, and three-business `100.05` repaid as `100.04 + 0.01`, for lending and borrowing. Historical journals/allocations are not rewritten.

### Medium: amount filters used individual lines after the activity contract became actions

Filtering lines before grouping hid a `100.01` action split into `33.33 / 66.68` when Minimum amount was `80`. The displayed action value and the filter consequently disagreed.

Historical min/max bounds now apply after action aggregation, while component bounds retain their balance semantics. The matching-change total includes only movements belonging to accepted actions. See migration lines 613–641 and `summarized-actions.sql`'s global and account-scoped `min=80` assertions.

### Medium: cutover must drain database work, not only stop its application containers

The deployment safeguard initially stopped REST/account/attendance services but inspected only active cron backends. A database operation can outlive its disconnected application process, and a queued cron start may not yet have an active backend PID. That did not establish the required absence of old RPC bodies before replacing posting/trigger functions.

The final exact-version cutover now requires zero `authenticator` client backends of any state, zero active/matched cron backends and zero starting or PID-less running job records after disabling schedules and stopping source services. A bounded drain timeout fails before taking the quiesced dump or applying SQL. See `deploy/backend.py:36–86`, particularly line 58.

The enclosing updater already owns the deployment/backup lock, exact migration approval and baseline health checks. The cutover retains private recovery intent, captures and validates a fresh quiesced archive, executes the original single-transaction migration batch, and attempts every runtime/scheduler restoration even if another restoration fails. Incomplete restoration is explicitly marked `recovery_required`. Four local mocked success/fault tests cover ordering, SQL failure, drain timeout and restoration failure; the primary agent reported the full deployment test suite passing after the strengthened query.

## Boundaries checked

- **API attacker model:** anonymous callers, authenticated callers from another tenant, and same-tenant staff lacking owner/action/wallet/report capabilities. The original gated implementations retain their owners and `SECURITY DEFINER` settings; new wrappers do not replace those checks. Private implementations and collector/loan helpers are revoked from public, anonymous and authenticated roles. No public API route to set the collector GUC was found.
- **Atomic posting:** transaction-local staging, nested action depth, final per-business balance checks and existing deferred journal validation remain transactional. Current wrappers finalize all successful return paths. Deferred guards cover source-state, wallet, rebate and Finance-request writes; exception rollback restores both source writes and local collector state.
- **Retry/source identity:** existing request-body, revision and source-state guards remain in the single owning implementations. Product/FIFO attribution is retained at its sources; real wallets, loan/asset identities, customer/supplier obligations and custody identities are retained where required. Salary recognition remains separated by employee/month/date.
- **Locking and inventory:** source/snapshot locks are acquired before deferred journal insertion can reorder downstream work. Per-layer conservation now includes internal value and internal shell value; ordinary inventory control includes remaining internal FIFO cost as well as the private external-cost control (lines 290–296).
- **Dependent reads:** activity/source searches remain tenant-qualified behind the existing scope checks. Cash classifications use immutable wallet legs; inventory positions normalize old product-attributed and new control-account lines. Custom-type historical labels retain their snapshots. UI links retain module permission checks.
- **Physical maintenance:** prefix-checked disposable restore databases, private dumps/evidence, measured per-table compaction selection, preserved index/constraint definitions, deployment locking and restoration of previous service/scheduler intent were reviewed. No reset/drop of legitimate business tables is present.

## Evidence and limits

The review used the privately captured baseline function catalog plus current source. Git history (`01c2b285`, the existing financial-dimensions foundation) was checked for the original posting validation; no removed authorization gate was found. The reviewer inspected the completed clone-suite log showing original-row upgrade preservation, exact before/after financial reports, guarded role/tenant access, principal boundaries, retries, FIFO/source controls, rollback and concurrency checks. The reviewer did not independently rerun that suite or mutate/deploy the live system.

Two internal design boundaries remain relevant for future extensions: direct private posting producers rely on their owning event/request guards rather than the old journal `src/id/event` uniqueness behavior, and new financial writers must participate in an action boundary and the existing deferred guard coverage. These are not demonstrated public exploits in the current call graph.

This is a focused differential review, not a full application audit or sustained-load certification. Real deployed Auth/API/browser acceptance, final health checks and physical/provider settlement are separate evidence. The measured tuple-byte/latency samples do not establish long-term throughput or complete backup disaster-recovery capacity.

The cutover addendum is a source/fault-test review. It does not claim a physical host-crash recovery test or a live long-running RPC/cron interruption experiment. A killed process/host still requires the recorded private recovery intent; normal Python exception paths restore prior intent automatically.

Reviewed migration SHA256: `38f3b10d046f1b7a435462d7d5607cd5698c0eb6c15524dbf2270f6ec844f29e`.

Reviewed maintenance-script SHA256: `e2f848616b937f397652a633a03ac4579b341c5c4e09b01e548669a75d8e3bd2`.

Reviewed deployment-updater SHA256: `8a4b4a316120bfd83bf409927b03768e849ac6c8474906e0e71681764482bd6e`.

Reviewed deployment-test SHA256: `d77a6369f58a83256dafc4c2b01a892f317b398f3e0bda175caa68aaed1fb5bd`.

## Source-label and compact-row addendum

The separate forward migration `20261105021335_accounting_action_source_labels.sql` was reviewed after the primary agent reported deployment of `05020000`. It replaces only the private read helper's definition; it does not edit the applied migration or modify historical records.

Every new customer/company/employee/loan/asset/product/service/transit label lookup is tenant-qualified, including joined records. The existing `record_kind` and `record_id` routing remains unchanged. The helper remains an invoker function in the private schema with an empty search path and its existing privileges/owner. It adds source identity labels rather than credentials, contact numbers or full notes. Ordinary identities deliberately use current names; financial entries use their saved immutable `type_name`, not an editable type default.

The compact card continues to render labels as escaped React text, keeps source opening behind the existing module permission checks and labels generic magnitudes as Value recorded with a neutral icon. No new privacy, tenant-isolation or stored-recognition issue was found. Final browser/layout checks remain pending at this addendum; no visual or physical-device verification is claimed by this reviewer. The primary agent's reported live source/credential preservation and seven-line API acceptance are separate evidence, not independently repeated here.

Reviewed label-migration SHA256: `b97b64402d6e55fc79cb891506bc111f7fd1d1d99e503fcc99bbcd3a74ce51eb`.

Reviewed compact-card SHA256: `56c8e48747e4165c6bbc928d3c6fb54252380e0a4f89194e55b1f6ef6f5ef8d0`.

Reviewed activity-CSS SHA256: `33495a8c0d481f9398e3b0a1f79954fcce144b830b0f05d610d36615be9cd636`.

## Request-namespace and mobile-evidence addendum

A fourth Medium correctness finding was reproduced by the primary agent on an isolated clone: POS and Finance legitimately use separate durable request registries, but the collector derived both journals from the same bare UUID. Reusing a successful checkout UUID for a distinct Finance action could therefore abort with a journal primary-key collision. Atomic rollback prevented a partial financial write, but a valid action was rejected.

The separate forward migration `20261105024016_accounting_request_namespaces.sql` derives the transaction-local root identity from `md5(action || ':' || request_id)` when a request UUID exists. Trusted wrapper action names distinguish the two namespaces; nested calls retain the existing root context. Durable request IDs, exact-body retry checks, tenant/date grouping and existing journals remain unchanged. An already-successful historical retry still returns its saved result before posting, so the new derivation does not duplicate history. The private helper's signature, owner and ACL are preserved by `CREATE OR REPLACE`. No unresolved issue was found in the twelve-line fix. `summarized-actions.sql` now explicitly reuses a checkout UUID for a distinct Finance capital action; completion of the final updated clone run remains a primary-agent verification gate at this addendum.

The final presentation changes shorten effect labels and display the existing journal debit/credit values in a phone-sized list. Signed amount calculations, server data access and source permissions are unchanged; labels remain escaped React text. Mobile zero-side cells are visually omitted while nonzero Debit/Credit sides retain explicit labels. Final deployed browser/accessibility checks remain separate and were not executed by this reviewer.

Reviewed request-namespace migration SHA256: `e2d0ed4bb78dad7dda86f94fb1e502ea5de7e45d278c065133e2fcc4ca4a33b3`.

Reviewed final JournalAudit SHA256: `15483c793008a6b28359b6caa1d8bb3d832bb596e365f1486d03960036153a6f`.

Reviewed final compact-card SHA256: `f5aaeccdbb43471e08f78748d2e8d5826ce74b7879165286d4e256ac67418f8a`.

Reviewed final effect-label helper SHA256: `4ca60deca03667c1f8a7c310e428ecaeff1d2decdbe4708003c35855db541bea`.

Reviewed final activity-CSS SHA256: `367b65ad4135c224c662083a46eabba95c4ee8d12cfbe68a9375fa604d63b37e`.
