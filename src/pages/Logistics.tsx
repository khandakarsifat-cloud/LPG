import { useState } from 'react';
import { Plus, Truck } from 'lucide-react';
import { AddTruckDialog } from '../components/logistics/AddTruckDialog';
import { TrucksGrid } from '../components/logistics/TrucksGrid';

type Tab = 'trucks' | 'trips';

export const LogisticsPage = () => {
  const [tab, setTab] = useState<Tab>('trucks');
  const [addTruckOpen, setAddTruckOpen] = useState(false);

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
        <div style={{ display: 'flex', gap: '0.75rem' }}>
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
        {tab === 'trucks' && (
          <TrucksGrid />
        )}
      </div>

      {/* ── Dialogs ── */}
      <AddTruckDialog open={addTruckOpen} onClose={() => setAddTruckOpen(false)} />
    </div>
  );
};
