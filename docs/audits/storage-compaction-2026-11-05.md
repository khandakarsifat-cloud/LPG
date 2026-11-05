# Physical storage preservation gate

Primary development VPS: `144.79.249.4`, `/opt/lpg`, PostgreSQL 17. Maintenance completed on 2026-11-05 Asia/Dhaka. Azure was untouched.

The initial full logical restore exposed two orphan Auth identities and two account-security rows belonging to two already-cleaned disposable rebate tests. The original users, profiles and tenants were absent. After explicit approval, only those four remnants were deleted. The complete dump then restored with foreign keys enabled. The earlier dump is retained.

## Measured result

| Measurement | Bytes |
| --- | ---: |
| Database before compaction | 4,643,802,259 |
| Database immediately after compaction | 36,662,419 |
| Database space reclaimed | 4,607,139,840 |
| Retained gate/rehearsal/recovery files at verification | 16,321,191 |

Backup bytes are retained disk usage, not subtracted from database size or described as deleted. PostgreSQL WAL and existing whole-system/cloud backups are separate from these database-size figures.

`deploy/compact-storage.py` restores a full dump into a prefix-checked disposable database, compares all 137 table counts/content fingerprints and index/constraint definitions, rehearses targeted commands and checks preservation again. PostgreSQL reparses seven legacy expressions into equivalent cast/parenthesis formats during restore; only these named, checked parser normalizations are allowed for the restore comparison. The live before/after comparison is exact.

The live write pause used the deployment/backup lock, disabled scheduled jobs, stopped the previously running application services and drained client sessions. A fresh database dump and roles backup were captured after quiescence. Fifteen tables had their indexes rebuilt; only `sale_items` needed a heap rewrite, justified by its measured size against the identical restored data. All 377 indexes and 596 constraints were retained. Statistics were refreshed and prior services/schedules restored.

The paused baseline and final database matched exactly across all captured records, including Auth credentials, stock/FIFO, payments, request identities, journals and retained acceptance evidence. At that recovery point there were 128 journal headers, 295 lines, 47 wallet movements, 9 sales and 20 sale items. No historical journal was rewritten.

Private recovery evidence is retained at `/opt/lpg/backups/storage-compaction-20261104T195235Z/`; do not publish its dumps, roles or row fingerprints.

## Verification

- Full database restore, foreign keys and matching record fingerprints passed before live maintenance.
- Exact live before/after record, index and constraint comparison passed; every index remained valid and ready.
- All twelve established backend services resumed; database, Auth, REST, gateway, Storage and supporting service health passed.
- `npm run accounting:db:test` passed before and after compaction on owned disposable clones: source/FIFO, exchange/returns, treasury, payroll/dependent modules, rebates, lending, visibility, tenancy, concurrent retries, oversell prevention and savepoint/full-journal equality.
- `node supabase/tests/core-security-api.mjs --vps` passed actual Auth/PostgREST role/tenant denial checks and immutable journal boundaries, preserving retained business stock. Its newly created fixture was removed through its scoped cleanup.

This gate authorizes proceeding to the event-accounting implementation. It does not claim that the journal redesign is implemented, that row-count reductions already occurred, or that load capacity has been benchmarked.
