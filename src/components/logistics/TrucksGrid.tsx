import { useState } from 'react';
import { Truck as TruckIcon, AlertCircle, MapPin, Pencil, Check, X } from 'lucide-react';
import { useTrucks, useSetTruckLocation } from '../../hooks/useLogistics';
import type { Truck } from '../../types/logistics';
import {
  TRUCK_SIZE_LABELS,
  TRUCK_STATUS_LABELS,
  TRUCK_STATUS_COLORS,
  TRUCK_STATUS_BG,
} from '../../types/logistics';

// ── Inline Location Editor ─────────────────────────────────────────────────────
const LocationCell = ({ truck }: { truck: Truck }) => {
  const setLocation = useSetTruckLocation();
  const [editing, setEditing] = useState(false);
  const [val, setVal] = useState(truck.location ?? '');

  const save = async () => {
    await setLocation.mutateAsync({
      truckId: truck.truck_id,
      location: val.trim() || null,
    });
    setEditing(false);
  };

  const cancel = () => {
    setVal(truck.location ?? '');
    setEditing(false);
  };

  if (editing) {
    return (
      <div style={{ display: 'flex', alignItems: 'center', gap: '0.375rem' }}>
        <input
          autoFocus
          type="text"
          value={val}
          onChange={(e) => setVal(e.target.value)}
          onKeyDown={(e) => { if (e.key === 'Enter') save(); if (e.key === 'Escape') cancel(); }}
          placeholder="e.g. Warehouse A"
          style={{
            background: 'var(--bg-secondary)',
            border: '1px solid var(--border)',
            borderRadius: '0.375rem',
            color: 'var(--text-main)',
            padding: '0.25rem 0.5rem',
            fontSize: '0.8rem',
            width: '130px',
          }}
        />
        <button
          onClick={save}
          disabled={setLocation.isPending}
          style={{ background: 'none', border: 'none', cursor: 'pointer', color: 'var(--accent)', padding: '0.25rem' }}
          title="Save"
        >
          <Check size={14} />
        </button>
        <button
          onClick={cancel}
          style={{ background: 'none', border: 'none', cursor: 'pointer', color: 'var(--text-muted)', padding: '0.25rem' }}
          title="Cancel"
        >
          <X size={14} />
        </button>
      </div>
    );
  }

  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: '0.5rem' }}>
      {truck.location ? (
        <span style={{ display: 'flex', alignItems: 'center', gap: '0.375rem', fontSize: '0.875rem' }}>
          <MapPin size={13} style={{ color: 'var(--text-muted)' }} />
          {truck.location}
        </span>
      ) : (
        <span style={{ color: 'var(--text-muted)', fontSize: '0.8rem' }}>—</span>
      )}
      <button
        onClick={() => { setVal(truck.location ?? ''); setEditing(true); }}
        style={{ background: 'none', border: 'none', cursor: 'pointer', color: 'var(--text-muted)', padding: '0.2rem', opacity: 0.6 }}
        title="Edit location"
      >
        <Pencil size={12} />
      </button>
    </div>
  );
};

// ── Status Selector ───────────────────────────────────────────────────────────
const StatusCell = ({ truck }: { truck: Truck }) => {
  return (
    <span
      style={{
        background: TRUCK_STATUS_BG[truck.status],
        color: TRUCK_STATUS_COLORS[truck.status],
        border: `1px solid ${TRUCK_STATUS_COLORS[truck.status]}40`,
        borderRadius: '0.375rem',
        padding: '0.25rem 0.5rem',
        fontSize: '0.8rem',
        fontWeight: 600,
        display: 'inline-block'
      }}
    >
      {TRUCK_STATUS_LABELS[truck.status]}
    </span>
  );
};

// ── Main Grid ─────────────────────────────────────────────────────────────────
export const TrucksGrid = () => {
  const { data: trucks = [], isLoading } = useTrucks();

  if (isLoading) {
    return (
      <div style={{ padding: '2rem', textAlign: 'center' }}>
        <div style={{ color: 'var(--text-muted)' }}>Loading trucks...</div>
      </div>
    );
  }

  if (trucks.length === 0) {
    return (
      <div className="empty-state" style={{ padding: '3rem' }}>
        <TruckIcon size={36} style={{ color: 'var(--text-muted)', opacity: 0.4 }} />
        <p style={{ color: 'var(--text-muted)' }}>No trucks registered yet.</p>
        <p style={{ fontSize: '0.8rem', color: 'var(--text-muted)', opacity: 0.6 }}>
          Click "Add Truck" to register your first vehicle.
        </p>
      </div>
    );
  }

  // Status summary counts
  const idleCount   = trucks.filter((t) => t.status === 'idle').length;
  const comingCount = trucks.filter((t) => t.status === 'coming').length;
  const goingCount  = trucks.filter((t) => t.status === 'going').length;

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '1.5rem' }}>
      {/* Fleet summary chips */}
      <div style={{ display: 'flex', gap: '0.75rem', flexWrap: 'wrap' }}>
        {[
          { label: 'Idle',       count: idleCount,   color: TRUCK_STATUS_COLORS.idle,   bg: TRUCK_STATUS_BG.idle },
          { label: 'Coming In',  count: comingCount, color: TRUCK_STATUS_COLORS.coming, bg: TRUCK_STATUS_BG.coming },
          { label: 'Going Out',  count: goingCount,  color: TRUCK_STATUS_COLORS.going,  bg: TRUCK_STATUS_BG.going },
        ].map(({ label, count, color, bg }) => (
          <div
            key={label}
            style={{
              background: bg,
              color,
              border: `1px solid ${color}40`,
              borderRadius: '2rem',
              padding: '0.3rem 0.9rem',
              fontSize: '0.8rem',
              fontWeight: 600,
              display: 'flex',
              alignItems: 'center',
              gap: '0.4rem',
            }}
          >
            <span style={{ fontWeight: 700 }}>{count}</span> {label}
          </div>
        ))}
      </div>

      {/* Trucks table */}
      <div className="glass-panel">
        <div style={{ marginBottom: '1rem', paddingBottom: '1rem', borderBottom: '1px solid var(--border)' }}>
          <h3 style={{ fontWeight: 600 }}>Fleet ({trucks.length})</h3>
        </div>
        <table className="data-table">
          <thead>
            <tr>
              <th>Name</th>
              <th>Serial Number</th>
              <th>Capacity (Units)</th>
              <th>Size</th>
              <th>Status</th>
              <th>Location</th>
            </tr>
          </thead>
          <tbody>
            {trucks.map((truck) => (
              <tr key={truck.truck_id}>
                <td className="td-strong">{truck.name}</td>
                <td style={{ fontFamily: 'monospace', fontSize: '0.85rem', letterSpacing: '0.04em' }}>
                  {truck.serial_no}
                </td>
                <td>{truck.capacity}</td>
                <td>
                  <span className="type-badge">{TRUCK_SIZE_LABELS[truck.size]}</span>
                </td>
                <td>
                  <StatusCell truck={truck} />
                </td>
                <td>
                  <LocationCell truck={truck} />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {trucks.length === 0 && (
        <div className="empty-state" style={{ padding: '2rem' }}>
          <AlertCircle size={28} style={{ color: 'var(--text-muted)', opacity: 0.4 }} />
          <p style={{ color: 'var(--text-muted)' }}>No trucks found.</p>
        </div>
      )}
    </div>
  );
};
