import type { SaleTransaction } from '../types/sale.ts';

/** Expected empty rows are presentation only; persisted refill lines own the obligation. */
export function saleDisplay(sale: SaleTransaction): SaleTransaction {
  if (sale.business_category === 'stove') return sale;
  const lines = sale.sale_items ?? [];
  return { ...sale, sale_items: [...lines, ...lines.filter(line => line.type === 'refill').map(line => ({
    ...line, type: 'empty_return', unit_price: 0, line_total: 0,
  }))] };
}
