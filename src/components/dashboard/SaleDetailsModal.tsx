import { useEffect, useRef } from 'react';
import { createPortal } from 'react-dom';
import { X, Printer, CheckCircle2 } from 'lucide-react';
import { formatBDNumber } from '../../lib/formatBDT';
import { usePrintSale } from '../../hooks/useReceiptPrinter';
import type { SaleTransaction } from '../../hooks/useDashboard';
import { useAuth } from '../../contexts/AuthContext';

interface SaleDetailsModalProps {
  isOpen: boolean;
  onClose: () => void;
  sale: SaleTransaction | null;
}

const TYPE_LABELS: Record<string, string> = {
  refill: 'Refill',
  package: 'New Package',
  empty_return: 'Empty Return',
};

export const SaleDetailsModal = ({ isOpen, onClose, sale }: SaleDetailsModalProps) => {
  const { profile } = useAuth();
  const printSale = usePrintSale();
  const overlayRef = useRef<HTMLDivElement>(null);

  // Close on Escape
  useEffect(() => {
    if (!isOpen) return;
    const handler = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose(); };
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, [isOpen, onClose]);

  if (!isOpen || !sale) return null;

  const customerName = sale.customers?.name || 'Unknown Customer';
  const customerPhone = sale.customers?.phone || 'Unknown Phone';
  const customerTier = sale.customers?.tier || 'retail';
  const shopName = sale.customers?.shop_name;
  
  const now = new Date(sale.created_at).toLocaleString('en-BD', {
    year: 'numeric', month: 'short', day: '2-digit',
    hour: '2-digit', minute: '2-digit', hour12: true,
  });

  const handlePrint = () => { if (!printSale.isPending) printSale.mutate(sale.sale_id); };

  const modalContent = (
    <div
      ref={overlayRef}
      style={{
        position: 'fixed', inset: 0, zIndex: 9999,
        background: 'var(--overlay)',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        padding: '1rem',
        animation: 'fadeIn 0.18s ease',
      }}
      onClick={e => { if (e.target === overlayRef.current) onClose(); }}
    >
      <div style={{
        background: 'var(--surface)',
        color: 'var(--text-main)',
        border: '1px solid var(--border-color)',
        borderRadius: 'var(--radius-xl)',
        boxShadow: 'var(--shadow-lg)',
        width: '100%',
        maxWidth: 'min(92vw, 33.75rem)',
        maxHeight: 'min(92dvh, 56rem)',
        display: 'flex',
        flexDirection: 'column',
        overflow: 'hidden',
        animation: 'slideUp 0.2s ease',
      }}>
        {/* ── Modal Header ── */}
        <div style={{
          display: 'flex', alignItems: 'center', justifyContent: 'space-between',
          padding: '1rem 1.25rem',
          borderBottom: '1px solid var(--border-color)',
          flexShrink: 0,
        }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: '0.6rem' }}>
            <div style={{
              width: 36, height: 36, borderRadius: 10,
              background: 'rgba(59,130,246,0.15)',
              display: 'flex', alignItems: 'center', justifyContent: 'center',
            }}>
              <CheckCircle2 size={20} style={{ color: 'var(--primary)' }} />
            </div>
            <div>
              <h2 style={{ margin: 0, fontSize: '1rem', fontWeight: 700, color: 'var(--text-main)' }}>Transaction Details</h2>
              <p style={{ margin: 0, fontSize: '0.72rem', color: 'var(--text-muted)' }}>
                Sale ID: #{sale.sale_id.split('-')[0].toUpperCase()}
              </p>
            </div>
          </div>
          <button
            onClick={onClose}
            style={{
              background: 'none', border: 'none', cursor: 'pointer',
              color: 'var(--text-muted)', padding: '0.35rem',
              borderRadius: 8, lineHeight: 1,
              transition: 'color 0.15s, background 0.15s',
            }}
            onMouseEnter={e => {
              (e.currentTarget as HTMLButtonElement).style.color = 'var(--text-main)';
              (e.currentTarget as HTMLButtonElement).style.background = 'var(--bg-elevated)';
            }}
            onMouseLeave={e => {
              (e.currentTarget as HTMLButtonElement).style.color = 'var(--text-muted)';
              (e.currentTarget as HTMLButtonElement).style.background = 'none';
            }}
          >
            <X size={18} />
          </button>
        </div>

        {/* ── Receipt Preview — scrollable ── */}
        <div style={{ flex: 1, overflowY: 'auto', padding: '1rem 1.25rem', minHeight: 0 }}>
          <div style={{
            background: '#ffffff',
            color: '#111',
            borderRadius: 10,
            padding: '1rem 1.25rem',
            fontFamily: "'Courier New', Courier, monospace",
            fontSize: '0.78rem',
            lineHeight: 1.55,
            boxShadow: '0 4px 20px rgba(0,0,0,0.3)',
            maxWidth: 'min(100%, 20rem)',
            margin: '0 auto',
          }}>
            {/* Header */}
            <div style={{ textAlign: 'center', marginBottom: '0.6rem' }}>
              <div style={{ fontWeight: 700, fontSize: '1rem', letterSpacing: '0.04em' }}>
                {profile?.business_name || 'Gas Dealership'}
              </div>
              <div style={{ fontSize: '0.65rem', color: '#555' }}>Official Sales Receipt</div>
              <div style={{ fontSize: '0.65rem', color: '#555', marginTop: '0.2rem' }}>{now}</div>
              <div style={{ fontSize: '0.65rem', color: '#777', fontStyle: 'italic' }}>
                Ref: #{sale.sale_id.slice(0, 8).toUpperCase()}
              </div>
            </div>

            <div style={{ borderTop: '1px dashed #999', margin: '0.4rem 0' }} />

            {/* Customer */}
            <div style={{ marginBottom: '0.5rem' }}>
              <div style={{ fontWeight: 700, fontSize: '0.65rem', color: '#777', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: '0.15rem' }}>Customer</div>
              <div style={{ fontWeight: 600 }}>{customerName}</div>
              <div style={{ fontSize: '0.7rem', color: '#555' }}>Ph: {customerPhone}</div>
              <div style={{ fontSize: '0.7rem', color: '#555', textTransform: 'capitalize' }}>{customerTier}</div>
              {shopName && (
                <div style={{ fontSize: '0.7rem', color: '#555' }}>{shopName}</div>
              )}
            </div>

            <div style={{ borderTop: '1px dashed #999', margin: '0.4rem 0' }} />

            {/* Items table */}
            <div>
              <div style={{ display: 'grid', gridTemplateColumns: '1fr auto auto', gap: '0.1rem 0.5rem', fontSize: '0.65rem', fontWeight: 700, color: '#777', textTransform: 'uppercase', marginBottom: '0.2rem' }}>
                <span>Item</span><span style={{ textAlign: 'right' }}>Qty</span><span style={{ textAlign: 'right' }}>Total</span>
              </div>
              {sale.sale_items?.map((item, idx) => {
                const brandName = item.items?.lpg_brands?.brand_name || item.items?.brand || 'Unknown';
                const size = item.items?.size_kg ? `${item.items.size_kg}kg` : '';
                const itemName = `${brandName} ${size}`.trim();
                
                return (
                  <div key={idx} style={{ marginBottom: '0.35rem' }}>
                    <div style={{ display: 'grid', gridTemplateColumns: '1fr auto auto', gap: '0.1rem 0.5rem', alignItems: 'start' }}>
                      <div>
                        <div style={{ fontWeight: 600, fontSize: '0.75rem' }}>{itemName}</div>
                        <div style={{ fontSize: '0.65rem', color: '#666' }}>
                          {TYPE_LABELS[item.type] || item.type}
                          {item.type !== 'empty_return' && (
                            <span> - Tk {formatBDNumber(Number(item.unit_price))}</span>
                          )}
                        </div>
                      </div>
                      <div style={{ textAlign: 'right', fontWeight: 600, paddingTop: '0.1rem' }}>x{item.quantity}</div>
                      <div style={{ textAlign: 'right', fontWeight: 700, paddingTop: '0.1rem', color: item.type === 'empty_return' ? '#888' : '#111' }}>
                        {item.type === 'empty_return' ? '-' : `Tk ${formatBDNumber(Number(item.line_total))}`}
                      </div>
                    </div>
                  </div>
                );
              })}
            </div>

            <div style={{ borderTop: '1px solid #bbb', margin: '0.5rem 0 0.4rem' }} />

            {/* Totals */}
            <div style={{ fontSize: '0.75rem' }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', color: '#555', marginBottom: '0.15rem' }}>
                <span>Subtotal</span><span>Tk {formatBDNumber(sale.subtotal)}</span>
              </div>
              {sale.discount_amount > 0 && (
                <div style={{ display: 'flex', justifyContent: 'space-between', color: '#e53e3e', marginBottom: '0.15rem' }}>
                  <span>Discount</span><span>-Tk {formatBDNumber(sale.discount_amount)}</span>
                </div>
              )}
              {sale.exchange_fee > 0 && (
                <div style={{ display: 'flex', justifyContent: 'space-between', color: '#555', marginBottom: '0.15rem' }}>
                  <span>Exchange Fee</span><span>Tk {formatBDNumber(sale.exchange_fee)}</span>
                </div>
              )}
              <div style={{ display: 'flex', justifyContent: 'space-between', fontWeight: 800, fontSize: '0.95rem', borderTop: '1px solid #bbb', paddingTop: '0.35rem', marginTop: '0.2rem' }}>
                <span>TOTAL</span><span style={{ color: '#1a56db' }}>Tk {formatBDNumber(sale.total_amount)}</span>
              </div>
            </div>

            {sale.notes && (
              <>
                <div style={{ borderTop: '1px dashed #999', margin: '0.5rem 0 0.35rem' }} />
                <div style={{ fontSize: '0.7rem', color: '#555', fontStyle: 'italic' }}>Note: {sale.notes}</div>
              </>
            )}

            <div style={{ borderTop: '1px dashed #999', margin: '0.55rem 0 0.4rem' }} />
            <div style={{ textAlign: 'center', fontSize: '0.7rem', color: '#666' }}>
              <div style={{ fontWeight: 700 }}>Thank you for your business!</div>
              <div style={{ fontSize: '0.62rem', marginTop: '0.15rem' }}>Powered by LPG Manager</div>
            </div>
          </div>
        </div>

        {/* ── Footer Buttons ── */}
        <div style={{
          display: 'flex', gap: '0.75rem',
          padding: '1rem 1.25rem',
          borderTop: '1px solid var(--border-color)',
          flexShrink: 0,
          background: 'var(--bg-secondary)',
        }}>
          {/* Cancel */}
          <button
            onClick={onClose}
            className="btn btn-secondary"
            style={{ flex: '0 0 auto', padding: '0.65rem 1.1rem', fontWeight: 600, fontSize: '0.88rem' }}
          >
            Close
          </button>

          {/* Confirm & Print */}
          <button
            onClick={handlePrint}
            disabled={printSale.isPending}
            className="btn"
            style={{
              flex: 1,
              padding: '0.65rem 1rem',
              fontWeight: 700,
              fontSize: '0.88rem',
              background: 'var(--primary)',
              color: 'white',
              border: 'none',
              borderRadius: 'var(--radius-md)',
              cursor: 'pointer',
              transition: 'opacity 0.15s, transform 0.1s',
            }}
            onMouseEnter={e => (e.currentTarget as HTMLButtonElement).style.opacity = '0.88'}
            onMouseLeave={e => (e.currentTarget as HTMLButtonElement).style.opacity = '1'}
          >
            <span style={{ display: 'flex', alignItems: 'center', gap: '0.4rem', justifyContent: 'center' }}>
              <Printer size={15} /> {printSale.isPending ? 'Printing…' : 'Print Receipt Again'}
            </span>
          </button>
        </div>
      </div>
    </div>
  );

  return createPortal(modalContent, document.body);
};
