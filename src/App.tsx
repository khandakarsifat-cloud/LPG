import { HashRouter, Routes, Route, Navigate } from 'react-router-dom';
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
import { POSPage } from './pages/POS';
import { CustomersPage } from './pages/Customers';
import { EmployeesPage } from './pages/Employees';
import { Toaster } from 'react-hot-toast';

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 1000 * 60 * 5, // 5 minutes
      retry: 1,
    },
  },
});

const Placeholder = ({ title }: { title: string }) => (
  <div className="empty-state" style={{ minHeight: 'min(60dvh, 32rem)' }}>
    <h2 style={{ margin: 0 }}>{title}</h2>
    <p style={{ margin: 0 }}>This workspace is available in navigation and will be completed in a later release.</p>
  </div>
);

function App() {
  return (
    <QueryClientProvider client={queryClient}>
      <Toaster position="top-right" />
      <AuthProvider>
        <HashRouter>
          <Routes>
            {/* Public auth routes */}
            <Route path="/login" element={<LoginPage />} />
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
              <Route path="inventory" element={<InventoryPage />} />
              <Route path="customers" element={<CustomersPage />} />
              <Route path="employees" element={<EmployeesPage />} />
              <Route path="finance" element={<Placeholder title="Financial Ledger" />} />
              <Route path="purchases" element={<PurchasesPage />} />
              <Route path="logistics" element={<LogisticsPage />} />
              <Route path="gas-plants" element={<GasPlantsPage />} />
              <Route path="settings" element={<SettingsPage />} />
              <Route path="pos" element={<POSPage />} />
            </Route>

            {/* Catch-all */}
            <Route path="*" element={<Navigate to="/" replace />} />
          </Routes>
        </HashRouter>
      </AuthProvider>
    </QueryClientProvider>
  );
}

export default App;
