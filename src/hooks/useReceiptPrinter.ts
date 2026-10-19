import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import toast from 'react-hot-toast';
import { useAuth } from '../contexts/AuthContext';
import { supabase } from '../lib/supabase';
import { discoverPrinters, sendReceipt } from '../lib/printBridge';
import type { ReceiptPrinterConfig, ReceiptPrintMethod } from '../types/printing';
import { readReceiptPrintMethod, writeReceiptPrintMethod } from '../lib/receiptPrintPreference';
import { printBrowserReceipt } from '../lib/browserPrint';
import type { ReceiptData } from '../types/receipt';
import type { SaleTransaction } from './useDashboard';

const configKey = (tenantId?: string) => ['receipt_printer', tenantId] as const;

export function useReceiptPrintMethod() {
  const { profile } = useAuth();
  const tenantId = profile?.tenant_id;
  const qc = useQueryClient();
  const queryKey = ['receipt_print_method', tenantId] as const;
  const preference = useQuery<ReceiptPrintMethod>({
    queryKey, enabled: Boolean(tenantId), staleTime: 0,
    queryFn: () => tenantId ? readReceiptPrintMethod(tenantId) : 'windows_usb',
  });
  return {
    method: preference.data ?? 'windows_usb',
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

export function useReceiptPrinter() {
  const { profile } = useAuth();
  const tenantId = profile?.tenant_id;
  return useQuery({
    queryKey: configKey(profile?.tenant_id),
    enabled: Boolean(profile?.tenant_id),
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
      const config = method === 'browser' ? null : await loadConfig(profile.tenant_id);
      const { data, error } = await supabase.from('sales').select(`
        sale_id, sale_tier, created_at, subtotal, discount_amount, exchange_fee, total_amount, notes,
        customers(name, phone, tier),
        sale_items(quantity, unit_price, line_total, type, items(brand, size_kg, lpg_brands(brand_name)))
      `).eq('tenant_id', profile.tenant_id).eq('sale_id', saleId).eq('status', 'completed').single()
        .overrideTypes<SaleTransaction, { merge: false }>();
      if (error) throw error;
      if (!data.sale_items?.length) throw new Error('The completed sale has no receipt items.');
      const customer = data.customers;
      const receipt: ReceiptData = {
        sale_id: data.sale_id, created_at: data.created_at, shop_name: profile.business_name,
        customer_name: customer?.name || 'Unknown', customer_phone: customer?.phone || '',
        customer_tier: data.sale_tier,
        subtotal: Number(data.subtotal), discount_amount: Number(data.discount_amount),
        exchange_fee: Number(data.exchange_fee), total_amount: Number(data.total_amount),
        notes: data.notes || undefined,
        items: data.sale_items.map(line => {
          if (line.type !== 'refill' && line.type !== 'package' && line.type !== 'empty_return') throw new Error('Unsupported receipt item type.');
          const item = line.items;
          const brand = item?.lpg_brands;
          return {
            name: `${brand?.brand_name || item?.brand || 'Unknown'} ${item?.size_kg ?? ''}kg`.trim(),
            type: line.type,
            quantity: Number(line.quantity), unit_price: Number(line.unit_price), line_total: Number(line.line_total),
          };
        }),
      };
      if (method === 'browser' || !config) return printBrowserReceipt(receipt);
      return sendReceipt(config, receipt);
    },
    onSuccess: result => { toast.success(result.message); },
    onError: error => { toast.error(`Receipt not confirmed: ${error.message} The completed sale is saved.`, { duration: 7000 }); },
  });
}
