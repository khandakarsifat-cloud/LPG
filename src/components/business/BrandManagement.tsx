import { useState } from 'react';
import { useLPGBrands, useCreateBrand, useUpdateBrand } from '../../hooks/useBrands';
import { Plus, Edit2, Trash2, AlertCircle, CheckCircle } from 'lucide-react';
import type { LPGBrand } from '../../types/inventory';

export const BrandManagement = () => {
  const { data: brands = [], isLoading, error } = useLPGBrands();
  const createBrand = useCreateBrand();
  const updateBrand = useUpdateBrand();

  const [showForm, setShowForm] = useState(false);
  const [editingBrand, setEditingBrand] = useState<LPGBrand | null>(null);
  const [formData, setFormData] = useState({ brand_name: '', description: '' });
  const [message, setMessage] = useState<{ type: 'success' | 'error'; text: string } | null>(null);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setMessage(null);

    try {
      if (editingBrand) {
        await updateBrand.mutateAsync({
          brand_id: editingBrand.brand_id,
          brand_name: formData.brand_name || editingBrand.brand_name,
          description: formData.description || editingBrand.description || undefined,
        });
        setMessage({ type: 'success', text: 'Brand updated successfully!' });
      } else {
        await createBrand.mutateAsync({
          brand_name: formData.brand_name,
          description: formData.description || undefined,
        });
        setMessage({ type: 'success', text: 'Brand added successfully!' });
      }

      setFormData({ brand_name: '', description: '' });
      setEditingBrand(null);
      setShowForm(false);

      setTimeout(() => setMessage(null), 3000);
    } catch (err) {
      const errorMsg = err instanceof Error ? err.message : 'Failed to save brand';
      setMessage({ type: 'error', text: errorMsg });
    }
  };

  const handleEdit = (brand: LPGBrand) => {
    setEditingBrand(brand);
    setFormData({
      brand_name: brand.brand_name,
      description: brand.description || '',
    });
    setShowForm(true);
  };

  const handleCancel = () => {
    setShowForm(false);
    setEditingBrand(null);
    setFormData({ brand_name: '', description: '' });
    setMessage(null);
  };

  const handleToggleActive = async (brand: LPGBrand) => {
    try {
      await updateBrand.mutateAsync({
        brand_id: brand.brand_id,
        is_active: !brand.is_active,
      });
      setMessage({
        type: 'success',
        text: `Brand ${!brand.is_active ? 'activated' : 'deactivated'}!`,
      });
      setTimeout(() => setMessage(null), 3000);
    } catch (err) {
      const errorMsg = err instanceof Error ? err.message : 'Failed to update brand';
      setMessage({ type: 'error', text: errorMsg });
    }
  };

  if (error) {
    return (
      <div className="card" style={{ borderColor: 'var(--status-error)' }}>
        <div style={{ display: 'flex', gap: '0.75rem', alignItems: 'flex-start', color: 'var(--status-error)' }}>
          <AlertCircle size={20} style={{ flexShrink: 0, marginTop: '0.25rem' }} />
          <div>
            <strong>Error loading brands</strong>
            <p style={{ fontSize: '0.875rem', marginTop: '0.25rem' }}>
              {error instanceof Error ? error.message : 'Unknown error'}
            </p>
          </div>
        </div>
      </div>
    );
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '1.5rem' }}>
      {/* Header */}
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
        <div>
          <h3 style={{ fontSize: '1.25rem', fontWeight: 600, margin: 0 }}>LPG Brands</h3>
          <p style={{ fontSize: '0.875rem', color: 'var(--text-muted)', margin: '0.5rem 0 0 0' }}>
            Manage the LPG brands your business is associated with
          </p>
        </div>
        {!showForm && (
          <button
            onClick={() => setShowForm(true)}
            style={{
              display: 'flex',
              alignItems: 'center',
              gap: '0.5rem',
              padding: '0.625rem 1rem',
              backgroundColor: 'var(--primary)',
              color: 'white',
              border: 'none',
              borderRadius: '0.5rem',
              cursor: 'pointer',
              fontWeight: 500,
              fontSize: '0.875rem',
            }}
          >
            <Plus size={16} />
            Add Brand
          </button>
        )}
      </div>

      {/* Message */}
      {message && (
        <div
          style={{
            display: 'flex',
            gap: '0.75rem',
            padding: '0.75rem 1rem',
            backgroundColor: message.type === 'success' ? 'rgba(16, 185, 129, 0.1)' : 'rgba(239, 68, 68, 0.1)',
            borderLeft: `4px solid ${message.type === 'success' ? 'var(--status-success)' : 'var(--status-error)'}`,
            borderRadius: '0.375rem',
            alignItems: 'center',
          }}
        >
          {message.type === 'success' ? (
            <CheckCircle size={18} style={{ color: 'var(--status-success)', flexShrink: 0 }} />
          ) : (
            <AlertCircle size={18} style={{ color: 'var(--status-error)', flexShrink: 0 }} />
          )}
          <span style={{ fontSize: '0.875rem' }}>{message.text}</span>
        </div>
      )}

      {/* Form */}
      {showForm && (
        <form onSubmit={handleSubmit} className="card" style={{ padding: '1.5rem' }}>
          <h4 style={{ margin: '0 0 1rem 0', fontSize: '1rem', fontWeight: 600 }}>
            {editingBrand ? 'Edit Brand' : 'Add New Brand'}
          </h4>

          <div style={{ display: 'flex', flexDirection: 'column', gap: '1rem' }}>
            <div>
              <label style={{ display: 'block', marginBottom: '0.5rem', fontSize: '0.875rem', fontWeight: 500 }}>
                Brand Name *
              </label>
              <input
                type="text"
                value={formData.brand_name}
                onChange={(e) => setFormData({ ...formData, brand_name: e.target.value })}
                placeholder="Enter brand name (e.g., Indane, Bharat Gas)"
                className="input-field"
                required
                style={{ width: '100%' }}
              />
            </div>

            <div>
              <label style={{ display: 'block', marginBottom: '0.5rem', fontSize: '0.875rem', fontWeight: 500 }}>
                Description
              </label>
              <textarea
                value={formData.description}
                onChange={(e) => setFormData({ ...formData, description: e.target.value })}
                placeholder="Enter brand description (optional)"
                className="input-field"
                rows={3}
                style={{ width: '100%', fontFamily: 'inherit' }}
              />
            </div>

            <div style={{ display: 'flex', gap: '0.75rem', justifyContent: 'flex-end' }}>
              <button
                type="button"
                onClick={handleCancel}
                style={{
                  padding: '0.625rem 1rem',
                  backgroundColor: 'var(--bg-secondary)',
                  border: `1px solid var(--border)`,
                  borderRadius: '0.5rem',
                  cursor: 'pointer',
                  fontWeight: 500,
                  fontSize: '0.875rem',
                }}
              >
                Cancel
              </button>
              <button
                type="submit"
                disabled={createBrand.isPending || updateBrand.isPending}
                style={{
                  padding: '0.625rem 1rem',
                  backgroundColor: 'var(--primary)',
                  color: 'white',
                  border: 'none',
                  borderRadius: '0.5rem',
                  cursor: createBrand.isPending || updateBrand.isPending ? 'not-allowed' : 'pointer',
                  fontWeight: 500,
                  fontSize: '0.875rem',
                  opacity: createBrand.isPending || updateBrand.isPending ? 0.6 : 1,
                }}
              >
                {editingBrand ? 'Update Brand' : 'Add Brand'}
              </button>
            </div>
          </div>
        </form>
      )}

      {/* Brands List */}
      {isLoading ? (
        <div style={{ textAlign: 'center', padding: '2rem', color: 'var(--text-muted)' }}>
          Loading brands...
        </div>
      ) : brands.length === 0 ? (
        <div className="card" style={{ textAlign: 'center', padding: '2rem', color: 'var(--text-muted)' }}>
          <div style={{ fontSize: '2rem', marginBottom: '0.5rem' }}>🏷️</div>
          <p>No brands added yet. Add your first brand to get started!</p>
        </div>
      ) : (
        <div
          style={{
            display: 'grid',
            gridTemplateColumns: 'repeat(auto-fill, minmax(300px, 1fr))',
            gap: '1rem',
          }}
        >
          {brands.map((brand) => (
            <div
              key={brand.brand_id}
              className="card"
              style={{
                padding: '1.25rem',
                display: 'flex',
                flexDirection: 'column',
                gap: '1rem',
                opacity: brand.is_active ? 1 : 0.6,
              }}
            >
              <div style={{ flex: 1 }}>
                <h4 style={{ margin: '0 0 0.25rem 0', fontSize: '1rem', fontWeight: 600 }}>
                  {brand.brand_name}
                </h4>
                {brand.description && (
                  <p style={{ margin: '0.5rem 0 0 0', fontSize: '0.875rem', color: 'var(--text-muted)' }}>
                    {brand.description}
                  </p>
                )}
                <div style={{ marginTop: '0.75rem', display: 'flex', alignItems: 'center', gap: '0.5rem' }}>
                  <span
                    style={{
                      display: 'inline-block',
                      padding: '0.25rem 0.625rem',
                      backgroundColor: brand.is_active
                        ? 'rgba(16, 185, 129, 0.1)'
                        : 'rgba(107, 114, 128, 0.1)',
                      color: brand.is_active ? 'var(--status-success)' : 'var(--text-muted)',
                      borderRadius: '0.25rem',
                      fontSize: '0.75rem',
                      fontWeight: 500,
                    }}
                  >
                    {brand.is_active ? 'Active' : 'Inactive'}
                  </span>
                </div>
              </div>

              <div style={{ display: 'flex', gap: '0.5rem', borderTop: '1px solid var(--border)', paddingTop: '1rem' }}>
                <button
                  onClick={() => handleEdit(brand)}
                  style={{
                    flex: 1,
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'center',
                    gap: '0.5rem',
                    padding: '0.5rem',
                    backgroundColor: 'var(--bg-secondary)',
                    border: `1px solid var(--border)`,
                    borderRadius: '0.375rem',
                    cursor: 'pointer',
                    fontSize: '0.875rem',
                  }}
                >
                  <Edit2 size={14} />
                  Edit
                </button>
                <button
                  onClick={() => handleToggleActive(brand)}
                  style={{
                    flex: 1,
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'center',
                    gap: '0.5rem',
                    padding: '0.5rem',
                    backgroundColor: brand.is_active
                      ? 'rgba(239, 68, 68, 0.1)'
                      : 'rgba(16, 185, 129, 0.1)',
                    border: `1px solid ${brand.is_active ? '#ef4444' : '#10b981'}`,
                    color: brand.is_active ? '#ef4444' : '#10b981',
                    borderRadius: '0.375rem',
                    cursor: 'pointer',
                    fontSize: '0.875rem',
                  }}
                >
                  {brand.is_active ? (
                    <>
                      <Trash2 size={14} />
                      Deactivate
                    </>
                  ) : (
                    <>
                      <CheckCircle size={14} />
                      Activate
                    </>
                  )}
                </button>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
};
