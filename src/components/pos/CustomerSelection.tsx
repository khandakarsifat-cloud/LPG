import { useState } from 'react';
import { useCustomers } from '../../hooks/useCustomers';

interface CustomerSelectionProps {
  customer: any;
  onChange: (customer: any) => void;
}

export const CustomerSelection = ({ customer, onChange }: CustomerSelectionProps) => {
  const [tier, setTier] = useState<'retail' | 'wholesale'>('retail');
  const [searchTerm, setSearchTerm] = useState('');
  const [showDropdown, setShowDropdown] = useState(false);
  
  const { data: customers } = useCustomers(searchTerm);

  const hasPhone = Boolean(customer?.phone?.trim());

  const handleSelectCustomer = (c: any) => {
    onChange({ ...c, tier: c.tier || tier });
    setTier(c.tier || tier);
    setSearchTerm(c.phone || c.name || '');
    setShowDropdown(false);
  };

  const handleChange = (field: string, value: string) => {
    if (field === 'phone' || field === 'name') {
      setSearchTerm(value);
      setShowDropdown(true);
    }
    onChange({ ...customer, [field]: value, tier });
  };

  const handleTierChange = (newTier: 'retail' | 'wholesale') => {
    setTier(newTier);
    onChange({ ...customer, tier: newTier });
  };

  const isNewCustomer = customer?.phone && (!customers || !customers.find(c => c.phone === customer.phone));

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '0.5rem', position: 'relative' }}>
      {/* Tier toggle */}
      <div style={{ display: 'flex', gap: '0.4rem', marginBottom: '0.25rem' }}>
        <button
          className={`btn ${tier === 'retail' ? 'btn-primary' : 'btn-secondary'}`}
          style={{ flex: 1, padding: '0.4rem 0.5rem', fontSize: '0.78rem', fontWeight: 600 }}
          onClick={() => handleTierChange('retail')}
        >
          Retail
        </button>
        <button
          className={`btn ${tier === 'wholesale' ? 'btn-primary' : 'btn-secondary'}`}
          style={{ flex: 1, padding: '0.4rem 0.5rem', fontSize: '0.78rem', fontWeight: 600 }}
          onClick={() => handleTierChange('wholesale')}
        >
          Wholesale
        </button>
      </div>

      {/* Phone field — REQUIRED */}
      <div style={{ position: 'relative' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: '0.4rem' }}>
          <label style={{
            fontSize: '0.68rem', fontWeight: 600, width: 42, flexShrink: 0,
            color: !hasPhone ? '#f87171' : 'var(--text-muted)',
            transition: 'color 0.2s',
          }}>
            Phone <span style={{ color: '#f87171' }}>*</span>
          </label>
          <input
            type="tel"
            className="input-field"
            style={{
              flex: 1, padding: '0.4rem 0.55rem', fontSize: '0.8rem',
              borderColor: !hasPhone ? 'rgba(248,113,113,0.5)' : undefined,
              transition: 'border-color 0.2s',
            }}
            placeholder="Required *"
            value={customer?.phone || ''}
            onChange={(e) => {
              const val = e.target.value.replace(/\D/g, '');
              handleChange('phone', val);
            }}
            onFocus={() => setShowDropdown(true)}
            onBlur={() => setTimeout(() => setShowDropdown(false), 200)}
          />
        </div>

        {/* Autocomplete Dropdown */}
        {showDropdown && customers && customers.length > 0 && (
          <div style={{
            position: 'absolute', top: '100%', left: 42, right: 0, zIndex: 50,
            backgroundColor: 'var(--bg-elevated)', border: '1px solid var(--border-color)',
            boxShadow: 'var(--shadow-lg)', borderRadius: 'var(--radius-md)', maxHeight: '180px', overflowY: 'auto', marginTop: '4px'
          }}>
            {customers.map(c => (
              <div
                key={c.customer_id}
                style={{ padding: '0.5rem 0.75rem', cursor: 'pointer', borderBottom: '1px solid var(--border-color)', transition: 'background 0.2s' }}
                onMouseEnter={(e) => e.currentTarget.style.background = 'var(--primary-glow)'}
                onMouseLeave={(e) => e.currentTarget.style.background = 'transparent'}
                onClick={() => handleSelectCustomer(c)}
              >
                <div style={{ fontWeight: 600, fontSize: '0.78rem' }}>{c.name || 'Unnamed'} {c.shop_name ? `(${c.shop_name})` : ''}</div>
                <div style={{ fontSize: '0.68rem', color: 'var(--text-muted)' }}>{c.phone} • {c.tier}</div>
              </div>
            ))}
          </div>
        )}

        {/* New customer notice */}
        {isNewCustomer && (
          <div style={{ fontSize: '0.65rem', color: 'var(--accent)', marginTop: '0.15rem', paddingLeft: 46 }}>
            ✨ New customer — will be saved on checkout
          </div>
        )}
      </div>

      {/* Name field */}
      <div style={{ display: 'flex', alignItems: 'center', gap: '0.4rem' }}>
        <label style={{ fontSize: '0.68rem', fontWeight: 600, color: 'var(--text-muted)', width: 42, flexShrink: 0 }}>Name</label>
        <input
          type="text"
          className="input-field"
          style={{ flex: 1, padding: '0.4rem 0.55rem', fontSize: '0.8rem' }}
          placeholder="Optional..."
          value={customer?.name || ''}
          onChange={(e) => handleChange('name', e.target.value)}
        />
      </div>

      {tier === 'wholesale' && (
        <>
          <div style={{ display: 'flex', alignItems: 'center', gap: '0.4rem' }}>
            <label style={{ fontSize: '0.68rem', fontWeight: 600, color: 'var(--text-muted)', width: 42, flexShrink: 0 }}>Shop *</label>
            <input
              type="text"
              className="input-field"
              style={{ flex: 1, padding: '0.4rem 0.55rem', fontSize: '0.8rem' }}
              placeholder="Required..."
              value={customer?.shop_name || ''}
              onChange={(e) => handleChange('shop_name', e.target.value)}
            />
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: '0.4rem' }}>
            <label style={{ fontSize: '0.68rem', fontWeight: 600, color: 'var(--text-muted)', width: 42, flexShrink: 0 }}>Addr.</label>
            <input
              type="text"
              className="input-field"
              style={{ flex: 1, padding: '0.4rem 0.55rem', fontSize: '0.8rem' }}
              placeholder="Optional..."
              value={customer?.address || ''}
              onChange={(e) => handleChange('address', e.target.value)}
            />
          </div>
        </>
      )}
    </div>
  );
};
