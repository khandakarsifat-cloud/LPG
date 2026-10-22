import type { PaymentDraft, PaymentInput, PaymentWallet } from '../types/finance.ts';

export const paymentMethodLabel: Record<string, string> = { cash: 'Cash', bkash: 'bKash', nagad: 'Nagad', bank: 'Bank', other: 'Other', logistics: 'Logistics' };
export const minorUnits = (amount: number) => Math.round((amount + Number.EPSILON) * 100);
export function paymentDraft(wallets: PaymentWallet[], amount: number): PaymentDraft {
  return { id: crypto.randomUUID(), wallet_id: wallets.find(w => w.type === 'cash')?.wallet_id ?? wallets[0]?.wallet_id ?? '', amount: (Math.max(0, minorUnits(amount)) / 100).toFixed(2), reference: '' };
}
export function validatePayments(entries: PaymentDraft[], total: number, wallets: PaymentWallet[]) {
  let paid = 0;
  const payments: PaymentInput[] = [];
  if (entries.length > 20) return { paid: 0, due: total, payments, error: 'Use up to 20 payment entries.' };
  for (const entry of entries) {
    if (!wallets.some(w => w.wallet_id === entry.wallet_id)) return { paid: paid / 100, due: total, payments, error: 'Select an available payment wallet.' };
    if (!/^\d+(\.\d{1,2})?$/.test(entry.amount) || !Number.isFinite(Number(entry.amount)) || Number(entry.amount) <= 0) return { paid: paid / 100, due: total, payments, error: 'Each payment needs a positive amount with up to two decimals. Remove entries for no initial payment.' };
    paid += minorUnits(Number(entry.amount));
    payments.push({ wallet_id: entry.wallet_id, amount: Number(entry.amount), reference: entry.reference.trim() });
  }
  const due = (minorUnits(total) - paid) / 100;
  return { paid: paid / 100, due, payments, error: due < 0 ? 'Payments exceed the amount due.' : null };
}
