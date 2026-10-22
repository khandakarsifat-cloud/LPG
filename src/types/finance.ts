export type WalletKind = 'cash' | 'bkash' | 'nagad' | 'bank' | 'other' | 'logistics';
export interface PaymentWallet { wallet_id: string; name: string; kind: WalletKind; type: string }
export interface FinanceWallet extends PaymentWallet {
  tenant_id: string; balance: number; opening_balance: number; details: string;
  is_active: boolean; revision: number; created_at: string; updated_at: string;
}
export interface SalePayment {
  payment_id: string; wallet_id: string; wallet_name: string; method: WalletKind;
  amount: number; phase: 'checkout' | 'collection'; reference: string; created_at: string;
}
export interface PaymentInput { wallet_id: string; amount: number; reference?: string }
export interface PaymentDraft { id: string; wallet_id: string; amount: string; reference: string }
export interface SaleSettlement {
  sale_id: string; tracking: boolean; total: number; paid: number; due: number;
  paid_at_checkout: number; checkout_payments: SalePayment[]; payment_count: number;
  payments: SalePayment[]; receipt_payments: Pick<SalePayment, 'wallet_name' | 'method' | 'amount' | 'phase'>[];
}
export interface WalletLedgerEntry {
  transaction_id: string; wallet_id: string; wallet_name: string; type: string; amount: number;
  balance_after: number; created_at: string; description: string; reference_id: string | null;
  operation_id: string | null; counterparty: string | null; actor: string | null;
  payment_reference: string | null; customer_name: string | null; customer_phone: string | null;
  source: 'sale' | 'purchase' | 'transit' | null;
}
export interface LedgerFilters { search: string; wallet: string; type: string; from: string; to: string; min: string; max: string; direction: string; sort: string }
export interface WalletLedger { entries: WalletLedgerEntry[]; total: number; received: number; paid_out: number }
export interface SaleDue { sale_id: string; customer_id: string; name: string; phone: string; shop_name: string | null; created_at: string; total_amount: number; paid_amount: number; due: number }
export interface FinanceDues { entries: SaleDue[]; total: number; due: number }
