# Whole-system cloud recovery

This is recovery of **every business together**. Do not run restore against an
existing LPG database or populated volume. Never run installation bootstrap on
a recovered cluster. Keep the original VPS isolated until cutover is reviewed.

Business deletion in Platform Admin uses the same full-backup and isolated restore
verification pipeline before removing files or data. Its root-owned worker holds
the existing deployment lock, so deployment/backup/deletion do not overlap. Track
progress and resume failed jobs in Admin → Businesses; a retry requires renewed
password and typed DELETE confirmation. Private jobs live in
`app_private.business_deletions` and `backups/cloud/business-deletions/`. A stopped
job must remain fenced; never reactivate it or manually disable source/FK guards.
The retained recovery point restores the whole system under this guide, not just
the deleted tenant. Normal backup retention still applies.

## Recovery kit (keep outside the VPS)

The private kit must contain `restic-password`, `rclone.conf`, this guide and the
`deploy/backup` source directory (including its Dockerfile). Save two secure
copies, for example an encrypted password manager attachment and an encrypted
offline drive. The password is random, root-only and **never in cloud backups**.
Losing it makes the cloud repository irrecoverable. Keep access to the original
Google account and its MFA recovery methods independently.

The workstation export helper is `node deploy/backup-kit.mjs`. It writes only to
`%LOCALAPPDATA%\LPG\Recovery\google-drive`, with inheritance disabled and access
limited to the current Windows identity. Run it after connecting/reconnecting
Drive, and copy that directory to the second secure location. Never attach the
kit to chat, Git, email, public Storage or an application ticket.

Account connection/reconnection/disconnection is in Superadmin → Backups.
Web OAuth uses the existing private client and this authorized redirect:
`https://api.lpg.144.79.249.4.sslip.io/backups/v1/oauth/callback`.
The external OAuth consent application must remain **In production**; testing
tokens can expire after seven days. `drive.file` scopes access to this app's
files. Connect explicitly validates a refresh token and caches account/quota.
Routine status reads never contact Google. Disconnect removes VPS tokens and
leaves backups intact; Google account settings can revoke the grant completely.

## Schedule, consistency and retention

`lpg-backup.timer` starts at **02:00 Asia/Dhaka daily**, without daytime catch-up.
Automatic jobs start from 02:00–02:14 and may finish later. No hourly synchronization.
An authorized superadmin may choose **Create Full Backup** for an immediate full
capture, cloud upload and isolated restore verification. It uses the same worker,
deployment lock, encryption and retention, without changing the timer. The server
job continues after browser closure; reopening Backups reconnects to its measured
stage progress. Percentages describe the current stage. Unknown totals remain
indeterminate. Processed bytes, measured upload network traffic and final compressed new-data bytes are distinct counters. Compression runs inside pgBackRest and Restic. **Request backup**
continues to queue a capture for the next scheduled window.

Recovery points carry a data-generation identifier. After an authorized business
reset, old points are labelled as previous-generation recovery and excluded from
current backup health. The pre-reset snapshot stays protected until the new full
baseline is restored and verified against the current migration and backend-source fingerprints. The isolated restore tool rejects a different
generation unless `--allow-previous-generation` is explicitly provided.
Never use an old generation to replace the current populated system.

Export the private recovery kit again after a baseline reset. It contains the
current `generation.json`; install that file at
`/opt/lpg/backups/cloud/generation.json` on a replacement host before verification.
Keep the previous kit with its protected recovery copy for deliberate isolated
historical recovery.

On the 1st, or the first successful capture after a missed month boundary,
pgBackRest creates a full backup. All other nights use block incremental backup.
Local WAL archiving is continuous, synchronous and local only. `archive-copy`
includes the WAL required for each backup's consistency in that backup set.
The archive retains the latest incremental WAL range; this deliberately does
not promise arbitrary between-backup PITR. A failed archiver retains WAL in
PostgreSQL; it never acknowledges/discards an unarchived WAL segment.

Storage is stopped while objects, the physical database backup and essential
configuration are captured; it is restarted and health-checked in `finally`.
Normal database transactions continue. The resulting physical backup restores
to its consistent backup end, while Storage metadata/objects remain unchanged.
Uploads/downloads of images are temporarily unavailable during this capture.
The shared deployment lock prevents configuration changes and overlapping jobs.
An archive `flock` freezes the repository just long enough to hard-link immutable
data/WAL and copy mutable manifests into a sealed capture. Restic backs up this
sealed capture, **never the active repository**. No `rclone sync` is used.

