# AGENTS.md

## Active development policy

- This project is in active development and has not entered production. Local Docker and the application on the primary VPS (`144.79.249.4`) with its Cloudflare frontend are development environments, regardless of deployment variable names. The VPS has production infrastructure; this does not make the application production-ready. The former Azure backend is retired from the active workflow and must remain untouched unless explicitly requested.
- Prefer one canonical implementation and forward migrations that normalize obsolete development records. Do not retain old fields, RPC overloads, duplicate models, or compatibility branches solely for superseded development formats.
- Development cleanup may transform or remove obsolete representations after inspecting dependencies and reconciling stock and financial evidence. Preserve legitimate business activity when it can be cleanly migrated; this is not permission for indiscriminate resets or invented payments, stock, or historical attribution.
- Never edit already-applied migrations. Keep their replay tests and establish the current state through new migrations.
- This policy does not relax security, trusted tenancy, RLS, authorization, transactional integrity, or database correctness.
- Revise this policy before production: backward compatibility, staged safe migrations, and preservation of historical business records then become mandatory. Destructive production operations always require explicit approval.

## Working Rules

- Read `README.md` before making repository-wide or architectural changes.
- Inspect the existing implementation around the target area first and follow established patterns rather than introducing parallel abstractions.
- Keep changes scoped to the requested task. Do not refactor unrelated code unless required for correctness.
- Prefer extending existing components, hooks, utilities, types, and styles over creating duplicate patterns.
- Use relevant skills from `.agents/skills/` when applicable. Follow their specialized guidance while preserving this project's architecture, conventions, business rules, and safety requirements. Do not invoke unrelated skills.
- Consult relevant architectural and module documentation before modifying complex workflows or cross-module behavior.

## Supabase & Database

- When backend state matters, use the configured Supabase MCP connection to inspect the actual project before making assumptions.
- Verify that MCP is connected to the Supabase instance used by this repository before relying on live database state.
- Prefer read-only MCP inspection unless the task explicitly requires backend changes.
- Make schema changes through a new migration. Do not rewrite historical migrations unless explicitly instructed.
- Do not run destructive database, volume, reset, or migration-repair operations without explicit user approval.
- Preserve tenant isolation, RLS behavior, authentication boundaries, and existing authorization assumptions.
- Never expose, log, hardcode, or commit secrets or privileged Supabase credentials.
- Accounting journals and inventory carrying-value entries remain authoritative. Month-end savepoints, customer metrics and reconciliation queues are private derived projections; never repair them with invented financial entries or a reporting baseline. Preserve atomic invalidation and the lock order when extending source writes. Verify savepoint-backed positions against full journal recomputation after changing accounting recognition.
- FIFO layers and consumption links are private maintained projections of actual Gas/Bottle acquisitions and issues. Preserve separate component evidence, shell ownership/cost/age through custody, immutable incoming-bottle current-price snapshots, original-layer restoration and dated savepoint invalidation. Monthly/product commission calculations remain removed. A purchase's manual `rebate_amount` is noncash settlement: retain gross Gas/Bottle prices, approximate buying references, inventory and COGS. Immutable private rebate events post supplier settlement and separate Other Income; cancelled applications restore company credit, and later use consumes existing credit before recognizing new income. Preserve exact cents, owner authorization, request identity, company isolation and source/snapshot lock order. Never reintroduce inferred Package/Refill or weighted-average costing.

- Wallet Use, Balance and History are independent scopes. Enforce Use at canonical posting, including automatic-wallet operations and both transfer legs. Never expose raw wallet tables, hidden opening/running balances, or aggregate Cash/audit snapshots to staff lacking the relevant balance visibility. Keep Finance tab reads and financial-entry own/all reads distinct from action permissions; preserve existing OWNER-only accounting writes. Account revisions must invalidate caches after wallet-scope changes.
- Product performance displays received Refill purchases as Gas − Bottle and Package purchases as Bottle; backend acquisitions remain independent Gas/Bottle components. Exact-product FIFO reports use actual linked component history, include attributable internal transport, label current-price margins as projections and exclude unsettled exchange variance/rebates. Do not sum component quantities as physical cylinders or replace missing/estimated costs with zero margin inputs.
- Every financial line must retain Type + fixed Category + LPG/Stove/Logistics Business and its source. Never persist an unknown/shared business or infer recognition from an editable type name.
- Financial writers must join the existing transaction-local accounting collector and finalize once per financial action/date; salary recognition retains employee/month dates. Extend its deferred source guards when adding writers. Combine equivalent account/business/type/required wallet or counterparty effects, removing zero-net intermediate lines; keep product/FIFO/actual-return detail at its owning source. Do not reintroduce per-product journals or a second durable event store. Preserve independent request namespaces and original retry results. See `docs/modules/finance.md` for the posting and reconciliation contract.
- Each real wallet has one balance and no business sub-balances. Transaction allocations retain exact LPG/Stove/Logistics cents; business Cash is pooled across real wallets and may be negative. Real-wallet transfers produce two principal legs without business allocation/equity/profit. Internal Logistics allocations are noncash. Retain Logistics revenue and the purchasing business’s transport component in Supplies and subsequent COGS; never also expense it separately. Combined is the exact additive total of the independently classified LPG/Stove/Logistics positions and results, without consolidation eliminations. Preserve original external-cost/FIFO evidence for private reconciliation.
- Custom entries retain type/category/allocation snapshots and exact cents. Editing defaults or deactivation never rewrites historical recognition. Partial returns use cumulative rounding and original source locks. Keep current retained acceptance labs separate from ordinary disposable cleanup.

## Frontend Conventions

