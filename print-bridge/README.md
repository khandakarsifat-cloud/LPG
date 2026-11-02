# Windows USB and Ethernet receipt print bridge

Run this silent Windows application on the shop computer for direct ESC/POS printing over USB or Ethernet. Its executable embeds the existing bridge and Node runtime: no separate Node.js, npm or repository checkout is required. It stays outside Docker and the VPS; local receipt bytes travel only from the browser to the shop bridge and then to the printer.

## Browser printing

**Browser printing (Chrome/system dialog)** is always available in the Dashboard printer selector and alongside the configured USB/Ethernet printer in checkout/reprint controls. It needs no bridge and lets the browser select any installed printer or Save as PDF. The choice is stored per business in this browser, leaving the tenant's shared bridge printer configuration intact. Cashiers with `receipts:print` can select browser printing without `printers:manage`. With no saved bridge printer configuration, receipts use browser printing by default.

Both methods use `get_sale_receipt` and one centralized builder/formatter to read the completed sale and current settlement in one database snapshot. Expected bottles preserve the original sale; received bottles combine checkout and all later collections by actual product identity, including excess and unexpected products. Current settlement costs, payments, due and Bottle Settled appear on reprints. Restart the bridge after updating to load the revised formatter and over-receipt validation. Browser printing builds a separate receipt-only document with escaped text and Unicode fonts, then calls the browser's print dialog; it does not print the app screen or open a popup. Select 58mm or 80mm in the app's browser receipt-width field, then choose matching printer media in the browser/OS dialog. The width is remembered per business/browser. Browser feedback confirms only that the dialog opened, including if it is later cancelled. An uncertain USB result never automatically falls back to browser printing: explicitly choose browser printing before reprinting to avoid duplicate receipts.

## Setup

1. Install the printer's Windows USB driver and confirm its queue appears in Windows Printers. The driver/port monitor must pass RAW ESC/POS data to an ESC/POS thermal printer. For Ethernet, use the Network/Ethernet Printer option with a private IPv4 address and RAW ESC/POS TCP port (usually 9100); it needs no Windows printer queue. Other protocols require browser/system printing or their installed driver.
2. Use Windows 10/11 **x64** with .NET Framework 4.8, Windows PowerShell 5.1, PrintManagement, PnpDevice, System.Drawing and Print Spooler. USB queues and Unicode fonts must be installed machine-wide. The service runs as **LocalSystem**, independently of the signed-in user; user-only printer connections/fonts are unavailable before login. Ensure SYSTEM has Print access to the installed local queue. Ethernet needs no Windows queue. ARM64 is not a separately built/tested target.
3. Run **LPG Print Bridge Setup.exe** and approve administrator elevation. It installs under `%ProgramFiles%\LPG Print Bridge`, starts **LPGPrintBridge**, and configures Automatic startup with a Spooler dependency. Windows starts it during boot, before login, and restarts it after crashes (5, 15, then repeating 60-second delays; failure count resets after a day). Normal operation has no window, console, tray icon or login task. Setup displays success/error feedback; `--quiet` suppresses its dialogs. The binaries are unsigned; verify `SHA256SUMS.txt` against your trusted release.

   The service binds `http://127.0.0.1:17891` by default and reserves loopback port **17892** for instance exclusion across service/source/portable modes. A global native mutex also excludes duplicate packaged processes across sessions. It requires no Supabase credentials.
4. In LPG Manager, open **POS Printer**, immediately left of **Open POS** on the Dashboard. Select the USB queue or Network/Ethernet Printer. For Ethernet enter its private IP, TCP port and a friendly name; use a DHCP reservation to retain its address. If Windows cannot associate a custom port monitor with its physical device, also select the matching **Physical USB device**. Serial number plus USB vendor/product IDs are preferred; the USBPRINT device instance and a hashed host/queue identity are retained as fallbacks. No hardware association is guessed from the printer name alone.
5. Select 80 mm or 58 mm paper. Defaults are **576** and **384** printable dots, respectively. Adjust this to the print head's documented width; dots must be a multiple of eight. **Auto-cut is on by default for newly selected printers**; turn it off for hardware without a cutter. Existing saved on/off choices are retained. Save Printer persists these settings for sale receipts and reprints. The tenant-keyed Supabase upsert keeps one configuration per business, including when the device is disconnected.

