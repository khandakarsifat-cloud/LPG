import { Package, Users, DollarSign, TrendingUp, Activity, ShoppingBag } from 'lucide-react';
import { useDashboardStats } from '../hooks/useDashboard';
import { SalesFeed } from '../components/dashboard/SalesFeed';
import { formatBDNumber } from '../lib/formatBDT';
import { Link } from 'react-router-dom';

export const Dashboard = () => {
  const { data: stats, isLoading } = useDashboardStats();

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '1.5rem', height: '100%', overflow: 'hidden' }}>
      <div style={{ flexShrink: 0 }}>
        <h1 style={{ fontSize: '1.875rem', fontWeight: 700 }}>Overview</h1>
        <p style={{ color: 'var(--text-muted)' }}>Real-time business metrics and ledger state.</p>
      </div>

      <div className="stats-grid" style={{ flexShrink: 0 }}>
        <div className="glass-panel stat-card">
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
            <div className="stat-label">Total Revenue (Today)</div>
            <div style={{ padding: '0.5rem', background: 'rgba(16, 185, 129, 0.1)', color: 'var(--accent)', borderRadius: 'var(--radius-md)' }}>
              <DollarSign size={20} />
            </div>
          </div>
          <div className="stat-value">
            {isLoading ? '...' : `৳${formatBDNumber(stats?.todayRevenue || 0)}`}
          </div>
          <div style={{ fontSize: '0.875rem', color: 'var(--accent)', display: 'flex', alignItems: 'center', gap: '0.25rem' }}>
            <TrendingUp size={14} /> Completed Sales
          </div>
        </div>

        <div className="glass-panel stat-card" style={{ '--primary': 'var(--warning)' } as React.CSSProperties}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
            <div className="stat-label">Inventory Movements</div>
            <div style={{ padding: '0.5rem', background: 'rgba(245, 158, 11, 0.1)', color: 'var(--warning)', borderRadius: 'var(--radius-md)' }}>
              <Package size={20} />
            </div>
          </div>
          <div className="stat-value">
            {isLoading ? '...' : stats?.todayMovements.toLocaleString()}
          </div>
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
          <div className="stat-value">
            {isLoading ? '...' : stats?.totalCustomers.toLocaleString()}
          </div>
          <div style={{ fontSize: '0.875rem', color: 'var(--text-muted)' }}>
            Across all tiers
          </div>
        </div>
      </div>

      <div style={{ display: 'flex', gap: '1.5rem', flex: 1, minHeight: 0 }}>
        {/* Sales Feed */}
        <div className="glass-panel card" style={{ flex: 2, display: 'flex', flexDirection: 'column', minHeight: 0 }}>
          <div className="card-header" style={{ flexShrink: 0, paddingBottom: '1rem', borderBottom: '1px solid var(--border-color)' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: '0.5rem' }}>
              <ShoppingBag size={20} style={{ color: 'var(--primary)' }} />
              <h2 className="card-title" style={{ margin: 0 }}>Today's Sales</h2>
            </div>
            <Link to="/inventory" className="btn btn-ghost" style={{ textDecoration: 'none' }}>
              View All
            </Link>
          </div>
          <div style={{ flex: 1, overflowY: 'auto', padding: '1rem 0' }}>
            <SalesFeed />
          </div>
        </div>
        
        {/* Low Stock Alerts */}
        <div className="glass-panel card" style={{ flex: 1, display: 'flex', flexDirection: 'column', minHeight: 0 }}>
          <div className="card-header" style={{ flexShrink: 0, paddingBottom: '1rem', borderBottom: '1px solid var(--border-color)' }}>
            <h2 className="card-title" style={{ margin: 0 }}>Low Stock Alerts</h2>
          </div>
          <div style={{ flex: 1, overflowY: 'auto', padding: '1rem 0', display: 'flex', flexDirection: 'column', gap: '1rem' }}>
            {/* Hardcoded placeholder for now until Low Stock hook is built */}
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', paddingBottom: '1rem', borderBottom: '1px solid var(--border-color)' }}>
              <div>
                <div style={{ fontWeight: 500 }}>Example 12kg Cylinder</div>
                <div style={{ fontSize: '0.75rem', color: 'var(--text-muted)' }}>Threshold: 20</div>
              </div>
              <div style={{ color: 'var(--danger)', fontWeight: 600 }}>12 left</div>
            </div>
            <div style={{ fontSize: '0.8rem', color: 'var(--text-muted)', textAlign: 'center', fontStyle: 'italic', marginTop: '1rem' }}>
              Low stock module coming soon
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};
