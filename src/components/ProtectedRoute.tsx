import { Navigate } from 'react-router-dom';
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
  const { session, isLoading } = useAuth();

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

  return <>{children}</>;
};
