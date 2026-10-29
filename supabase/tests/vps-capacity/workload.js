import http from 'k6/http';
import { sleep, fail } from 'k6';
import exec from 'k6/execution';
import crypto from 'k6/crypto';
import { SharedArray } from 'k6/data';
import { Counter, Rate, Trend, Gauge } from 'k6/metrics';

const config = JSON.parse(open(__ENV.CONFIG));
const accounts = new SharedArray('businesses', () => JSON.parse(open(__ENV.ACCOUNTS)));
const warmup = Number(__ENV.WARMUP || 60);
const duration = Number(__ENV.DURATION || 300);
const errors = new Rate('operation_errors');
const correctness = new Counter('correctness_failures');
const replays = new Counter('idempotent_replays');
const latency = new Trend('operation_latency', true);
const reads = new Trend('read_latency', true);
const writes = new Trend('write_latency', true);
const actions = new Trend('action_latency', true);
const successes = new Counter('successful_requests');
const unexpected = new Counter('unexpected_errors');
const timeouts = new Counter('request_timeouts');
const measurementStart = new Gauge('measurement_start_seconds');
let lastRefresh = 0;
let lastIdentity = 0;
let prepared = false;
let sequence = 0;

export const options = {
  scenarios: { active: { executor: 'constant-vus', vus: Number(__ENV.USERS),
    duration: `${warmup + duration}s`, gracefulStop: '20s' } },
  setupTimeout: '30s',
  thresholds: {
    'operation_latency{phase:measured}': ['p(99)<3000', { threshold: 'p(95)<8000', abortOnFail: true, delayAbortEval: '120s' }],
    'operation_errors{phase:measured}': ['rate<0.005', { threshold: 'rate<0.05', abortOnFail: true, delayAbortEval: '90s' }],
    'read_latency{phase:measured}': ['p(95)<1000'],
    'write_latency{phase:measured}': ['p(95)<1500'],
    correctness_failures: [{ threshold: 'count==0', abortOnFail: true, delayAbortEval: '15s' }],
  },
  systemTags: ['status','method','name','scenario','error_code','expected_response'],
  summaryTrendStats: ['avg','med','p(90)','p(95)','p(99)','max'],
  insecureSkipTLSVerify: false,
  userAgent: 'LPG-Capacity-k6/1.0',
};

