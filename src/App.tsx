import { lazy, Suspense } from 'react';
import { HashRouter, Routes, Route, Navigate } from 'react-router-dom';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { AuthProvider } from './contexts/AuthContext';
import { ProtectedRoute } from './components/ProtectedRoute';
import { Layout } from './components/Layout';
import { Toaster } from 'react-hot-toast';

const Dashboard = lazy(() => import('./pages/Dashboard').then(module => ({ default: module.Dashboard })));
const InventoryPage = lazy(() => import('./pages/Inventory').then(module => ({ default: module.InventoryPage })));
const LogisticsPage = lazy(() => import('./pages/Logistics').then(module => ({ default: module.LogisticsPage })));
const GasPlantsPage = lazy(() => import('./pages/GasPlants').then(module => ({ default: module.GasPlantsPage })));
const PurchasesPage = lazy(() => import('./pages/Purchases').then(module => ({ default: module.PurchasesPage })));
const SettingsPage = lazy(() => import('./pages/Settings').then(module => ({ default: module.SettingsPage })));
const LoginPage = lazy(() => import('./pages/auth/LoginPage').then(module => ({ default: module.LoginPage })));
const RegisterPage = lazy(() => import('./pages/auth/RegisterPage').then(module => ({ default: module.RegisterPage })));
const POSPage = lazy(() => import('./pages/POS').then(module => ({ default: module.POSPage })));
const CustomersPage = lazy(() => import('./pages/Customers').then(module => ({ default: module.CustomersPage })));
const EmployeesPage = lazy(() => import('./pages/Employees').then(module => ({ default: module.EmployeesPage })));

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 1000 * 60 * 5, // 5 minutes
      retry: 1,
    },
  },
});

const Placeholder = ({ title }: { title: string }) => (
  <div className="empty-state workspace-placeholder">
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
          <Suspense fallback={<div className="empty-state" role="status">Loading page…</div>}>
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
          </Suspense>
        </HashRouter>
      </AuthProvider>
    </QueryClientProvider>
  );
}

export default App;
