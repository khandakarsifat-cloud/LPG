import { useState } from 'react';
import { Route, Truck } from 'lucide-react';
import { useLogisticsOperation, useLogisticsSummary, useWallets } from '../hooks/useLogistics';
import { VehicleFleet } from '../components/logistics/VehicleFleet';
import { LogisticsOperationNotice } from '../components/logistics/LogisticsControls';
import { TransitsView } from '../components/logistics/TransitsView';
import { formatBDT } from '../lib/formatBDT';
import '../components/logistics/logistics.css';

export const LogisticsPage = () => {
 const [tab, setTab] = useState<'vehicles' | 'transits'>('vehicles'); const summary = useLogisticsSummary(); const wallets = useWallets(); const operation = useLogisticsOperation();
 const wallet = wallets.data?.find(w => w.kind === 'logistics');
 return <div className="logistics-page"><p className="page-subtitle">Vehicles, journeys and employee transit earnings.</p><div className="logistics-overview" aria-label="Logistics overview">
  <div><span>Vehicles at Home</span><strong>{summary.data ? `${summary.data.home} / ${summary.data.vehicles}` : '—'}</strong></div><div><span>In transit</span><strong>{summary.data?.active ?? '—'}</strong></div><div><span>Outstanding crew earnings</span><strong>{summary.data ? formatBDT(summary.data.outstanding) : '—'}</strong></div><div><span>Logistics wallet</span><strong>{wallet ? formatBDT(Number(wallet.balance)) : '—'}</strong></div>
 </div>{summary.isError && <p role="alert" className="purchase-error">Summary unavailable. <button className="btn btn-ghost" onClick={() => void summary.refetch()}>Retry</button></p>}<LogisticsOperationNotice operation={operation} />
 <nav className="logistics-tabs" aria-label="Logistics sections"><button aria-current={tab === 'vehicles' ? 'page' : undefined} onClick={() => setTab('vehicles')}><Truck size={16} />Vehicles</button><button aria-current={tab === 'transits' ? 'page' : undefined} onClick={() => setTab('transits')}><Route size={16} />Transits</button></nav>
 {tab === 'vehicles' ? <VehicleFleet operation={operation} /> : <TransitsView operation={operation} />}</div>;
};
