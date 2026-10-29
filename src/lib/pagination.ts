/** Keep the navigation anchor independent of capacity so resize round trips are lossless. */
export function pageForOffset(offset: number, pageSize: number, total?: number) {
  const page = Math.floor(Math.max(0, offset) / pageSize);
  return total === undefined ? page : Math.min(page, Math.max(0, Math.ceil(total / pageSize) - 1));
}

export function gridPageCapacity(columns: number, width: number, height?: number, rowHeight = 150) {
  // Variable-height directories scroll naturally; compact pickers use bounded rows.
  const rows = height === undefined
    ? width <= 600 ? Math.max(3, Math.ceil(10 / columns)) : 3
    : Math.max(2, Math.min(4, Math.floor((height - 320) / rowHeight)));
  return columns * rows;
}

/** Brand boundaries consume the remaining tracks in their row, including in pickers. */
export function groupedPageStarts(items: readonly { brand_id: string }[], columns: number, capacity: number) {
  const starts = [0];
  let used = 0;
  for (let index = 0; index < items.length; index++) {
    if (index > 0 && items[index].brand_id !== items[index - 1].brand_id && used % columns) {
      used += columns - used % columns;
    }
    if (used >= capacity) { starts.push(index); used = 0; }
    used++;
  }
  return starts;
}
