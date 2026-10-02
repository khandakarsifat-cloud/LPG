import { useEffect, useRef, useState, type FormEvent } from 'react';
import { createPortal } from 'react-dom';
import { Printer, RefreshCw, X } from 'lucide-react';
import toast from 'react-hot-toast';
import { usePrinterDiscovery, useReceiptPrinter, useSaveReceiptPrinter } from '../../hooks/useReceiptPrinter';
import { PAPER_PROFILES, type PrinterIdentity, type ReceiptPrinterConfig } from '../../types/printing';
import { findPrinterQueue, findUSBDevice } from '../../lib/printerIdentity';

export function PrinterConfigModal({ onClose }: { onClose: () => void }) {
  const saved = useReceiptPrinter();
  const discovery = usePrinterDiscovery();
  const save = useSaveReceiptPrinter();
  const [draft, setDraft] = useState<Omit<ReceiptPrinterConfig, 'tenant_id'> | null>(null);
  const dialogRef = useRef<HTMLDivElement>(null);
  const scan = discovery.mutate;

  useEffect(() => { scan(); }, [scan]);
  useEffect(() => {
    const previous = document.activeElement;
    dialogRef.current?.focus();
    const handleKey = (event: KeyboardEvent) => {
      if (event.key === 'Escape' && !save.isPending) onClose();
      if (event.key !== 'Tab') return;
      const controls = dialogRef.current?.querySelectorAll<HTMLElement>('button:not(:disabled), select:not(:disabled), input:not(:disabled)');
      if (!controls?.length) return;
      const first = controls[0];
      const last = controls[controls.length - 1];
      if (event.shiftKey && (document.activeElement === first || document.activeElement === dialogRef.current)) {
        event.preventDefault(); last.focus();
      } else if (!event.shiftKey && (document.activeElement === last || document.activeElement === dialogRef.current)) {
        event.preventDefault(); first.focus();
      }
    };
    window.addEventListener('keydown', handleKey);
    return () => { window.removeEventListener('keydown', handleKey); if (previous instanceof HTMLElement) previous.focus(); };
  }, [onClose, save.isPending]);

  const config = draft ?? saved.data;
  const printers = discovery.data?.printers ?? [];
  const current = config && discovery.data ? findPrinterQueue(config.printer, discovery.data) : undefined;
  const devices = discovery.data?.usb_devices ?? [];
  const devicePresent = Boolean(config?.printer.device && findUSBDevice(config.printer.device, devices)?.present);
  const unavailable = Boolean(config && discovery.isSuccess && (!current?.available || !devicePresent));

  const selectPrinter = (queueId: string) => {
    const printer = printers.find(candidate => candidate.queue_id === queueId);
    if (!printer) return;
    const identity: PrinterIdentity = {
      queue_id: printer.queue_id, host_id: printer.host_id, queue_name: printer.queue_name,
      port_name: printer.port_name, driver_name: printer.driver_name,
      transport: printer.transport, device: printer.device,
    };
    setDraft({
      printer: identity, paper_width_mm: config?.paper_width_mm ?? 80,
      printable_width_dots: config?.printable_width_dots ?? PAPER_PROFILES[80].dots,
      auto_cut: config?.auto_cut ?? false,
    });
  };

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    if (!config) return;
    try { await save.mutateAsync(config); toast.success('Receipt printer configuration saved.'); onClose(); }
    catch (error) { toast.error(error instanceof Error ? error.message : 'Could not save printer configuration.'); }
  };

  return createPortal(
    <div className="modal-overlay" onClick={event => { if (event.target === event.currentTarget && !save.isPending) onClose(); }}>
      <div className="modal-content glass-panel" role="dialog" aria-modal="true" aria-labelledby="printer-title" tabIndex={-1} ref={dialogRef}>
        <div className="modal-header">
          <div><h2 id="printer-title" className="modal-title"><Printer size={18} /> Receipt Printer</h2>
            <p className="modal-subtitle">One USB receipt printer for this business</p></div>
          <button className="modal-close" onClick={onClose} disabled={save.isPending} aria-label="Close"><X size={18} /></button>
        </div>
        <form onSubmit={submit} style={{ display: 'flex', flexDirection: 'column', minHeight: 0 }}>
          <div className="modal-body" style={{ display: 'grid', gap: '1rem' }}>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: '1rem' }}>
              <span style={{ color: 'var(--text-muted)' }}>Windows printers on this computer</span>
              <button className="btn btn-secondary" type="button" onClick={() => scan()} disabled={discovery.isPending}>
                <RefreshCw size={15} /> {discovery.isPending ? 'Scanning…' : 'Refresh'}
              </button>
            </div>
            {saved.isLoading && <p role="status">Loading saved configuration…</p>}
            {saved.error && <p role="alert">Could not load saved configuration: {saved.error.message}</p>}
            {discovery.error && <p role="alert">{discovery.error.message}</p>}
            {discovery.data?.warnings?.map(warning => <p role="status" key={warning}>{warning}</p>)}
            {discovery.isSuccess && printers.length === 0 && <p role="status">No Windows printers detected. Connect and install a USB ESC/POS printer, then Refresh.</p>}
            {discovery.isSuccess && printers.length > 0 && !printers.some(printer => printer.supported) &&
              <p role="status">No USB receipt queues detected. Install the printer's Windows USB driver, then Refresh.</p>}
            <div className="input-group">
              <label className="input-label" htmlFor="receipt-printer">Printer</label>
              <select id="receipt-printer" className="input-field" value={current?.queue_id ?? config?.printer.queue_id ?? ''} onChange={event => selectPrinter(event.target.value)} disabled={save.isPending || saved.isLoading || Boolean(saved.error)}>
                <option value="">Select a USB ESC/POS printer</option>
                {config && !current && <option value={config.printer.queue_id}>{config.printer.queue_name} (saved, unavailable here)</option>}
                {printers.map(printer => <option key={printer.queue_id} value={printer.queue_id} disabled={!printer.supported}>
                  {printer.queue_name} — {printer.supported ? (printer.available ? printer.port_name : 'unavailable') : 'unsupported transport'}
                </option>)}
              </select>
            </div>
            {config && <>
              <p style={{ margin: 0, fontSize: 'var(--font-sm)', color: 'var(--text-muted)' }}>{config.printer.driver_name} · {config.printer.port_name}</p>
              {unavailable && <p role="status">Configured printer unavailable on this computer. Its saved configuration is retained; you can still update paper settings.</p>}
              {!current?.device && <div className="input-group">
                <label className="input-label" htmlFor="receipt-usb-device">Physical USB device</label>
                <select id="receipt-usb-device" className="input-field" value={config.printer.device?.device_id ?? ''} disabled={save.isPending}
                  onChange={event => setDraft({ ...config, printer: { ...config.printer, device: devices.find(device => device.device_id === event.target.value) ?? null } })}>
                  <option value="">Select the USB device connected to this queue</option>
                  {config.printer.device && !devices.some(device => device.device_id === config.printer.device?.device_id) &&
                    <option value={config.printer.device.device_id}>{config.printer.device.model} (saved, disconnected)</option>}
                  {devices.map(device => <option key={device.device_id} value={device.device_id}>{device.model} · {device.serial_number || device.device_id} {device.present ? '' : '(disconnected)'}</option>)}
                </select>
                <small style={{ color: 'var(--text-muted)' }}>This Windows port monitor does not identify its device. Select the matching hardware so disconnection can be detected reliably.</small>
              </div>}
              {config.printer.device && <small style={{ color: 'var(--text-muted)' }}>USB {config.printer.device.vendor_id}:{config.printer.device.product_id} · {config.printer.device.serial_number || config.printer.device.device_id}</small>}
              <div className="input-group">
                <label className="input-label" htmlFor="receipt-paper">Paper width</label>
                <select id="receipt-paper" className="input-field" value={config.paper_width_mm} disabled={save.isPending} onChange={event => {
                  const width = event.target.value === '58' ? 58 : 80;
                  setDraft({ ...config, paper_width_mm: width, printable_width_dots: PAPER_PROFILES[width].dots });
                }}><option value="80">80 mm</option><option value="58">58 mm</option></select>
              </div>
              <div className="input-group">
                <label className="input-label" htmlFor="receipt-dots">Printable width (dots)</label>
                <input id="receipt-dots" type="number" className="input-field" min={240} max={PAPER_PROFILES[config.paper_width_mm].maxDots} step={8} required
                  value={config.printable_width_dots} disabled={save.isPending} onChange={event => setDraft({ ...config, printable_width_dots: Number(event.target.value) })} />
                <small style={{ color: 'var(--text-muted)' }}>Usually 576 dots for 80 mm or 384 for 58 mm at 203 dpi. Use your printer's supported width.</small>
              </div>
              <label style={{ display: 'flex', gap: '0.5rem', alignItems: 'center' }}>
                <input type="checkbox" checked={config.auto_cut} disabled={save.isPending} onChange={event => setDraft({ ...config, auto_cut: event.target.checked })} />
                Auto-cut after receipt (enable only if the printer has a cutter)
              </label>
            </>}
          </div>
          <div className="modal-footer">
            <button type="button" className="btn btn-secondary" onClick={onClose} disabled={save.isPending}>Cancel</button>
            <button className="btn btn-primary" type="submit" disabled={!config?.printer.device || saved.isLoading || Boolean(saved.error) || save.isPending}>{save.isPending ? 'Saving…' : 'Save Printer'}</button>
          </div>
        </form>
      </div>
    </div>, document.body,
  );
}
