import test from 'node:test';
import assert from 'node:assert/strict';
import { validatePayments } from '../src/lib/payments.ts';
import { formatReceipt } from '../src/lib/receipt.ts';
import { browserReceiptHTML } from '../src/lib/browserPrint.ts';
import type { PaymentDraft, PaymentWallet } from '../src/types/finance.ts';
import type { ReceiptData } from '../src/types/receipt.ts';
const wallets: PaymentWallet[] = [{ wallet_id: 'cash', name: 'Cash Register', kind: 'cash', type: 'cash' }, { wallet_id: 'bkash', name: 'bKash', kind: 'bkash', type: 'bkash' }];
const entry = (wallet_id: string, amount: string): PaymentDraft => ({ id: wallet_id, wallet_id, amount, reference: '' });
test('split decimals use minor units and partial amounts remain due', () => {
  assert.equal(validatePayments([entry('cash', '0.10'), entry('bkash', '0.20')], .3, wallets).error, null);
  const partial = validatePayments([entry('cash', '100'), entry('bkash', '200.25')], 500, wallets);
  assert.equal(partial.paid, 300.25); assert.equal(partial.due, 199.75); assert.equal(partial.payments.length, 2);
  assert.equal(validatePayments([], 500, wallets).due, 500);
});
test('invalid, unknown and excessive payments are rejected', () => {
  for (const amount of ['', '-1', '0', '1.001', 'NaN', 'Infinity', '2e2']) assert(validatePayments([entry('cash', amount)], 500, wallets).error);
  assert(validatePayments([entry('missing', '1')], 500, wallets).error);
  assert(validatePayments([entry('cash', '501')], 500, wallets).error);
});
const receipt: ReceiptData = { sale_id: 'finance-test', created_at: '2026-10-20T10:00:00Z', shop_name: 'বাংলা দোকান', customer_name: 'Customer', customer_phone: '01700000000', customer_tier: 'retail', items: [{ name: 'Long brand name with Bengali বাংলা 12kg', type: 'package', quantity: 1, unit_price: 500, line_total: 500 }], subtotal: 500, total_amount: 500, discount_amount: 0, exchange_fee: 0, paid_amount: 300, due_amount: 200, payments: [{ wallet_name: 'Cash Register', method: 'cash', amount: 100 }, { wallet_name: '<b>bKash</b>', method: 'bkash', amount: 200 }] };
test('58 and 80mm use distinct item layouts, retain partial payments and escape wallet names', () => {
  const narrow = formatReceipt(receipt, 58), wide = formatReceipt(receipt, 80);
  assert(narrow.length > wide.length); assert.equal(narrow.find(l => l.text.startsWith('Long'))?.right, undefined);
  assert.equal(wide.find(l => l.text.startsWith('Long'))?.right, 'Tk 500.00');
  for (const lines of [narrow, wide]) {
    assert(lines.some(l => l.text === 'PARTIALLY PAID'));
    assert(lines.some(l => l.text === 'Remaining due' && l.right === 'Tk 200.00'));
    assert(lines.some(l => l.text === 'Cash Register' && l.right === 'Tk 100.00'));
  }
  const html = browserReceiptHTML(receipt, 58); assert(html.includes('&lt;b&gt;bKash&lt;/b&gt;')); assert(!html.includes('<b>bKash</b>'));
  assert(formatReceipt({ ...receipt, payments: [], paid_amount: 0, due_amount: 500 }).some(l => l.text === 'UNPAID'));
  assert(formatReceipt({ ...receipt, paid_amount: 500, due_amount: 0 }).some(l => l.text === 'PAID IN FULL'));
  assert(formatReceipt({ ...receipt, payments: [{ wallet_name: 'Personal account', method: 'bank', amount: 300 }] }).some(l => l.text === 'Bank · Personal account'));
});
