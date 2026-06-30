import { useState } from 'react';
import { Route, Search, Navigation, CheckCircle, Plus } from 'lucide-react';
import { useTransits } from '../../hooks/useLogistics';
import { TransitCostsModal } from './TransitCostsModal';
import { CreateCustomTransitModal } from './CreateCustomTransitModal';
import type { Transit } from '../../types/logistics';

export const TransitsView = () => {
  const { data: transits = [], isLoading } = useTransits();
  const [searchTerm, setSearchTerm] = useState('');
  
  const [selectedTransit, setSelectedTransit] = useState<Transit | null>(null);
  const [isCostsModalOpen, setIsCostsModalOpen] = useState(false);
  const [isCustomTransitModalOpen, setIsCustomTransitModalOpen] = useState(false);


  const filteredTransits = transits.filter(t => 
    t.truck_name?.toLowerCase().includes(searchTerm.toLowerCase()) ||
    t.transit_id.includes(searchTerm)
  );

  const activeFiltered = filteredTransits.filter(t => t.status === 'active');
  const completedFiltered = filteredTransits.filter(t => t.status === 'completed');

  if (isLoading) {
    return (
      <div style={{ padding: '2rem', textAlign: 'center' }}>
        <div style={{ color: 'var(--text-muted)' }}>Loading transits...</div>
      </div>
    );
  }

  const handleTransitClick = (transit: Transit) => {
    setSelectedTransit(transit);
    setIsCostsModalOpen(true);
  };

  const renderTransitCard = (transit: Transit) => {
    const dateStr = new Date(transit.created_at).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' });
    
    return (
      <div 
        key={transit.transit_id} 
        className="glass-panel" 
        style={{ 
          padding: '1.25rem', 
          cursor: 'pointer',
          transition: 'transform 0.2s, box-shadow 0.2s',
          border: '1px solid var(--border)',
          display: 'flex',
          flexDirection: 'column',
          gap: '1rem'
        }}
        onClick={() => handleTransitClick(transit)}
        onMouseEnter={(e) => {
          e.currentTarget.style.transform = 'translateY(-2px)';
          e.currentTarget.style.boxShadow = '0 10px 25px -5px rgba(0, 0, 0, 0.3), 0 8px 10px -6px rgba(0, 0, 0, 0.2)';
        }}
        onMouseLeave={(e) => {
          e.currentTarget.style.transform = 'translateY(0)';
          e.currentTarget.style.boxShadow = 'none';
        }}
      >
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: '0.75rem' }}>
            <div style={{ 
              background: transit.status === 'active' ? 'rgba(16,185,129,0.1)' : 'rgba(148,163,184,0.1)', 
              color: transit.status === 'active' ? 'var(--accent)' : 'var(--text-muted)',
              padding: '0.5rem',
              borderRadius: '0.5rem'
            }}>
              <Route size={20} />
            </div>
            <div>
              <h4 style={{ margin: 0, fontWeight: 600, color: 'var(--text-main)', fontSize: '1rem' }}>
                {transit.truck_name || 'Unknown Truck'}
              </h4>
              <p style={{ margin: 0, color: 'var(--text-muted)', fontSize: '0.75rem', marginTop: '0.2rem' }}>
                ID: {transit.transit_id.split('-')[0]} • {dateStr}
              </p>
            </div>
          </div>
          <span style={{ 
            fontSize: '0.75rem', 
            fontWeight: 600,
            padding: '0.25rem 0.5rem',
            borderRadius: '1rem',
            background: transit.purchase_id ? 'rgba(59,130,246,0.1)' : 'rgba(245,158,11,0.1)',
            color: transit.purchase_id ? 'var(--primary)' : 'var(--warning)',
          }}>
            {transit.purchase_id ? 'Purchase' : 'Custom'}
          </span>
        </div>

        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '0.5rem', fontSize: '0.875rem' }}>
          <div>
            <span style={{ color: 'var(--text-muted)' }}>Driver:</span>
            <div style={{ fontWeight: 500 }}>৳ {transit.driver_cost.toLocaleString()}</div>
          </div>
          <div>
            <span style={{ color: 'var(--text-muted)' }}>Oil:</span>
            <div style={{ fontWeight: 500 }}>৳ {transit.oil_cost.toLocaleString()}</div>
          </div>
          <div>
            <span style={{ color: 'var(--text-muted)' }}>Helper:</span>
            <div style={{ fontWeight: 500 }}>৳ {transit.helper_cost.toLocaleString()}</div>
          </div>
          <div>
            <span style={{ color: 'var(--text-muted)' }}>Total Cost:</span>
            <div style={{ fontWeight: 700, color: 'var(--danger)' }}>৳ {transit.total_cost.toLocaleString()}</div>
          </div>
        </div>
      </div>
    );
  };

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '1.5rem' }}>
      {/* Top Bar */}
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: '1rem' }}>
        <div className="search-bar" style={{ width: 'min(100%, clamp(13rem, 24vw, 18.75rem))' }}>
          <Search size={18} className="search-icon" />
          <input
            type="text"
            className="search-input"
            placeholder="Search transits by truck or ID..."
            value={searchTerm}
            onChange={(e) => setSearchTerm(e.target.value)}
          />
        </div>
        <button className="btn btn-primary" onClick={() => setIsCustomTransitModalOpen(true)}>
          <Plus size={16} /> Add Custom Transit
        </button>
      </div>

      {transits.length === 0 ? (
        <div className="empty-state" style={{ padding: '3rem' }}>
          <Navigation size={36} style={{ color: 'var(--text-muted)', opacity: 0.4 }} />
          <p style={{ color: 'var(--text-muted)' }}>No transits found.</p>
          <p style={{ fontSize: '0.8rem', color: 'var(--text-muted)', opacity: 0.6 }}>
            Transits are automatically created when you make a Purchase.
          </p>
        </div>
      ) : (
        <>
          {/* Active Transits */}
          <div>
            <div style={{ display: 'flex', alignItems: 'center', gap: '0.5rem', marginBottom: '1rem' }}>
              <Navigation size={18} style={{ color: 'var(--accent)' }} />
              <h3 style={{ margin: 0, fontWeight: 600 }}>Active Transits ({activeFiltered.length})</h3>
            </div>
            
            {activeFiltered.length > 0 ? (
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(300px, 1fr))', gap: '1rem' }}>
                {activeFiltered.map(renderTransitCard)}
              </div>
            ) : (
              <div style={{ color: 'var(--text-muted)', fontSize: '0.875rem', fontStyle: 'italic', padding: '1rem' }}>
                No active transits match your search.
              </div>
            )}
          </div>

          <hr style={{ border: 0, borderTop: '1px solid var(--border)', margin: '1rem 0' }} />

          {/* Completed Transits */}
          <div>
            <div style={{ display: 'flex', alignItems: 'center', gap: '0.5rem', marginBottom: '1rem' }}>
              <CheckCircle size={18} style={{ color: 'var(--text-muted)' }} />
              <h3 style={{ margin: 0, fontWeight: 600, color: 'var(--text-muted)' }}>Completed Transits ({completedFiltered.length})</h3>
            </div>
            
            {completedFiltered.length > 0 ? (
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(300px, 1fr))', gap: '1rem' }}>
                {completedFiltered.map(renderTransitCard)}
              </div>
            ) : (
              <div style={{ color: 'var(--text-muted)', fontSize: '0.875rem', fontStyle: 'italic', padding: '1rem' }}>
                No completed transits match your search.
              </div>
            )}
          </div>
        </>
      )}

      {selectedTransit && (
        <TransitCostsModal 
          open={isCostsModalOpen}
          onClose={() => {
            setIsCostsModalOpen(false);
            setTimeout(() => setSelectedTransit(null), 200);
          }}
          transit={selectedTransit}
        />
      )}

      <CreateCustomTransitModal 
        open={isCustomTransitModalOpen}
        onClose={() => setIsCustomTransitModalOpen(false)}
      />
    </div>
  );
};