- Follow the existing React + TypeScript structure and naming conventions.
- Keep Supabase/data-fetching logic in the existing hook/data-access layer rather than scattering it through UI components.
- Reuse shared types and utilities instead of redefining domain models locally.
- Follow the existing TanStack Query caching/invalidation patterns when changing server-backed data.
- Match the existing UI and CSS conventions; do not introduce a new component library or styling system without a clear requirement.
- Avoid `any` and unnecessary type assertions when proper types can be expressed.

## Change Quality

- Prefer small, coherent changes over broad rewrites.
- Do not add dependencies unless they materially simplify the requested feature and fit the existing stack.
- During development, prefer canonical contracts over compatibility with obsolete development formats; coordinate frontend, database, and tests when replacing a contract.
- Treat existing business rules as intentional until verified otherwise from code, migrations, or the live Supabase state.

## Verification

### Authenticated live feature testing

- Dedicated burner account: `sifatsiam244@gmail.com`. Use it for authenticated browser/API acceptance; it is not a customer or production operator account.
- Read credentials from ignored root `.env.live-test` (`LPG_TEST_EMAIL`, `LPG_TEST_PASSWORD`) or injected environment variables. Never print credentials/session tokens, capture password fields, or place secrets in tracked docs, fixtures, scripts or configuration.
- Verify the API/Worker target from the existing private deployment configuration before login. Inspect the burner's trusted tenant/membership first; use a clearly named disposable test business and uniquely labeled fixture records. Never repurpose a genuine business, change its membership, or alter its stock, wallets or transactions for acceptance tests.
- Exercise real Auth/PostgREST and browser flows with the burner's normal permissions. Test other roles/tenants with isolated fixture accounts. Keep retries on their original request IDs. Use rolled-back SQL fixtures or a disposable database for fault injection, concurrency and destructive cases.
- Track fixture IDs, verify ledger/stock reconciliation and before/after preservation, then clean up only the explicitly created test records/businesses through the established fixture cleanup. Retain the burner login for future testing. Report live checks separately from intercepted-browser fixtures and physical/provider settlement.

After implementation:

- Run the relevant build, type, lint, or test checks available for the affected area.
- Verify important user flows touched by the change.
- Distinguish failures introduced by the change from pre-existing repository issues.
- Never claim something was tested or verified when it was not.

## Architecture & Documentation

- `README.md` is the current project snapshot, not a development diary. Update it only when changes materially affect documented behavior, architecture, setup, integrations, dependencies, module status, or limitations.
- Keep root `documentation.md` as a short navigation index; detailed contracts remain in their owning module documents.
- Maintain `docs/architecture.md` as a concise, current architectural map covering major modules, their responsibilities, dependencies, and important code locations.
- Maintain documentation for critical business rules, complex modules, and non-obvious cross-module workflows under `docs/modules/` when such documentation provides lasting value.
- Create new module documentation only when necessary. Prefer updating existing documentation over creating overlapping files.
- Update relevant architectural and module documentation whenever implementation changes make it inaccurate.
- Keep specialized documentation near its existing subsystem when appropriate; do not duplicate it under `docs/`.
- Document important architectural decisions and invariants, not routine implementation details that can be easily discovered from source code.
- Keep documentation concise, accurate, and grounded in the actual implementation. Source code and database migrations remain authoritative.
- Do not duplicate implementation history that Git already records.

## Deployment

- After every change, check for pending database migrations, apply them, and deploy through the established workflow. Deployment is part of completing the change, not an optional follow-up.
- The user's standing instruction authorizes routine non-destructive migrations and deployments after changes. Do not ask for deployment permission again unless the user explicitly restricts the task to local work or the operation is destructive.
- Consult `README.md` and the existing deployment configuration to identify the current frontend and backend environments. The primary backend is `144.79.249.4` (`lpgadmin`, `/opt/lpg`, `compose.vps.yml`); the frontend remains the existing Cloudflare Worker. Use `VPS_*` deployment settings, never the archived Azure configuration.
- Do not assume local Docker or Supabase availability represents the state of the deployed backend.
- Use the established deployment workflow and verify the target environment before making changes. Review pending migrations and provide their exact versions to any migration-approval flags required by the deployment tooling.
- Apply pending database migrations before deploying dependent frontend changes. If no migrations are pending, verify that state and continue deployment without rerunning historical migrations.
- Preserve production data, volumes and credentials, and use the existing backup and recovery safeguards.
- Never perform destructive production operations without explicit approval.
- Verify deployed backend health, frontend publication and the important affected user flows. Report the migration and deployment results, including any unverified functionality or blockers.

## Completion

Before finishing a task:

- Review the final diff for unrelated edits, accidental generated files, and exposed secrets.
- Check whether architectural or module documentation needs updating.
- Ensure affected documentation remains consistent with the implementation and verified Supabase state.
- Complete the required migration and deployment workflow before reporting a change as finished. If an actual blocker prevents deployment, state the blocker and the remaining work explicitly; do not present a local-only implementation as complete.

The earlier FIFO and dimensional development labs belong to the pre-core backup generation and are superseded by the explicitly authorized core reset. Their obsolete manifests are not current acceptance evidence. Preserve current acceptance credentials/manifests and never print credentials.


The current retained acceptance lab is `LPG Component Development Lab 2026-11-04` (`9ae10ffa-e8b6-42ce-af9d-587d84c441f7`). Preserve ignored `.env.core-test` and `.temp/core-business/manifest.json`; `npm run accounting:api:test` reuses original request IDs, and `core-independent.mjs --vps` verifies original-operation expectations independently of application calculations.
