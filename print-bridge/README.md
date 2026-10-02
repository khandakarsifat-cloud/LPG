# Windows receipt print bridge

Run this service on the same Windows computer as the browser and USB printer. It stays outside Docker; the frontend and Supabase remain in Compose.

## Setup

1. Install the printer's Windows USB driver and confirm its queue appears in Windows Printers. The driver/port monitor must pass RAW ESC/POS data to an ESC/POS thermal printer. PDF, file, serial, network and virtual queues are not supported in this version.
2. Install Node.js **22.18 or newer** (native TypeScript execution; no bridge dependencies). Windows PowerShell 5.1, PrintManagement, PnpDevice, .NET Framework/System.Drawing and the Windows Print Spooler must be available. No administrator access is normally needed for discovery or printing.
3. From the repository root, start the bridge:

   ```powershell
   npm run print:bridge
   ```

   Leave it running while using POS. It binds only `http://127.0.0.1:17891`. It needs no Supabase keys, passwords or machine secrets. Startup is manual; this version does not install a Windows service or scheduled task.
4. In LPG Manager, open **Receipt Printer**, immediately left of **Open POS** on the Dashboard. Select the USB queue. If Windows cannot associate a custom port monitor with its physical device, also select the matching **Physical USB device**. Serial number plus USB vendor/product IDs are preferred; the USBPRINT device instance and a hashed host/queue identity are retained as fallbacks. No hardware association is guessed from the printer name alone.
5. Select 80 mm or 58 mm paper. Defaults are **576** and **384** printable dots, respectively. Adjust this to the print head's documented width; dots must be a multiple of eight. Enable auto-cut only for hardware with a cutter, then save. The tenant-keyed Supabase upsert keeps one configuration per business, including when the device is disconnected.

The bridge allows exact loopback frontend origins on ports 3001 and 5173. For another local frontend port, set a comma-separated list of additional exact loopback origins before starting it:

```powershell
$env:LPG_PRINT_ORIGINS = 'http://127.0.0.1:5174,http://localhost:5174'
npm run print:bridge
```

Allow local-network access for LPG Manager if the browser requests it. The bridge rejects non-loopback Host headers, unapproved origins and requests without its custom client header. It does not expose arbitrary byte printing or remote access. The browser's Supabase session/RLS protects the saved configuration and sale reads; the bridge is a local device service, not another database API.

Discovery uses Windows `Get-Printer`, independently of the saved configuration. Each modal open or Refresh sends an uncached request and enumerates Windows again. Installed queues remain listed when disconnected; the saved physical USB identity determines whether they can be used for printing. A USB or port metadata failure shows a warning while preserving the installed queue list. A queue enumeration failure is an API error, not an empty list.

If Windows sees the printer but the app cannot, first check that the host bridge is running: Docker does not start it. Start `npm run print:bridge`, leave it running, and Refresh; no configuration/data change is needed. Startup/listener and enumeration failures are logged. For temporary discovery request/response counts and timings, set `$env:LPG_PRINT_DIAGNOSTICS = '1'` before starting the bridge. Clear that variable or start a fresh terminal afterward to return to normal logging. Receipt content and print payloads are not logged.

## Checkout and reprinting

**Confirm & Print** first completes the existing sale RPC, clears the cart, and then loads that completed sale and the latest tenant printer configuration. **Confirm** retains the existing sale-only behavior. Print failures have separate feedback and never retry checkout. **Reprint Last Sale** in POS and **Print Receipt Again** in Dashboard sale details print the saved sale without creating a new sale.

Success means Windows accepted the RAW job and the bridge did not observe an immediate queue error. It does **not** prove paper physically emerged: some driver/port monitors report success before the device finishes, and paper/cover errors may be reported late. Check the printer before reprinting after an uncertain outcome. Requests are never retried automatically. Each explicit reprint uses a new request ID.

The bridge stores only request hashes and job outcomes under `%LOCALAPPDATA%\LPGManager\PrintBridge\jobs`; it stores no receipt content, credentials or tokens. A request is reserved on disk before sending bytes. Repeating an ID returns its previous result, or an unknown-result error after interruption, rather than sending it again. Do not remove the job journal while requests are being retried.

## Implementation boundaries

| File | Responsibility |
| --- | --- |
| `src/types/receipt.ts` | Shared receipt content |
| `src/types/printing.ts`, `src/lib/printerIdentity.ts` | Settings and stable device/queue matching |
| `src/hooks/useReceiptPrinter.ts` | Tenant configuration upsert and completed-sale reads |
| `src/lib/printBridge.ts` | Browser localhost client and feedback |
| `print-bridge/receipt.ts` | Receipt content formatting, independent of printer discovery |
| `print-bridge/windows.ts`, `windows.ps1` | Windows queue/USB discovery and device availability |
| `print-bridge/WindowsPrinting.cs` | Unicode raster rendering, ESC/POS encoding, Winspool RAW writes |
| `print-bridge/transport.ts` | Byte transport interface; Windows USB implementation |
| `print-bridge/server.ts`, `jobs.ts` | Restricted API and persistent request deduplication |

Windows font shaping/fallback renders Unicode content to monochrome raster bands, avoiding printer-specific code pages for Bengali. ESC/POS initialization, print-area width, raster images, feed, and optional partial-cut commands are emitted. Other ESC/POS models can use the same Windows USB boundary. Ethernet transport is not implemented; a future transport can consume the same printer-ready bytes.

References: [Microsoft RAW spooler sequence](https://learn.microsoft.com/en-us/windows/win32/printdocs/sending-data-directly-to-a-printer), [WritePrinter](https://learn.microsoft.com/en-us/windows/win32/printdocs/writeprinter), [ESC/POS raster command](https://download4.epson.biz/sec_pubs/pos/reference_en/escpos/gs_lv_0.html). GS v 0 is widely used by compatible thermal printers but is a legacy command; compatibility depends on the printer firmware.

## Checks

```powershell
npm run build
npm run print:check
npm run print:test
npx eslint src/hooks/useReceiptPrinter.ts src/lib/printBridge.ts src/lib/printerIdentity.ts src/lib/completeSale.ts src/types/printing.ts src/types/receipt.ts src/components/dashboard/PrinterConfigModal.tsx src/components/dashboard/SaleDetailsModal.tsx src/pages/Dashboard.tsx src/pages/POS.tsx print-bridge/*.ts
```

Bridge tests cover formatting, paper validation, device disconnection/matching, checkout/print failure separation, persistent deduplication, and real Windows raster rendering for both profiles. They do not dispatch physical print jobs. The SQL integration check in `supabase/tests/receipt_printers.sql` uses isolated transaction fixtures and rolls them back.

Interactive acceptance checks still require a browser: open/refresh the modal, save and reload configuration, update the same row, disconnect/reconnect the device, checkout with printing, and reprint the completed sale. On 2026-10-02, Windows discovery and RAW dispatch of one marked test receipt were exercised; the same request returned the original Windows job without a second dispatch. The user confirmed that the receipt printed correctly, including Bengali text and cutting. Interactive browser flows were not observed by the agent because no browser was exposed by the computer-use connection.
