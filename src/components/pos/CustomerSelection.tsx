import { useEffect, useState } from 'react';
import toast from 'react-hot-toast';
import { Edit2, MapPin, Phone, Save, Store, User } from 'lucide-react';
import { useAddCustomer, useCustomers } from '../../hooks/useCustomers';
import type { Customer } from '../../hooks/useCustomers';
import {
  BD_MOBILE_PHONE_ERROR,
  getPhoneSearchTerms,
  normalizePhoneInput,
  validateBDMobilePhone,
} from '../../lib/bdPhone';

export type POSCustomerDraft = Partial<Omit<Customer, 'tier' | 'name' | 'phone'>> & {
  name?: string | null;
  phone?: string | null;
  tier?: 'retail' | 'wholesale';
};

interface CustomerSelectionProps {
  customer: POSCustomerDraft | null;
  onChange: (customer: POSCustomerDraft | null) => void;
}

const getPhoneCandidateFromSearch = (value: string) => {
  const normalized = normalizePhoneInput(value);
  const match = normalized.match(/(?:08801[3-9]\d{0,8}|01[3-9]\d{0,8})/);
  return match?.[0] ?? '';
};

export const CustomerSelection = ({ customer, onChange }: CustomerSelectionProps) => {
  const [tier, setTier] = useState<'retail' | 'wholesale'>('retail');
  const [searchTerm, setSearchTerm] = useState('');
  const [showDropdown, setShowDropdown] = useState(false);
  const [isCollapsed, setIsCollapsed] = useState(Boolean(customer?.customer_id));
  const [selectedCustomerId, setSelectedCustomerId] = useState<string | null>(customer?.customer_id ?? null);

  const { data: customers } = useCustomers(searchTerm);
  const addCustomer = useAddCustomer();

  const currentCustomer = customer ?? {};
  const phone = customer?.phone?.trim() || '';
  const hasPhone = Boolean(phone);
  const hasNonNumericPhoneSearch = Boolean(searchTerm.trim() && /\d/.test(searchTerm) && /\D/.test(searchTerm));
  const phoneError = (hasPhone && !validateBDMobilePhone(phone)) || hasNonNumericPhoneSearch ? BD_MOBILE_PHONE_ERROR : '';
  const isSelectedCustomer = Boolean(currentCustomer.customer_id) && selectedCustomerId === currentCustomer.customer_id && isCollapsed;
  const phoneSearchTerms = getPhoneSearchTerms(phone);
  const exactPhoneMatch = Boolean(phone && customers?.some(c => phoneSearchTerms.includes(c.phone)));
  const isNewCustomer = Boolean(phone && !phoneError && customers && !exactPhoneMatch);
  const requiredName = tier === 'retail' ? currentCustomer.name?.trim() : currentCustomer.shop_name?.trim();
  const canSaveCustomer = Boolean(phone && !phoneError && requiredName) && isNewCustomer && !addCustomer.isPending;

  useEffect(() => {
    if (!customer) {
      // eslint-disable-next-line react-hooks/set-state-in-effect
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
    const selectedTier = c.tier === 'wholesale' ? 'wholesale' : 'retail';
    onChange({ ...c, tier: selectedTier });
    setTier(selectedTier);
    setSearchTerm(c.phone || '');
    setShowDropdown(false);
    setSelectedCustomerId(c.customer_id);
    setIsCollapsed(true);
  };

  const handleClearSelectedCustomer = () => {
    onChange(null);
    setTier('retail');
    setSearchTerm('');
    setShowDropdown(false);
    setSelectedCustomerId(null);
    setIsCollapsed(false);
  };

  const handleChange = (field: string, value: string) => {
    if (field === 'phone') {
      const phoneValue = getPhoneCandidateFromSearch(value);
      setSearchTerm(value);
      setShowDropdown(true);
      setIsCollapsed(false);
      setSelectedCustomerId(null);

      const draftCustomer = { ...currentCustomer, phone: phoneValue, tier };
      delete draftCustomer.customer_id;
      delete draftCustomer.tenant_id;
      delete draftCustomer.created_at;
      onChange(draftCustomer);
      return;
    }

    const nextValue = value;
    setIsCollapsed(false);
    setSelectedCustomerId(null);

    const draftCustomer = { ...currentCustomer, [field]: nextValue, tier };
    delete draftCustomer.customer_id;
    delete draftCustomer.tenant_id;
    delete draftCustomer.created_at;
    onChange(draftCustomer);
  };

  const handleTierChange = (newTier: 'retail' | 'wholesale') => {
    setTier(newTier);
    setIsCollapsed(false);
    setSelectedCustomerId(null);

    const draftCustomer = { ...currentCustomer, tier: newTier };
    delete draftCustomer.customer_id;
    delete draftCustomer.tenant_id;
    delete draftCustomer.created_at;
    onChange(draftCustomer);
  };

  const handleSaveCustomer = async () => {
    if (!canSaveCustomer) return;

    try {
      const customerName = currentCustomer.name?.trim() || '';
      const shopName = currentCustomer.shop_name?.trim() || '';
      const saved = await addCustomer.mutateAsync({
        name: tier === 'retail' ? customerName : (customerName || shopName),
        phone,
        shop_name: tier === 'wholesale' ? shopName : null,
        address: currentCustomer.address?.trim() || null,
        tier,
      });
      toast.success('Customer saved and selected');
      handleSelectCustomer(saved);
    } catch (err: unknown) {
      toast.error(err instanceof Error ? err.message : 'Failed to save customer');
    }
  };

  if (isSelectedCustomer && customer) {
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
          title="Choose another customer"
          style={{ width: 34, height: 34, padding: 0, flexShrink: 0 }}
          onClick={handleClearSelectedCustomer}
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
            type="text"
            inputMode="search"
            className="input-field"
            style={{
              flex: 1,
              padding: '0.4rem 0.55rem',
              fontSize: '0.8rem',
              borderColor: !hasPhone || phoneError ? 'rgba(248,113,113,0.5)' : undefined,
              transition: 'border-color 0.2s',
            }}
            placeholder="Phone, name, shop, address..."
            value={searchTerm || customer?.phone || ''}
            onChange={(e) => handleChange('phone', e.target.value)}
            onFocus={() => {
              if (!searchTerm && customer?.phone) setSearchTerm(customer.phone);
              setShowDropdown(true);
            }}
            onBlur={() => setTimeout(() => setShowDropdown(false), 200)}
            required
          />
        </div>

        {phoneError && (
          <div style={{ marginLeft: 42, marginTop: '0.25rem', fontSize: '0.68rem', color: '#fca5a5' }}>
            {phoneError}
          </div>
        )}

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
            maxHeight: 'min(16rem, 42vh)',
            overflowY: 'auto',
            overscrollBehavior: 'contain',
            marginTop: '4px',
          }}>
            {customers.map(c => (
              <div
                key={c.customer_id}
                style={{
                  padding: '0.55rem 0.7rem',
                  cursor: 'pointer',
                  borderBottom: '1px solid var(--border-color)',
                  transition: 'background 0.2s',
                }}
                onMouseDown={(e) => e.preventDefault()}
                onMouseEnter={(e) => e.currentTarget.style.background = 'var(--primary-glow)'}
                onMouseLeave={(e) => e.currentTarget.style.background = 'transparent'}
                onClick={() => handleSelectCustomer(c)}
              >
                <div style={{ display: 'flex', alignItems: 'center', gap: '0.45rem', minWidth: 0 }}>
                  <div style={{
                    width: 28,
                    height: 28,
                    borderRadius: 'var(--radius-md)',
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'center',
                    background: 'var(--bg-tertiary)',
                    color: 'var(--text-muted)',
                    flexShrink: 0,
                  }}>
                    {c.tier === 'wholesale' ? <Store size={14} /> : <User size={14} />}
                  </div>
                  <div style={{ minWidth: 0, flex: 1 }}>
                    <div style={{ fontWeight: 700, fontSize: '0.78rem', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
                      {c.name || c.shop_name || 'Unnamed customer'}
                    </div>
                    {c.shop_name && c.shop_name !== c.name && (
                      <div style={{ fontSize: '0.68rem', color: 'var(--text-muted)', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
                        {c.shop_name}
                      </div>
                    )}
                  </div>
                </div>
                <div style={{
                  display: 'grid',
                  gridTemplateColumns: 'minmax(0, max-content) minmax(0, 1fr)',
                  gap: '0.25rem 0.55rem',
                  marginTop: '0.4rem',
                  paddingLeft: 34,
                  fontSize: '0.68rem',
                  color: 'var(--text-muted)',
                }}>
                  <span style={{ display: 'inline-flex', alignItems: 'center', gap: '0.2rem', whiteSpace: 'nowrap' }}>
                    <Phone size={10} /> {c.phone}
                  </span>
                  <span style={{ textTransform: 'capitalize', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
                    {c.tier}
                  </span>
                  {c.address && (
                    <span style={{
                      gridColumn: '1 / -1',
                      display: 'inline-flex',
                      alignItems: 'center',
                      gap: '0.2rem',
                      minWidth: 0,
                      whiteSpace: 'nowrap',
                      overflow: 'hidden',
                      textOverflow: 'ellipsis',
                    }}>
                      <MapPin size={10} style={{ flexShrink: 0 }} /> {c.address}
                    </span>
                  )}
                </div>
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

      <div style={{ display: 'flex', alignItems: 'center', gap: '0.4rem' }}>
        <label style={{ fontSize: '0.68rem', fontWeight: 600, color: 'var(--text-muted)', width: 42, flexShrink: 0 }}>
          Address
        </label>
        <input
          type="text"
          className="input-field"
          style={{ flex: 1, padding: '0.4rem 0.55rem', fontSize: '0.8rem' }}
          placeholder="Optional address..."
          value={customer?.address || ''}
          onChange={(e) => handleChange('address', e.target.value)}
        />
      </div>

      {isNewCustomer && (
        <button
          type="button"
          className="btn btn-primary"
          style={{ width: '100%', padding: '0.45rem 0.6rem', fontSize: '0.78rem', fontWeight: 700 }}
          onClick={handleSaveCustomer}
          disabled={!canSaveCustomer}
          title={phoneError || (!requiredName ? `Enter ${tier === 'wholesale' ? 'shop name' : 'customer name'} to save` : undefined)}
        >
          <Save size={14} />
          {addCustomer.isPending ? 'Saving...' : 'Save and Select Customer'}
        </button>
      )}
    </div>
  );
};
