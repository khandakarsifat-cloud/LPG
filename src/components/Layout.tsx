import { Outlet, NavLink, useLocation, useNavigate } from 'react-router-dom';
import {
  ChevronDown,
  ChevronLeft,
  ChevronRight,
  CreditCard,
  Factory,
  LayoutDashboard,
  LogOut,
  Menu,
  Moon,
  Package,
  Settings,
  ShoppingCart,
  Sun,
  Truck,
  UserCircle,
  UserRound,
  Users,
  Wallet,
  X,
} from 'lucide-react';
import { Suspense, useEffect, useState } from 'react';
import { useAuth } from '../contexts/AuthContext';
import { hasAnyPermission, routePermissions } from '../lib/authorization';
import { applyTheme, getPreferredTheme, getStoredTheme, persistTheme, type AppTheme } from '../lib/theme';
import { useWallets } from '../hooks/useLogistics';
import { formatBDT } from '../lib/formatBDT';

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

const SIDEBAR_COLLAPSED_STORAGE_KEY = 'lpg-sidebar-collapsed';

function DealershipWallet() {
  const { data, isLoading, isError } = useWallets();
  const wallet = data?.find(wallet => wallet.type === 'dealership');
  return <div className={`topbar-wallet${Number(wallet?.balance) < 0 ? ' negative' : ''}`}>
    <Wallet size={19} aria-hidden="true" />
    <div><span>Dealership wallet</span><strong>{isLoading ? '…' : isError || !wallet ? '—' : formatBDT(Number(wallet.balance))}</strong></div>
  </div>;
}

const getStoredSidebarCollapsed = (): boolean => {
  if (typeof window === 'undefined') return false;
  return window.localStorage.getItem(SIDEBAR_COLLAPSED_STORAGE_KEY) === 'true';
};

