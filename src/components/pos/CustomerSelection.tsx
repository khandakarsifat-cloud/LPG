import { useEffect, useState } from 'react';
import toast from 'react-hot-toast';
import { Edit2, Phone, Save, Store, User } from 'lucide-react';
import { useAddCustomer, useCustomers } from '../../hooks/useCustomers';
import type { Customer } from '../../hooks/useCustomers';

interface CustomerSelectionProps {
  customer: any;
  onChange: (customer: any) => void;
}

export const CustomerSelection = ({ customer, onChange }: CustomerSelectionProps) => {
  const [tier, setTier] = useState<'retail' | 'wholesale'>('retail');
  const [searchTerm, setSearchTerm] = useState('');
  const [showDropdown, setShowDropdown] = useState(false);
  const [isCollapsed, setIsCollapsed] = useState(Boolean(customer?.customer_id));
  const [selectedCustomerId, setSelectedCustomerId] = useState<string | null>(customer?.customer_id ?? null);

  const { data: customers } = useCustomers(searchTerm);
  const addCustomer = useAddCustomer();

  const phone = customer?.phone?.trim() || '';
  const hasPhone = Boolean(phone);
  const isSelectedCustomer = Boolean(customer?.customer_id) && selectedCustomerId === customer.customer_id && isCollapsed;
  const exactPhoneMatch = Boolean(phone && customers?.some(c => c.phone === phone));
  const isNewCustomer = Boolean(phone && customers && !exactPhoneMatch);
  const requiredName = tier === 'retail' ? customer?.name?.trim() : customer?.shop_name?.trim();
  const canSaveCustomer = Boolean(phone && requiredName) && isNewCustomer && !addCustomer.isPending;

  useEffect(() => {
    if (!customer) {
      setIsCollapsed(false);
      setSelectedCustomerId(null);
      setSearchTerm('');
      setTier('retail');
      return;
    }

    if (customer.tier) {
      setTier(customer.tier || 'retail');
    }
  }, [customer]);

  const handleSelectCustomer = (c: Customer) => {
    onChange({ ...c, tier: c.tier || tier });
    setTier((c.tier as 'retail' | 'wholesale') || tier);
    setSearchTerm(c.phone || '');
    setShowDropdown(false);
    setSelectedCustomerId(c.customer_id);
    setIsCollapsed(true);
  };

  const handleChange = (field: string, value: string) => {
    if (field === 'phone') {
      setSearchTerm(value);
      setShowDropdown(true);
    }
    setIsCollapsed(false);
    setSelectedCustomerId(null);

    const draftCustomer = { ...customer, [field]: value, tier };
    delete draftCustomer.customer_id;
    delete draftCustomer.tenant_id;
    delete draftCustomer.created_at;
    onChange(draftCustomer);
  };

  const handleTierChange = (newTier: 'retail' | 'wholesale') => {
    setTier(newTier);
    setIsCollapsed(false);
    setSelectedCustomerId(null);

    const draftCustomer = { ...customer, tier: newTier };
    delete draftCustomer.customer_id;
    delete draftCustomer.tenant_id;
    delete draftCustomer.created_at;
    onChange(draftCustomer);
  };

  const handleSaveCustomer = async () => {
    if (!canSaveCustomer) return;

    try {
      const saved = await addCustomer.mutateAsync({
        name: tier === 'retail' ? customer.name.trim() : (customer.name?.trim() || customer.shop_name.trim()),
        phone,
        shop_name: tier === 'wholesale' ? customer.shop_name.trim() : null,
        address: customer?.address?.trim() || null,
        tier,
      });
      toast.success('Customer saved and selected');
      handleSelectCustomer(saved);
    } catch (err: any) {
      toast.error(err.message || 'Failed to save customer');
    }
  };

  if (isSelectedCustomer) {
    const title = customer.name || customer.shop_name || 'Saved customer';
    const subtitle = customer.tier === 'wholesale'
      ? customer.shop_name || 'Wholesale customer'
      : 'Retail customer';

    return (
      <div style={{
        display: 'flex',
        alignItems: 'center',
        gap: '0.55rem',
        padding: '0.55rem',
        border: '1px solid rgba(16,185,129,0.32)',
        borderRadius: 'var(--radius-md)',
        background: 'rgba(16,185,129,0.08)',
      }}>
        <div style={{
          width: 34,
          height: 34,
          borderRadius: 'var(--radius-md)',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          background: 'rgba(16,185,129,0.14)',
          color: 'var(--accent)',
          flexShrink: 0,
        }}>
          {customer.tier === 'wholesale' ? <Store size={17} /> : <User size={17} />}
        </div>
        <div style={{ minWidth: 0, flex: 1 }}>
          <div style={{ fontSize: '0.82rem', fontWeight: 700, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
            {title}
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: '0.3rem', fontSize: '0.7rem', color: 'var(--text-muted)', minWidth: 0 }}>
            <Phone size={11} />
            <span style={{ whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{phone}</span>
            <span style={{ color: 'var(--accent)' }}>-</span>
            <span style={{ textTransform: 'capitalize' }}>{subtitle}</span>
          </div>
        </div>
        <button
          type="button"
          className="btn btn-secondary"
          title="Change customer"
          style={{ width: 34, height: 34, padding: 0, flexShrink: 0 }}
          onClick={() => {
            setIsCollapsed(false);
            setSelectedCustomerId(null);
            setShowDropdown(false);
          }}
        >
          <Edit2 size={14} />
        </button>
      </div>
    );
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '0.5rem', position: 'relative' }}>
      <div style={{ display: 'flex', gap: '0.4rem', marginBottom: '0.25rem' }}>
        <button
          type="button"
          className={`btn ${tier === 'retail' ? 'btn-primary' : 'btn-secondary'}`}
          style={{ flex: 1, padding: '0.4rem 0.5rem', fontSize: '0.78rem', fontWeight: 600 }}
          onClick={() => handleTierChange('retail')}
        >
          Retail
        </button>
        <button
          type="button"
          className={`btn ${tier === 'wholesale' ? 'btn-primary' : 'btn-secondary'}`}
          style={{ flex: 1, padding: '0.4rem 0.5rem', fontSize: '0.78rem', fontWeight: 600 }}
          onClick={() => handleTierChange('wholesale')}
        >
          Wholesale
        </button>
      </div>

      <div style={{ position: 'relative' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: '0.4rem' }}>
          <label style={{
            fontSize: '0.68rem',
            fontWeight: 600,
            width: 42,
            flexShrink: 0,
            color: !hasPhone ? '#f87171' : 'var(--text-muted)',
            transition: 'color 0.2s',
          }}>
            Phone <span style={{ color: '#f87171' }}>*</span>
          </label>
          <input
            type="tel"
            className="input-field"
            style={{
              flex: 1,
              padding: '0.4rem 0.55rem',
              fontSize: '0.8rem',
              borderColor: !hasPhone ? 'rgba(248,113,113,0.5)' : undefined,
              transition: 'border-color 0.2s',
            }}
            placeholder="Required *"
            value={customer?.phone || ''}
            onChange={(e) => handleChange('phone', e.target.value.replace(/\D/g, ''))}
            onFocus={() => setShowDropdown(true)}
            onBlur={() => setTimeout(() => setShowDropdown(false), 200)}
          />
        </div>

        {showDropdown && customers && customers.length > 0 && (
          <div style={{
            position: 'absolute',
            top: '100%',
            left: 42,
            right: 0,
            zIndex: 50,
            backgroundColor: 'var(--bg-elevated)',
            border: '1px solid var(--border-color)',
            boxShadow: 'var(--shadow-lg)',
            borderRadius: 'var(--radius-md)',
            maxHeight: '180px',
            overflowY: 'auto',
            marginTop: '4px',
          }}>
            {customers.map(c => (
              <div
                key={c.customer_id}
                style={{
                  padding: '0.5rem 0.75rem',
                  cursor: 'pointer',
                  borderBottom: '1px solid var(--border-color)',
                  transition: 'background 0.2s',
                }}
                onMouseEnter={(e) => e.currentTarget.style.background = 'var(--primary-glow)'}
                onMouseLeave={(e) => e.currentTarget.style.background = 'transparent'}
                onClick={() => handleSelectCustomer(c)}
              >
                <div style={{ fontWeight: 600, fontSize: '0.78rem' }}>
                  {c.name || 'Unnamed'} {c.shop_name ? `(${c.shop_name})` : ''}
                </div>
                <div style={{ fontSize: '0.68rem', color: 'var(--text-muted)' }}>{c.phone} - {c.tier}</div>
              </div>
            ))}
          </div>
        )}
      </div>

      <div style={{ display: 'flex', alignItems: 'center', gap: '0.4rem' }}>
        <label style={{ fontSize: '0.68rem', fontWeight: 600, color: 'var(--text-muted)', width: 42, flexShrink: 0 }}>
          {tier === 'wholesale' ? 'Shop *' : 'Name *'}
        </label>
        <input
          type="text"
          className="input-field"
          style={{ flex: 1, padding: '0.4rem 0.55rem', fontSize: '0.8rem' }}
          placeholder={tier === 'wholesale' ? 'Shop name...' : 'Customer name...'}
          value={tier === 'wholesale' ? customer?.shop_name || '' : customer?.name || ''}
          onChange={(e) => handleChange(tier === 'wholesale' ? 'shop_name' : 'name', e.target.value)}
        />
      </div>

      {isNewCustomer && (
        <button
          type="button"
          className="btn btn-primary"
          style={{ width: '100%', padding: '0.45rem 0.6rem', fontSize: '0.78rem', fontWeight: 700 }}
          onClick={handleSaveCustomer}
          disabled={!canSaveCustomer}
          title={!requiredName ? `Enter ${tier === 'wholesale' ? 'shop name' : 'customer name'} to save` : undefined}
        >
          <Save size={14} />
          {addCustomer.isPending ? 'Saving...' : 'Save and Select Customer'}
        </button>
      )}
    </div>
  );
};
