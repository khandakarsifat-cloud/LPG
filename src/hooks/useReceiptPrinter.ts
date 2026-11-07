import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import toast from 'react-hot-toast';
import { useAuth } from '../contexts/AuthContext';
import { supabase } from '../lib/supabase';
import { discoverPrinters, discoverNetworkPrinters, sendReceipt, testNetworkPrinter } from '../lib/printBridge';
import type { ReceiptPrinterConfig, ReceiptPrintMethod } from '../types/printing';
import { readReceiptPrintMethod, writeReceiptPrintMethod, readBrowserPaperWidth, writeBrowserPaperWidth } from '../lib/receiptPrintPreference';
import { printBrowserReceipt } from '../lib/browserPrint';
import { buildSaleReceipt } from '../lib/receipt';
import { saleDisplay } from '../lib/saleDisplay';
import type { SaleTransaction } from './useDashboard';
import type { SaleSettlement } from '../types/finance';
import type { SaleBottles } from '../types/bottles';
import type { LPGBrand } from '../types/inventory';

interface SavedReceiptSource {
  sale: SaleTransaction; settlement: SaleSettlement; bottles: SaleBottles;
  shop_name: string; brands: Pick<LPGBrand, 'brand_id' | 'brand_name'>[];
}

/** One database statement reads identity, immutable sale facts and current settlement. */
async function loadSaleReceipt(saleId: string, signal?: AbortSignal) {
  const request = supabase.rpc('get_sale_receipt', { p_sale_id: saleId });
  const { data, error } = await (signal ? request.abortSignal(signal) : request);
  if (error) throw error;
  const source: SavedReceiptSource | null = data;
  if (!source?.sale.sale_items?.length) throw new Error('The completed sale has no receipt items.');
  return buildSaleReceipt(saleDisplay(source.sale), source.settlement, source.shop_name, source.bottles, source.brands);
}

export function useSaleReceipt(saleId: string) {
  const { profile, can } = useAuth();
  return useQuery({
    queryKey: ['sales', 'receipt', profile?.tenant_id, saleId], enabled: Boolean(profile) && can('receipts:print'),
    queryFn: ({ signal }) => loadSaleReceipt(saleId, signal), staleTime: 0, refetchOnMount: 'always', refetchInterval: 30_000,
  });
}

const configKey = (tenantId?: string) => ['receipt_printer', tenantId] as const;

export function useBrowserPaperWidth() {
  const { profile } = useAuth(); const tenant = profile?.tenant_id; const qc = useQueryClient();
  const queryKey = ['browser_paper_width', tenant];
  const query = useQuery<58 | 80>({ queryKey, enabled: Boolean(tenant), queryFn: () => tenant ? readBrowserPaperWidth(tenant) : 80 });
  return { width: query.data ?? 80, setWidth: (width: 58 | 80) => {
    if (!tenant) throw new Error('Business profile unavailable.');
    writeBrowserPaperWidth(tenant, width); qc.setQueryData(queryKey, width);
  } };
}

export function useReceiptPaperWidth() {
  const { method } = useReceiptPrintMethod(); const { can } = useAuth();
  const saved = useReceiptPrinter(can('receipts:print')); const browser = useBrowserPaperWidth();
  return method === 'browser' || !saved.data ? browser.width : saved.data.paper_width_mm;
}

export function useReceiptPrintMethod() {
  const { profile } = useAuth();
  const tenantId = profile?.tenant_id;
  const qc = useQueryClient();
  const queryKey = ['receipt_print_method', tenantId] as const;
  const preference = useQuery<ReceiptPrintMethod>({
    queryKey, enabled: Boolean(tenantId), staleTime: 0,
    queryFn: () => tenantId ? readReceiptPrintMethod(tenantId) : 'bridge',
  });
  return {
    method: preference.data ?? 'bridge',
    setMethod: (method: ReceiptPrintMethod) => {
      if (!tenantId) throw new Error('Business profile unavailable.');
      writeReceiptPrintMethod(tenantId, method);
      qc.setQueryData(queryKey, method);
    },
  };
}

