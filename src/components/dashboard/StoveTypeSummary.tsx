import { Package, Shapes } from 'lucide-react';
import type { StoveSystemKey } from '../../types/accounting';
import type { DashboardSnapshot } from '../../types/dashboard';
import { formatBDQty } from '../../lib/formatBDT';

const defaultTones: Record<StoveSystemKey, string> = { single_stove: 'blue', double_stove: 'green', regulator: 'orange', pipe: 'purple', others: 'red' };
function typeTone(type: DashboardSnapshot['stove_types'][number]) {
  if (type.system_key) return defaultTones[type.system_key];
  // UUID-based assignment gives custom types a random-looking color that stays stable on refresh.
  const hash = [...type.type_id].reduce((value, character) => (value * 31 + character.charCodeAt(0)) >>> 0, 0);
  return ['blue', 'green', 'orange', 'purple', 'red'][hash % 5];
}
function StoveTypeIcon({ kind }: { kind: StoveSystemKey | null }) {
  if (kind === null) return <Package size={29} strokeWidth={1.7} aria-hidden="true" />;
  if (kind === 'others') return <Shapes size={29} strokeWidth={1.7} aria-hidden="true" />;
  return <svg width="32" height="32" viewBox="0 0 32 32" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    {kind === 'single_stove' || kind === 'double_stove' ? <>
      <rect x="2.5" y="9" width="27" height="15" rx="3" /><path d="M6 24v3m20-3v3M4 20h24" />
      {kind === 'single_stove' ? <><ellipse cx="16" cy="14" rx="6" ry="3.5" /><path d="M10 10l2 2m10-2-2 2M16 9v3" /><circle cx="16" cy="22" r=".7" /></> : <><ellipse cx="10" cy="14" rx="4.5" ry="3" /><ellipse cx="22" cy="14" rx="4.5" ry="3" /><path d="M10 9v3m12-3v3" /><circle cx="10" cy="22" r=".7" /><circle cx="22" cy="22" r=".7" /></>}
    </> : kind === 'regulator' ? <><path d="M5 16H2v6h5m18-6h5v5h-6M13 6h7v6h-7zM11 6h11" /><ellipse cx="16" cy="19" rx="10" ry="7" /><path d="M9 19c1 5 13 5 14 0M13 16h6" /></> : <><path d="M5 26V12a8 8 0 0 1 16 0v8a3 3 0 0 0 6 0V8M9 26V12a4 4 0 0 1 8 0v8a7 7 0 0 0 14 0V8M3 26h8M25 8h7" /></>}
  </svg>;
}

export function StoveTypeSummary({ types, unavailable }: { types: DashboardSnapshot['stove_types']; unavailable: boolean }) {
  return <div className="dashboard-bottles dashboard-stove-types">{types.map(type => <div className={`dashboard-bottle tone-${typeTone(type)}`} key={type.type_id} data-stove-type={type.system_key ?? 'custom'}>
    <span className="dashboard-bottle-icon"><StoveTypeIcon kind={type.system_key} /></span><div className="dashboard-type-copy"><strong>{type.name}</strong><span>{formatBDQty(type.quantity)} units</span></div>
  </div>)}{!types.length && <p className="dashboard-empty">{unavailable ? 'Stove quantities unavailable.' : 'No active stove product types configured.'}</p>}</div>;
}
