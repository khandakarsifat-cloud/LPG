import { useEffect, useRef, useState, type FormEvent } from 'react';
import { createPortal } from 'react-dom';
import { Check, Monitor, Network, Printer, RefreshCw, Scissors, Usb, X } from 'lucide-react';
import toast from 'react-hot-toast';
import { useBrowserPaperWidth, useNetworkPrinterDiscovery, useNetworkPrinterTest, usePrinterDiscovery, usePrinterTestReceipt, useReceiptPrinter, useReceiptPrintMethod, useSaveReceiptPrinter } from '../../hooks/useReceiptPrinter';
import { PAPER_PROFILES, type PrinterIdentity, type ReceiptPrinterConfig } from '../../types/printing';
import { findPrinterQueue, findUSBDevice, isPrinterIPAddress } from '../../lib/printerIdentity';
import { readBridgeSettings, saveBridgeSettings } from '../../lib/printBridge';
import './printer-config.css';

type PrinterMode = 'browser' | 'windows_usb' | 'network_tcp';
const methods = [
  { value: 'browser', title: 'Browser', detail: 'System dialog or PDF', icon: Monitor },
  { value: 'windows_usb', title: 'USB printer', detail: 'Windows printer driver', icon: Usb },
  { value: 'network_tcp', title: 'Ethernet printer', detail: 'Direct network printing', icon: Network },
] as const;

