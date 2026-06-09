import { Truck as TruckIcon, AlertCircle, Power, CheckCircle2 } from 'lucide-react';
import { useTrucks, useActivateTruck, useDeactivateTruck } from '../../hooks/useLogistics';
import type { Truck } from '../../types/logistics';
import { TRUCK_SIZE_LABELS } from '../../types/logistics';

export const TrucksGrid = () => {
  const { data: trucks = [], isLoading } = useTrucks(false); // false to get all trucks including inactive
  const deactivateTruck = useDeactivateTruck();
  const activateTruck = useActivateTruck();

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
      </div>
    );
  }

  const activeTrucks = trucks.filter((t) => t.is_active);
  const inactiveTrucks = trucks.filter((t) => !t.is_active);

  const renderTruckRow = (truck: Truck) => (
    <tr key={truck.truck_id} style={{ opacity: truck.is_active ? 1 : 0.6 }}>
      <td className="td-strong">{truck.name}</td>
      <td>{truck.serial_no}</td>
      <td>{truck.capacity}</td>
      <td>
        <span className="type-badge">
          {TRUCK_SIZE_LABELS[truck.size]}
        </span>
      </td>
      <td>
        {truck.is_active ? (
          <span style={{ color: 'var(--accent)', fontWeight: 500, display: 'flex', alignItems: 'center', gap: '0.5rem' }}>
            <CheckCircle2 size={14} /> Active
          </span>
        ) : (
          <span style={{ color: 'var(--text-muted)', fontWeight: 500, display: 'flex', alignItems: 'center', gap: '0.5rem' }}>
            <AlertCircle size={14} /> Inactive
          </span>
        )}
      </td>
      <td>
        <div style={{ display: 'flex', gap: '0.5rem' }}>
          {truck.is_active ? (
            <button
              className="btn btn-sm"
              style={{ background: 'rgba(239, 68, 68, 0.1)', color: 'var(--danger)', border: 'none' }}
              onClick={() => deactivateTruck.mutate(truck.truck_id)}
              disabled={deactivateTruck.isPending}
            >
              <Power size={14} /> Deactivate
            </button>
          ) : (
            <button
              className="btn btn-sm"
              style={{ background: 'rgba(16, 185, 129, 0.1)', color: 'var(--accent)', border: 'none' }}
              onClick={() => activateTruck.mutate(truck.truck_id)}
              disabled={activateTruck.isPending}
            >
              <CheckCircle2 size={14} /> Activate
            </button>
          )}
        </div>
      </td>
    </tr>
  );

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '1.5rem' }}>
      {/* Active Trucks */}
      {activeTrucks.length > 0 && (
        <div className="glass-panel">
          <div style={{ marginBottom: '1rem', paddingBottom: '1rem', borderBottom: '1px solid var(--border)' }}>
            <h3 style={{ fontWeight: 600 }}>Active Fleet ({activeTrucks.length})</h3>
          </div>
          <table className="data-table">
            <thead>
              <tr>
                <th>Name</th>
                <th>Serial Number</th>
                <th>Capacity (Units)</th>
                <th>Size</th>
                <th>Status</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              {activeTrucks.map(renderTruckRow)}
            </tbody>
          </table>
        </div>
      )}

      {/* Inactive Trucks */}
      {inactiveTrucks.length > 0 && (
        <div className="glass-panel">
          <div style={{ marginBottom: '1rem', paddingBottom: '1rem', borderBottom: '1px solid var(--border)' }}>
            <h3 style={{ fontWeight: 600 }}>Inactive Trucks ({inactiveTrucks.length})</h3>
          </div>
          <table className="data-table">
            <thead>
              <tr>
                <th>Name</th>
                <th>Serial Number</th>
                <th>Capacity (Units)</th>
                <th>Size</th>
                <th>Status</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              {inactiveTrucks.map(renderTruckRow)}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
};
