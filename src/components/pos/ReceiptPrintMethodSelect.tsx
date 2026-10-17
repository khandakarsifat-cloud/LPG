import { useId } from 'react';
import toast from 'react-hot-toast';
import { useReceiptPrinter, useReceiptPrintMethod } from '../../hooks/useReceiptPrinter';

export function ReceiptPrintMethodSelect({ disabled = false }: { disabled?: boolean }) {
  const id = useId();
  const { method, setMethod } = useReceiptPrintMethod();
  const saved = useReceiptPrinter();
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
  </div>;
}
