import { createConnection, isIPv4 } from 'node:net';
import { networkInterfaces } from 'node:os';
import type { DiscoveredPrinter, NetworkPrinterIdentity } from '../src/types/printing.ts';
import { PrintError } from './errors.ts';

export function privateIPv4(ip: unknown): ip is string {
  if (typeof ip !== 'string' || !isIPv4(ip)) return false;
  const [a, b] = ip.split('.').map(Number);
  return a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168);
}
export function validateNetworkTarget(value: unknown): { ip_address: string; port: number } {
  const target = value as Partial<NetworkPrinterIdentity> | null;
  if (!target || !privateIPv4(target.ip_address) || typeof target.port !== 'number' || !Number.isInteger(target.port) || target.port < 1024 || target.port > 65535) {
    throw new PrintError('INVALID_NETWORK_PRINTER', 'Use a private IPv4 printer address and a TCP port from 1024 to 65535 (usually 9100).');
  }
  return { ip_address: target.ip_address, port: target.port };
}
export function networkPrinter(ip: string, port = 9100): NetworkPrinterIdentity {
  validateNetworkTarget({ ip_address: ip, port });
  return { transport: 'network_tcp', ip_address: ip, port, protocol: 'escpos', device: null,
    queue_id: `tcp:${ip}:${port}`, host_id: 'local-network', queue_name: `Network printer ${ip}`, port_name: `${ip}:${port}`, driver_name: 'ESC/POS over TCP' };
}
const toNumber = (ip: string) => ip.split('.').reduce((sum, n) => (sum * 256 + Number(n)) >>> 0, 0);
export function localSubnets(interfaces = networkInterfaces()): string[] {
  return [...new Set(Object.values(interfaces).flatMap(addresses => (addresses ?? []).flatMap(a => {
    if (a.internal || a.family !== 'IPv4' || !privateIPv4(a.address)) return [];
    // Limit a scan to this adapter's /24 (or smaller actual subnet).
    const mask = toNumber(a.netmask);
    const prefix = mask.toString(2).replace(/0+$/, '').length;
    if (prefix > 30 || !/^1+0*$/.test(mask.toString(2))) return [];
    const bits = Math.max(24, prefix);
    const net = (toNumber(a.address) & (0xffffffff << (32 - bits))) >>> 0;
    const ip = [24, 16, 8, 0].map(s => (net >>> s) & 255).join('.');
    return [`${ip}/${bits}`];
  })))];
}

// A probe opens/closes TCP without sending commands. This proves reachability, not printer protocol or paper status.
export function probeNetwork(value: unknown, timeout = 1800): Promise<{ connected: boolean; message: string }> {
  const target = validateNetworkTarget(value);
  return new Promise(resolve => {
    const socket = createConnection({ host: target.ip_address, port: target.port });
    const finish = (connected: boolean, message: string) => { socket.destroy(); resolve({ connected, message }); };
    socket.setTimeout(timeout);
    socket.once('connect', () => finish(true, `TCP connection to ${target.ip_address}:${target.port} succeeded. Print a test receipt to verify ESC/POS compatibility.`));
    socket.once('timeout', () => finish(false, 'Printer connection timed out. Check its IP, port, power and local network.'));
    socket.once('error', error => finish(false, `Printer connection failed (${(error as NodeJS.ErrnoException).code ?? 'network error'}). Check the printer address and firewall.`));
  });
}
export async function discoverNetwork(subnet: unknown, port: unknown = 9100): Promise<DiscoveredPrinter[]> {
  if (typeof subnet !== 'string' || !localSubnets().includes(subnet)) throw new PrintError('INVALID_SUBNET', 'Choose a subnet attached to the print bridge computer. Use a manual IP for other routed printer networks.');
  const [ip, bits] = subnet.split('/');
  validateNetworkTarget({ ip_address: ip, port });
  const base = toNumber(ip); const count = 2 ** (32 - Number(bits));
  const addresses = Array.from({ length: count - 2 }, (_, n) => base + n + 1);
  const found: DiscoveredPrinter[] = [];
  let next = 0;
  await Promise.all(Array.from({ length: 16 }, async () => {
    while (next < addresses.length) {
      const n = addresses[next++];
      const address = [24, 16, 8, 0].map(s => (n >>> s) & 255).join('.');
      if ((await probeNetwork({ ip_address: address, port }, 350)).connected) found.push({ ...networkPrinter(address, Number(port)), supported: true, available: true, unavailable_reason: null });
    }
  }));
  return found.sort((a, b) => a.port_name.localeCompare(b.port_name, undefined, { numeric: true }));
}
export function sendNetwork(printer: NetworkPrinterIdentity, bytes: Uint8Array): Promise<{ job_id: number }> {
  const target = validateNetworkTarget(printer);
  return new Promise((resolve, reject) => {
    let sending = false;
    const socket = createConnection({ host: target.ip_address, port: target.port });
    const fail = (message: string) => { socket.destroy(); reject(new PrintError(sending ? 'RESULT_UNKNOWN' : 'PRINTER_UNREACHABLE', `${message}${sending ? ' Some bytes may have reached the printer. Check it before reprinting.' : ''}`, 503)); };
    socket.setTimeout(8000);
    socket.once('timeout', () => fail('Network printer timed out.'));
    socket.once('error', error => fail(`Network printing failed (${(error as NodeJS.ErrnoException).code ?? 'network error'}).`));
    socket.once('connect', () => {
      sending = true;
      socket.end(bytes, () => { socket.destroy(); resolve({ job_id: Date.now() }); });
    });
  });
}
