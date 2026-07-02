import { useState } from 'react';
import {
  Factory,
  Plus,
  MapPin,
  Phone,
  Mail,
  Edit2,
  UserCheck,
  Building2,
  Layers,
  Tag,
} from 'lucide-react';
import { useGasPlants, useUpdateGasPlant } from '../hooks/useGasPlants';
import { AddGasPlantModal } from '../components/gasplants/AddGasPlantModal';
import { AreaOfficerModal } from '../components/gasplants/AreaOfficerModal';
import type { GasPlant } from '../types/gasPlants';

export const GasPlantsPage = () => {
  const { data: plants = [], isLoading, error } = useGasPlants();
  const updatePlant = useUpdateGasPlant();

  const [addDialogOpen,    setAddDialogOpen]    = useState(false);
  const [editingPlant,     setEditingPlant]      = useState<GasPlant | null>(null);
  const [officerDialogOpen, setOfficerDialogOpen] = useState(false);
  const [officerPlant,     setOfficerPlant]      = useState<GasPlant | null>(null);

  // Stats
  const totalPlants  = plants.length;
  const activePlants = plants.filter((p) => p.is_active).length;
  const withOfficer  = plants.filter((p) => !!p.officer_id).length;
  const brandSet     = new Set(plants.map((p) => p.brand_id).filter(Boolean));
  const totalBrands  = brandSet.size;

  const handleEditPlant = (plant: GasPlant) => {
    setEditingPlant(plant);
    setAddDialogOpen(true);
  };

  const handleAddDialogClose = () => {
    setAddDialogOpen(false);
    setEditingPlant(null);
  };

  const handleOfficer = (plant: GasPlant) => {
    setOfficerPlant(plant);
    setOfficerDialogOpen(true);
  };

  const handleToggleActive = async (plant: GasPlant) => {
    await updatePlant.mutateAsync({ plant_id: plant.plant_id, is_active: !plant.is_active });
  };

  return (
    <div className="inventory-page">
      {/* ── Page Header ── */}
      <div className="page-header">
        <div>
          <h1 className="page-title">Gas Plants</h1>
          <p className="page-subtitle">
            Manage LPG filling plants and their area officers across all brands.
          </p>
        </div>
        <button className="btn btn-primary" onClick={() => setAddDialogOpen(true)}>
          <Plus size={16} />
          Add Gas Plant
        </button>
      </div>

      {/* ── Stats Row ── */}
      <div className="inv-stats-row">
        <div className="glass-panel inv-stat">
          <div className="inv-stat-icon" style={{ background: 'rgba(59,130,246,0.1)', color: 'var(--primary)' }}>
            <Factory size={18} />
          </div>
          <div>
            <div className="inv-stat-value">{totalPlants}</div>
            <div className="inv-stat-label">Total Plants</div>
          </div>
        </div>
        <div className="glass-panel inv-stat">
          <div className="inv-stat-icon" style={{ background: 'rgba(16,185,129,0.1)', color: 'var(--accent)' }}>
            <Layers size={18} />
          </div>
          <div>
            <div className="inv-stat-value">{activePlants}</div>
            <div className="inv-stat-label">Active Plants</div>
          </div>
        </div>
        <div className="glass-panel inv-stat">
          <div className="inv-stat-icon" style={{ background: 'rgba(139,92,246,0.1)', color: '#8b5cf6' }}>
            <Tag size={18} />
          </div>
          <div>
            <div className="inv-stat-value">{totalBrands}</div>
            <div className="inv-stat-label">Brands Covered</div>
          </div>
        </div>
        <div className="glass-panel inv-stat">
          <div className="inv-stat-icon" style={{ background: 'rgba(245,158,11,0.1)', color: 'var(--warning)' }}>
            <UserCheck size={18} />
          </div>
          <div>
            <div className="inv-stat-value">{withOfficer}</div>
            <div className="inv-stat-label">Officers Assigned</div>
          </div>
        </div>
      </div>

      {/* ── Content ── */}
      <div className="app-screen-scroll">
      {error ? (
        <div className="glass-panel" style={{ padding: '2rem', textAlign: 'center', color: 'var(--danger)' }}>
          <Factory size={32} style={{ marginBottom: '0.75rem', opacity: 0.5 }} />
          <p style={{ fontWeight: 600 }}>Failed to load gas plants</p>
          <p style={{ fontSize: '0.875rem', color: 'var(--text-muted)', marginTop: '0.25rem' }}>
            {(error as Error).message}
          </p>
        </div>
      ) : isLoading ? (
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(340px, 1fr))', gap: '1rem' }}>
          {[1, 2, 3].map((i) => (
            <div key={i} className="glass-panel" style={{ padding: '1.5rem', minHeight: '200px', opacity: 0.4 }}>
              <div style={{ background: 'var(--bg-secondary)', borderRadius: '0.5rem', height: '1.25rem', width: '60%', marginBottom: '1rem' }} />
              <div style={{ background: 'var(--bg-secondary)', borderRadius: '0.5rem', height: '1rem', width: '40%', marginBottom: '0.5rem' }} />
              <div style={{ background: 'var(--bg-secondary)', borderRadius: '0.5rem', height: '1rem', width: '80%' }} />
            </div>
          ))}
        </div>
      ) : plants.length === 0 ? (
        <div className="glass-panel" style={{ padding: '4rem 2rem', textAlign: 'center' }}>
          <Factory size={48} style={{ margin: '0 auto 1rem', color: 'var(--text-muted)', opacity: 0.4 }} />
          <h3 style={{ fontWeight: 600, margin: '0 0 0.5rem' }}>No Gas Plants Yet</h3>
          <p style={{ color: 'var(--text-muted)', fontSize: '0.875rem', margin: '0 0 1.5rem' }}>
            Add your first LPG filling plant to get started.
          </p>
          <button className="btn btn-primary" onClick={() => setAddDialogOpen(true)}>
            <Plus size={16} />
            Add First Plant
          </button>
        </div>
      ) : (
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(340px, 1fr))', gap: '1rem' }}>
          {plants.map((plant) => (
            <PlantCard
              key={plant.plant_id}
              plant={plant}
              onEdit={handleEditPlant}
              onOfficer={handleOfficer}
              onToggleActive={handleToggleActive}
              isToggling={updatePlant.isPending}
            />
          ))}
        </div>
      )}
      </div>

      {/* ── Dialogs ── */}
      <AddGasPlantModal
        open={addDialogOpen}
        onClose={handleAddDialogClose}
        editingPlant={editingPlant}
      />
      <AreaOfficerModal
        open={officerDialogOpen}
        onClose={() => { setOfficerDialogOpen(false); setOfficerPlant(null); }}
        plant={officerPlant}
      />
    </div>
  );
};

