import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import type { DiscoveredPrinter, PrinterDiscovery, PrinterIdentity, USBDevice } from '../src/types/printing.ts';
import { PrintError } from './errors.ts';
import { findPrinterQueue, findUSBDevice } from '../src/lib/printerIdentity.ts';

export function runWindows<T>(action: 'discover' | 'render' | 'print', input: unknown = {}): Promise<T> {
  if (process.platform !== 'win32') throw new PrintError('WINDOWS_REQUIRED', 'The print bridge must run on the Windows host.', 503);
  return new Promise((resolve, reject) => {
    const child = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', fileURLToPath(new URL('./windows.ps1', import.meta.url)), '-Action', action], { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
    let stdout = '';
    const timeout = setTimeout(() => {
      child.kill();
      reject(new PrintError('RESULT_UNKNOWN', action === 'print'
        ? 'Windows printing timed out. The job may have printed; check the printer before reprinting.'
        : 'Windows printer discovery/rendering timed out.', 504));
    }, action === 'print' ? 35_000 : 15_000);
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', chunk => { stdout += chunk; });
    // Native errors are intentionally not logged; receipts and device identifiers stay local.
    child.stderr.resume();
    child.stdin.on('error', () => {});
    child.on('error', () => { clearTimeout(timeout); reject(new PrintError('WINDOWS_FAILED', 'Could not start Windows printer helper.', 503)); });
    child.on('close', () => {
      clearTimeout(timeout);
      try {
        const result = JSON.parse(stdout.trim().replace(/^\uFEFF/, ''));
        if (result.error) reject(new PrintError(result.code || 'PRINT_FAILED', result.error, 503));
        else resolve(result);
      } catch { reject(new PrintError('WINDOWS_FAILED', 'Windows printer helper failed. Check the Print Spooler service and printer driver.', 503)); }
    });
    child.stdin.end(JSON.stringify(input));
  });
}

const hash = (text: string) => createHash('sha256').update(text.toLowerCase()).digest('hex');

export async function discoverWindowsPrinters(): Promise<PrinterDiscovery> {
  const result = await runWindows<{ host_id: string; printers: Array<Omit<DiscoveredPrinter, 'queue_id' | 'host_id' | 'transport' | 'device'>>; usb_devices: USBDevice[] }>('discover');
  const hostId = hash(result.host_id);
  return {
    usb_devices: result.usb_devices,
    printers: result.printers.map(printer => {
      const matches = result.usb_devices.filter(device => device.port_name?.toLowerCase() === printer.port_name.toLowerCase());
      return {
        ...printer, host_id: hostId, queue_id: hash(`${hostId}|${printer.queue_name}|${printer.port_name}|${printer.driver_name}`),
        transport: 'windows_usb', device: matches.find(device => device.present) ?? matches[0] ?? null,
      };
    }),
  };
}

export function resolvePrinter(identity: PrinterIdentity, discovery: PrinterDiscovery): DiscoveredPrinter {
  const sameHost = discovery.printers.filter(printer => printer.host_id === identity.host_id && printer.supported);
  if (!sameHost.length) throw new PrintError('PRINTER_UNAVAILABLE', 'Configured printer unavailable on this Windows computer.', 409);
  const device = identity.device;
  if (!device) throw new PrintError('DEVICE_REQUIRED', 'Select the physical USB device in Dashboard printer configuration.', 409);
  const physical = findUSBDevice(device, discovery.usb_devices);
  if (!physical?.present) throw new PrintError('PRINTER_UNAVAILABLE', 'Configured USB printer is disconnected or unavailable.', 409);
  // Prefer an exact queue, otherwise an unambiguous queue linked to the same hardware.
  const selected = findPrinterQueue(identity, discovery);
  if (!selected || (selected.device && selected.device.device_id !== physical.device_id)) {
    throw new PrintError('PRINTER_UNAVAILABLE', 'Saved printer queue no longer matches the USB device. Select it again in Dashboard.', 409);
  }
  if (!selected.available) throw new PrintError('PRINTER_UNAVAILABLE', selected.unavailable_reason || 'Configured printer is unavailable.', 409);
  return selected;
}
