import { useMemo, useState } from 'react';
import { PurchaseSelect } from '../purchases/PurchaseControls';

// Intl enumerates the browser's IANA registry; SQL validates against PostgreSQL's
// registry as well. The saved alias is retained even if Intl canonicalizes it.
export function TimezoneSelect({ value, onChange }: { value: string; onChange: (value: string) => void }) {
 const [search, setSearch] = useState('');
 const zones = useMemo(() => [...new Set(['UTC', value, ...Intl.supportedValuesOf('timeZone')])].sort(), [value]);
 const matches = zones.filter(zone => zone.toLowerCase().replaceAll('_', ' ').includes(search.toLowerCase().replaceAll('_', ' ').trim()));
 return <div className="timezone-picker"><label className="input-group"><span className="input-label">Find timezone</span><input type="search" className="input-field" placeholder="Search city or region" value={search} onChange={event => setSearch(event.target.value)} /></label><PurchaseSelect label="Business timezone" value={value} options={[...new Set([value, ...matches])].map(zone => ({ value: zone, label: zone.replaceAll('_', ' ') }))} onChange={onChange} /><small className="employee-hint">{matches.length} matching timezones</small></div>;
}
