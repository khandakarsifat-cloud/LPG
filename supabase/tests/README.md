# Database and live acceptance

Current application contracts have one Gas/Bottle/Unit model. No current test command installs old fields, RPC overloads or compatibility views.

| Command | Current boundary |
| --- | --- |
| `npm run accounting:db:test` | Owned clone; component lifecycle/replay/concurrency, FIFO reports, wallet visibility, capability boundaries, guarded deletion, rebates, transport and summarized financial actions |
| `npm run purchase:db:test` | Same canonical database suite; optional `--replay-module` explicitly selects historical migration replay |
| `npm run auth:db:test` | Owned clone; account/session/RLS/tenant access plus current permission, employee and attendance-device regressions |
| `npm run attendance:db:test` | Owned clone; attendance storage/calendar/concurrency and current permission/employee/device regressions |
| `npm run accounting:api:test` | Real Auth/API and published browser; fresh isolated component fixture, financial feature operations, independent expected positions, scoped cleanup |
| `npm run finance:dimensions:api:test` | Full current API acceptance, including independent business/Combined financial totals |
| `npm run finance:visibility:api:test` | Real owner/staff access editor, hidden wallet posting/reads, current component FIFO and live revocation |
| `npm run rebate:api:test` | Real rebate corrections/recovery, original gross costs, supplier refund/credit reuse, capability denial and scoped cleanup |
| `npm run accounting:actions:live:test` | Summarized financial source posting and published activity UI |

The canonical database runner does not dispatch historical commission, wallet-sub-balance, paired-cylinder, old purchase-line or consolidation-elimination tests against the latest schema. Those SQL files remain migration replay evidence and must be executed only at their original migration boundary. Applied migrations and their replay fixtures are never rewritten merely to make them look current. Superseded retained-live lab scripts are removed; their evidence and credentials remain ignored historical artifacts.

Current disposable API acceptance uses ignored `.temp/component-acceptance/`. The populated volume-audit business and `.temp/component-live/` are retained separately and never adopted by a new acceptance run. Run live suites sequentially when they fingerprint all other businesses for preservation; concurrent test businesses legitimately change those fingerprints. `--new-run` on the summarized-action test starts a separately tracked fixture without overwriting an earlier failed run's evidence.

Frontend Filled/Empty presentation remains intentional. Backend fixture payloads and current report assertions use only canonical components. Historical SQL and old intercepted browser fixtures are not evidence that the current application accepts their formats. See [Finance validation](../../docs/modules/finance-validation.md) for evidence limits.
