import { Outlet, NavLink, useNavigate } from 'react-router-dom';
import {
  LayoutDashboard,
  Package,
  Users,
  CreditCard,
  Truck,
  Settings,
  Bell,
  Search,
  LogOut,
  ChevronDown,
  Factory,
  ShoppingCart
} from 'lucide-react';
import { useState } from 'react';
import { useAuth } from '../contexts/AuthContext';

const navItems = [
  { path: '/',           label: 'Dashboard',  icon: LayoutDashboard, end: true },
  { path: '/inventory',  label: 'Inventory',  icon: Package },
  { path: '/purchases',  label: 'Purchases',  icon: ShoppingCart },
  { path: '/pos',        label: 'POS',        icon: ShoppingCart },
  { path: '/customers',  label: 'Customers',  icon: Users },
  { path: '/finance',    label: 'Finance',    icon: CreditCard },
  { path: '/logistics',  label: 'Logistics',  icon: Truck },
  { path: '/gas-plants', label: 'Gas Plants', icon: Factory },
  { path: '/settings',   label: 'Settings',   icon: Settings },
];

export const Layout = () => {
  const { profile, signOut } = useAuth();
  const navigate = useNavigate();
  const [userMenuOpen, setUserMenuOpen] = useState(false);

  const handleSignOut = async () => {
    await signOut();
    navigate('/login');
  };

  const initials = profile?.full_name
    ? profile.full_name.split(' ').map((n) => n[0]).join('').toUpperCase().slice(0, 2)
    : '?';

  return (
    <div className="app-container">
      {/* ── Sidebar ── */}
      <aside className="sidebar">
        {/* Logo */}
        <div className="sidebar-logo">
          <span className="sidebar-logo-text">
            Nexus<span>LPG</span>
          </span>
          <div className="sidebar-logo-badge">ERP</div>
        </div>

        {/* Navigation */}
        <nav className="sidebar-nav">
          <div className="sidebar-nav-label">Main Menu</div>
          {navItems.map((item) => {
            const Icon = item.icon;
            return (
              <NavLink
                key={item.path}
                to={item.path}
                end={item.end}
                className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`}
              >
                <Icon size={18} />
                <span>{item.label}</span>
              </NavLink>
            );
          })}
        </nav>

        {/* Tenant Card at bottom */}
        <div className="sidebar-tenant-card glass-panel">
          <div className="sidebar-tenant-info">
            <div className="sidebar-tenant-avatar">{initials}</div>
            <div>
              <div className="sidebar-tenant-name">
                {profile?.business_name ?? 'Loading…'}
              </div>
              <div className="sidebar-tenant-role">Owner</div>
            </div>
          </div>
        </div>
      </aside>

      {/* ── Main Content ── */}
      <main className="main-content">
        {/* Topbar */}
        <header className="topbar">
          <div className="topbar-search">
            <Search size={16} className="topbar-search-icon" />
            <input
              type="text"
              placeholder="Search anything…"
              className="input-field topbar-search-input"
            />
          </div>

          <div className="topbar-actions">
            <button className="topbar-icon-btn" aria-label="Notifications">
              <Bell size={18} />
              <span className="topbar-notif-dot" />
            </button>

            {/* User menu */}
            <div className="user-menu-wrapper">
              <button
                className="user-menu-trigger"
                onClick={() => setUserMenuOpen((v) => !v)}
              >
                <div className="user-avatar">{initials}</div>
                <div className="user-menu-info">
                  <span className="user-menu-name">{profile?.full_name ?? '—'}</span>
                  <span className="user-menu-email">{profile?.email ?? '—'}</span>
                </div>
                <ChevronDown
                  size={14}
                  style={{
                    color: 'var(--text-muted)',
                    transform: userMenuOpen ? 'rotate(180deg)' : 'none',
                    transition: 'transform 0.2s',
                  }}
                />
              </button>

              {userMenuOpen && (
                <div className="user-menu-dropdown glass-panel">
                  <div className="user-menu-header">
                    <div className="user-avatar user-avatar-lg">{initials}</div>
                    <div>
                      <div style={{ fontWeight: 600 }}>{profile?.full_name}</div>
                      <div style={{ fontSize: '0.75rem', color: 'var(--text-muted)' }}>
                        {profile?.business_name}
                      </div>
                    </div>
                  </div>
                  <div className="user-menu-divider" />
                  <button
                    className="user-menu-item user-menu-item-danger"
                    onClick={handleSignOut}
                  >
                    <LogOut size={15} />
                    Sign Out
                  </button>
                </div>
              )}
            </div>
          </div>
        </header>

        {/* Page content */}
        <div className="page-content">
          <Outlet />
        </div>
      </main>
    </div>
  );
};