export function PrinterConfigModal({ onClose }: { onClose: () => void }) {
  const saved = useReceiptPrinter(); const discovery = usePrinterDiscovery(); const save = useSaveReceiptPrinter();
  const preference = useReceiptPrintMethod(); const browserPaper = useBrowserPaperWidth();
  const networkScan = useNetworkPrinterDiscovery(); const connectivity = useNetworkPrinterTest(); const testReceipt = usePrinterTestReceipt();
  const [subnet, setSubnet] = useState('');
  const [bridge, setBridge] = useState(readBridgeSettings);
  const [draftMode, setDraftMode] = useState<PrinterMode | null>(null);
  const [draft, setDraft] = useState<Omit<ReceiptPrinterConfig, 'tenant_id'> | null>(null);
  const [browserWidth, setBrowserWidth] = useState<58 | 80 | null>(null);
  const busy = save.isPending || testReceipt.isPending || connectivity.isPending || networkScan.isPending;
  const dialogRef = useRef<HTMLDivElement>(null);
  const scan = discovery.mutate;
  const config = draft ?? saved.data;
  const mode = draftMode ?? (preference.method === 'browser' || !config ? 'browser' : config.printer.transport);
  const browser = mode === 'browser';
  const selected = config?.printer.transport === mode ? config : null;
  const current = selected && discovery.data ? findPrinterQueue(selected.printer, discovery.data) : undefined;
  const devices = discovery.data?.usb_devices ?? [];
  const usbPrinters = discovery.data?.printers.filter(printer => printer.transport === 'windows_usb') ?? [];
  const networkPrinters = networkScan.data?.printers ?? [];
  const scanSubnet = subnet || discovery.data?.network_subnets?.[0] || '';
  const devicePresent = Boolean(selected?.printer.device && findUSBDevice(selected.printer.device, devices)?.present);
  const unavailable = Boolean(mode === 'windows_usb' && selected && discovery.isSuccess && (!current?.available || !devicePresent));
  useEffect(() => { scan(); }, [scan]);
  useEffect(() => {
    const previous = document.activeElement; dialogRef.current?.focus();
    const handleKey = (event: KeyboardEvent) => {
      if (event.key === 'Escape' && CSS.supports('appearance', 'base-select') && event.target instanceof Element && event.target.closest('select')?.matches(':open')) return;
      if (event.key === 'Escape' && !busy) onClose();
      if (event.key !== 'Tab') return;
      const controls = dialogRef.current?.querySelectorAll<HTMLElement>('button:not(:disabled), select:not(:disabled), input:not(:disabled), summary');
      const visible = Array.from(controls ?? []).filter(control => control.getClientRects().length > 0);
      const first = visible[0]; const last = visible[visible.length - 1];
      if (event.shiftKey && (document.activeElement === first || document.activeElement === dialogRef.current)) { event.preventDefault(); last?.focus(); }
      else if (!event.shiftKey && (document.activeElement === last || document.activeElement === dialogRef.current)) { event.preventDefault(); first?.focus(); }
    };
    window.addEventListener('keydown', handleKey);
    return () => { window.removeEventListener('keydown', handleKey); if (previous instanceof HTMLElement) previous.focus(); };
  }, [onClose, busy]);
  const resetFeedback = () => { connectivity.reset(); testReceipt.reset(); };
  const chooseMode = (value: PrinterMode) => {
    setDraftMode(value); resetFeedback();
    if (value === 'network_tcp' && config?.printer.transport !== 'network_tcp') setDraft({
      printer: { transport: 'network_tcp', queue_id: 'network-manual', host_id: 'local-network', queue_name: 'Network/Ethernet Printer', port_name: 'TCP 9100', driver_name: 'ESC/POS over TCP', device: null, ip_address: '', port: 9100, protocol: 'escpos' },
      paper_width_mm: config?.paper_width_mm ?? 80, printable_width_dots: config?.printable_width_dots ?? 576, auto_cut: true,
    });
  };
  const selectPrinter = (printer: PrinterIdentity) => {
    setDraftMode(printer.transport); resetFeedback();
    if (config?.printer.queue_id === printer.queue_id) return;
    if (saved.data?.printer.queue_id === printer.queue_id) { setDraft(saved.data); return; }
    setDraft({ printer, paper_width_mm: config?.paper_width_mm ?? 80, printable_width_dots: config?.printable_width_dots ?? 576, auto_cut: true });
  };
  const setEndpoint = (ip: string, port: number) => {
    if (selected?.printer.transport !== 'network_tcp') return;
    setDraft({ ...selected, printer: { ...selected.printer, ip_address: ip, port, queue_id: `tcp:${ip}:${port}`, port_name: `${ip}:${port}` } }); resetFeedback();
  };
  const validEndpoint = selected?.printer.transport === 'network_tcp' && isPrinterIPAddress(selected.printer.ip_address) && Number.isInteger(selected.printer.port) && selected.printer.port >= 1024 && selected.printer.port <= 65535;
  const canSave = browser || Boolean(selected && (mode === 'network_tcp' ? validEndpoint : selected.printer.device));
  const submit = async (event: FormEvent) => {
    event.preventDefault(); if (!canSave) return;
    try {
      if (!browser && selected) await save.mutateAsync(selected);
      if (browser) browserPaper.setWidth(browserWidth ?? browserPaper.width);
      preference.setMethod(browser ? 'browser' : 'bridge'); toast.success('Receipt printer configuration saved.'); onClose();
    } catch (error) { toast.error(error instanceof Error ? error.message : 'Could not save printer configuration.'); }
  };
  return createPortal(
    <div className="modal-overlay" onClick={event => { if (event.target === event.currentTarget && !busy) onClose(); }}>
      <div className="modal-content printer-config" role="dialog" aria-modal="true" aria-labelledby="printer-title" tabIndex={-1} ref={dialogRef}>
        <div className="modal-header"><div><h2 id="printer-title" className="modal-title"><Printer size={20} aria-hidden="true" />POS Printer</h2><p className="modal-subtitle">Choose a printer, set up the receipt, then test.</p></div><button className="modal-close" onClick={onClose} disabled={busy} aria-label="Close"><X size={18} /></button></div>
        <form onSubmit={submit}>
          <div className="modal-body printer-config-body">
            <div className="printer-methods" role="group" aria-label="Printing method">{methods.map(({ value, title, detail, icon: Icon }) => <button type="button" key={value} className="printer-method" aria-pressed={mode === value} onClick={() => chooseMode(value)} disabled={busy}><Icon size={20} aria-hidden="true" /><strong>{title}</strong><small>{detail}</small></button>)}</div>
            {saved.isLoading && <p role="status" className="printer-notice">Loading saved configuration…</p>}
            {saved.error && <p role="alert" className="printer-notice">Could not load saved configuration: {saved.error.message}</p>}
            <div className={`printer-workspace${browser ? ' is-browser' : ''}`}>
              <section className="printer-connection" aria-label="Printer connection">
                {browser ? <><h3>Print through your browser</h3><p>Choose an installed printer or Save as PDF in the system print dialog.</p><label className="input-group"><span className="input-label">Paper width</span><select aria-label="Paper width" className="input-field" value={browserWidth ?? browserPaper.width} onChange={event => setBrowserWidth(event.target.value === '58' ? 58 : 80)}><option value="80">80 mm</option><option value="58">58 mm</option></select></label><p className="printer-hint">Cutter behavior is controlled by your printer driver in this mode. Direct USB/Ethernet printing uses the auto-cut setting.</p></> : <>
                  <div className="printer-section-heading"><div><h3>{mode === 'network_tcp' ? 'Find your Ethernet printer' : 'Choose a USB printer'}</h3><span className="printer-hint">{discovery.isPending ? 'Connecting to bridge…' : discovery.isSuccess ? 'Print bridge connected' : 'Print bridge unavailable'}</span></div><button className="btn btn-secondary" type="button" onClick={() => { resetFeedback(); scan(); }} disabled={busy || discovery.isPending}><RefreshCw size={15} aria-hidden="true" />{discovery.isPending ? 'Refreshing…' : 'Refresh'}</button></div>
                  {discovery.error && <p role="status" className="printer-notice">{discovery.error.message}</p>}
                  {discovery.data?.warnings?.map(warning => <p role="status" className="printer-notice" key={warning}>{warning}</p>)}
                  {mode === 'network_tcp' && <>
                    <div className="printer-scan-controls"><label className="input-group"><span className="input-label">Local network discovery</span><select aria-label="Local network discovery" className="input-field" value={scanSubnet} onChange={event => { setSubnet(event.target.value); networkScan.reset(); }} disabled={busy}><option value="">Choose a bridge subnet</option>{discovery.data?.network_subnets?.map(value => <option key={value} value={value}>{value}</option>)}</select></label><button type="button" className="btn btn-secondary" disabled={busy || !scanSubnet} onClick={() => { if (selected?.printer.transport === 'network_tcp') networkScan.mutate({ subnet: scanSubnet, port: selected.printer.port }); }}>{networkScan.isPending ? 'Scanning network…' : 'Discover Network Printers'}</button></div>
                    {networkScan.data && <div className="printer-results" aria-label="Discovered network printers"><p role="status">{networkPrinters.length ? `${networkPrinters.length} reachable ${networkPrinters.length === 1 ? 'endpoint' : 'endpoints'}. Select one below.` : 'No endpoints found. Enter the printer IP address below.'}</p>{networkPrinters.map(printer => <button type="button" className="printer-result" key={printer.queue_id} aria-pressed={selected?.printer.queue_id === printer.queue_id} onClick={() => selectPrinter(printer)} disabled={busy}><Network size={18} aria-hidden="true" /><span><strong>{printer.transport === 'network_tcp' ? printer.ip_address : printer.queue_name}</strong><small>{printer.port_name}</small></span>{selected?.printer.queue_id === printer.queue_id ? <Check size={18} aria-hidden="true" /> : <span className="printer-result-action">Select</span>}</button>)}{networkPrinters.length > 0 && <small>An open port is reachable. Print a test to confirm printer compatibility.</small>}</div>}
                    {networkScan.error && <p role="alert" className="printer-notice">{networkScan.error.message}</p>}
                    {selected?.printer.transport === 'network_tcp' && <>
                      <div className="printer-endpoint-fields"><label className="input-group"><span className="input-label">Printer IP address</span><input className="input-field" required inputMode="decimal" placeholder="192.168.1.100" value={selected.printer.ip_address} onChange={event => { if (selected.printer.transport === 'network_tcp') setEndpoint(event.target.value.trim(), selected.printer.port); }} disabled={busy} /></label><label className="input-group"><span className="input-label">Printer TCP port</span><input className="input-field" type="number" required min={1024} max={65535} step={1} value={selected.printer.port} onChange={event => { if (selected.printer.transport === 'network_tcp') setEndpoint(selected.printer.ip_address, Number(event.target.value)); networkScan.reset(); }} disabled={busy} /></label></div>
                      <p className="printer-hint">Use the printer’s private IP and RAW ESC/POS port, usually 9100. No Windows driver needed.</p>
                      <label className="input-group"><span className="input-label">Printer name</span><input className="input-field" required maxLength={100} value={selected.printer.queue_name} onChange={event => setDraft({ ...selected, printer: { ...selected.printer, queue_name: event.target.value } })} disabled={busy} /></label>
                      <button type="button" className="btn btn-secondary" disabled={busy || !validEndpoint} onClick={() => { if (selected.printer.transport === 'network_tcp') connectivity.mutate({ ip: selected.printer.ip_address, port: selected.printer.port }); }}>{connectivity.isPending ? 'Connecting…' : 'Test Connectivity'}</button>
                      {connectivity.data && <p role="status" className="printer-notice">{connectivity.data.connected ? 'Connected. ' : 'Not connected. '}{connectivity.data.message}</p>}{connectivity.error && <p role="alert" className="printer-notice">{connectivity.error.message}</p>}
                    </>}
                  </>}
                  {mode === 'windows_usb' && <>
                    <label className="input-group"><span className="input-label">Printer</span><select aria-label="Printer" className="input-field" value={current?.queue_id ?? selected?.printer.queue_id ?? ''} disabled={busy} onChange={event => { const printer = usbPrinters.find(value => value.queue_id === event.target.value); if (printer) selectPrinter(printer); }}><option value="">Select an installed printer</option>{selected && !current && <option value={selected.printer.queue_id}>{selected.printer.queue_name} (saved, unavailable here)</option>}{usbPrinters.map(printer => <option key={printer.queue_id} value={printer.queue_id} disabled={!printer.supported}>{printer.queue_name} — {printer.supported ? printer.available ? printer.port_name : 'unavailable' : 'unsupported transport'}</option>)}</select></label>
                    {discovery.isSuccess && !usbPrinters.some(printer => printer.supported) && <p role="status" className="printer-notice">No USB receipt queues detected. Install the Windows USB driver, then Refresh.</p>}
                    {unavailable && <p role="status" className="printer-notice">Configured printer unavailable. Its saved settings are retained.</p>}
                    {selected && !current?.device && <label className="input-group"><span className="input-label">Physical USB device</span><select aria-label="Physical USB device" className="input-field" value={selected.printer.device?.device_id ?? ''} disabled={busy} onChange={event => { if (selected.printer.transport === 'windows_usb') setDraft({ ...selected, printer: { ...selected.printer, device: devices.find(device => device.device_id === event.target.value) ?? null } }); }}><option value="">Select the device connected to this queue</option>{selected.printer.device && !devices.some(device => device.device_id === selected.printer.device?.device_id) && <option value={selected.printer.device.device_id}>{selected.printer.device.model} (saved, disconnected)</option>}{devices.map(device => <option key={device.device_id} value={device.device_id}>{device.model} · {device.serial_number || device.device_id}{device.present ? '' : ' (disconnected)'}</option>)}</select><small>Match the physical device so disconnections can be detected.</small></label>}
                    {selected && <p className="printer-hint">{selected.printer.driver_name} · {selected.printer.port_name}</p>}
                  </>}
                </>}
              </section>
              {!browser && <section className="printer-receipt" aria-label="Receipt settings"><h3>Receipt settings</h3>{selected ? <>
                <label className="input-group"><span className="input-label">Paper width</span><select aria-label="Paper width" className="input-field" value={selected.paper_width_mm} disabled={busy} onChange={event => { const width = event.target.value === '58' ? 58 : 80; setDraft({ ...selected, paper_width_mm: width, printable_width_dots: PAPER_PROFILES[width].dots }); resetFeedback(); }}><option value="80">80 mm</option><option value="58">58 mm</option></select></label>
                <label className="input-group"><span className="input-label">Printable width (dots)</span><input type="number" className="input-field" min={240} max={PAPER_PROFILES[selected.paper_width_mm].maxDots} step={8} required value={selected.printable_width_dots} disabled={busy} onChange={event => { setDraft({ ...selected, printable_width_dots: Number(event.target.value) }); resetFeedback(); }} /></label>
                <label className="printer-cutter"><Scissors size={20} aria-hidden="true" /><span><strong>Auto-cut after receipt</strong><small>{selected.auto_cut ? 'On · cuts after each direct print' : 'Off · receipt feeds without cutting'}</small></span><input type="checkbox" role="switch" aria-label="Auto-cut after receipt" checked={selected.auto_cut} disabled={busy} onChange={event => { setDraft({ ...selected, auto_cut: event.target.checked }); testReceipt.reset(); }} /></label>
                <p className="printer-hint">On by default for new printers. Switch off if your printer has no cutter. Hardware must support the ESC/POS cut command.</p>
                <div className="printer-test"><h4>Check before saving</h4><p>Print a sample using these settings. Check the text, paper width and cut.</p><button type="button" className="btn btn-secondary" disabled={busy || !canSave} onClick={() => testReceipt.mutate(selected)}><Printer size={16} aria-hidden="true" />{testReceipt.isPending ? 'Printing test…' : 'Print Test Receipt'}</button><small>Creates no sale or payment.</small></div>
                {testReceipt.data && <p role="status" className="printer-notice">{testReceipt.data.message}</p>}{testReceipt.error && <p role="alert" className="printer-notice">{testReceipt.error.message}</p>}
              </> : <p>Choose a USB queue to configure paper and cutting.</p>}</section>}
            </div>
            <details className="printer-bridge-settings"><summary>Print Bridge connection (this device)</summary><div className="dialog-form"><p className="printer-hint">Windows uses localhost. Another device needs a trusted HTTPS bridge and pairing token.</p><label className="input-group"><span className="input-label">Bridge URL</span><input className="input-field" type="url" value={bridge.url} onChange={event => setBridge({ ...bridge, url: event.target.value })} /></label><label className="input-group"><span className="input-label">Bridge pairing token (LAN access)</span><input className="input-field" type="password" autoComplete="off" value={bridge.token} onChange={event => setBridge({ ...bridge, token: event.target.value })} /></label><button type="button" className="btn btn-secondary" disabled={busy || discovery.isPending} onClick={() => { try { saveBridgeSettings(bridge.url, bridge.token); networkScan.reset(); resetFeedback(); scan(); toast.success('Bridge settings saved on this device'); } catch (error) { toast.error(error instanceof Error ? error.message : 'Could not save bridge settings'); } }}>Save Bridge & Refresh</button></div></details>
          </div>
          <div className="modal-footer"><small>{browser ? 'Output choice is saved in this browser.' : 'Printer settings are shared by this business.'}</small><button type="button" className="btn btn-secondary" onClick={onClose} disabled={busy}>Cancel</button><button className="btn btn-primary" type="submit" disabled={!canSave || (!browser && (saved.isLoading || Boolean(saved.error))) || busy}>{save.isPending ? 'Saving…' : 'Save Printer'}</button></div>
        </form>
      </div>
    </div>, document.body,
  );
}
