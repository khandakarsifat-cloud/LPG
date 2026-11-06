import { Fragment, useState } from 'react';
import { useFifoStock } from '../../hooks/useProductPerformance';
import { formatBDT } from '../../lib/formatBDT';
import { Pagination } from '../ui/Pagination';

const money = (value: number | null) => value === null ? 'Unavailable' : formatBDT(value);
const date = (value: string) => new Date(value).toLocaleString('en-BD', { timeZone: 'Asia/Dhaka', dateStyle: 'medium', timeStyle: 'short' });

export function StockCostTable({ itemId, state, business }: { itemId: string; state: 'all' | 'filled' | 'empty'; business: 'lpg' | 'stove' }) {
  const [page, setPage] = useState(0);
  const [tier, setTier] = useState('retail');
  const query = useFifoStock(itemId, tier, page, state);
  return <section className="cost-panel" aria-label="FIFO stock costs and margins">
    <header><div><h3>Available stock & margins</h3><span>Original FIFO order · purchase entries stay separate</span></div><label className="input-group"><span className="input-label">Selling price tier</span><select className="input-field" value={tier} onChange={e => { setTier(e.target.value); setPage(0); }}><option value="retail">Retail</option><option value="wholesale">Wholesale</option></select></label></header>
    {query.isPending && <p className="report-message" role="status">Loading stock costs…</p>}
    {query.error && <p className="report-message" role="alert">{query.error.message} <button className="btn btn-secondary" onClick={() => void query.refetch()}>Retry</button></p>}
    {query.data && <>
      <div className="fifo-reference-prices">{query.data.prices.filter(p => business === 'lpg' || p.price_type === 'package').map(p => <span key={p.price_type}><span>{business === 'stove' ? 'Selling price' : p.price_type === 'refill' ? 'Refill selling price' : 'Package selling price'}</span><strong>{money(p.price)}</strong><small>{p.customer_tier !== tier ? 'Retail fallback · ' : ''}Effective {date(p.effective_from)}</small></span>)}</div>
      <div className="report-table-scroll"><table className="report-table cost-table unified-fifo-table"><thead><tr><th scope="col">Stock / source</th><th scope="col">Component</th><th scope="col">Remaining units</th><th scope="col">Remaining value</th><th scope="col">Unit cost</th><th scope="col">Margin / unit <small>Projected at current prices</small></th></tr></thead>
      <tbody>{query.data.layers.map(row => {
        const filledLpg = row.state === 'filled' && business === 'lpg';
        const identity = <><strong>{business === 'stove' ? 'Product stock' : row.state === 'filled' ? 'Filled stock' : 'Empty bottles'}</strong><small>{row.source_count > 1 ? `${row.source_count} consecutive customer returns` : row.source_kind === 'purchase_receipt' || row.source_kind === 'stove_purchase_receipt' ? 'Purchase receipt' : row.source_kind.replaceAll('_', ' ')}</small>
          <small>{row.state === 'filled' && business === 'lpg' ? 'Gas received' : 'Received'} {date(row.acquired_at)}</small>{row.last_acquired_at !== row.acquired_at && <small>Through {date(row.last_acquired_at)}</small>}
          {business === 'lpg' && row.state === 'filled' && <><small>Bottle acquired {date(row.bottle_acquired_at)}</small><span className="fifo-origin">{row.bottle_origin === 'owned_reused' ? 'Owned bottle reused · not purchased' : row.bottle_origin === 'purchased' ? 'New bottle purchased' : 'Recorded bottle stock'}</span></>}{row.estimated && <small>Estimated basis · margin unavailable</small>}</>;
        return <Fragment key={row.group_id}>{filledLpg && <tr className="fifo-group-start"><th rowSpan={2} scope="rowgroup">{identity}</th><th scope="row">Gas</th><td>{row.remaining}</td><td>{money(row.gas_value)}</td><td>{money(row.gas_unit_cost)}</td><td><strong>{money(row.refill_margin)}</strong><small>Refill margin</small></td></tr>}
          <tr className={filledLpg ? 'fifo-group-end' : 'fifo-group-start fifo-group-end'}>{!filledLpg && <th scope="row">{identity}</th>}<th scope="row">{business === 'stove' ? 'Product' : 'Bottle'}</th><td>{row.remaining}</td><td>{money(business === 'stove' ? row.carrying_value : row.bottle_value)}</td><td>{money(business === 'stove' ? row.estimated ? null : row.carrying_value / row.remaining : row.bottle_unit_cost)}</td><td><strong>{money(business === 'stove' ? row.package_margin : row.bottle_contribution_margin)}</strong><small>{business === 'stove' ? 'Product margin' : 'Implied Bottle contribution'}</small>{filledLpg && <small>Package margin (Gas + Bottle): {money(row.package_margin)}</small>}</td></tr></Fragment>;
      })}{!query.data.layers.length && <tr><td colSpan={6} className="report-empty">No available stock in this view.</td></tr>}</tbody>
      </table></div>
      <div className="fifo-summary"><span>{query.data.summary.filled} {business === 'lpg' ? 'filled' : 'product units'}{business === 'lpg' ? ` · ${query.data.summary.empty} empty` : ''}</span><strong>Carrying value {money(query.data.summary.carrying_value)}</strong></div>
      <Pagination page={page} pageSize={25} total={query.data.total} onChange={setPage} busy={query.isFetching} label="stock groups" />
      <p className="finance-note">{business === 'lpg' ? 'Gas and Bottle rows describe the same filled cylinders. Owned bottles keep their original cost and acquisition date through refilling. Bottle contribution uses Package − Refill selling prices; it is not an empty-bottle sale margin. ' : ''}Margins are projections, not realized profit. Missing prices or estimated costs show Unavailable; rebates and future exchange variance are excluded.</p>
    </>}
  </section>;
}
