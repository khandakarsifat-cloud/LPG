# Local migration reconciliation

Audited **2026-10-04**. Target: the running LPG Compose database, PostgreSQL 17.6 (`public.ecr.aws/supabase/postgres:17.6.1.140`), through the configured Supabase MCP gateway at `http://127.0.0.1:54321`. MCP and the Compose database returned the same PostgreSQL system identifier.

**Result: ten migration files, ten history records, and zero remaining application-schema differences.** The live schema and all 29 public tables' row counts/full-row checksums remained unchanged. Only two migration-history records were inserted; no existing record or historical migration file was changed.

## Migration coverage

| Migration file | History before → after | Live representation |
| --- | --- | --- |
| `20260627000000_cloud_baseline.sql` | Recorded → recorded | Baseline objects present; subsequent migrations intentionally replace some definitions. |
| `20260627185300_fix_schema_inconsistencies.sql` | Recorded → recorded | Added columns, policy corrections and 14 permission seed values match. |
| `20260701130553_enforce_customers_phone_format.sql` | Recorded → recorded | Phone NOT NULL remains; original format check is superseded by later phone migrations. Historical data normalization was not rerun. |
| `20260701150242_require_customers_phone_bd_mobile.sql` | Recorded → recorded | Intermediate phone check is intentionally superseded by `numeric_customer_phone_lengths`. |
| `20260702152740_pos_customer_id_no_update.sql` | Recorded → recorded | Both POS function signatures and their definitions match. |
| `20260702155154_numeric_customer_phone_lengths.sql` | Recorded → recorded | Final numeric Bangladesh phone constraint matches. Historical data normalization was not rerun. |
| `20260702164710_employees.sql` | **Missing → recorded** | Five tables, 10 functions, 14 policies, two payment triggers and seven explicitly created indexes already existed. Constraint differences below are captured by the new forward migration. |
| `20261002061042_receipt_printers.sql` | Recorded → recorded | Table, checks and three policies match; authenticated grants are narrowed by the next migration. |
| `20261002062554_receipt_printer_grants.sql` | Recorded → recorded | Anonymous/public access revoked; authenticated SELECT/INSERT/UPDATE only. |
| `20261004165315_reconcile_live_schema.sql` | New → recorded | Reproduces the existing constraint names, two additional foreign keys and three administrator default-privilege groups. |

All eight pre-existing history entries have matching names and matching SQL tokens after comments, statement separators and line endings are normalized. The baseline history contains CRLF inside some function bodies; this is a formatting difference, not different logic. No orphan versions, duplicate versions or meaningful stored-statement differences were found. Adding the employee entry prevents migration tooling from trying to recreate its existing policies/triggers.

## Every application-object difference found

Names below are in `public`. “Migration” means the schema obtained by replaying the original nine active files in order, not an obsolete intermediate definition.

| Object | Original migrations versus live | Safest reconciliation, completed |
| --- | --- | --- |
| `employee_payment_categories` unique constraint | Migration: `employee_payment_categories_tenant_id_category_id_code_key`; live: `employee_payment_categories_tenant_category_code_unique`. Both enforce `(tenant_id, category_id, code)`. | Forward migration renames the constraint and its backing unique index on replay. Existing live objects are left intact. |
| `employee_payments` three-column FK | Migration: `employee_payments_tenant_id_category_id_category_code_fkey`; live: `employee_payments_tenant_category_consistent_fkey`. Both reference category `(tenant_id, category_id, code)`. | Forward rename on replay; no constraint replacement or data change. |
| `employee_payments_tenant_id_category_id_fkey` | **Live only:** `(tenant_id, category_id)` references `employee_payment_categories(tenant_id, category_id)`. Validated, immediate, NO ACTION. | Add on replay if absent. Preserve the live FK, although the three-column FK also enforces consistency. |
| `employee_payments_tenant_id_category_code_fkey` | **Live only:** `(tenant_id, category_code)` references `employee_payment_categories(tenant_id, code)`. Validated, immediate, NO ACTION. | Add on replay if absent. Preserve the existing FK; removing overlap belongs to a separate schema decision. |
| `supabase_admin` default table privileges in `public` | **Live only:** ALL for `postgres`, `anon`, `authenticated`, `service_role`. Includes PostgreSQL 17 MAINTAIN. | Capture the existing defaults in the forward migration, guarded to skip matching ACLs. |
| `supabase_admin` default sequence privileges in `public` | **Live only:** SELECT/UPDATE/USAGE for the same four roles. | Capture with the same guard. |
| `supabase_admin` default function privileges in `public` | **Live only:** EXECUTE for the same four roles. | Capture with the same guard. |

The only migration-only application objects were the two alternative constraint names and the unique constraint's backing index name. Their definitions were equivalent to the live names. There were no live-only application tables, columns, enums, functions, policies, triggers or independent indexes. Differences in the ordering of GRANT statements were normalized as unordered ACL sets; their privileges and grantors were identical.

## Object coverage and drift checks

After replaying the forward migration, comparison matched **29 tables, 225 columns, 10 enums, 37 functions, 70 policies, five user triggers, 102 constraints and 71 indexes**, including constraint-backed indexes.

Schema-only dumps were compared by object, including full function bodies/signatures/configuration, owners, comments, defaults, grants, default privileges, RLS and replica identity. Catalog queries additionally checked function security/volatility/strictness/parallelism, constraint validation/deferral, index validity/readiness, trigger enabled state, policy expressions and roles, extension dependencies, event triggers and publication configuration. Every public table has RLS enabled. There are no non-public triggers calling public application functions, and `supabase_realtime` currently has no published tables.

