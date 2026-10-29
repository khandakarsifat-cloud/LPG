import test from 'node:test';
import assert from 'node:assert/strict';
import { browserReceiptHTML } from '../src/lib/browserPrint.ts';
import { readReceiptPrintMethod, writeReceiptPrintMethod } from '../src/lib/receiptPrintPreference.ts';
import type { ReceiptData } from '../src/types/receipt.ts';

test('browser receipts escape untrusted content and retain Unicode, saved amounts and compact empty returns', () => {
  const receipt: ReceiptData = {
    sale_id: '11111111-1111-4111-8111-111111111111', created_at: '2026-10-16T00:00:00Z',
    shop_name: 'বাংলা দোকান', customer_name: '<script>window.print()</script>',
    customer_phone: '01700000000', customer_tier: 'retail',
    subtotal: 1200, discount_amount: 100, exchange_fee: 50, total_amount: 1150,
    paid_amount: 1150, due_amount: 0, unattributed_paid: 0, payments: [{ wallet_name: 'Cash Register', method: 'cash', amount: 1150 }],
    notes: '<img src=x onerror="alert(1)"> & thank you',
    items: [{ name: 'Gas 12kg', type: 'refill', quantity: 1, unit_price: 1200, line_total: 1200 },
      { item_id: 'empty', name: 'Empty', type: 'empty_return', quantity: 1, unit_price: 0, line_total: 0 }],
    bottles: { expected: 1, received: 1, outstanding: 0, obligations: [{ name: 'Empty', expected: 1 }], actual: [{ phase: 'checkout', item_id: 'empty', name: 'Empty', quantity: 1 }] },
  };
  const html = browserReceiptHTML(receipt);
  assert.ok(html.includes('বাংলা দোকান'));
  assert.ok(html.includes('&lt;script&gt;'));
  assert.ok(html.includes('&lt;img src=x onerror=&quot;alert(1)&quot;&gt; &amp; thank you'));
  assert.ok(!html.includes('<script>'));
  assert.ok(!html.includes('<img'));
  assert.ok(html.includes('Tk 1,150.00'));
  assert.ok(html.includes('Expected 1 | Received 1'));
  assert.ok(!html.includes('Free'));
  assert.ok(!html.includes('999'));
  assert.ok(html.includes('Bottle Settled'));
  assert.ok(html.includes('max-width: 72mm'));
  assert.ok(browserReceiptHTML(receipt, 58).includes('max-width: 48mm'));
});

test('browser output preferences are business-scoped, preserve the USB default, and survive reload reads', () => {
  const original = Object.getOwnPropertyDescriptor(globalThis, 'localStorage');
  const entries = new Map<string, string>();
  Object.defineProperty(globalThis, 'localStorage', { configurable: true, value: {
    getItem: (key: string) => entries.get(key) ?? null,
    setItem: (key: string, value: string) => { entries.set(key, value); },
  } });
  try {
    assert.equal(readReceiptPrintMethod('business-a'), 'windows_usb');
    writeReceiptPrintMethod('business-a', 'browser');
    assert.equal(readReceiptPrintMethod('business-a'), 'browser');
    assert.equal(readReceiptPrintMethod('business-b'), 'windows_usb');
    writeReceiptPrintMethod('business-a', 'windows_usb');
    assert.equal(readReceiptPrintMethod('business-a'), 'windows_usb');
  } finally {
    if (original) Object.defineProperty(globalThis, 'localStorage', original);
    else Reflect.deleteProperty(globalThis, 'localStorage');
  }
});
