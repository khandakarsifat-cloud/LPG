
import { Package, Users, DollarSign, TrendingUp } from 'lucide-react';

export const Dashboard = () => {
  return (
    <div>
      <div style={{ marginBottom: '2rem' }}>
        <h1 style={{ fontSize: '1.875rem', fontWeight: 700 }}>Overview</h1>
        <p style={{ color: 'var(--text-muted)' }}>Real-time business metrics and ledger state.</p>
      </div>

      <div className="stats-grid">
        <div className="glass-panel stat-card">
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
            <div className="stat-label">Total Revenue (Today)</div>
            <div style={{ padding: '0.5rem', background: 'rgba(16, 185, 129, 0.1)', color: 'var(--accent)', borderRadius: 'var(--radius-md)' }}>
              <DollarSign size={20} />
            </div>
          </div>
          <div className="stat-value">$12,450.00</div>
          <div style={{ fontSize: '0.875rem', color: 'var(--accent)', display: 'flex', alignItems: 'center', gap: '0.25rem' }}>
            <TrendingUp size={14} /> +8.2% from yesterday
          </div>
        </div>

        <div className="glass-panel stat-card" style={{ '--primary': 'var(--warning)' } as React.CSSProperties}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
            <div className="stat-label">Inventory Movements</div>
            <div style={{ padding: '0.5rem', background: 'rgba(245, 158, 11, 0.1)', color: 'var(--warning)', borderRadius: 'var(--radius-md)' }}>
              <Package size={20} />
            </div>
          </div>
          <div className="stat-value">342</div>
          <div style={{ fontSize: '0.875rem', color: 'var(--text-muted)' }}>
            Actions recorded today
          </div>
        </div>

        <div className="glass-panel stat-card" style={{ '--primary': 'var(--primary)' } as React.CSSProperties}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
            <div className="stat-label">Active Customers</div>
            <div style={{ padding: '0.5rem', background: 'rgba(59, 130, 246, 0.1)', color: 'var(--primary)', borderRadius: 'var(--radius-md)' }}>
              <Users size={20} />
            </div>
          </div>
          <div className="stat-value">1,893</div>
          <div style={{ fontSize: '0.875rem', color: 'var(--text-muted)' }}>
            Across all tiers
          </div>
        </div>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: '1.5rem' }}>
        <div className="glass-panel card">
          <div className="card-header">
            <h2 className="card-title">Recent Transactions Ledger</h2>
            <button className="btn btn-ghost">View All</button>
          </div>
          <div style={{ color: 'var(--text-muted)', fontSize: '0.875rem', textAlign: 'center', padding: '3rem' }}>
            Connect to Supabase to view real-time immutable ledger entries.
          </div>
        </div>
        
        <div className="glass-panel card">
          <div className="card-header">
            <h2 className="card-title">Low Stock Alerts</h2>
          </div>
          <div style={{ display: 'flex', flexDirection: 'column', gap: '1rem' }}>
            {[
              { item: '12.5kg Cylinder (Empty)', qty: 45, threshold: 50 },
              { item: '50kg Cylinder (Filled)', qty: 12, threshold: 20 },
            ].map((alert, i) => (
              <div key={i} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', paddingBottom: '1rem', borderBottom: i === 0 ? '1px solid var(--border-color)' : 'none' }}>
                <div>
                  <div style={{ fontWeight: 500 }}>{alert.item}</div>
                  <div style={{ fontSize: '0.75rem', color: 'var(--text-muted)' }}>Threshold: {alert.threshold}</div>
                </div>
                <div style={{ color: 'var(--danger)', fontWeight: 600 }}>{alert.qty} left</div>
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
};
