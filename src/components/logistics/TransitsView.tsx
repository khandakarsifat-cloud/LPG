import { useState } from 'react';
import { Plus, Route } from 'lucide-react';
import { useAuth } from '../../contexts/AuthContext';
import { useTransits } from '../../hooks/useLogistics';
import { formatBDT } from '../../lib/formatBDT';
import { TransitCostsModal } from './TransitCostsModal';
import { CreateCustomTransitModal } from './CreateCustomTransitModal';
import '../purchases/purchases.css';

export function TransitsView() {
  const query = useTransits();
  const { can } = useAuth();
  const [search, setSearch] = useState('');
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [creating, setCreating] = useState(false);
  const transits = query.data ?? [];
  const selected = transits.find(t => t.transit_id === selectedId);
  const filtered = transits.filter(t => [t.truck_name, t.transit_id, t.client_name, t.destination, t.description].join(' ').toLowerCase().includes(search.toLowerCase()));
  if (query.isLoading) return <p className="purchase-hint">Loading transits…</p>;
  if (query.isError) return <p role="alert" className="purchase-error">Transits could not be loaded. <button className="btn btn-secondary" onClick={() => void query.refetch()}>Retry</button></p>;
  return <div className="transits-view">
    <div className="purchase-section-heading"><label className="input-group transit-search"><span className="input-label">Search transits</span><input className="input-field" placeholder="Truck, client, destination or ID…" value={search} onChange={e => setSearch(e.target.value)} /></label>
      {can('logistics:manage') && <button className="btn btn-primary" onClick={() => setCreating(true)}><Plus size={16} /> Add custom transit</button>}</div>
    {(['active', 'finished'] as const).map(group => {
      const rows = filtered.filter(t => group === 'active' ? t.status === 'active' : t.status !== 'active');
      return <section key={group}><h3 className="transit-group-title">{group === 'active' ? 'Active transits' : 'Completed & cancelled'} <span>{rows.length}</span></h3>
        {!rows.length ? <p className="purchase-hint">No {group === 'active' ? 'active' : 'completed or cancelled'} transits.</p> : <div className="transit-grid">{rows.map(t => <button key={t.transit_id} className="glass-panel transit-card" onClick={() => setSelectedId(t.transit_id)}>
          <div className="purchase-section-heading"><strong><Route size={18} /> {t.truck_name}</strong><span className="purchase-badge transit-cost-state">{t.purchase_id ? 'Purchase' : 'Custom'}</span></div>
          <div className="purchase-statuses"><span className={`purchase-badge ${t.status === 'cancelled' ? 'transit-cancelled' : t.status === 'active' ? 'payment-unpaid' : 'payment-paid'}`}>{t.status === 'active' ? 'In transit' : t.status === 'cancelled' ? 'Cancelled' : 'Completed'}</span><span className="purchase-badge transit-cost-state">{t.closed_at ? 'Costs closed' : 'Costs open'}</span></div>
          <p>{t.client_name || 'Client not recorded'}{t.destination ? ` · ${t.destination}` : ''}</p>
          <div className="transit-card-total"><span>Operating costs</span><strong>{formatBDT(Number(t.total_cost))}</strong></div>
          <small>{new Date(t.created_at).toLocaleDateString('en-BD', { timeZone: 'Asia/Dhaka' })} · {t.transit_id.slice(0, 8)}</small>
        </button>)}</div>}
      </section>;
    })}
    {selected && <TransitCostsModal open transit={selected} onClose={() => setSelectedId(null)} />}
    <CreateCustomTransitModal open={creating} onClose={() => setCreating(false)} />
  </div>;
}
