import { Link } from 'react-router-dom';
import { DollarSign, Package, ShoppingBag, TrendingUp, Users } from 'lucide-react';
import { useDashboardStats } from '../hooks/useDashboard';
import { SalesFeed } from '../components/dashboard/SalesFeed';
import { formatBDNumber } from '../lib/formatBDT';

export const Dashboard = () => {
  const { data: stats, isLoading } = useDashboardStats();

  return (
    <div className="page-container">
      <div className="page-header">
        <div>
          <h1 className="page-title">Operations Overview</h1>
          <p className="page-subtitle">Daily sales, stock activity, and customer coverage.</p>
        </div>
        <Link to="/pos" className="btn btn-primary">
          <ShoppingBag size={16} />
          Open POS
        </Link>
      </div>

      <div className="stats-grid">
        <div className="glass-panel stat-card">
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
            <div className="stat-label">Today Revenue</div>
            <div className="inv-stat-icon" style={{ background: 'var(--accent-weak)', color: 'var(--accent)' }}>
              <DollarSign size={18} />
            </div>
          </div>
          <div className="stat-value">
            {isLoading ? '...' : `Tk ${formatBDNumber(stats?.todayRevenue || 0)}`}
          </div>
          <div style={{ fontSize: 'var(--font-sm)', color: 'var(--accent)', display: 'flex', alignItems: 'center', gap: '0.25rem' }}>
            <TrendingUp size={14} /> Completed sales
          </div>
        </div>

        <div className="glass-panel stat-card">
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
            <div className="stat-label">Inventory Movements</div>
            <div className="inv-stat-icon" style={{ background: 'var(--warning-weak)', color: 'var(--warning)' }}>
              <Package size={18} />
            </div>
          </div>
          <div className="stat-value">
            {isLoading ? '...' : stats?.todayMovements.toLocaleString()}
          </div>
          <div style={{ fontSize: 'var(--font-sm)', color: 'var(--text-muted)' }}>
            Actions recorded today
          </div>
        </div>

        <div className="glass-panel stat-card">
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
            <div className="stat-label">Active Customers</div>
            <div className="inv-stat-icon">
              <Users size={18} />
            </div>
          </div>
          <div className="stat-value">
            {isLoading ? '...' : stats?.totalCustomers.toLocaleString()}
          </div>
          <div style={{ fontSize: 'var(--font-sm)', color: 'var(--text-muted)' }}>
            Across retail and wholesale tiers
          </div>
        </div>
      </div>

      <div className="dashboard-workspace">
        <section className="glass-panel card" style={{ minHeight: '28rem' }}>
          <div className="card-header" style={{ borderBottom: '1px solid var(--border-color)', paddingBottom: 'var(--space-md)' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 'var(--space-sm)' }}>
              <ShoppingBag size={20} style={{ color: 'var(--primary)' }} />
              <h2 className="card-title">Today's Sales</h2>
            </div>
            <Link to="/pos" className="btn btn-ghost">
              New Sale
            </Link>
          </div>
          <div className="app-screen-scroll">
            <SalesFeed />
          </div>
        </section>

        <section className="glass-panel card">
          <div className="card-header" style={{ borderBottom: '1px solid var(--border-color)', paddingBottom: 'var(--space-md)' }}>
            <h2 className="card-title">Stock Exceptions</h2>
          </div>
          <div className="empty-state" style={{ flex: 1, minHeight: '18rem' }}>
            <Package size={28} />
            <p style={{ margin: 0 }}>Low-stock exception reporting is not configured yet.</p>
            <Link to="/inventory" className="btn btn-ghost">
              Review Inventory
            </Link>
          </div>
        </section>
      </div>
    </div>
  );
};