async function loadConfig(tenantId: string): Promise<ReceiptPrinterConfig | null> {
  const { data, error } = await supabase.from('receipt_printers')
    .select('tenant_id, printer, paper_width_mm, printable_width_dots, auto_cut')
    .eq('tenant_id', tenantId).maybeSingle().overrideTypes<ReceiptPrinterConfig | null, { merge: false }>();
  if (error) throw error;
  return data;
}

export function useReceiptPrinter(enabled = true) {
  const { profile } = useAuth();
  const tenantId = profile?.tenant_id;
  return useQuery({
    queryKey: configKey(profile?.tenant_id),
    enabled: Boolean(profile?.tenant_id) && enabled,
    queryFn: () => {
      if (!tenantId) throw new Error('Business profile unavailable.');
      return loadConfig(tenantId);
    },
  });
}

export function useSaveReceiptPrinter() {
  const { profile } = useAuth();
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (config: Omit<ReceiptPrinterConfig, 'tenant_id'>) => {
      if (!profile) throw new Error('Business profile unavailable.');
      const { data, error } = await supabase.from('receipt_printers')
        .upsert({ ...config, tenant_id: profile.tenant_id }, { onConflict: 'tenant_id' })
        .select('tenant_id, printer, paper_width_mm, printable_width_dots, auto_cut').single()
        .overrideTypes<ReceiptPrinterConfig, { merge: false }>();
      if (error) throw error;
      return data;
    },
    onSuccess: data => qc.setQueryData(configKey(data.tenant_id), data),
  });
}

// Each modal open/Refresh calls the host; discovered hardware is never saved configuration.
export const usePrinterDiscovery = () => useMutation({ mutationFn: discoverPrinters, retry: false });
export const useNetworkPrinterDiscovery = () => useMutation({ mutationFn: ({ subnet, port }: { subnet: string; port: number }) => discoverNetworkPrinters(subnet, port), retry: false });
export const useNetworkPrinterTest = () => useMutation({ mutationFn: ({ ip, port }: { ip: string; port: number }) => testNetworkPrinter(ip, port), retry: false });
export function usePrinterTestReceipt() {
  const { profile } = useAuth();
  return useMutation({ retry: false, mutationFn: async (config: Omit<ReceiptPrinterConfig, 'tenant_id'>) => {
    if (!profile) throw new Error('Business profile unavailable.');
    return sendReceipt({ ...config, tenant_id: profile.tenant_id }, {
      sale_id: crypto.randomUUID(), created_at: new Date().toISOString(), shop_name: profile.business_name,
      customer_name: 'PRINTER TEST — NOT A SALE', customer_phone: '', customer_tier: 'retail',
      items: [{ name: 'বাংলা / ESC-POS test receipt', quantity: 1, type: 'refill', unit_price: 0, line_total: 0 }],
      subtotal: 0, discount_amount: 0, exchange_fee: 0, total_amount: 0, paid_amount: 0, due_amount: 0,
      payments: [], unattributed_paid: 0, notes: 'Printer configuration test only. No sale, stock movement or payment was recorded.',
    });
  } });
}

// Both checkout and reprinting read committed sale data; this path never creates sales.
export function usePrintSale() {
  const { profile, can } = useAuth();
  return useMutation({
    retry: false,
    mutationFn: async (saleId: string) => {
      if (!can('receipts:print')) throw new Error('Receipt printing access is required.');
      if (!profile) throw new Error('Business profile unavailable.');
      const method = readReceiptPrintMethod(profile.tenant_id);
      // Browser printing also works before any USB printer is configured.
      const [config, receipt] = await Promise.all([loadConfig(profile.tenant_id), loadSaleReceipt(saleId)]);
      if (method === 'browser' || !config) return printBrowserReceipt(receipt, readBrowserPaperWidth(profile.tenant_id));
      return sendReceipt(config, receipt);
    },
    onSuccess: result => { toast.success(result.message); },
    onError: error => { toast.error(`Receipt not confirmed: ${error.message} The completed sale is saved.`, { duration: 7000 }); },
  });
}
