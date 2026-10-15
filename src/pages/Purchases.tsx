import { useState } from 'react';
import { Plus } from 'lucide-react';
import { PurchasesList } from '../components/purchases/PurchasesList';
import { CreatePurchaseModal } from '../components/purchases/CreatePurchaseModal';
import { useAuth } from '../contexts/AuthContext';
import { formatBDT } from '../lib/formatBDT';
import { usePurchases } from '../hooks/usePurchases';

export const PurchasesPage = () => {
  const [purchaseOpen, setPurchaseOpen] = useState(false);
  const { can } = useAuth();
  const purchasesQuery = usePurchases();
  const purchases = purchasesQuery.data ?? [];
  const unpaid = purchases.filter(p => p.payment_status === 'unpaid' && p.status !== 'created' && p.status !== 'cancelled');
  const summaryValue = (value: number | string) => purchasesQuery.isLoading ? '…' : purchasesQuery.isError ? '—' : value;

  return (
    <div className="purchases-page">
      {/* ── Page Header ── */}
      <div className="page-header purchases-header">
        <dl className="purchase-list-summary" aria-label="Purchase overview">
          <div><dt>Created</dt><dd>{summaryValue(purchases.filter(p => p.status === 'created').length)}</dd></div>
          <div><dt>In Transit</dt><dd>{summaryValue(purchases.filter(p => p.status === 'in_transit').length)}</dd></div>
          <div><dt>Awaiting Payment</dt><dd>{summaryValue(unpaid.length)}</dd></div>
          <div className="purchase-overview-payable"><dt>Company Payable</dt><dd>{summaryValue(formatBDT(unpaid.reduce((sum, p) => sum + Number(p.company_payable), 0)))}</dd></div>
        </dl>
        
        <div className="purchases-header-actions">
          {can('purchases:manage') && <button className="btn btn-primary" aria-label="New Purchase" onClick={() => setPurchaseOpen(true)}>
            <Plus size={16} />
            <span className="purchase-new-label">New Purchase</span>
            <span className="purchase-new-short" aria-hidden="true">New</span>
          </button>}
        </div>
      </div>

      {/* ── Purchases List ── */}
      <div className="purchase-list-panel">
        <PurchasesList query={purchasesQuery} />
      </div>

      <CreatePurchaseModal open={purchaseOpen} onClose={() => setPurchaseOpen(false)} />
    </div>
  );
};
