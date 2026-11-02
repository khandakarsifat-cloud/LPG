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
const PurchasesPage = lazy(() => import('./pages/Purchases').then(module => ({ default: module.PurchasesPage })));
const SalesPage = lazy(() => import('./pages/Sales').then(module => ({ default: module.SalesPage })));
const SettingsPage = lazy(() => import('./pages/Settings').then(module => ({ default: module.SettingsPage })));
const LoginPage = lazy(() => import('./pages/auth/LoginPage').then(module => ({ default: module.LoginPage })));
const AdminPage = lazy(() => import('./pages/Admin').then(module => ({ default: module.AdminPage })));
const UserAccessPage = lazy(() => import('./pages/UserAccess').then(module => ({ default: module.UserAccessPage })));
const AccountPage = lazy(() => import('./pages/auth/AccountPage').then(module => ({ default: module.AccountPage })));
const POSPage = lazy(() => import('./pages/POS').then(module => ({ default: module.POSPage })));
const CustomersPage = lazy(() => import('./pages/Customers').then(module => ({ default: module.CustomersPage })));
const EmployeesPage = lazy(() => import('./pages/Employees').then(module => ({ default: module.EmployeesPage })));
const FinancePage = lazy(() => import('./pages/Finance').then(module => ({ default: module.FinancePage })));

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 1000 * 60 * 5, // 5 minutes
      retry: 1,
    },
  },
});

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
              <Route path="/register" element={<Navigate to="/login" replace />} />
              <Route path="/account" element={<AccountPage />} />
              <Route path="/admin" element={<AdminPage />} />

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
                <Route path="finance" element={<FinancePage />} />
                <Route path="purchases" element={<PurchasesPage />} />
                <Route path="sales" element={<SalesPage />} />
                <Route path="logistics" element={<LogisticsPage />} />
                <Route path="settings" element={<SettingsPage />} />
                <Route path="users" element={<UserAccessPage />} />
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
