import { useState } from 'react';
import { useFifoStock } from '../../hooks/useProductPerformance';
import { formatBDT } from '../../lib/formatBDT';
import { Pagination } from '../ui/Pagination';

const money = (value: number | null) => value === null ? 'Unavailable' : formatBDT(value);
const date = (value: string) => new Date(value).toLocaleString('en-BD', {
  timeZone: 'Asia/Dhaka', dateStyle: 'medium', timeStyle: 'short',
});

export function StockCostTable({ itemId, component, business }: {
  itemId: string; component: 'all' | 'gas' | 'bottle' | 'unit'; business: 'lpg' | 'stove';
}) {
  const [page, setPage] = useState(0);
  const [tier, setTier] = useState('retail');
  const query = useFifoStock(itemId, tier, page, component);
  return <section className="cost-panel" aria-label="FIFO stock costs and margins">
    <header>
      <div><h3>Available components & margins</h3><span>Gas and Bottle use independent FIFO queues</span></div>
      <label className="input-group"><span className="input-label">Selling price tier</span>
        <select className="input-field" value={tier} onChange={event => { setTier(event.target.value); setPage(0); }}>
          <option value="retail">Retail</option><option value="wholesale">Wholesale</option>
        </select>
      </label>
    </header>
    {query.isPending && <p className="report-message" role="status">Loading component costs…</p>}
    {query.error && <p className="report-message" role="alert">{query.error.message}
      <button className="btn btn-secondary" onClick={() => void query.refetch()}>Retry</button>
    </p>}
    {query.data && <>
      <div className="fifo-reference-prices">{query.data.prices.map(price => <span key={price.price_type}>
        <span>{business === 'stove' ? 'Selling price' : price.price_type === 'refill' ? 'Refill selling price' : 'Package selling price'}</span>
        <strong>{money(price.price)}</strong>
        <small>{price.customer_tier !== tier ? 'Retail fallback · ' : ''}Effective {date(price.effective_from)}</small>
      </span>)}</div>
      <div className="report-table-scroll"><table className="report-table cost-table">
        <thead><tr><th scope="col">Source</th><th scope="col">Component</th>
          <th scope="col">Available quantity</th><th scope="col">Available value</th>
          <th scope="col">Unit cost</th><th scope="col">Projected margin / unit</th></tr></thead>
        <tbody>{query.data.layers.map(layer => <tr key={layer.layer_id}>
          <th scope="row"><strong>{layer.source_kind.replaceAll('_', ' ')}</strong><small>{date(layer.acquired_at)}</small>
            {layer.in_transit > 0 && <small>{layer.in_transit} reserved in transit</small>}
            {layer.estimated && <small>Estimated basis</small>}
          </th>
          <td>{layer.component === 'gas' ? 'Gas' : layer.component === 'bottle' ? 'Bottle' : 'Product'}</td>
          <td>{layer.remaining}</td><td>{money(layer.carrying_value)}</td><td>{money(layer.unit_cost)}</td>
          <td><strong>{money(layer.projected_margin)}</strong>
            {layer.component === 'bottle' && <small>Package − Refill price − Bottle cost</small>}
          </td>
        </tr>)}
        {!query.data.layers.length && <tr><td colSpan={6} className="report-empty">No available components.</td></tr>}
        </tbody>
      </table></div>
      <div className="fifo-summary"><span>{business === 'lpg'
        ? `${query.data.summary.gas} filled · ${query.data.summary.bottle - query.data.summary.gas} empty · ${query.data.summary.transit_bottles} bottles in transit`
        : `${query.data.summary.unit} product units`}</span></div>
      <Pagination page={page} pageSize={25} total={query.data.total} onChange={setPage} busy={query.isFetching} label="component layers" />
      <p className="finance-note">Costs include attributable labour and transport. Bottle acquisitions keep their original cost and date through refilling.
        Margins use current selling prices. Missing prices or estimated costs show Unavailable.</p>
    </>}
  </section>;
}