// ── Plant Card ─────────────────────────────────────────────────────────────────
interface PlantCardProps {
  plant:           GasPlant;
  onEdit:          (p: GasPlant) => void;
  onOfficer:       (p: GasPlant) => void;
  onToggleActive:  (p: GasPlant) => void;
  isToggling:      boolean;
}

const PlantCard = ({ plant, onEdit, onOfficer, onToggleActive, isToggling }: PlantCardProps) => {
  return (
    <div
      className="glass-panel"
      style={{
        padding: '1.5rem',
        display: 'flex',
        flexDirection: 'column',
        gap: '1rem',
        opacity: plant.is_active ? 1 : 0.65,
        transition: 'opacity 0.2s',
        border: '1px solid var(--border)',
      }}
    >
      {/* Card Header */}
      <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: '0.75rem' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: '0.75rem', flex: 1, minWidth: 0 }}>
          <div
            style={{
              width: '42px',
              height: '42px',
              borderRadius: '10px',
              background: 'rgba(59,130,246,0.12)',
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              flexShrink: 0,
              color: 'var(--primary)',
            }}
          >
            <Factory size={20} />
          </div>
          <div style={{ minWidth: 0 }}>
            <h3
              style={{
                margin: 0,
                fontSize: '1rem',
                fontWeight: 700,
                whiteSpace: 'nowrap',
                overflow: 'hidden',
                textOverflow: 'ellipsis',
              }}
            >
              {plant.plant_name}
            </h3>
            <span
              style={{
                display: 'inline-block',
                marginTop: '0.25rem',
                padding: '0.2rem 0.6rem',
                fontSize: '0.7rem',
                fontWeight: 600,
                borderRadius: '999px',
                background: plant.is_active ? 'rgba(16,185,129,0.12)' : 'rgba(107,114,128,0.12)',
                color: plant.is_active ? 'var(--accent)' : 'var(--text-muted)',
                textTransform: 'uppercase',
                letterSpacing: '0.05em',
              }}
            >
              {plant.is_active ? 'Active' : 'Inactive'}
            </span>
          </div>
        </div>
        <button
          className="btn btn-ghost"
          style={{ padding: '0.4rem 0.6rem', fontSize: '0.8rem' }}
          onClick={() => onEdit(plant)}
          title="Edit plant"
        >
          <Edit2 size={14} />
        </button>
      </div>

      {/* Company / Brand */}
      {plant.brand_name && (
        <div style={{ display: 'flex', alignItems: 'center', gap: '0.5rem' }}>
          <Building2 size={14} style={{ color: 'var(--primary)', flexShrink: 0 }} />
          <span
            style={{
              fontSize: '0.85rem',
              fontWeight: 600,
              padding: '0.2rem 0.65rem',
              borderRadius: '0.375rem',
              background: 'rgba(59,130,246,0.1)',
              color: 'var(--primary)',
            }}
          >
            {plant.brand_name}
          </span>
        </div>
      )}

      {/* Location */}
      {plant.location && (
        <div style={{ display: 'flex', alignItems: 'flex-start', gap: '0.5rem', color: 'var(--text-muted)' }}>
          <MapPin size={14} style={{ flexShrink: 0, marginTop: '0.15rem' }} />
          <span style={{ fontSize: '0.85rem', lineHeight: 1.5 }}>{plant.location}</span>
        </div>
      )}

      {/* Divider */}
      <div style={{ borderTop: '1px solid var(--border)' }} />

      {/* Area Officer Section */}
      <div>
        <div
          style={{
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            marginBottom: plant.officer_id ? '0.75rem' : '0',
          }}
        >
          <span
            style={{
              fontSize: '0.75rem',
              fontWeight: 600,
              color: 'var(--text-muted)',
              textTransform: 'uppercase',
              letterSpacing: '0.06em',
            }}
          >
            Area Officer
          </span>
          <button
            className="btn btn-ghost"
            style={{
              padding: '0.3rem 0.7rem',
              fontSize: '0.78rem',
              display: 'flex',
              alignItems: 'center',
              gap: '0.35rem',
            }}
            onClick={() => onOfficer(plant)}
          >
            <UserCheck size={13} />
            {plant.officer_id ? 'Edit' : 'Assign'}
          </button>
        </div>

        {plant.officer_id ? (
          <div style={{ display: 'flex', flexDirection: 'column', gap: '0.45rem' }}>
            <div style={{ fontWeight: 600, fontSize: '0.9rem' }}>{plant.officer_name}</div>
            {plant.whatsapp_phone && (
              <a
                href={`https://wa.me/${plant.whatsapp_phone.replace(/[^0-9]/g, '')}`}
                target="_blank"
                rel="noreferrer"
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  gap: '0.45rem',
                  fontSize: '0.82rem',
                  color: '#25D366',
                  textDecoration: 'none',
                }}
              >
                <Phone size={13} />
                {plant.whatsapp_phone}
              </a>
            )}
            {plant.email && (
              <a
                href={`mailto:${plant.email}`}
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  gap: '0.45rem',
                  fontSize: '0.82rem',
                  color: 'var(--primary)',
                  textDecoration: 'none',
                }}
              >
                <Mail size={13} />
                {plant.email}
              </a>
            )}
          </div>
        ) : (
          <p style={{ fontSize: '0.82rem', color: 'var(--text-muted)', fontStyle: 'italic', margin: 0 }}>
            No area officer assigned yet
          </p>
        )}
      </div>

      {/* Footer Actions */}
      <div style={{ borderTop: '1px solid var(--border)', paddingTop: '0.75rem' }}>
        <button
          className="btn btn-ghost"
          style={{
            width: '100%',
            fontSize: '0.82rem',
            color: plant.is_active ? 'var(--danger)' : 'var(--accent)',
            borderColor: plant.is_active ? 'rgba(239,68,68,0.3)' : 'rgba(16,185,129,0.3)',
          }}
          onClick={() => onToggleActive(plant)}
          disabled={isToggling}
        >
          {plant.is_active ? 'Deactivate Plant' : 'Activate Plant'}
        </button>
      </div>
    </div>
  );
};
