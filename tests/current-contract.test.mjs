import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';

test('current test commands reference existing entry points and canonical backend objects', () => {
  const { scripts } = JSON.parse(readFileSync('package.json', 'utf8'));
  for (const command of Object.values(scripts)) {
    for (const [, file] of command.matchAll(/node\s+([^\s;&]+\.mjs)/g)) {
      assert(existsSync(file), `Current command points at a removed entry: ${file}`);
      assert.doesNotMatch(readFileSync(file, 'utf8'), /\b(get_lpg_fifo_stock|fifo_positions|fifo_component_layers|empty_dispatched)\b/, file);
    }
  }
});

test('current source-contract fixtures use independent component fields', () => {
  for (const file of ['finance-visibility-performance.sql', 'access-performance-deletion.sql',
    'purchase-rebate.sql', 'purchase-transport-cash.sql', 'summarized-actions.sql']) {
    assert.doesNotMatch(readFileSync(`supabase/tests/${file}`, 'utf8'),
      /\b(filled_quantity|empty_quantity|filled_value|empty_value|get_lpg_fifo_stock|fifo_positions|fifo_component_layers|empty_return)\b/, file);
  }
});
