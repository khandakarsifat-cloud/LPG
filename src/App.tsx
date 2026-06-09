import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { AuthProvider } from './contexts/AuthContext';
import { ProtectedRoute } from './components/ProtectedRoute';
import { Layout } from './components/Layout';
import { Dashboard } from './pages/Dashboard';
import { InventoryPage } from './pages/Inventory';
import { LogisticsPage } from './pages/Logistics';
import { GasPlantsPage } from './pages/GasPlants';
import { PurchasesPage } from './pages/Purchases';
import { SettingsPage } from './pages/Settings';
import { LoginPage } from './pages/auth/LoginPage';
import { RegisterPage } from './pages/auth/RegisterPage';

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 1000 * 60 * 5, // 5 minutes
      retry: 1,
    },
  },
});

// Placeholder pages for modules not yet built
const Placeholder = ({ title }: { title: string }) => (
  <div style={{ display: 'flex', flexDirection: 'column', justifyContent: 'center', alignItems: 'center', height: '60vh', gap: '1rem' }}>
    <div style={{ fontSize: '3rem' }}>🚧</div>
    <h2 style={{ color: 'var(--text-muted)' }}>{title}</h2>
    <p style={{ color: 'var(--text-muted)', fontSize: '0.875rem' }}>This module is coming soon.</p>
  </div>
);

function App() {
  return (
    <QueryClientProvider client={queryClient}>
      <AuthProvider>
        <BrowserRouter>
          <Routes>
            {/* Public auth routes */}
            <Route path="/login"    element={<LoginPage />} />
            <Route path="/register" element={<RegisterPage />} />

            {/* Protected application routes */}
            <Route
              path="/"
              element={
                <ProtectedRoute>
                  <Layout />
                </ProtectedRoute>
              }
            >
              <Route index element={<Dashboard />} />
              <Route path="inventory"  element={<InventoryPage />} />
              <Route path="customers"  element={<Placeholder title="Customer Management" />} />
              <Route path="finance"    element={<Placeholder title="Financial Ledger" />} />
              <Route path="purchases"  element={<PurchasesPage />} />
              <Route path="logistics"  element={<LogisticsPage />} />
              <Route path="gas-plants" element={<GasPlantsPage />} />
              <Route path="settings"   element={<SettingsPage />} />
            </Route>

            {/* Catch-all */}
            <Route path="*" element={<Navigate to="/" replace />} />
          </Routes>
        </BrowserRouter>
      </AuthProvider>
    </QueryClientProvider>
  );
}

export default App;