POS Printer separates Browser, USB printer and Ethernet printer setup. Ethernet scan results appear as selectable IP/port rows immediately below Discover Network Printers; selecting a row fills the endpoint fields. Receipt settings group paper width, printable dots and the visible auto-cut switch beside the connection fields on desktop and beneath them on phones. Print Test Receipt uses the current draft settings without saving or creating a sale; ordinary sale printing uses the saved configuration. Bridge URL/pairing settings are collapsed at the bottom. Browser mode retains its own paper width and leaves cutter control to the system driver.

### Restart, updates and state

Run **Restart LPG Print Bridge.exe** to start a stopped service or restart a running one. The launcher requests administrator elevation and has no application window. It is supplied separately and installed beside the bridge. Windows Services (`services.msc`) also works. Running the installed **LPG Print Bridge.exe** as administrator starts a stopped service and leaves a running one alone.

Run newer Setup to update. It stops the service and waits for in-flight requests, replaces the application, then starts it again. A failed update retains the previous executable for restoration. The host contains Node and every helper in a kill-on-close Windows Job Object, preventing orphan processes after a crash. No print job automatically retries after interruption.

Service data is under **`%ProgramData%\LPGManager\PrintBridge`**, protected for SYSTEM and administrators:

- `settings.json`: allowed origins, LAN/TLS pairing and diagnostics. Edit as administrator, then restart. Updates preserve it.
- `jobs\`: hashes, reservations and outcomes; no receipt content. Updates/restarts preserve every record. Never delete this folder to fix a failed job.
- `bridge.log` and `bridge.log.1`: bounded diagnostics, about 512 KiB combined. Receipt bodies and tokens are not logged.
- `runtime\<content-hash>\`: embedded runtime/assets, extracted once per version. Updates remove superseded flat runtime caches, leaving jobs intact.

Stop the old terminal/source bridge before first installation. Setup copies the installing user's `%LOCALAPPDATA%\LPGManager\PrintBridge\jobs` and optional `settings.json`, leaving originals intact. Conflicting job records block installation. If UAC uses another administrator account, first back up both directories and copy the original shop user's journal/settings into that administrator's legacy directory while bridges are stopped. Shared printer/paper/cutter configuration stays in Supabase; browser output/pairing preferences remain in that browser. Journal durability during power failure remains subject to Windows/storage write caching.

For a manual standalone run without installation, double-click **LPG Print Bridge.exe**. When no service is installed, it silently uses the current user's legacy data directory. `--portable` explicitly selects this mode; `LPG_PRINT_DATA_DIR` isolates development tests. Portable execution has no boot/crash recovery: install the service for unattended use. Do not run a source bridge alongside the installed service.

To remove the service while preserving history, run `Stop-Service LPGPrintBridge` and `sc.exe delete LPGPrintBridge` in elevated PowerShell. After it stops, the application directory can be removed. Keep ProgramData and the legacy journal for reinstalls and pending request retries.

### Local settings

The bridge allows exact loopback frontend origins on ports 3001 and 5173, plus the existing deployed app at `https://floral-dew-443b.khandakarsifat.workers.dev`. For additional origins, edit `settings.json` and restart:

```json
{"LPG_PRINT_ORIGINS":"http://127.0.0.1:5174,http://localhost:5174"}
```

Only `LPG_PRINT_ORIGINS`, `LPG_PRINT_HOST`, `LPG_PRINT_TLS_CERT`, `LPG_PRINT_TLS_KEY`, `LPG_PRINT_TOKEN` and `LPG_PRINT_DIAGNOSTICS` are accepted, all with string values. Malformed/unsupported settings fail closed. TLS paths must be absolute and readable by SYSTEM; keep keys/settings private. Setup captures these environment variables only when first creating settings. Later edits belong in `settings.json`.

Developers can still run the same bridge from source with Node.js 22.18+ and npm:

```powershell
$env:LPG_PRINT_ORIGINS = 'http://127.0.0.1:5174,http://localhost:5174'
npm run print:bridge
```