Local pgBackRest retains one full chain. Cloud Restic snapshots independently
retain the complete chain and WAL captured with each recovery point. Cloud
retention keeps the latest point on each of the last 30 Dhaka calendar dates,
plus the latest 12 monthly full points. Monthly full points are explicitly
tagged, not inferred from an arbitrary month's last incremental. A full's first
snapshot does not contain obsolete previous-month chains. Dependencies shared
by retained snapshots remain deduplicated. Retention only runs after a verified
new point; Restic forget/prune owns cloud deletion. It never operates on another
application's snapshots. Missed nights cannot be reconstructed or called valid.

Restic repository v2 encrypts/authenticates contents and metadata, compresses and
deduplicates. pgBackRest also uses low-level Zstandard and block incremental
files; incremental cost depends on changed blocks, rewrites and WAL, not just
new rows. One process, idle IO, low priority, two rclone connections and 8 MiB/s
upload limiting reduce interference. Backup CPU/RAM limits do not reserve RAM.

## Fresh VPS recovery (no original VPS needed)

Use a clean **x86-64 Linux** host with Docker/Compose, Python 3, restic ≥0.16.4
and rclone ≥1.60.1. Reserve space for the downloaded repository, restored PGDATA,
Storage and verification (at least 3× the database plus file size and free WAL
headroom). Keep all public ingress blocked during restore. Use a trusted SSH
key and host verification. Commands below run in a root shell on the new host.

1. Transfer the kit privately to `/root/lpg-recovery-kit`, mode 700 directory,
   mode 600 password/config. Do not display it. Restore only a **specific**
   snapshot after listing them:

   ```sh
   umask 077
   export RESTIC_PASSWORD_FILE=/root/lpg-recovery-kit/restic-password
   export RCLONE_CONFIG=/root/lpg-recovery-kit/rclone.conf
   export RESTIC_REPOSITORY=rclone:lpg-drive:LPG-System-Recovery/restic
   restic snapshots --tag lpg-system
   restic check --read-data
   restic restore SNAPSHOT_ID --target /root/lpg-restored --verify
   ```

   Recovery is an explicit operator action and may access Drive outside the
   normal nightly schedule. If the saved token was revoked, reconnect the
   original Google account using the same OAuth client; do not initialize a
   replacement repository. A new host/domain requires updating OAuth redirects
   before panel reconnection. The kit's refresh token normally works without
   the old VPS or callback endpoint.

2. The restored capture is
   `/root/lpg-restored/opt/lpg/backups/cloud/capture`. Call this directory
   `CAPTURE` below. Inspect `manifest.json` (no credentials); it contains the
   exact pgBackRest backup label, image and backend source checksums. Verify
   the restored Storage/configuration/volume SHA256s using `file-hashes.json`.
   Restic `--verify` has already checked restored file contents against encrypted
   repository metadata. Rebuild the image with the kit Dockerfile:

   ```sh
   docker build -t lpg-postgres-backup:17.6.1.140-pgbackrest2.57.0 /root/lpg-recovery-kit/backup
   ```

3. Copy `CAPTURE/config/` to a new `/opt/lpg` directory, preserving permissions. Restore the non-secret files from `CAPTURE/backup-state/` into `/opt/lpg/backups/cloud/` as well.
   **No `.env` generation or bootstrap.** Create empty named volumes only on this
   confirmed fresh host: `lpg_db_data`, `lpg_storage_data`, `lpg_db-config`,
   `lpg_caddy-data`, `lpg_caddy-config`. Locate their mountpoints with
   `docker volume inspect --format '{{.Mountpoint}}' VOLUME`.
   Copy `CAPTURE/storage/.` to the Storage volume and `CAPTURE/volumes/VOLUME/.`
   to each of the other three saved configuration/TLS volumes using `cp -a`.
   PGDATA must remain empty. Do not copy the capture's repository into PGDATA.

