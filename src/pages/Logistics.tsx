import { useState } from 'react';
import { Plus, Truck } from 'lucide-react';
import { AddTruckModal } from '../components/logistics/AddTruckModal';
import { TransitsView } from '../components/logistics/TransitsView';
import { TrucksGrid } from '../components/logistics/TrucksGrid';
import { useWallets } from '../hooks/useLogistics';

type Tab = 'trucks' | 'transits';

export const LogisticsPage = () => {
  const { data: wallets = [] } = useWallets();
  const [tab, setTab] = useState<Tab>('trucks');
  const [addTruckOpen, setAddTruckOpen] = useState(false);

  const logisticsWallet = wallets?.find((w: any) => w.type === 'logistics');

  return (
    <div className="inventory-page">
      {/* ── Page Header ── */}
      <div className="page-header">
        <div>
          <h1 className="page-title">Logistics Management</h1>
          <p className="page-subtitle">
            Manage your fleet and track delivery operations.
          </p>
        </div>
        <div style={{ display: 'flex', gap: '1rem', alignItems: 'center' }}>
          {logisticsWallet && (
            <div style={{ 
              background: 'rgba(16,185,129,0.1)', 
              color: 'var(--accent)', 
              padding: '0.5rem 1rem', 
              borderRadius: '0.5rem',
              fontWeight: 600,
              display: 'flex',
              alignItems: 'center',
              gap: '0.5rem',
              border: '1px solid rgba(16,185,129,0.2)'
            }}>
              <span>Wallet:</span>
              <span style={{ fontSize: '1.25rem' }}>৳ {Number(logisticsWallet.balance).toLocaleString()}</span>
            </div>
          )}
          {tab === 'trucks' && (
            <button className="btn btn-primary" onClick={() => setAddTruckOpen(true)}>
              <Plus size={16} />
              Add Truck
            </button>
          )}
        </div>
      </div>

      {/* ── Tabs ── */}
      <div className="inv-tabs">
        {([
          { key: 'trucks', label: 'Fleet Management', icon: Truck },
          { key: 'transits', label: 'Transits & Trips', icon: Truck },
        ] as { key: Tab; label: string; icon: React.ElementType }[]).map(({ key, label, icon: Icon }) => (
          <button
            key={key}
            className={`inv-tab ${tab === key ? 'inv-tab-active' : ''}`}
            onClick={() => setTab(key)}
          >
            <Icon size={15} />
            {label}
          </button>
        ))}
      </div>

      {/* ── Tab Content ── */}
      <div className="inv-tab-content">
        {tab === 'trucks' && <TrucksGrid />}
        {tab === 'transits' && <TransitsView />}
      </div>

      {/* ── Dialogs ── */}
      <AddTruckModal open={addTruckOpen} onClose={() => setAddTruckOpen(false)} />
    </div>
  );
};
