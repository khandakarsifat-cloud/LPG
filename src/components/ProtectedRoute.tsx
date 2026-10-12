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
  const { session, profile, permissions, isLoading, signOut } = useAuth();
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

  const required = routePermissions[pathname];
  if (!profile || (required && !hasAnyPermission(permissions, required))) {
    const available = Object.entries(routePermissions).find(([, needed]) =>
      hasAnyPermission(permissions, needed));
    return (
      <div className="empty-state" role="alert">
        <h2>Workspace access unavailable</h2>
        <p>Your active business membership and permissions are required for this page.</p>
        {available && <Link to={available[0]} className="btn btn-primary">Open workspace</Link>}
        <button className="btn btn-secondary" onClick={() => void signOut()}>Sign Out</button>
      </div>
    );
  }

  return <>{children}</>;
};
