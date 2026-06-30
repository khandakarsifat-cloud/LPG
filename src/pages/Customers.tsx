import React, { useState } from 'react';
import { Plus, Search } from 'lucide-react';
import { useCustomers, useAddCustomer } from '../hooks/useCustomers';

export const CustomersPage = () => {
  const [searchTerm, setSearchTerm] = useState('');
  const [activeTab, setActiveTab] = useState<'retail' | 'wholesale'>('retail');
  const { data: customers, isLoading, isError } = useCustomers(searchTerm);
  
  const filteredCustomers = customers?.filter(c => c.tier === activeTab);
  
  const [isModalOpen, setIsModalOpen] = useState(false);
  
  return (
    <div className="page-container">
      <div className="page-header">
        <h1 className="page-title">Customer Management</h1>
        <button className="btn btn-primary" onClick={() => setIsModalOpen(true)}>
          <Plus size={18} />
          <span>Add Customer</span>
        </button>
      </div>

      <div className="card glass-panel p-4" style={{ marginBottom: '1.5rem' }}>
        <div className="input-group" style={{ margin: 0 }}>
          <div style={{ position: 'relative' }}>
            <Search size={18} style={{ position: 'absolute', left: '1rem', top: '50%', transform: 'translateY(-50%)', color: 'var(--text-muted)' }} />
            <input 
              type="text" 
              className="input-field" 
              placeholder="Search customers by name, phone, or shop name..."
              value={searchTerm}
              onChange={(e) => setSearchTerm(e.target.value)}
              style={{ paddingLeft: '2.5rem' }}
            />
          </div>
        </div>
      </div>

      <div className="card glass-panel" style={{ overflow: 'hidden' }}>
        
        {/* Tabs */}
        <div style={{ display: 'flex', borderBottom: '1px solid var(--border-color)' }}>
          <button 
            style={{ 
              flex: 1, padding: '1rem', background: 'transparent', border: 'none', 
              borderBottom: activeTab === 'retail' ? '2px solid var(--primary)' : '2px solid transparent',
              color: activeTab === 'retail' ? 'var(--primary)' : 'var(--text-muted)',
              fontWeight: activeTab === 'retail' ? 600 : 400,
              cursor: 'pointer', transition: 'all 0.2s'
            }}
            onClick={() => setActiveTab('retail')}
          >
            Retail Customers
          </button>
          <button 
            style={{ 
              flex: 1, padding: '1rem', background: 'transparent', border: 'none', 
              borderBottom: activeTab === 'wholesale' ? '2px solid var(--primary)' : '2px solid transparent',
              color: activeTab === 'wholesale' ? 'var(--primary)' : 'var(--text-muted)',
              fontWeight: activeTab === 'wholesale' ? 600 : 400,
              cursor: 'pointer', transition: 'all 0.2s'
            }}
            onClick={() => setActiveTab('wholesale')}
          >
            Wholesale Customers
          </button>
        </div>

        {isLoading ? (
          <div className="p-8 text-center" style={{ color: 'var(--text-muted)' }}>Loading customers...</div>
        ) : isError ? (
          <div className="p-8 text-center" style={{ color: 'var(--accent)' }}>Failed to load customers.</div>
        ) : !filteredCustomers || filteredCustomers.length === 0 ? (
          <div className="p-8 text-center" style={{ color: 'var(--text-muted)' }}>No {activeTab} customers found.</div>
        ) : (
          <div style={{ overflowX: 'auto' }}>
            <table style={{ width: '100%', borderCollapse: 'collapse', textAlign: 'left' }}>
              <thead>
                <tr style={{ borderBottom: '1px solid var(--border-color)' }}>
                  <th style={{ padding: '1rem', fontWeight: 600, color: 'var(--text-muted)' }}>Customer Name</th>
                  <th style={{ padding: '1rem', fontWeight: 600, color: 'var(--text-muted)' }}>Phone Number</th>
                  {activeTab === 'wholesale' && (
                    <th style={{ padding: '1rem', fontWeight: 600, color: 'var(--text-muted)' }}>Shop Name</th>
                  )}
                  <th style={{ padding: '1rem', fontWeight: 600, color: 'var(--text-muted)' }}>Address</th>
                  <th style={{ padding: '1rem', fontWeight: 600, color: 'var(--text-muted)' }}>Joined Date</th>
                </tr>
              </thead>
              <tbody>
                {filteredCustomers.map((c) => (
                  <tr key={c.customer_id} style={{ borderBottom: '1px solid var(--border-color)', transition: 'background 0.2s' }}>
                    <td style={{ padding: '1rem', fontWeight: 600 }}>{c.name || 'Unknown'}</td>
                    <td style={{ padding: '1rem' }}>{c.phone || '-'}</td>
                    {activeTab === 'wholesale' && (
                      <td style={{ padding: '1rem', color: 'var(--primary)' }}>{c.shop_name || '-'}</td>
                    )}
                    <td style={{ padding: '1rem', color: 'var(--text-muted)' }}>{c.address || '-'}</td>
                    <td style={{ padding: '1rem', color: 'var(--text-muted)', fontSize: '0.875rem' }}>
                      {new Date(c.created_at).toLocaleDateString()}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>

      {isModalOpen && <AddCustomerModal onClose={() => setIsModalOpen(false)} />}
    </div>
  );
};

const AddCustomerModal = ({ onClose }: { onClose: () => void }) => {
  const [tier, setTier] = useState<'retail' | 'wholesale'>('retail');
  const [phone, setPhone] = useState('');
  const [name, setName] = useState('');
  const [shopName, setShopName] = useState('');
  const [address, setAddress] = useState('');
  const [errorMsg, setErrorMsg] = useState('');
  
  const addCustomerMutation = useAddCustomer();

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setErrorMsg('');
    
    if (tier === 'wholesale' && !shopName.trim()) {
      setErrorMsg('Shop name is required for wholesale customers.');
      return;
    }
    
    try {
      await addCustomerMutation.mutateAsync({
        tier,
        phone: phone || null,
        name: name || 'Unknown',
        shop_name: shopName || null,
        address: address || null
      });
      onClose();
    } catch (err: any) {
      setErrorMsg(err.message || 'Failed to add customer.');
    }
  };

  return (
    <div style={{
      position: 'fixed', top: 0, left: 0, right: 0, bottom: 0, zIndex: 100,
      backgroundColor: 'rgba(0,0,0,0.5)', backdropFilter: 'blur(4px)',
      display: 'flex', alignItems: 'center', justifyContent: 'center', padding: '1rem'
    }}>
      <div className="card glass-panel" style={{ width: '100%', maxWidth: 'min(92vw, 31.25rem)', display: 'flex', flexDirection: 'column' }}>
        <div style={{ padding: '1.5rem', borderBottom: '1px solid var(--border-color)', display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
          <h2 style={{ margin: 0, fontSize: '1.25rem' }}>Add New Customer</h2>
          <button onClick={onClose} style={{ background: 'none', border: 'none', color: 'var(--text-muted)', cursor: 'pointer', fontSize: '1.5rem' }}>&times;</button>
        </div>
        
        <form onSubmit={handleSubmit} style={{ padding: '1.5rem', display: 'flex', flexDirection: 'column', gap: '1rem' }}>
          {errorMsg && (
            <div style={{ padding: '0.75rem', backgroundColor: 'rgba(239, 68, 68, 0.1)', color: '#ef4444', borderRadius: 'var(--radius-md)', fontSize: '0.875rem' }}>
              {errorMsg}
            </div>
          )}

          <div style={{ display: 'flex', gap: '1rem', marginBottom: '0.5rem' }}>
            <button 
              type="button"
              className={`btn ${tier === 'retail' ? 'btn-primary' : 'btn-secondary'}`} 
              style={{ flex: 1 }}
              onClick={() => setTier('retail')}
            >
              Retail
            </button>
            <button 
              type="button"
              className={`btn ${tier === 'wholesale' ? 'btn-primary' : 'btn-secondary'}`} 
              style={{ flex: 1 }}
              onClick={() => setTier('wholesale')}
            >
              Wholesale
            </button>
          </div>

          <div className="input-group">
            <label className="input-label">Phone Number {tier === 'wholesale' && '*'}</label>
            <input 
              type="tel" 
              className="input-field" 
              placeholder="Enter phone..."
              value={phone}
              onChange={(e) => setPhone(e.target.value.replace(/\D/g, ''))}
              required={tier === 'wholesale'}
            />
          </div>

          <div className="input-group">
            <label className="input-label">Customer Name</label>
            <input 
              type="text" 
              className="input-field" 
              placeholder="Optional name..."
              value={name}
              onChange={(e) => setName(e.target.value)}
            />
          </div>

          {tier === 'wholesale' && (
            <div className="input-group">
              <label className="input-label">Shop Name *</label>
              <input 
                type="text" 
                className="input-field" 
                placeholder="Required for wholesale..."
                value={shopName}
                onChange={(e) => setShopName(e.target.value)}
              />
            </div>
          )}

          <div className="input-group">
            <label className="input-label">Location / Address</label>
            <input 
              type="text" 
              className="input-field" 
              placeholder="Optional address..."
              value={address}
              onChange={(e) => setAddress(e.target.value)}
            />
          </div>

          <div style={{ display: 'flex', gap: '1rem', marginTop: '1rem' }}>
            <button type="button" className="btn btn-secondary" style={{ flex: 1 }} onClick={onClose}>Cancel</button>
            <button type="submit" className="btn btn-primary" style={{ flex: 1 }} disabled={addCustomerMutation.isPending}>
              {addCustomerMutation.isPending ? 'Adding...' : 'Save Customer'}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
};
