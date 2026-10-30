# Attendance acceptance — 2026-10-30

> This report records the original integration through `20261030033603`. Its mapping, cutoff and source-IP behavior was superseded by the [Employees/Attendance/Settings update](2026-10-30-employees-attendance-settings-verification.md); use the current [attendance guide](../modules/attendance.md) for operational rules.

## Deployment

- Primary VPS `/opt/lpg`, existing API HTTPS host and existing Cloudflare Worker. Applied forward migrations `20261030025827` and `20261030033603` through the normal exact-approval/checksum/validated-backup workflow; historical migrations were unchanged.
- 41 migrations, 46 public tables and zero public tables without RLS. Eleven backend services healthy. Only the receiver and Caddy required recreation for the integration; no Supabase container recreation was needed. Receiver observed at about 21 MiB under a 96 MiB ceiling. Public listeners remain SSH/22 and Caddy/80/443; API gateway/Studio remain loopback.
- Existing uncommitted employee UI changes were preserved. No dependencies, Edge Functions or public device port were added. The standalone listener prototype was removed.

## Automated and authenticated checks

- TypeScript/Vite build and source ESLint passed. Five receiver tests include the real device's eleven-column format; its regression was observed failing before the parser correction, then passing.
- Ten JavaScript deployment tests and eighteen Python deployment tests passed, including receiver addition without core-service recreation and privately generated role-scoped JWTs.
- Rolled-back SQL on the actual VPS passed event-time/timezone conversion, out-of-order/late uploads, repeated scans, retry deduplication, future-clock warnings, historical cutoff rules, today's cutoff recalculation, provisional/finalized days, mapping, denied table/ingestion access and tenant isolation. The whitespace reassignment regression failed before the forward fix and passed afterward.
- Real Auth/PostgREST/HTTPS acceptance used independently created fixture businesses. Concurrent upload retries, polling/options, source-header spoof rejection, disabled-device reconnection, unmapped pagination and tenant isolation passed. Normal authenticated published browser flows passed overview, history/activity, enrollment linking, cutoff saves and device disable/re-enable at 320/375/812/1440px with light/dark checks. Existing employee fixtures also passed payment/recovery flows at 320/390/768/1440px.
- Fixture cleanup retained the burner account. Stock, financial, employee and prior attendance evidence/configuration fingerprints were preserved. Normal real-device heartbeat/append activity was allowed while those checks ran.

## Physical MB20-VL

- Owner supplied the serial ending `0679`, LAN address `192.168.0.111`, and server address `api.lpg.144.79.249.4.sslip.io:443`. Actual Caddy/receiver evidence established **TLS 1.3**, serial identity, authenticated initialization and attendance uploads with that exact address format. HTTPS and the shared TLS configuration were not weakened.
- Owner explicitly authorized registration in the existing development business and made a fresh scan. Six genuine device events were saved, without fabricated requests under that machine's serial. Queued events arrived as a five-record batch, followed by a real-time one-record upload; both were acknowledged after database commit.
- Fresh device timestamp **09:30:38 Asia/Dhaka** was retained as `2026-10-30T03:30:38Z`, received at `03:30:38.754026Z`, with no clock warning. An earlier **08:52:42** scan retained its original time when received at **09:30:36.472326**. This verifies event time rather than arrival-time attendance and actual queued retry synchronization.
- Normal authenticated desktop/phone Settings showed the real terminal, accepted upload and unmapped **User ID 1**. It was intentionally not assigned to an arbitrary employee. Link that ID in the correct employee profile; existing scans will become visible there.
- LAN ping worked while TCP 4370 refused a connection. Outbound ADMS on 443 worked independently; no inbound 4370 port was opened.

## Boundaries

A deliberate physical power-off/internet-disconnection trial and a real post-15:00 departure were not performed. Cutoff/midnight/late-sync semantics were verified with SQL and isolated real API fixtures. Serial plus source-IP restrictions are not cryptographic terminal identity. Identical same-second scans in separate packets cannot be distinguished from retries by this protocol. See [attendance rules, security and operations](../modules/attendance.md).