function id() {
  const bytes = new Uint8Array(crypto.randomBytes(16));
  bytes[6] = (bytes[6] & 15) | 64; bytes[8] = (bytes[8] & 63) | 128;
  const s = Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
  return `${s.slice(0,8)}-${s.slice(8,12)}-${s.slice(12,16)}-${s.slice(16,20)}-${s.slice(20)}`;
}
function phase() { return exec.instance.currentTestRunDuration / 1000 >= warmup ? 'measured' : 'warmup'; }
function broken(label) {
  correctness.add(1, { phase: phase(), invariant: label });
  fail('Fixture invariant failed: ' + label);
}
function assert(ok, label) { if (!ok) broken(label); }
function headers(a) {
  return { apikey: config.anon, Authorization: 'Bearer '+a.token,
    'Content-Type': 'application/json', Origin: config.worker };
}
function params(a, name, kind='read') {
  return { headers: headers(a), timeout: '15s', tags: {name, kind, phase: phase()} };
}
function processResponse(r, name, kind='read', expectedDenial=false) {
  const tags = { phase: phase(), endpoint: name, kind };
  const valid = expectedDenial ? r.status >= 400 && r.status < 500 : r.status >= 200 && r.status < 300;
  errors.add(!valid, tags);
  latency.add(r.timings.duration, tags);
  (kind === 'write' ? writes : reads).add(r.timings.duration, tags);
  if (!valid) {
    let code = r.status===0 ? 'transport_'+r.error_code : String(r.status);
    try { code = r.json('code') || code; } catch { /* no body on transport errors */ }
    unexpected.add(1, { ...tags, code });
    if ([1050,1211].includes(r.error_code) || r.status===504) timeouts.add(1, tags);
    return null;
  }
  successes.add(1, tags);
  if (expectedDenial) return {};
  try { return r.body ? r.json() : {}; } catch { broken('json_'+name); }
}
function rpc(a, name, body={}, kind='read', deny=false) {
  const r = http.post(config.url+'/rest/v1/rpc/'+name, JSON.stringify(body), params(a,name,kind));
  return processResponse(r,name,kind,deny);
}
function get(a, path, name) {
  const r = http.get(config.url+'/rest/v1/'+path,params(a,name));
  return processResponse(r,name);
}
function batch(a, requests) {
  const responses = http.batch(requests.map(([name,body,kind='rpc']) => kind === 'get'
    ? { method:'GET', url:config.url+'/rest/v1/'+body, params:params(a,name) }
    : { method:'POST', url:config.url+'/rest/v1/rpc/'+name, body:JSON.stringify(body), params:params(a,name) }));
  return responses.map((r,i) => processResponse(r,requests[i][0]));
}
function directory(a, filters, offset=0) {
  const data = rpc(a,'get_customer_directory',{p_filters:filters,p_offset:offset,p_limit:25});
  if (data) {
    assert(data.total===2000 || (filters.search && data.total===1) || 'item_ids' in filters, 'customer_count');
    assert(Array.isArray(data.entries) && data.entries.length <=25,'bounded_directory');
    for (const c of data.entries) {
      assert(c.tenant_id===a.tenant_id && c.name.startsWith(`Capacity ${a.index} Customer `),'customer_tenant');
      assert(c.total_due>=0 && c.total_sold_amount>=c.total_due,'customer_money');
    }
  }
  return data;
}
function tenantRows(rows, a, label) {
  if (rows) for (const row of rows) assert(row.tenant_id===a.tenant_id,label+'_tenant');
}
function refreshPOS(a, force=false) {
  if (force || Date.now()-lastRefresh>30000) {
    const [stock, prices] = batch(a,[['inventory','items?select=*,lpg_brands(brand_id,brand_name)&order=brand_id.asc,item_id.asc','get'],
      ['prices','price_books?select=*&order=effective_from.desc','get'], ['get_payment_wallets',{}]]);
    tenantRows(stock,a,'inventory'); tenantRows(prices,a,'prices');
    if (stock) assert(stock.length===6 && stock.every(x=>x.filled_quantity>=0 && x.empty_quantity>=0),'stock');
    lastRefresh = Date.now();
  }
}
function customer(a) { return a.customers[(sequence*17+__VU)%a.customers.length]; }
function sale(a, partial=false) {
  const c=customer(a), item=a.item_ids[sequence%6], i=sequence%6;
  // Typical refill with its physical empty return; occasional package cart.
  const packageSale=sequence%5===0;
  const amount=packageSale ? 2300+i*100 : 1200+i*100;
  const cart=[{item_id:item,type:packageSale?'package':'refill',quantity:1,unit_price:amount}];
  if (!packageSale) cart.push({item_id:item,type:'empty_return',quantity:1,unit_price:0});
  const request=id();
  const body={p_customer_phone:c.phone,p_customer_name:null,p_customer_shop_name:null,p_customer_address:null,
    p_customer_tier:c.tier,p_discount_amount:0,p_exchange_fee:0,p_notes:'Capacity measured '+__ENV.STAGE,
    p_customer_id:c.customer_id,p_items:cart,p_request_id:request,
    p_payments:[{wallet_id:a.cash.wallet_id,amount:partial?amount/2:amount}]};
  sleep(2+Math.random()*2); // reviewing cart and payment before confirmation
  const data=rpc(a,'create_pos_sale',body,'write');
  if (!data) return;
  assert(data.total_amount===amount && data.paid_amount===(partial?amount/2:amount)
    && data.due===(partial?amount/2:0) && data.customer_id===c.customer_id,'checkout_money');
  if (sequence%100===5) {
    const replay=rpc(a,'create_pos_sale',body,'write');
    if (replay) {
      assert(replay.sale_id===data.sale_id,'idempotent_sale');
      replays.add(1,{phase:phase()});
    }
  }
  if (partial) {
    sleep(1.5+Math.random());
    const payment=rpc(a,'collect_sale_payment',{p_sale_id:data.sale_id,
      p_payments:[{wallet_id:a.bank.wallet_id,amount:amount/2}],p_request_id:id()},'write');
    // An unsuccessful mutation has an unknown outcome. Its request error is
    // already counted; do not assert a downstream state that was never acked.
    if (!payment) return;
    assert(payment.due===0 && payment.paid_amount===amount,'collection_money');
  }
  const receipt=rpc(a,'get_sale_receipt',{p_sale_id:data.sale_id});
  if (receipt) assert(receipt.sale.sale_id===data.sale_id && receipt.settlement.due===0,'receipt_identity');
  refreshPOS(a,true);
}
function purchase(a) {
  const i=sequence%6, sku=a.item_ids[i];
  const created=rpc(a,'create_purchase',{p_payload:{plant_id:a.plant_id,truck_id:a.truck_id,
    request_id:id(),transport_cost:30,labour_cost:20,commission:0,notes:'Capacity measured supply '+__ENV.STAGE,
    items:[{item_id:sku,type:'package',quantity:10,empty_dispatched:0,unit_price:1800+i*100}]}},'write');
  if (!created) return;
  const pid=created.purchase_id;
  const dispatched=rpc(a,'dispatch_purchase',{p_purchase_id:pid,p_revision:1},'write');
  if (!dispatched) return;
  let rows=rpc(a,'get_purchases_by_ids',{p_ids:[pid]});
  if (!rows?.length) return;
  let received=rpc(a,'receive_purchase',{p_purchase_id:pid,p_revision:rows[0].revision},'write');
  if (!received) return;
  rows=rpc(a,'get_purchases_by_ids',{p_ids:[pid]});
  if (!rows?.length) return;
  const due=rows[0].total_cost-rows[0].paid_amount;
  const paid=rpc(a,'record_purchase_payment',{p_purchase_id:pid,p_payments:[{wallet_id:a.bank.wallet_id,amount:due}],p_request_id:id()},'write');
  if (!paid) return;
  assert(paid.due===0,'purchase_paid');
  const settlement=rpc(a,'get_purchase_settlement',{p_purchase_id:pid});
  if (settlement) assert(settlement.due===0,'purchase_settlement');
}

