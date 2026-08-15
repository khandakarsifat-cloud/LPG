import { Outlet, NavLink, useNavigate } from 'react-router-dom';
import {
  Bell,
  ChevronDown,
  CreditCard,
  Factory,
  LayoutDashboard,
  LogOut,
  Moon,
  Package,
  Search,
  Settings,
  ShoppingCart,
  Sun,
  Truck,
  UserCircle,
  UserRound,
  Users,
} from 'lucide-react';
import { useEffect, useState } from 'react';
import { useAuth } from '../contexts/AuthContext';
import { applyTheme, getPreferredTheme, getStoredTheme, persistTheme, type AppTheme } from '../lib/theme';

const navItems = [
  { path: '/', label: 'Dashboard', icon: LayoutDashboard, end: true },
  { path: '/inventory', label: 'Inventory', icon: Package },
  { path: '/pos', label: 'Point of Sale', icon: ShoppingCart },
  { path: '/purchases', label: 'Purchases', icon: ShoppingCart },
  { path: '/customers', label: 'Customers', icon: Users },
  { path: '/employees', label: 'Employees', icon: UserRound },
  { path: '/finance', label: 'Finance', icon: CreditCard },
  { path: '/logistics', label: 'Logistics', icon: Truck },
  { path: '/gas-plants', label: 'Gas Plants', icon: Factory },
  { path: '/settings', label: 'Settings', icon: Settings },
];

export const Layout = () => {
  const { profile, signOut } = useAuth();
  const navigate = useNavigate();
  const [userMenuOpen, setUserMenuOpen] = useState(false);
  const [theme, setTheme] = useState<AppTheme>(() => getStoredTheme() ?? getPreferredTheme());

  useEffect(() => {
    applyTheme(theme);
    persistTheme(theme);
  }, [theme]);

  const handleSignOut = async () => {
    await signOut();
    navigate('/login');
  };

  const initials = profile?.full_name
    ? profile.full_name.split(' ').map((n) => n[0]).join('').toUpperCase().slice(0, 2)
    : '?';

  return (
    <div className="app-container">
      <aside className="sidebar">
        <div className="sidebar-logo">
          <span className="sidebar-logo-text">
            Nexus<span>LPG</span>
          </span>
          <div className="sidebar-logo-badge">OPS</div>
        </div>

        <nav className="sidebar-nav" aria-label="Primary navigation">
          <div className="sidebar-nav-label">Operations</div>
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

        <div className="sidebar-tenant-card">
          <div className="sidebar-tenant-info">
            <div className="sidebar-tenant-avatar">{initials}</div>
            <div>
              <div className="sidebar-tenant-name">
                {profile?.business_name ?? 'Loading...'}
              </div>
              <div className="sidebar-tenant-role">Owner workspace</div>
            </div>
          </div>
        </div>
      </aside>

      <main className="main-content">
        <header className="topbar">
          <div className="topbar-search">
            <Search size={16} className="topbar-search-icon" />
            <input
              type="text"
              placeholder="Search workspace"
              className="input-field topbar-search-input"
              aria-label="Search workspace"
            />
          </div>

          <div className="topbar-actions">
            <button
              className="topbar-icon-btn"
              type="button"
              aria-label={theme === 'dark' ? 'Switch to light theme' : 'Switch to dark theme'}
              title={theme === 'dark' ? 'Switch to light theme' : 'Switch to dark theme'}
              onClick={() => setTheme((currentTheme) => (currentTheme === 'dark' ? 'light' : 'dark'))}
            >
              {theme === 'dark' ? <Sun size={18} /> : <Moon size={18} />}
            </button>

            <button className="topbar-icon-btn" aria-label="Notifications">
              <Bell size={18} />
              <span className="topbar-notif-dot" />
            </button>

            <div className="user-menu-wrapper">
              <button
                className="user-menu-trigger"
                onClick={() => setUserMenuOpen((v) => !v)}
                aria-haspopup="menu"
                aria-expanded={userMenuOpen}
              >
                <div className="user-avatar">{initials === '?' ? <UserCircle size={18} /> : initials}</div>
                <div className="user-menu-info">
                  <span className="user-menu-name">{profile?.full_name ?? 'Signed in user'}</span>
                  <span className="user-menu-email">{profile?.email ?? 'No email'}</span>
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
                <div className="user-menu-dropdown glass-panel" role="menu">
                  <div className="user-menu-header">
                    <div className="user-avatar user-avatar-lg">
                      {initials === '?' ? <UserCircle size={20} /> : initials}
                    </div>
                    <div>
                      <div style={{ fontWeight: 700 }}>{profile?.full_name ?? 'Signed in user'}</div>
                      <div style={{ fontSize: '0.75rem', color: 'var(--text-muted)' }}>
                        {profile?.business_name ?? 'Workspace'}
                      </div>
                    </div>
                  </div>
                  <div className="user-menu-divider" />
                  <button
                    className="user-menu-item user-menu-item-danger"
                    onClick={handleSignOut}
                    role="menuitem"
                  >
                    <LogOut size={15} />
                    Sign Out
                  </button>
                </div>
              )}
            </div>
          </div>
        </header>

        <div className="page-content">
          <Outlet />
        </div>
      </main>
    </div>
  );
};
