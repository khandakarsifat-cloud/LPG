import type { BottleReceiptLine, BottleObligation, BottleProduct } from '../types/bottles.ts';

/** Expectations describe the agreement; actual receipts settle the aggregate count. */
export function validateBottles(obligations: readonly BottleObligation[], products: readonly BottleProduct[], lines: readonly BottleReceiptLine[], collection = false, previouslyReceived = obligations.reduce((sum, o) => sum + o.received, 0)) {
 const received = lines.reduce((sum,line) => sum + line.quantity,0); const used = new Set<string>();
 for (const line of lines) {
  const expected = obligations.find(o => o.item_id === line.received_item_id);
  const actual = products.find(p => p.item_id === line.received_item_id);
  if (!actual) return { error: 'Select a valid received product.', received };
  if (used.has(line.received_item_id)) return { error: 'Use one quantity per received product.', received };
  used.add(line.received_item_id);
  if (!Number.isSafeInteger(line.quantity) || line.quantity <= 0 || line.quantity > 2147483647) return { error: 'Received quantities must be positive whole numbers.', received };
  if ((!expected || expected.received + line.quantity > expected.expected) && !line.acknowledged) return { error: 'Acknowledge unexpected products or quantities above the original expectation.', received };
 }
 if (collection && previouslyReceived >= obligations.reduce((sum,o) => sum + o.expected, 0)) return { error: 'Bottle obligation is already settled.', received };
 if (collection && received === 0) return { error: 'Add at least one received bottle.', received };
 return { error: undefined, received };
}
