import { Link, Navigate, useLocation } from 'react-router-dom';
import { hasAnyPermission, routePermissions } from '../lib/authorization';
import { useAuth } from '../contexts/AuthContext';

interface ProtectedRouteProps {
  children: React.ReactNode;
}

/**
 * Wraps any route that requires the user to be authenticated.
 * Shows a full-screen loader while Supabase hydrates the session.
 * Redirects to /login if unauthenticated.
 */
export const ProtectedRoute = ({ children }: ProtectedRouteProps) => {
  const { session, profile, access, accessError, permissions, isLoading, signOut, refreshAccess } = useAuth();
  const { pathname } = useLocation();

  if (isLoading) {
    return (
      <div style={{
        minHeight: '100dvh',
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        justifyContent: 'center',
        gap: 'var(--space-md)',
        background: 'var(--bg-base)',
      }}>
        <div className="loader-ring" />
        <span style={{ color: 'var(--text-muted)', fontSize: 'var(--font-sm)' }}>
          Loading your workspace...
        </span>
      </div>
    );
  }

  if (!session) {
    return <Navigate to="/login" replace />;
  }

  if (access?.must_change_password) return <Navigate to="/account" replace />;
  if (access?.is_superadmin && !profile) return <Navigate to="/admin" replace />;

  const required = routePermissions[pathname];
  if (!profile || (required && !hasAnyPermission(permissions, required))) {
    const available = Object.entries(routePermissions).find(([, needed]) =>
      hasAnyPermission(permissions, needed));
    return (
      <div className="empty-state" role="alert">
        <h2>Workspace access unavailable</h2>
        <p>{accessError ?? (access?.access_status === 'suspended' ? 'Your business is suspended. Contact the platform administrator.' : access?.access_status === 'disabled' ? 'Your account is disabled. Contact your business owner.' : 'Your active business membership and permissions are required for this page.')}</p>
        {available && <Link to={available[0]} className="btn btn-primary">Open workspace</Link>}
        <button className="btn btn-secondary" onClick={() => void refreshAccess()}>Retry access</button>
        <button className="btn btn-secondary" onClick={() => void signOut()}>Sign Out</button>
      </div>
    );
  }

  return <>{children}</>;
};
