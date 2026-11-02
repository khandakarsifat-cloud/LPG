import { useAuth } from '../../contexts/AuthContext';
import type { DashboardSale } from '../../types/dashboard';
import { formatBDT } from '../../lib/formatBDT';

export function SalesFeed({ sales, onOpen }: { sales: DashboardSale[]; onOpen: (id: string) => void }) {
  const { can } = useAuth(); const readable = can('sales:view') || can('receipts:print');
  return sales.length ? <div className="dashboard-sales-scroll"><table className="dashboard-sales-table"><thead><tr>
    <th>Time</th><th>Invoice No.</th><th>Customer</th><th>Items</th><th>Amount</th>
  </tr></thead><tbody>{sales.map(sale => <tr key={sale.sale_id} onClick={readable ? () => onOpen(sale.sale_id) : undefined}>
    <td data-label="Time"><time dateTime={sale.created_at}>{new Intl.DateTimeFormat('en-BD', { timeZone: 'Asia/Dhaka', hour: '2-digit', minute: '2-digit', hour12: true }).format(new Date(sale.created_at))}</time></td>
    <td data-label="Invoice"><button className="dashboard-invoice" disabled={!readable} onClick={event => { event.stopPropagation(); onOpen(sale.sale_id); }}>POS #{sale.sale_id.slice(0, 8).toUpperCase()}</button></td>
    <td data-label="Customer">{sale.customer}</td><td data-label="Items">{sale.items || 'No product lines'}</td><td data-label="Amount"><strong>{formatBDT(sale.amount)}</strong></td>
  </tr>)}</tbody></table></div> : <p className="dashboard-empty">No sales recorded today.</p>;
}