Allow local-network access for LPG Manager if the browser requests it. The bridge rejects non-loopback Host headers, unapproved origins and requests without its custom client header. It does not expose arbitrary byte printing or remote access. The browser's Supabase session/RLS protects the saved configuration and sale reads; the bridge is a local device service, not another database API.

Discovery uses Windows `Get-Printer`, independently of the saved configuration. Each modal open or Refresh sends an uncached request and enumerates Windows again. Installed queues remain listed when disconnected; the saved physical USB identity determines whether they can be used for printing. A USB or port metadata failure shows a warning while preserving the installed queue list. A queue enumeration failure is an API error, not an empty list.

If Windows sees the printer but the app cannot, run **Restart LPG Print Bridge.exe**, then Refresh. Docker does not start the Windows service. Inspect protected `bridge.log`, Services status, Spooler and machine-wide queue/SYSTEM access. Temporary discovery counts/timings use `"LPG_PRINT_DIAGNOSTICS":"1"` in settings; remove it and restart after diagnosis. Receipt content and print payloads are not logged.

A discovery `403 FORBIDDEN` occurs before Windows enumeration. The bridge log now includes whether the Host, application origin or client header was rejected; an unapproved origin message explains how to configure `LPG_PRINT_ORIGINS`. Keep this list restricted to trusted exact app origins.

## Checkout and reprinting

**Confirm & Print** first completes the existing sale RPC, clears the cart, and then loads that completed sale and the latest tenant printer configuration. **Confirm** retains the existing sale-only behavior. Print failures have separate feedback and never retry checkout. **Reprint Last Sale** in POS prints the saved sale without creating a new sale. Dashboard and Sales open the shared transaction details first. **Print receipt** opens a separate dialog with printer selection, paper width and the saved slip preview; only **Print receipt** inside that dialog sends the job. Payment collection, bottle settlement and history stay in transaction details, which remain open when the print dialog closes.

Success means Windows accepted the RAW job and the bridge did not observe an immediate queue error. It does **not** prove paper physically emerged: some driver/port monitors report success before the device finishes, and paper/cover errors may be reported late. Check the printer before reprinting after an uncertain outcome. Requests are never retried automatically. Each explicit reprint uses a new request ID.

The bridge's data directory stores only request hashes and job outcomes in `jobs`; this journal contains no receipt content, credentials or tokens. A request is reserved on disk before sending bytes. Repeating an ID returns its previous result, or an unknown-result error after interruption, rather than sending it again. Do not remove the job journal while requests are being retried.

## Implementation boundaries

| File | Responsibility |
| --- | --- |
| `src/types/receipt.ts` | Shared receipt content |
| `src/types/printing.ts`, `src/lib/printerIdentity.ts` | Settings and stable device/queue matching |
| `src/hooks/useReceiptPrinter.ts` | Tenant configuration upsert and completed-sale reads |
| `src/lib/printBridge.ts` | Browser localhost client and feedback |
| `src/lib/receipt.ts`, `print-bridge/receipt.ts` | Shared receipt formatting and bridge re-export, independent of printer discovery |
| `src/lib/browserPrint.ts`, `receiptPrintPreference.ts` | Receipt-only browser dialog and per-business browser preference |
| `print-bridge/windows.ts`, `windows.ps1` | Windows queue/USB discovery and device availability |
| `print-bridge/WindowsPrinting.cs` | Unicode raster rendering, ESC/POS encoding, Winspool RAW writes |
| `print-bridge/transport.ts` | Byte transport interface; Windows USB implementation |
| `print-bridge/server.ts`, `jobs.ts` | Restricted API and persistent request deduplication |
| `print-bridge/main.ts`, `runtime.ts` | Shared startup, instance exclusion, settings and graceful shutdown |
| `print-bridge/packaging/`, `build.mjs` | Native silent service host, process containment, installer/restart launcher and packaging |

Windows font shaping/fallback renders Unicode content to monochrome raster bands, avoiding printer-specific code pages for Bengali. ESC/POS initialization, print-area width, raster images, feed, and optional partial-cut commands are emitted. Other ESC/POS models can use the same Windows USB boundary. Ethernet sends those same printer-ready bytes over a local TCP connection. USB and Ethernet use the same saved-sale receipt layouts, validation and persistent request deduplication. A successful TCP write does not confirm physical paper output.

