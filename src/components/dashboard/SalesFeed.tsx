import { useState } from 'react';
import { formatDistanceToNow } from 'date-fns';
import { ShoppingBag, Activity } from 'lucide-react';
import { useTodaySalesFeed, type SaleTransaction } from '../../hooks/useDashboard';
import { formatBDNumber } from '../../lib/formatBDT';
import { SaleDetailsModal } from './SaleDetailsModal';
import '../inventory/inventory.css'; // Reuse existing styles if any

export const SalesFeed = () => {
  const { data: sales = [], isLoading } = useTodaySalesFeed();
  const [selectedSale, setSelectedSale] = useState<SaleTransaction | null>(null);

  if (isLoading) {
    return (
      <div style={{ display: 'flex', flexDirection: 'column', gap: '0.75rem' }}>
        {Array.from({ length: 6 }).map((_, i) => (
          <div key={i} className="movement-row skeleton" style={{ height: '62px', borderRadius: 'var(--radius-md)' }} />
        ))}
      </div>
    );
  }

  if (sales.length === 0) {
    return (
      <div className="empty-state" style={{ padding: '3rem 1rem' }}>
        <Activity size={32} style={{ color: 'var(--text-muted)', opacity: 0.4 }} />
        <p style={{ color: 'var(--text-muted)', fontSize: '0.875rem' }}>No sales recorded today.</p>
      </div>
    );
  }

  return (
    <>
      <div className="movements-feed">
        {sales.map((sale) => {
          // Handle both possible ways customer name is stored
          const customerName = sale.customers?.name || sale.customer_name || 'Unknown Customer';
          
          return (
            <div 
              key={sale.sale_id} 
              className="movement-row" 
              style={{ cursor: 'pointer' }}
              onClick={() => setSelectedSale(sale)}
            >
            {/* Icon */}
            <div className="movement-icon" style={{ color: 'var(--primary)' }}>
              <ShoppingBag size={20} />
            </div>

            {/* Info */}
            <div className="movement-info">
              <div className="movement-item-name" style={{ fontSize: '0.95rem', fontWeight: 600 }}>
                {customerName}
              </div>
              <div className="movement-meta" style={{ marginTop: '0.15rem' }}>
                <span className="movement-type-badge" style={{ background: `rgba(59,130,246,0.1)`, color: 'var(--primary)' }}>
                  Completed Sale
                </span>
                <span style={{
                  fontSize: '0.65rem', fontWeight: 700, padding: '0.08rem 0.4rem',
                  borderRadius: 20, background: 'rgba(59,130,246,0.12)',
                  color: '#60a5fa', border: '1px solid rgba(59,130,246,0.2)',
                  marginLeft: '0.5rem'
                }}>
                  POS #{sale.sale_id.split('-')[0].toUpperCase()}
                </span>
              </div>
            </div>

            {/* Amount + time */}
            <div className="movement-right">
              <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'flex-end', gap: '0.1rem' }}>
                <span style={{ color: 'var(--accent)', fontSize: '1rem', fontWeight: 700 }}>
                  ৳{formatBDNumber(sale.total_amount)}
                </span>
              </div>
              <span className="movement-time">
                {formatDistanceToNow(new Date(sale.created_at), { addSuffix: true })}
              </span>
            </div>
          </div>
        );
      })}
      </div>

      <SaleDetailsModal
        isOpen={!!selectedSale}
        onClose={() => setSelectedSale(null)}
        sale={selectedSale}
      />
    </>
  );
};
