import { CreateStovePurchaseModal } from '../components/purchases/StovePurchaseForm';
import { useState } from 'react';
import { Plus } from 'lucide-react';
import { PurchasesList } from '../components/purchases/PurchasesList';
import { CreatePurchaseModal } from '../components/purchases/CreatePurchaseModal';
import { useAuth } from '../contexts/AuthContext';
import { formatBDT } from '../lib/formatBDT';
import { usePurchaseOverview } from '../hooks/usePurchases';
import { PurchaseDialog } from '../components/purchases/PurchaseControls';

export const PurchasesPage = () => {
  const [category, setCategory] = useState<'all' | 'lpg' | 'stove'>('all');
  const [purchaseCategory, setPurchaseCategory] = useState<'lpg' | 'stove' | null>(null);
  const [purchaseOpen, setPurchaseOpen] = useState(false);
  const { can } = useAuth();
  const purchasesQuery = usePurchaseOverview(category === 'all' ? undefined : category);
  const summaryValue = (value: number | string) => purchasesQuery.isLoading ? '…' : purchasesQuery.isError ? '—' : value;

  return (
    <div className="purchases-page">
      {/* ── Page Header ── */}
      <div className="page-header purchases-header">
        <dl className="purchase-list-summary" aria-label="Purchase overview">
          <div><dt>Created</dt><dd>{summaryValue(purchasesQuery.data?.created ?? 0)}</dd></div>
          <div><dt>In Transit</dt><dd>{summaryValue(purchasesQuery.data?.in_transit ?? 0)}</dd></div>
          <div><dt>Awaiting Payment</dt><dd>{summaryValue(purchasesQuery.data?.unpaid ?? 0)}</dd></div>
          <div className="purchase-overview-payable"><dt>Outstanding</dt><dd>{summaryValue(formatBDT(purchasesQuery.data?.outstanding ?? purchasesQuery.data?.company_payable ?? 0))}</dd></div>
        </dl>
        
        <div className="purchases-header-actions">
          {can('purchases:manage') && <button className="btn btn-primary" aria-label="New Purchase" onClick={() => { setPurchaseCategory(category === 'all' ? null : category); setPurchaseOpen(true); }}>
            <Plus size={16} />
            <span className="purchase-new-label">New Purchase</span>
            <span className="purchase-new-short" aria-hidden="true">New</span>
          </button>}
        </div>
      </div>

      {purchasesQuery.isError && <p role="alert" className="purchase-error">Purchase overview could not be loaded. <button className="btn btn-secondary" onClick={() => void purchasesQuery.refetch()}>Retry overview</button></p>}

      {/* ── Purchases List ── */}
      <div className="purchase-list-panel">
        <PurchasesList category={category} onCategoryChange={setCategory} totalPurchases={purchasesQuery.data?.total} />
      </div>

      {purchaseOpen && purchaseCategory === null && <PurchaseDialog title="New purchase" subtitle="Choose the business for this purchase." compact onClose={() => setPurchaseOpen(false)}><div className="modal-body dialog-form"><button className="btn btn-secondary" onClick={() => setPurchaseCategory('lpg')}>LPG purchase</button><button className="btn btn-secondary" onClick={() => setPurchaseCategory('stove')}>Stove purchase</button></div></PurchaseDialog>}
      {purchaseOpen && purchaseCategory === 'stove' && <CreateStovePurchaseModal onClose={() => setPurchaseOpen(false)} />}
      <CreatePurchaseModal open={purchaseOpen && purchaseCategory === 'lpg'} onClose={() => setPurchaseOpen(false)} />
    </div>
  );
};
