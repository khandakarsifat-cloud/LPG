import assert from 'node:assert/strict';
import { test } from 'node:test';
import { gridPageCapacity, groupedPageStarts, pageForOffset } from '../src/lib/pagination.ts';

test('capacity changes preserve the anchor through a resize round trip', () => {
  const offset = 48;
  for (const size of [12, 15, 21, 10, 12]) {
    const page = pageForOffset(offset, size);
    assert.ok(page * size <= offset && (page + 1) * size > offset);
  }
  assert.equal(pageForOffset(offset, 12), 4);
});
test('empty or shrinking datasets clamp to a usable page', () => {
  assert.equal(pageForOffset(72, 12, 40), 3);
  assert.equal(pageForOffset(72, 12, 0), 0);
  assert.equal(pageForOffset(-5, 12), 0);
});
test('directory capacity fills rows and stays independent of card heights', () => {
  assert.equal(gridPageCapacity(4, 1040), 12);
  assert.equal(gridPageCapacity(7, 1820), 21);
  assert.equal(gridPageCapacity(1, 320), 10);
  assert.equal(gridPageCapacity(2, 550), 10);
  assert.equal(gridPageCapacity(3, 590), 12);
});
test('compact picker capacity stays in whole rows and is bounded on short and tall windows', () => {
  for (const columns of [1, 2, 3, 5, 9]) for (const height of [400, 568, 844, 1080, 2160]) {
    const size = gridPageCapacity(columns, columns * 160, height);
    assert.equal(size % columns, 0);
    assert.ok(size >= columns * 2 && size <= columns * 4);
  }
});

test('brand-aware pages reserve row endings, retain every record and report actual ranges', () => {
  const items = [3, 11, 16].flatMap((count, brand) => Array.from({ length: count }, () => ({ brand_id: String(brand) })));
  for (const columns of [1, 2, 3, 4, 7]) for (const rows of [2, 3, 4]) {
    const starts = groupedPageStarts(items, columns, columns * rows);
    const pages = starts.map((start, index) => items.slice(start, starts[index + 1] ?? items.length));
    assert.deepEqual(pages.flat(), items);
    for (const page of pages) {
      let used = 0;
      page.forEach((item, index) => {
        if (index && item.brand_id !== page[index - 1].brand_id && used % columns) used += columns - used % columns;
        used++;
      });
      assert.ok(used <= columns * rows);
      assert.ok(page.length > 0);
    }
  }
  assert.deepEqual(groupedPageStarts([], 4, 12), [0]);
  assert.deepEqual(groupedPageStarts(items, 4, 12), [0, 11, 22]);
});
