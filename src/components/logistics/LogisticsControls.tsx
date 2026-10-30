import { useCrewOptions } from '../../hooks/useLogistics';
import type { useLogisticsOperation } from '../../hooks/useLogistics';
import { PurchaseSelect } from '../purchases/PurchaseControls';
export type LogisticsOperationHandle = ReturnType<typeof useLogisticsOperation>;
export function LogisticsOperationNotice({ operation, onRecovered }: { operation: LogisticsOperationHandle; onRecovered?: () => void }) {
 return <>{operation.error && <p role="alert" className="purchase-error">{operation.error.message}</p>}{operation.hasPending && <div className="purchase-alert">A save has an uncertain result. Recover it before making another change. <button type="button" className="btn btn-secondary" disabled={operation.isPending} onClick={() => { void operation.mutateAsync(undefined).then(onRecovered).catch(() => {}); }}>Recover save</button></div>}</>;
}
export function CrewPicker({ role, value, onChange }: { role:'Driver'|'Helper';value:string|null;name?:string|null;onChange:(value:string|null)=>void }) {
 const query=useCrewOptions(role);
 return <><PurchaseSelect label={role} value={value??''} onChange={id=>onChange(id||null)} options={[{value:'',label:role==='Driver'?'No driver':'No helper'},...(query.data??[]).map(e=>({value:e.employee_id,label:e.name}))]} />{query.isError && <p className="purchase-error" role="alert">{role} list unavailable. <button type="button" className="btn btn-ghost" onClick={()=>void query.refetch()}>Retry</button></p>}</>;
}