export default function () {
  const a=accounts[__VU-1];
  assert(Boolean(a),'unique_business_assignment');
  if (!prepared) {
    measurementStart.add((Date.now()-exec.instance.currentTestRunDuration)/1000+warmup);
    // Deliberately stagger session navigation, not the fixed number of active VUs.
    sleep((__VU%10)*0.2);
    prepared=true;
    sequence=__VU%20;
  }
  if (Date.now()-lastIdentity>30000) {
    const [profile]=batch(a,[['profile',`user_profiles?select=tenant_id,user_id,is_active&user_id=eq.${a.user_id}`,'get'],['get_my_permissions',{}]]);
    if (profile) assert(profile.length===1 && profile[0].tenant_id===a.tenant_id && profile[0].is_active,'trusted_identity');
    lastIdentity=Date.now();
  }
  const start=Date.now(), step=sequence%20;
  const since=new Date(); since.setUTCHours(18,0,0,0); since.setUTCDate(since.getUTCDate()-1);
  if ([0,12].includes(step)) {
    const [stats,feed]=batch(a,[['get_dashboard_stats',{p_since:since.toISOString()}],
      ['dashboard_feed','sales?select=sale_id,sale_tier,created_at,total_amount,additional_charges,paid_amount,subtotal,discount_amount,exchange_fee,notes,customers(name,phone,shop_name,tier),sale_items(quantity,unit_price,line_total,type,items(size_kg,lpg_brands(brand_name)))&status=eq.completed&created_at=gte.'+encodeURIComponent(since.toISOString())+'&order=created_at.desc,sale_id.desc&limit=9','get']]);
    if (stats) assert(stats.totalCustomers===2000 && stats.todayRevenue>=0,'dashboard');
    if (feed) assert(feed.length<=9,'dashboard_feed');
  } else if ([1,14,19].includes(step)) {
    directory(a,{sort:step===19?'name_desc':'name_asc'},step===14?975:0);
    if (step===1) rpc(a,'get_customer_overview');
  } else if ([2,7,10,18].includes(step)) {
    const filters={sort:{2:'sold_desc',7:'due_desc',10:'due_asc',18:'last_sale_desc'}[step]};
    if (step===10) Object.assign(filters,{from:'2026-05-01',to:'2026-10-31',item_ids:[a.item_ids[0]],transactions_min:'1'});
    directory(a,filters,step===10?25:0);
  } else if ([3,4].includes(step)) {
    refreshPOS(a);
    directory(a,{search:customer(a).phone,sort:'name_asc'});
  } else if ([5,13].includes(step)) {
    sale(a,step===13);
  } else if (step===6) {
    refreshPOS(a,true);
    rpc(a,'get_product_inventory',{p_item_id:a.item_ids[sequence%6]});
  } else if (step===8) {
    batch(a,[['get_wallet_ledger',{p_filters:{search:'',sort:'date_desc'},p_limit:25,p_offset:0}],
      ['get_finance_dues',{p_search:'',p_offset:0,p_limit:25}],
      ['wallets','wallets?select=*&order=type.asc','get']]);
  } else if (step===9) {
    batch(a,[['get_sales_directory',{p_filters:{sort:'date_desc'},p_offset:0,p_limit:25}],['get_sales_overview',{}]]);
  } else if (step===11) {
    const rows=get(a,'inventory_movements?select=*,items(size_kg,filled_quantity,empty_quantity,mouth_size,lpg_brands(brand_id,brand_name)),user_profiles(email)&order=created_at.desc,movement_id.desc&limit=11','inventory_history');
    tenantRows(rows,a,'movement');
  } else if (step===15) {
    batch(a,[['get_purchase_directory',{p_filters:{sort:'date_desc'},p_offset:0,p_limit:25}],['get_purchase_overview',{}]]);
  } else if (step===16) {
    purchase(a);
  } else if (step===17) {
    rpc(a,'move_wallet_money',{p_payload:{action:'transfer',wallet_id:a.cash.wallet_id,destination_id:a.bank.wallet_id,amount:50,reason:'Capacity cash banking'},p_request_id:id()},'write');
  }
  actions.add(Date.now()-start,{phase:phase(),action:String(step)});
  // Sample hostile tenant reads with the actual business session, outside error metrics.
  if (sequence%100===0 && accounts.length>1) {
    const foreign=accounts[__VU%accounts.length];
    const rows=get(a,`customers?select=customer_id,tenant_id&tenant_id=eq.${foreign.tenant_id}&limit=1`,'cross_tenant_probe');
    if (rows) assert(rows.length===0,'cross_tenant_denied');
  }
  sequence++;
  sleep(1.5+Math.random());
}

export function handleSummary(data) {
  return { [__ENV.SUMMARY]: JSON.stringify(data,null,2) };
}
