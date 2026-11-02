import { ArrowDown, ArrowUp } from 'lucide-react';
import { PurchaseSelect } from '../purchases/PurchaseControls';
import './directory-sort.css';

export interface SortOption<T extends string> { label: string; asc: T; desc: T }

/** Customers' field selector and independent direction control for directories. */
export function DirectorySort<T extends string>({ value, options, onChange }: {
  value: T; options: SortOption<T>[]; onChange: (value: T) => void;
}) {
  const selected = options.find(option => option.asc === value || option.desc === value) ?? options[0];
  const ascending = value === selected.asc;
  return <div className="directory-sort">
    <PurchaseSelect label="Sort by" value={selected.asc} options={options.map(option => ({ value: option.asc, label: option.label }))}
      onChange={next => { const option = options.find(option => option.asc === next); if (option) onChange(ascending ? option.asc : option.desc); }} />
    <button type="button" className="btn btn-secondary directory-sort-direction"
      aria-label={`Sort direction: ${ascending ? 'ascending' : 'descending'}`}
      title={`${ascending ? 'Ascending' : 'Descending'}; switch to ${ascending ? 'descending' : 'ascending'}`}
      onClick={() => onChange(ascending ? selected.desc : selected.asc)}>
      {ascending ? <ArrowUp size={16} /> : <ArrowDown size={16} />}
    </button>
  </div>;
}
