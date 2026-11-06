import {Fragment,useState} from 'react';
import {useProductPerformance} from '../../hooks/useProductPerformance';
import {formatBDT} from '../../lib/formatBDT';
import {Pagination} from '../ui/Pagination';

export function PerformanceTable({business,from,to}:{business:'lpg'|'stove';from:string;to:string}) {
 const [page,setPage]=useState(0);
 const report=useProductPerformance(from,to,page,business);
 const money=(value:number|null)=>value===null?'Unavailable':formatBDT(value);
 return <>{report.isPending&&<p role="status">Loading product performance…</p>}
 {report.error&&<p role="alert">{report.error.message} <button className="btn btn-secondary" onClick={()=>void report.refetch()}>Retry</button></p>}
 {report.data&&<>
 {(report.data.totals.missing_units>0||report.data.totals.estimated_units>0)&&<p className="purchase-alert" role="status">{report.data.totals.missing_units>0&&`${report.data.totals.missing_units} sold/returned units lack complete FIFO evidence. Their cost and margin are unavailable. `}{report.data.totals.estimated_units>0&&`${report.data.totals.estimated_units} sold/returned units include estimated acquisition costs; related margins are estimates.`}</p>}
 <div className="report-table-scroll"><table className="report-table performance-table"><thead><tr><th>Product</th>{business==='lpg'&&<th>Operation</th>}<th>Net bought</th><th>Net sold</th><th>Net sales</th><th>FIFO COGS</th><th>Total margin</th><th>Avg. margin / unit</th></tr></thead><tbody>
 {report.data.rows.map((row,index,rows)=><Fragment key={`${row.item_id}:${row.type}`}>{(index===0||rows[index-1].category!==row.category)&&<tr className="report-group"><th scope="rowgroup" colSpan={business==='lpg'?8:7}>{row.category}</th></tr>}
 <tr><th scope="row">{row.product_name}{(row.missing_units>0||row.estimated_units>0)&&<small className="report-cost-warning">{row.missing_units>0?'Incomplete costs':'Estimated costs'}</small>}</th>{business==='lpg'&&<td className="report-text">{row.type==='refill'?'Refill':'Package'}</td>}<td>{row.bought}</td><td>{row.sold}</td><td>{money(row.revenue)}</td><td>{money(row.cogs)}</td><td>{money(row.margin)}</td><td>{money(row.average_margin)}</td></tr></Fragment>)}
 {!report.data.rows.length&&<tr><td colSpan={business==='lpg'?8:7} className="report-empty">No products.</td></tr>}
 </tbody><tfoot><tr><th colSpan={business==='lpg'?2:1}>All {business==='lpg'?'LPG':'Stove'} products</th><td>{report.data.totals.bought}</td><td>{report.data.totals.sold}</td><td>{money(report.data.totals.revenue)}</td><td>{money(report.data.totals.cogs)}</td><td>{money(report.data.totals.margin)}</td><td>{money(report.data.totals.average_margin)}</td></tr></tfoot></table></div>
 <p className="finance-note">Net sales include allocated checkout discounts. Returns reverse the original sale and FIFO cost on the cancellation date. Average margin uses net units sold. Separate exchange charges and bottle exchange differences are excluded from product margin.</p>
 <Pagination page={page} pageSize={25} total={report.data.total} onChange={setPage} busy={report.isFetching} label="product rows" alwaysVisible/>
 </>}
 </>;
}
