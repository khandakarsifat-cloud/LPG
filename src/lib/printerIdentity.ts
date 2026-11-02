import type { DiscoveredPrinter, PrinterDiscovery, PrinterIdentity, USBDevice } from '../types/printing.ts';

export function isPrinterIPAddress(ip: string): boolean {
  const parts = ip.split('.');
  if (parts.length !== 4 || parts.some(part => !/^(0|[1-9]\d{0,2})$/.test(part) || Number(part) > 255)) return false;
  const [a, b] = parts.map(Number);
  return a === 10 || a === 172 && b >= 16 && b <= 31 || a === 192 && b === 168;
}

export function findUSBDevice(saved: USBDevice, devices: USBDevice[]): USBDevice | undefined {
  const matches = devices.filter(device => saved.serial_number
    ? device.serial_number === saved.serial_number && device.vendor_id === saved.vendor_id && device.product_id === saved.product_id
    : device.device_id === saved.device_id);
  return matches.find(device => device.present) ?? matches[0];
}

export function findPrinterQueue(saved: PrinterIdentity, discovery: PrinterDiscovery): DiscoveredPrinter | undefined {
  const queues = discovery.printers.filter(printer => printer.host_id === saved.host_id && printer.supported);
  const exact = queues.find(printer => printer.queue_id === saved.queue_id);
  if (exact) return exact;
  const physical = saved.device && findUSBDevice(saved.device, discovery.usb_devices);
  const linked = physical ? queues.filter(printer => printer.device?.device_id === physical.device_id) : [];
  return linked.length === 1 ? linked[0] : undefined;
}
