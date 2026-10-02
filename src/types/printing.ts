export interface USBDevice {
  device_id: string;
  serial_number: string | null;
  vendor_id: string | null;
  product_id: string | null;
  manufacturer: string | null;
  model: string | null;
  present: boolean;
  port_name: string | null;
}

export interface PrinterIdentity {
  queue_id: string;
  host_id: string;
  queue_name: string;
  port_name: string;
  driver_name: string;
  transport: 'windows_usb';
  device: USBDevice | null;
}

export interface DiscoveredPrinter extends PrinterIdentity {
  supported: boolean;
  available: boolean;
  unavailable_reason: string | null;
}

export interface PrinterDiscovery {
  printers: DiscoveredPrinter[];
  usb_devices: USBDevice[];
  warnings?: string[];
}

export interface PrinterSettings {
  paper_width_mm: 58 | 80;
  printable_width_dots: number;
  auto_cut: boolean;
}

export interface ReceiptPrinterConfig extends PrinterSettings {
  tenant_id: string;
  printer: PrinterIdentity;
}

export const PAPER_PROFILES = {
  80: { dots: 576, maxDots: 640 },
  58: { dots: 384, maxDots: 464 },
} as const;