export const Layout = () => {
  const { profile, permissions, signOut } = useAuth();
  const navigate = useNavigate();
  const { pathname } = useLocation();
  const [userMenuOpen, setUserMenuOpen] = useState(false);
  const [mobileMenuOpen, setMobileMenuOpen] = useState(false);
  const [theme, setTheme] = useState<AppTheme>(() => getStoredTheme() ?? getPreferredTheme());
  const [sidebarCollapsed, setSidebarCollapsed] = useState(getStoredSidebarCollapsed);
  const currentPage = navItems.find(item => item.path === pathname);

  const [prevPathname, setPrevPathname] = useState(pathname);
  if (prevPathname !== pathname) {
    setPrevPathname(pathname);
    setMobileMenuOpen(false);
  }

  useEffect(() => {
    applyTheme(theme);
    persistTheme(theme);
  }, [theme]);

  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape' && mobileMenuOpen) {
        setMobileMenuOpen(false);
      }
    };
    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [mobileMenuOpen]);

  useEffect(() => {
    if (typeof window !== 'undefined') {
      window.localStorage.setItem(SIDEBAR_COLLAPSED_STORAGE_KEY, String(sidebarCollapsed));
    }
  }, [sidebarCollapsed]);

  const handleSignOut = async () => {
    await signOut();
    navigate('/login');
  };

  const initials = profile?.full_name
    ? profile.full_name.split(' ').map((n) => n[0]).join('').toUpperCase().slice(0, 2)
    : '?';

  return (
    <div className="app-container">
      {mobileMenuOpen && (
        <div
          className="sidebar-backdrop mobile-only"
          onClick={() => setMobileMenuOpen(false)}
          aria-hidden="true"
        />
      )}

      <aside className={`sidebar ${sidebarCollapsed ? 'collapsed' : ''} ${mobileMenuOpen ? 'mobile-open' : ''}`}>
        <div className="sidebar-logo">
          <div className="sidebar-logo-brand">
            <span className="sidebar-logo-text">
              Nexus<span>LPG</span>
            </span>
            <div className="sidebar-logo-badge">OPS</div>
          </div>
          <button
            type="button"
            className="sidebar-collapse-btn desktop-only"
            onClick={() => setSidebarCollapsed((v) => !v)}
            aria-label={sidebarCollapsed ? 'Expand sidebar' : 'Collapse sidebar'}
            aria-expanded={!sidebarCollapsed}
            title={sidebarCollapsed ? 'Expand sidebar' : 'Collapse sidebar'}
          >
            {sidebarCollapsed ? <ChevronRight size={16} /> : <ChevronLeft size={16} />}
          </button>
          <button
            type="button"
            className="sidebar-close-btn mobile-only"
            onClick={() => setMobileMenuOpen(false)}
            aria-label="Close navigation menu"
            title="Close navigation menu"
          >
            <X size={18} />
          </button>
        </div>

        <nav className="sidebar-nav" aria-label="Primary navigation">
          <div className="sidebar-nav-label">Operations</div>
          {navItems.filter(item => hasAnyPermission(permissions, routePermissions[item.path])).map((item) => {
            const Icon = item.icon;
            return (
              <NavLink
                key={item.path}
                to={item.path}
                end={item.end}
                className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`}
                title={sidebarCollapsed ? item.label : undefined}
                onClick={() => setMobileMenuOpen(false)}
              >
                <Icon size={18} />
                <span>{item.label}</span>
              </NavLink>
            );
          })}
        </nav>

        <div className="user-menu-wrapper sidebar-account" onBlur={event => {
          if (!event.currentTarget.contains(event.relatedTarget)) setUserMenuOpen(false);
        }} onKeyDown={event => {
          if (event.key === 'Escape') { setUserMenuOpen(false); event.currentTarget.querySelector<HTMLButtonElement>('.user-menu-trigger')?.focus(); }
        }}>
          <button
            className="user-menu-trigger sidebar-tenant-card"
            type="button"
            aria-label={`Account: ${profile?.full_name ?? 'Signed in user'}`}
            title={sidebarCollapsed ? profile?.full_name : undefined}
            onClick={() => setUserMenuOpen((v) => !v)}
            aria-haspopup="menu"
            aria-expanded={userMenuOpen}
          >
            <div className="sidebar-tenant-avatar">{initials}</div>
            <div className="sidebar-account-info">
              <span className="sidebar-tenant-name">{profile?.business_name ?? 'Loading…'}</span>
              <span className="sidebar-tenant-role">{profile?.full_name ?? 'Signed in user'}</span>
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
                    {profile?.email ?? ''}
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
      </aside>

      <main className="main-content">
        <header className="topbar">
          <div className="topbar-left">
            <button
              className="topbar-icon-btn topbar-menu-btn mobile-only"
              type="button"
              onClick={() => setMobileMenuOpen((v) => !v)}
              aria-label={mobileMenuOpen ? 'Close navigation menu' : 'Open navigation menu'}
              aria-expanded={mobileMenuOpen}
              title={mobileMenuOpen ? 'Close navigation menu' : 'Open navigation menu'}
            >
              <Menu size={20} />
            </button>
            <h1 className="topbar-page-title">{currentPage?.label ?? 'Workspace'}</h1>
          </div>

          <div className="topbar-actions">
            {hasAnyPermission(permissions, ['logistics:view', 'logistics:manage', 'finance:view', 'finance:manage']) && <DealershipWallet />}
            <button
              className="topbar-icon-btn"
              type="button"
              aria-label={theme === 'dark' ? 'Switch to light theme' : 'Switch to dark theme'}
              title={theme === 'dark' ? 'Switch to light theme' : 'Switch to dark theme'}
              onClick={() => setTheme((currentTheme) => (currentTheme === 'dark' ? 'light' : 'dark'))}
            >
              {theme === 'dark' ? <Sun size={18} /> : <Moon size={18} />}
            </button>
          </div>
        </header>

        <div className="page-content">
          <Suspense fallback={<div className="empty-state" role="status">Loading page…</div>}>
            <Outlet />
          </Suspense>
        </div>
      </main>
    </div>
  );
};
