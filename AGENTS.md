# AGENTS.md

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
- Preserve backward compatibility unless the task explicitly requires a breaking change.
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
- Consult `README.md` and the existing deployment configuration to identify the current frontend and backend environments.
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
