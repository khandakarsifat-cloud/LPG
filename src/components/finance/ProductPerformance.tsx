import {useDeferredValue,useState} from 'react';

import {useFifoProducts} from '../../hooks/useProductPerformance';

import type {FifoProduct} from '../../types/productPerformance';

import {DatePicker} from '../ui/DatePicker';

import {Pagination} from '../ui/Pagination';

import {StockCostTable} from './StockCostTable';

import {PerformanceTable} from './PerformanceTable';

import './product-performance.css';



export function ProductPerformance(){

 const [from,setFrom]=useState('');const [to,setTo]=useState('');

 const [search,setSearch]=useState('');const [productPage,setProductPage]=useState(0);

 const [business,setBusiness]=useState<'lpg'|'stove'>('lpg'); const [state,setState]=useState<'all'|'filled'|'empty'>('all');

 const products=useFifoProducts(useDeferredValue(search),productPage,business);const [product,setProduct]=useState<FifoProduct|null>(null);



 return <div className="product-performance"><section className="settings-card"><header className="finance-section-heading"><div><h2>LPG purchases & sales</h2><p className="finance-note">Received purchases and historical product margins. Refill purchases = Gas − Bottle; Package purchases = Bottle.</p></div></header>

 <div className="performance-filters"><label className="input-group"><span className="input-label">From</span><DatePicker label="From" value={from} onChange={v=>{setFrom(v);}}/></label><label className="input-group"><span className="input-label">To</span><DatePicker label="To" value={to} onChange={v=>{setTo(v);}} min={from||undefined}/></label><button className="btn btn-secondary" onClick={()=>{setFrom('');setTo('');}}>All time</button></div>

 {from&&to&&from>to&&<p role="alert">From must be on or before To.</p>}
 <PerformanceTable key={`lpg:${from}:${to}`} business="lpg" from={from} to={to}/>

 </section><section className="settings-card"><header className="finance-section-heading"><div><h2>Stove purchases & sales</h2><p className="finance-note">Products grouped by category. Uses the same date range as LPG above.</p></div><span className="report-badge">Stove business</span></header><PerformanceTable key={`stove:${from}:${to}`} business="stove" from={from} to={to}/></section><section className="settings-card fifo-workspace"><header className="finance-section-heading"><div><h2>Stock costs · FIFO</h2><p className="finance-note">Current available stock and projected margins. Matching consecutive customer empty returns share a row; purchase entries remain separate.</p></div><span className="report-badge">Current stock</span></header>

 <div className="performance-filters"><label className="input-group"><span className="input-label">Business</span><select className="input-field" value={business} onChange={e=>{setBusiness(e.target.value==='stove'?'stove':'lpg');setProduct(null);setProductPage(0);setSearch('');}}><option value="lpg">LPG</option><option value="stove">Stove</option></select></label><label className="input-group"><span className="input-label">Find product</span><input className="input-field" type="search" value={search} onChange={e=>{setSearch(e.target.value);setProductPage(0);}} placeholder={business==='lpg'?'Company, weight or mouth size':'Product or category'}/></label></div>

 {products.isPending&&<p role="status">Loading products…</p>}{products.error&&<p role="alert">{products.error.message}</p>}<div className="performance-products">{products.data?.entries.map(p=><button aria-pressed={product?.item_id===p.item_id} className={`product-choice ${product?.item_id===p.item_id?'is-selected':''}`} key={p.item_id} onClick={()=>setProduct(p)}>{p.label}</button>)}</div>{products.data&&<Pagination page={productPage} pageSize={25} total={products.data.total} onChange={setProductPage} busy={products.isFetching} label="products"/>}

 {product?<div className="fifo-selection"><header className="fifo-selection-heading"><h3>{product.label}</h3>{business==='lpg'&&<div className="report-segmented" role="group" aria-label="Cylinder stock state">{(['all','filled','empty'] as const).map(s=><button key={s} aria-pressed={state===s} onClick={()=>setState(s)}>{s==='all'?'All stock':s==='filled'?'Filled stock':'Empty bottles'}</button>)}</div>}</header>

 <div className="fifo-cost-panels"><StockCostTable key={`${product.item_id}:${state}`} itemId={product.item_id} business={business} state={business==='stove'?'filled':state}/></div>

 <p className="finance-note">{business==='lpg'&&state==='filled'?'Gas and Bottle describe the same cylinders; do not add their quantities. ':''}Costs include attributable labour and transport. Stock in transit and outstanding bottle claims are excluded. Original FIFO order and acquisition evidence remain intact.</p></div>:<div className="report-empty">Choose a product to inspect its available stock costs.</div>}

 </section></div>;

}
