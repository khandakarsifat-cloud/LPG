import { useState } from 'react';
import { Plus, Wallet } from 'lucide-react';
import { useWallets } from '../hooks/useLogistics';
import { PurchasesList } from '../components/purchases/PurchasesList';
import { CreatePurchaseModal } from '../components/purchases/CreatePurchaseModal';

export const PurchasesPage = () => {
  const [purchaseOpen, setPurchaseOpen] = useState(false);
  const { data: wallets } = useWallets();

  const dealershipWallet = wallets?.find((w: any) => w.type === 'dealership');

  return (
    <div className="purchases-page">
      {/* ── Page Header ── */}
      <div className="page-header" style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
        <div>
          <h1 className="page-title">Purchases</h1>
          <p className="page-subtitle">
            Manage incoming stock and Dealership financials
          </p>
        </div>
        
        <div style={{ display: 'flex', gap: '1rem', alignItems: 'center' }}>
          {dealershipWallet && (
            <div className="glass-panel" style={{ padding: '0.5rem 1rem', display: 'flex', alignItems: 'center', gap: '0.75rem', border: '1px solid rgba(16,185,129,0.2)' }}>
              <div style={{ background: 'rgba(16,185,129,0.1)', color: 'var(--accent)', padding: '0.5rem', borderRadius: '0.5rem' }}>
                <Wallet size={16} />
              </div>
              <div>
                <div style={{ fontSize: '0.75rem', color: 'var(--text-muted)', fontWeight: 600 }}>Dealership Wallet</div>
                <div style={{ fontSize: '1.125rem', fontWeight: 700, color: 'var(--accent)' }}>
                  ৳ {Number(dealershipWallet.balance).toLocaleString()}
                </div>
              </div>
            </div>
          )}

          <button className="btn btn-primary" onClick={() => setPurchaseOpen(true)}>
            <Plus size={16} />
            New Purchase
          </button>
        </div>
      </div>

      {/* ── Purchases List ── */}
      <div className="glass-panel" style={{ padding: '1.25rem' }}>
        <PurchasesList />
      </div>

      <CreatePurchaseModal open={purchaseOpen} onClose={() => setPurchaseOpen(false)} />
    </div>
  );
};