4. Restore physical PostgreSQL (replace paths and `BACKUP_LABEL` with manifest
   values; mount the **new empty** PGDATA volume):

   ```sh
   docker run --rm --network none --user 0 \
     -v CAPTURE/pgbackrest:/repo:ro -v lpg_db_data:/restore \
     --entrypoint pgbackrest lpg-postgres-backup:17.6.1.140-pgbackrest2.57.0 \
     --stanza=lpg --repo1-path=/repo --pg1-path=/restore \
     --set=BACKUP_LABEL --type=immediate --target-action=promote restore
   ```

   Ensure restored PGDATA is owned by image UID:GID `100:101`, mode 700.
   Start only the database on an internal recovery network, with saved database
   environment, restored `db-config`, repository mounted at `/repo:ro`,
   `archive_mode=off`, `cron.launch_active_jobs=off`, and
   `restore_command=pgbackrest --stanza=lpg --repo1-path=/repo archive-get %f "%p"`.
   See the executable isolated drill in `restore.py` for the exact Docker run
   arguments. Wait for `pg_is_in_recovery() = false` before starting dependents.

5. Verify all databases (including `_supabase`), roles, schema/RLS/grants,
   migrations, business records, balanced journals and FIFO. Restore preserves
   the entire cluster including Auth identities, hashes, roles and privileges;
   do not replay migrations already recorded. Check the current retained component-lab original-operation manifest. Test the burner login, private Storage
   object downloads and cross-tenant denial using real restored Auth/PostgREST.
   Compare independent source operations and savepoints/full journal positions.
   The scheduled drill performs physical recovery, journal balance checks,
   SHA256 inventories and isolated Auth/Storage service health; these checks
   do not replace all application acceptance or physical/provider tests.

6. Keep original signing keys/JWKS, database password, Storage credentials,
   realtime/vault/encryption keys, generated account/attendance credentials and
   db-config volume. Review `.env` for the replacement host: API domain, Site
   URL, redirect allowlist and public endpoint must match the final frontend.
   Existing deployment tooling deliberately targets the original IP, so review
   that target and `deploy/docker-firewall.sh` for the replacement IP before
   subsequent routine deployment. Recreate UFW/Docker ingress protection from
   `deploy/production-vps.md`; do not copy old-IP exceptions unchanged.

7. Put the Restic password and rclone configuration in the new root-only
   `/opt/lpg/deploy/backup-secrets`. Initialize a new local pgBackRest repository
   and its lock/directory owners via `backup/install.py`; do not overwrite cloud
   identity or initialize a new cloud repository. On the recovered cluster
   remove recovery-only command overrides, enable normal archiving and validate
   `pgbackrest stanza-create` / `check`. Confirm encryption keys are still saved
   off-host. Retain the original snapshot during recovery.

8. Start the pinned internal services with saved configuration, then the gateway
   and Caddy after reviewing TLS/DNS and ingress. Test authenticated API and
   frontend paths before cutover. Reactivate pg_cron only on the selected primary
   after auditing its restored jobs. Update/publish the Worker with the new API
   URL and original public anon key. Disconnect/isolate the old primary before
   enabling the new primary's scheduled jobs and backup timer.

## Operations and failures

`systemctl status lpg-backup.timer lpg-backup-control.service` and the panel show
state; `journalctl -u lpg-backup.service` contains sanitized errors. Commands never
print credentials/raw SQL. Existing deployment backups and legacy encrypted
bundles are preserved; the old daily bundle timer is replaced. Do not bulk-delete
legacy archives without review. `deploy/restore-check.py` remains solely for
reading legacy bundles, not the new cloud recovery path.

Interrupted uploads keep the sealed capture and reuse the point tag; completed
Restic packs are reused on retry. There is one job/deployment lock, three bounded
retries, then retry the next night. A failed snapshot, verification, quota check,
Storage restart or drill never reports overall success. A private pause marker
and systemd stop/boot handlers resume Storage after an interrupted capture;
they act only on a pause recorded by this backup engine. Restic checks metadata
nightly and rotates data verification in sevenths; full recovery downloads run
on monthly/first successful points and at least every 31 days. Pruning is followed
by a structural check. A large drill may extend the nightly job.

Keep enough free disk for WAL and a restore drill. A failed job does not prune
cloud snapshots. Do not reset migration history, delete live volumes or disable
WAL safety to clear a failure. The data-loss objective is approximately one day
**while nightly uploads succeed**; consecutive failures increase it. There is no
independent alert provider in this project, so someone must monitor backup health.
