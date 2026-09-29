# AGENTS.md

## Working Rules

- Read `README.md` before making repository-wide or architectural changes.
- Inspect the existing implementation around the target area first and follow established patterns rather than introducing parallel abstractions.
- Keep changes scoped to the requested task. Do not refactor unrelated code unless required for correctness.
- Prefer extending existing components, hooks, utilities, types, and styles over creating duplicate patterns.

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

After implementation:

- run the relevant build, type, lint, or test checks available for the affected area;
- verify important user flows touched by the change;
- distinguish failures introduced by the change from pre-existing repository issues;
- never claim something was tested or verified when it was not.

## Documentation

- `README.md` is the current project snapshot, not a development diary.
- Update it only when a change materially alters documented behavior, architecture, setup, integrations, dependencies, module status, or limitations.
- Do not duplicate implementation history that Git already records.
- Keep documentation consistent with the repository and verified Supabase state.

## Completion

Before finishing a task, review the final diff for unrelated edits, accidental generated files, exposed secrets, and documentation that became inaccurate.
