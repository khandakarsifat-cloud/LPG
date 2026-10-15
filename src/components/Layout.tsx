import { Outlet, NavLink, useNavigate } from 'react-router-dom';
import {
  ChevronDown,
  ChevronLeft,
  ChevronRight,
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
import { hasAnyPermission, routePermissions } from '../lib/authorization';
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

const SIDEBAR_COLLAPSED_STORAGE_KEY = 'lpg-sidebar-collapsed';

const getStoredSidebarCollapsed = (): boolean => {
  if (typeof window === 'undefined') return false;
  return window.localStorage.getItem(SIDEBAR_COLLAPSED_STORAGE_KEY) === 'true';
};

export const Layout = () => {
  const { profile, permissions, signOut } = useAuth();
  const navigate = useNavigate();
  const [userMenuOpen, setUserMenuOpen] = useState(false);
  const [workspaceSearch, setWorkspaceSearch] = useState('');
  const [searchOpen, setSearchOpen] = useState(false);
  const [theme, setTheme] = useState<AppTheme>(() => getStoredTheme() ?? getPreferredTheme());
  const [sidebarCollapsed, setSidebarCollapsed] = useState(getStoredSidebarCollapsed);
  const availablePages = navItems.filter(item => hasAnyPermission(permissions, routePermissions[item.path]));
  const matchingPages = availablePages.filter(item => item.label.toLowerCase().includes(workspaceSearch.trim().toLowerCase()));
  const openPage = (path: string) => { navigate(path); setSearchOpen(false); setWorkspaceSearch(''); };

  useEffect(() => {
    applyTheme(theme);
    persistTheme(theme);
  }, [theme]);

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
      <aside className={`sidebar ${sidebarCollapsed ? 'collapsed' : ''}`}>
        <div className="sidebar-logo">
          <div className="sidebar-logo-brand">
            <span className="sidebar-logo-text">
              Nexus<span>LPG</span>
            </span>
            <div className="sidebar-logo-badge">OPS</div>
          </div>
          <button
            type="button"
            className="sidebar-collapse-btn"
            onClick={() => setSidebarCollapsed((v) => !v)}
            aria-label={sidebarCollapsed ? 'Expand sidebar' : 'Collapse sidebar'}
            aria-expanded={!sidebarCollapsed}
            title={sidebarCollapsed ? 'Expand sidebar' : 'Collapse sidebar'}
          >
            {sidebarCollapsed ? <ChevronRight size={16} /> : <ChevronLeft size={16} />}
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
              >
                <Icon size={18} />
                <span>{item.label}</span>
              </NavLink>
            );
          })}
        </nav>

        <div
          className="sidebar-tenant-card"
          title={sidebarCollapsed ? (profile?.business_name ?? 'Business workspace') : undefined}
        >
          <div className="sidebar-tenant-info">
            <div className="sidebar-tenant-avatar">{initials}</div>
            <div>
              <div className="sidebar-tenant-name">
                {profile?.business_name ?? 'Loading...'}
              </div>
              <div className="sidebar-tenant-role">Business workspace</div>
            </div>
          </div>
        </div>
      </aside>

      <main className="main-content">
        <header className="topbar">
          <div className="topbar-search workspace-search" onBlur={event => {
            if (!event.currentTarget.contains(event.relatedTarget)) setSearchOpen(false);
          }}>
            <Search size={16} className="topbar-search-icon" />
            <input
              type="text"
              placeholder="Find a page…"
              className="input-field topbar-search-input"
              aria-label="Search workspace"
              aria-expanded={searchOpen}
              aria-controls="workspace-search-results"
              value={workspaceSearch}
              onFocus={() => setSearchOpen(true)}
              onChange={event => { setWorkspaceSearch(event.target.value); setSearchOpen(true); }}
              onKeyDown={event => {
                if (event.key === 'Escape') { setSearchOpen(false); event.currentTarget.blur(); }
                if (event.key === 'Enter' && matchingPages.length) { openPage(matchingPages[0].path); event.currentTarget.blur(); }
                if (event.key === 'ArrowDown') { event.preventDefault(); event.currentTarget.parentElement?.querySelector<HTMLButtonElement>('.workspace-search-result')?.focus(); }
              }}
            />
            {searchOpen && <div id="workspace-search-results" className="workspace-search-results">
              {matchingPages.length ? matchingPages.map(item => <button key={item.path} type="button" className="workspace-search-result" onClick={() => openPage(item.path)}>
                <item.icon size={16} aria-hidden="true" />{item.label}
              </button>) : <p>No pages match your search.</p>}
            </div>}
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

            <div className="user-menu-wrapper" onBlur={event => {
              if (!event.currentTarget.contains(event.relatedTarget)) setUserMenuOpen(false);
            }} onKeyDown={event => {
              if (event.key === 'Escape') { setUserMenuOpen(false); event.currentTarget.querySelector<HTMLButtonElement>('.user-menu-trigger')?.focus(); }
            }}>
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
