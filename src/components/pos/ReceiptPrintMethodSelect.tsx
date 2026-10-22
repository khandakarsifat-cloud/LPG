import { useId } from 'react';
import toast from 'react-hot-toast';
import { useBrowserPaperWidth, useReceiptPrinter, useReceiptPrintMethod } from '../../hooks/useReceiptPrinter';

export function ReceiptPrintMethodSelect({ disabled = false }: { disabled?: boolean }) {
  const id = useId();
  const { method, setMethod } = useReceiptPrintMethod();
  const saved = useReceiptPrinter();
  const paper = useBrowserPaperWidth();
  return <div className="input-group" style={{ minWidth: 0, maxWidth: '100%' }}>
    <label className="input-label" htmlFor={id}>Receipt printer</label>
    <select id={id} className="input-field" disabled={disabled || saved.isLoading}
      value={method === 'browser' || !saved.data ? 'browser' : 'windows_usb'}
      onChange={event => {
        try { setMethod(event.target.value === 'browser' ? 'browser' : 'windows_usb'); }
        catch { toast.error('Could not remember the receipt printer in this browser.'); }
      }}>
      <option value="browser">Browser printing (Chrome/system dialog)</option>
      {saved.data && <option value="windows_usb">{saved.data.printer.queue_name} (USB bridge)</option>}
    </select>
    {(method === 'browser' || !saved.data) && <><label className="input-label" htmlFor={`${id}-width`}>Browser receipt width</label><select id={`${id}-width`} className="input-field" value={paper.width} disabled={disabled} onChange={event => { try { paper.setWidth(event.target.value === '58' ? 58 : 80); } catch { toast.error('Could not remember paper width.'); } }}><option value="80">80 mm</option><option value="58">58 mm</option></select></>}
  </div>;
}
