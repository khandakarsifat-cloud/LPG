import { useState } from 'react';
import { Settings as SettingsIcon, Building2 } from 'lucide-react';
import { BrandManagement } from '../components/business/BrandManagement';

export const SettingsPage = () => {
  const [activeTab, setActiveTab] = useState<'business' | 'brands'>('business');

  return (
    <div className="app-screen" style={{ display: 'flex', flexDirection: 'column', gap: 'var(--space-md)' }}>
      {/* Page Header */}
      <div className="app-screen-header" style={{ display: 'flex', alignItems: 'center', gap: '1rem' }}>
        <div style={{ backgroundColor: 'var(--primary)', padding: '0.75rem', borderRadius: '0.5rem' }}>
          <SettingsIcon size={24} color="white" />
        </div>
        <div>
          <h1 style={{ margin: 0, fontSize: '1.875rem', fontWeight: 700 }}>Settings</h1>
          <p style={{ margin: '0.5rem 0 0 0', fontSize: '0.875rem', color: 'var(--text-muted)' }}>
            Manage your business profile and preferences
          </p>
        </div>
      </div>

      {/* Tabs */}
      <div style={{ display: 'flex', gap: '0.5rem', borderBottom: '1px solid var(--border)', flexShrink: 0 }}>
        <button
          onClick={() => setActiveTab('business')}
          style={{
            padding: '1rem 1.5rem',
            backgroundColor: 'transparent',
            border: 'none',
            borderBottom: activeTab === 'business' ? '3px solid var(--primary)' : 'none',
            cursor: 'pointer',
            fontWeight: activeTab === 'business' ? 600 : 500,
            color: activeTab === 'business' ? 'var(--text-primary)' : 'var(--text-muted)',
            fontSize: '0.95rem',
            display: 'flex',
            alignItems: 'center',
            gap: '0.5rem',
          }}
        >
          <Building2 size={18} />
          Business Profile
        </button>
        <button
          onClick={() => setActiveTab('brands')}
          style={{
            padding: '1rem 1.5rem',
            backgroundColor: 'transparent',
            border: 'none',
            borderBottom: activeTab === 'brands' ? '3px solid var(--primary)' : 'none',
            cursor: 'pointer',
            fontWeight: activeTab === 'brands' ? 600 : 500,
            color: activeTab === 'brands' ? 'var(--text-primary)' : 'var(--text-muted)',
            fontSize: '0.95rem',
          }}
        >
          🏷️ LPG Brands
        </button>
      </div>

      {/* Tab Content */}
      <div className="app-screen-scroll">
        {activeTab === 'business' && (
          <div className="card" style={{ padding: '2rem' }}>
            <div style={{ textAlign: 'center', color: 'var(--text-muted)' }}>
              <div style={{ fontSize: '3rem', marginBottom: '1rem' }}>🏢</div>
              <h3 style={{ margin: 0, fontSize: '1.125rem', fontWeight: 600 }}>Business Profile</h3>
              <p style={{ margin: '0.5rem 0 0 0', fontSize: '0.875rem' }}>
                Business profile management coming soon
              </p>
            </div>
          </div>
        )}

        {activeTab === 'brands' && <BrandManagement />}
      </div>
    </div>
  );
};