## Live-only Supabase platform objects

The active LPG files target `public`; they do not install Supabase itself. The following platform objects therefore also exist only in the runtime relative to those files. Preserve them through the pinned Supabase stack and its service/extension migrations, rather than duplicating their DDL in LPG migrations.

| Schema | Existing platform tables |
| --- | --- |
| `auth` (23) | `audit_log_entries`, `custom_oauth_providers`, `flow_state`, `identities`, `instances`, `mfa_amr_claims`, `mfa_challenges`, `mfa_factors`, `oauth_authorizations`, `oauth_client_states`, `oauth_clients`, `oauth_consents`, `one_time_tokens`, `refresh_tokens`, `saml_providers`, `saml_relay_states`, `schema_migrations`, `sessions`, `sso_domains`, `sso_providers`, `users`, `webauthn_challenges`, `webauthn_credentials` |
| `_realtime` (4) | `extensions`, `feature_flags`, `schema_migrations`, `tenants` |
| `realtime` (10, including partitioned parent) | `messages`, seven `messages_2026_10_01` through `messages_2026_10_07` partitions, `schema_migrations`, `subscription` |
| `storage` (10) | `buckets`, `buckets_analytics`, `buckets_vectors`, `iceberg_namespaces`, `iceberg_tables`, `migrations`, `objects`, `s3_multipart_uploads`, `s3_multipart_uploads_parts`, `vector_indexes` |
| `supabase_functions` (2) | `hooks`, `migrations` |
| `net` (2) | `_http_response`, `http_request_queue` |
| `vault` (1) | `secrets` |
| `supabase_migrations` (1) | `schema_migrations`, managed separately from application DDL |

Platform schemas also contain their own types, sequences, functions, constraints, indexes, triggers, RLS configuration, grants and default privileges. Additional runtime schemas are `extensions`, `graphql`, `graphql_public` and `pgbouncer`. Installed extensions are `plpgsql`, `uuid-ossp` 1.1, `pgcrypto` 1.3, `pg_stat_statements` 1.11, `pg_net` 0.20.3 and `supabase_vault` 0.3.1. The six platform event triggers are `graphql_drop_api`, `issue_pg_cron_access`, `issue_pg_graphql_access`, `issue_pg_net_access`, `pgrst_ddl_watch` and `pgrst_drop_watch`. Their definitions and all other dumpable platform objects are retained in the private full-schema snapshot below. No custom platform-object changes were inferred or made.

## Changes and verification

- Added `20261004165315_reconcile_live_schema.sql` using `supabase migration new`; left all nine previous files unchanged.
- Inserted history entries for `20260702164710` (`employees`) and `20261004165315` (`reconcile_live_schema`) in one MCP transaction, with guards for the database identity and the original eight-version history. Each entry stores the corresponding file SQL. This records already represented schema; neither SQL file was executed against live data. [Supabase documents applied-history repair as insertion of a history record.](https://supabase.com/docs/reference/cli/supabase-migration-repair)
- Replayed the migration chain in an isolated, network-disabled PostgreSQL container using the exact live image and schema-only platform dependencies. No live rows or credentials were copied. The replay verifies LPG DDL against existing Supabase dependencies; it is not a fresh-stack service-installation test.
- Ran the forward migration again under a non-superuser role without `supabase_admin` membership; it was a no-op and the schema still matched.
- On the isolated replay, passed the existing `supabase/tests/receipt_printers.sql` checks for configuration upserts, tenant/anonymous access and real POS checkout. Also passed employee creation, salary payment/readback, duplicate salary rejection, owner-level payment update/delete rejection and paid-employee deactivation. All fixtures rolled back. No browser flow or frontend build was run for this database-only change.
- Verified ten files equal ten live history records, zero application-schema differences, unchanged live schema, and identical before/after row counts and full-row checksums for every public table.

Private evidence is retained in [`.local-backups/2026-10-04-migration-audit/`](../.local-backups/2026-10-04-migration-audit/), ignored by Git: full and public schema snapshots, platform bootstrap SQL, before/after history, catalog inventories, object diffs, guarded history correction SQL, and public-data checksums. The original history backup is preserved. Audit helpers remain under ignored `.temp/migration-audit/`.

## Remaining decisions and limits

**No unresolved LPG application migration/history discrepancy remains on this local database.** Other deployments and the retained CLI rollback volumes were not changed or audited.

The later security audit still needs to decide which broad grants/default grants and callable SECURITY DEFINER functions are appropriate. Current MCP security advisories remain **71**: 32 anonymous-callable definer functions, 32 authenticated-callable definer functions, six mutable function search paths, and `permissions` with RLS but no policy. Existing policies and business logic were preserved. [Supabase advisory guidance](https://supabase.com/docs/guides/database/database-linter).

Supabase normally bootstraps the administrator default privileges. If rebuilding into an environment where those defaults are missing, their creation requires `supabase_admin`/superuser bootstrap access; the regular local `postgres` role cannot grant another administrator's defaults. No role escalation was introduced. Reproduction targets PostgreSQL 17 with Supabase roles/extensions and service schemas, not bare PostgreSQL. Historical customer data normalization was verified by its recorded SQL and final schema, not by rewriting current data.
