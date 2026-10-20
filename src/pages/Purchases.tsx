import { useState } from 'react';
import { Plus } from 'lucide-react';
import { PurchasesList } from '../components/purchases/PurchasesList';
import { CreatePurchaseModal } from '../components/purchases/CreatePurchaseModal';
import { useAuth } from '../contexts/AuthContext';
import { formatBDT } from '../lib/formatBDT';
import { usePurchaseOverview } from '../hooks/usePurchases';

export const PurchasesPage = () => {
  const [purchaseOpen, setPurchaseOpen] = useState(false);
  const { can } = useAuth();
  const purchasesQuery = usePurchaseOverview();
  const summaryValue = (value: number | string) => purchasesQuery.isLoading ? '…' : purchasesQuery.isError ? '—' : value;

  return (
    <div className="purchases-page">
      {/* ── Page Header ── */}
      <div className="page-header purchases-header">
        <dl className="purchase-list-summary" aria-label="Purchase overview">
          <div><dt>Created</dt><dd>{summaryValue(purchasesQuery.data?.created ?? 0)}</dd></div>
          <div><dt>In Transit</dt><dd>{summaryValue(purchasesQuery.data?.in_transit ?? 0)}</dd></div>
          <div><dt>Awaiting Payment</dt><dd>{summaryValue(purchasesQuery.data?.unpaid ?? 0)}</dd></div>
          <div className="purchase-overview-payable"><dt>Company Payable</dt><dd>{summaryValue(formatBDT(purchasesQuery.data?.company_payable ?? 0))}</dd></div>
        </dl>
        
        <div className="purchases-header-actions">
          {can('purchases:manage') && <button className="btn btn-primary" aria-label="New Purchase" onClick={() => setPurchaseOpen(true)}>
            <Plus size={16} />
            <span className="purchase-new-label">New Purchase</span>
            <span className="purchase-new-short" aria-hidden="true">New</span>
          </button>}
        </div>
      </div>

      {purchasesQuery.isError && <p role="alert" className="purchase-error">Purchase overview could not be loaded. <button className="btn btn-secondary" onClick={() => void purchasesQuery.refetch()}>Retry overview</button></p>}

      {/* ── Purchases List ── */}
      <div className="purchase-list-panel">
        <PurchasesList totalPurchases={purchasesQuery.data?.total} />
      </div>

      <CreatePurchaseModal open={purchaseOpen} onClose={() => setPurchaseOpen(false)} />
    </div>
  );
};