References: [Microsoft RAW spooler sequence](https://learn.microsoft.com/en-us/windows/win32/printdocs/sending-data-directly-to-a-printer), [WritePrinter](https://learn.microsoft.com/en-us/windows/win32/printdocs/writeprinter), [ESC/POS raster command](https://download4.epson.biz/sec_pubs/pos/reference_en/escpos/gs_lv_0.html). GS v 0 is widely used by compatible thermal printers but is a legacy command; compatibility depends on the printer firmware.

## Ethernet discovery, status and testing

Choose **Network/Ethernet Printer**, then an adapter subnet and **Discover Network Printers**. The bridge probes the selected port without sending data, using 16 concurrent connections and a 350 ms probe timeout. It scans at most 254 hosts within one directly attached private adapter subnet, respecting narrower subnet masks. It does not sweep arbitrary remote networks, identify every model, or prove that an open port speaks ESC/POS. VPN/guest VLAN/firewall isolation can prevent discovery. Manual private IP/port configuration remains available for routed printer networks. Only canonical RFC1918 IPv4 addresses and integer ports 1024–65535 are accepted; public addresses, hostnames, metadata addresses and loopback printer targets are rejected.

**Test Connectivity** opens/closes TCP without printing and reports reachability, refusal or timeout. **Print Test Receipt** explicitly dispatches a marked test slip through the existing Unicode renderer; it creates no sale, payment or stock movement. Save and reload the chosen printer. Normal checkout and saved-sale reprinting then use this tenant configuration. The browser's output choice is browser or bridge; the saved printer selects USB or Ethernet.

Test the paper width, ESC/POS raster compatibility and cutter on actual hardware. TCP reachability cannot universally report paper-out, cover, cutter or physical completion status. An uncertain job never retries or falls back automatically. Check the printer before explicitly reprinting.

## Android/PWA and another browser device

The default bridge binds only `http://127.0.0.1:17891`. On Android that address refers to the phone. Access through a Windows shop host needs explicit secure LAN setup:

1. Give the host a stable private IP. Obtain a PEM certificate/key with that IP in its subject alternative names and a chain trusted by every browser device. Provision this through the shop's certificate/IT setup; bypassing certificate errors is unsupported.
2. In protected `settings.json`, set `LPG_PRINT_HOST` to that private IP, `LPG_PRINT_TLS_CERT` and `LPG_PRINT_TLS_KEY` to absolute local PEM paths, and `LPG_PRINT_TOKEN` to a privately generated random token of at least 32 characters. Restart using the launcher. Never commit the token/key. The service refuses a LAN listener without all four. Restrict firewall access to the trusted shop network and keep the computer awake.
3. On each phone/browser, open **POS Printer → Print Bridge connection (this device)**. Enter `https://<bridge-private-IP>:17891` and its pairing token, then **Save Bridge & Refresh**. These settings stay in that browser; they are never saved to Supabase or sent through the VPS. Grant local-network permission when prompted. The bridge enforces exact allowed application origins, the configured Host and the pairing token (constant-time comparison). CORS preflights disclose no receipt data.
4. Configure the printer, test connectivity and explicitly print a test slip. The bridge IP and printer IP are separate addresses. USB devices still use the Windows host's existing physical identity matching; Ethernet uses the saved private endpoint.

See [Chrome's local-network access policy](https://developer.chrome.com/blog/local-network-access). Browser/OS policy, permissions, certificate trust, Wi-Fi isolation and Android print-service support vary. When the bridge cannot be reached, select **Browser printing (Chrome/system dialog)** and an installed system/network print service or PDF. No universal browser discovery, raw browser TCP or VPS receipt relay is assumed.

Update with Setup on the shop host. Web/database deployment does not update shop executables, install certificates or open firewalls. Physical Android/PWA certificate trust and paper/cutter output remain hardware acceptance boundaries.

## Checks

```powershell
npm run build
npm run print:check
npm run print:test
npm run print:package
npm run print:standalone:test
npx eslint src/hooks/useReceiptPrinter.ts src/lib/printBridge.ts src/lib/printerIdentity.ts src/lib/completeSale.ts src/types/printing.ts src/types/receipt.ts src/components/dashboard/PrinterConfigModal.tsx src/components/pos/ReceiptPrintModal.tsx src/pages/Dashboard.tsx src/pages/POS.tsx print-bridge/*.ts
```

`print:package` builds artifacts in ignored `print-bridge/release/`. Build prerequisites are Node 22.18+, `npm ci`, Windows PowerShell and the Windows .NET Framework C# compiler. It downloads pinned Node **24.20.0** from nodejs.org, checks a pinned SHA256, bundles the existing bridge using pinned Rolldown, and compiles GUI-subsystem executables. Node's full redistribution license is included. No build dependency runs on the shop computer. The host and Node idle between requests; PowerShell/render helpers run on demand. Embedded runtime disk size and transient rendering memory are the cost of preserving the existing engine.

Bridge tests cover formatting, paper validation, USB disconnection/matching, checkout/print failure separation, persistent deduplication and real Windows raster rendering for both profiles. Standalone tests launch the actual exe outside the checkout with Node removed from PATH, use Windows discovery/a private TCP receiver and the existing browser client, prevent duplicates, kill/restart the host, preserve settings/journals and reject invalid settings/origins/targets. They dispatch no physical USB or Ethernet printer jobs. Run packaging tests with no other bridge on its ports. The SQL integration check in `supabase/tests/receipt_printers.sql` uses rolled-back fixtures.

To verify the actual installed service, run the supplied `verify-service.ps1` from an **elevated Windows PowerShell** in the release directory:

```powershell
.\verify-service.ps1 -ReleaseDirectory $PWD.Path -ResultFile "$PWD\service-verification.txt"
```

This installs/updates the service, checks Automatic/LocalSystem/Spooler/recovery registration, discovers queues and renders a receipt to a private TCP fixture in Session 0, kills only the bridge runtime/host to check Windows recovery/deduplication, runs the manual restart launcher, and reinstalls to check exact settings/job-reservation preservation. It removes only its own fixture job records and leaves the service installed/running. It dispatches no physical print jobs and does not reboot Windows. Run on the development shop computer while receipts are idle. An actual reboot/before-login observation remains a separate acceptance check.

`tests/printing.browser.cjs` runs through `playwright-cli run-code` on local Vite using isolated Auth/API/device fixtures and intercepted browser print calls. It checks stopped-bridge browser selection, preference persistence, cashier access, saved-sale reprinting and the retained USB path without physical dispatch.

Interactive acceptance checks still require a browser: open/refresh the modal, save and reload configuration, update the same row, disconnect/reconnect the device, checkout with printing, and reprint the completed sale. On 2026-10-02, Windows discovery and RAW dispatch of one marked test receipt were exercised; the same request returned the original Windows job without a second dispatch. The user confirmed that the receipt printed correctly, including Bengali text and cutting. Interactive browser flows were not observed by the agent because no browser was exposed by the computer-use connection.

## Payment receipts and paper layouts

Checkout drafts, saved-sale previews, browser receipts and USB rendering share `src/lib/receipt.ts`. The 58mm profile stacks product names, quantity/type and price/amount; the 80mm profile aligns a product total beside its name and puts quantity/unit price beneath it. Their font sizes, usable widths and spacing differ. USB chooses the configured paper width and printable dots; do not infer paper width from queue/driver names. Browser previews use the same content and 48/72mm printable widths; the OS dialog still controls its physical media.

Completed receipts read persisted payment wallet names, methods and amounts, total paid and remaining due. Later collections are labeled separately; reprints reflect current persisted settlement, while checkout snapshots remain in SQL. Paid amounts lacking method attribution are explicit `unattributed_paid` values. The bridge always requires paid/due/payment values and reconciles attributed plus unattributed paid amounts; an old tracking flag cannot disable validation. Neither printing nor reprinting creates a payment or repeats checkout. Bridge validation checks payment totals, and job deduplication/uncertain-outcome behavior is unchanged. Restart the host bridge after updating its code.

Bottle receipts show original expectations and all actual checkout/later products independently, with outstanding quantity clamped at zero. Update the bridge with Setup; its validator reconciles each list against its own total, including over-receipts. Additional Settlement Cost increases the customer slip's current payable/due; historical business expenses retain their original Finance accounting.
