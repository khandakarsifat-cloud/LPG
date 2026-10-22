// Execute with playwright-cli run-code --filename=tests/purchase.browser.cjs
// against a local Vite server. Uses isolated API fixtures, never real Auth/data.
async page => {
  const appUrl=new URL(page.url()).origin;
  const userId='aa000000-0000-4000-8000-000000000001';
  const tenant='aa000000-0000-4000-8000-000000000002';
  const plant='aa000000-0000-4000-8000-000000000003';
  const brand='aa000000-0000-4000-8000-000000000004';
  const sku='aa000000-0000-4000-8000-000000000005';
  const truck='aa000000-0000-4000-8000-000000000006';
  const now=new Date().toISOString();
  const user={ id:userId,aud:'authenticated',role:'authenticated',email:'purchase-ui@example.invalid',app_metadata:{provider:'email'},user_metadata:{},created_at:now };
  const payload=btoa(JSON.stringify({sub:userId,exp:Math.floor(Date.now()/1000)+86400,aud:'authenticated',role:'authenticated'})).replaceAll('=','').replaceAll('+','-').replaceAll('/','_');
  const token='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.'+payload+'.Zml4dHVyZQ';
  await page.context().addInitScript(({user,token})=>{
    localStorage.setItem('lpg-theme','light');
    localStorage.setItem('sb-api-auth-token',JSON.stringify({access_token:token,refresh_token:'fixture-refresh',token_type:'bearer',expires_in:86400,expires_at:Math.floor(Date.now()/1000)+86400,user}));
    localStorage.setItem('sb-127-auth-token',localStorage.getItem('sb-api-auth-token'));
  },{user,token});
  const purchases=[];
  const creationBodies=[];
  let loseResponse=true;
  const history=new Map();
  const transits=[];
  let emptyAvailable=20;
  const calls=[];
  let purchasePageLimit=6;
  const activityRequests=[];
  let role='manage';
  let failDispatch=false;
  let failActivity=false;
  function recalculate(p) {
    p.subtotal=p.items.reduce((sum,i)=>sum+i.billed_quantity*i.unit_price,0);
    p.company_payable=p.subtotal-p.commission;
    p.total_cost=p.company_payable+p.transport_cost+p.labour_cost;
  }
  function record(p,action,details={}) {
    history.set(p.purchase_id,[...(history.get(p.purchase_id)||[]),{activity_id:crypto.randomUUID(),action,details,actor_name:'Purchase Operator',created_at:new Date().toISOString()}]);
  }
  await page.route('**/auth/v1/**',route=>route.fulfill({json:user}));

  const purchasePage = (args) => {
    const f={search:'',status:'all',payment:'all',from:'',to:'',sort:'date_desc',...args.p_filters};
    const groups=f.search.toLowerCase().split(',').map(g=>g.trim().split(/\s+/).filter(Boolean)).filter(g=>g.length);
    const rows=purchases.filter(p=>{
      const day=new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Dhaka',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date(p.created_at));
      const text=[p.purchase_id,p.company_name,p.plant_name,p.truck_name,p.notes,p.receipt_notes,p.status,p.payment_status,...p.items.flatMap(i=>[i.brand_name,`${i.size_kg}kg`,`${i.size_kg} kg`,i.mouth_size,i.type==='refill'?'refill exchange':'package new cylinders'])].join(' ').toLowerCase();
      return (f.status==='all'||p.status===f.status)&&(f.payment==='all'||p.payment_status===f.payment)&&(!f.from||day>=f.from)&&(!f.to||day<=f.to)&&(!groups.length||groups.some(g=>g.every(t=>text.includes(t))));
    }).sort((a,b)=>{
      const d=f.sort.startsWith('amount')?Number(a.total_cost)-Number(b.total_cost):Date.parse(a.created_at)-Date.parse(b.created_at);
      return (f.sort.endsWith('desc')?-d:d)||a.purchase_id.localeCompare(b.purchase_id);
    });
    return {total:rows.length,entries:rows.slice(args.p_offset||0,(args.p_offset||0)+(args.p_limit||6))};
  };
  const purchaseOverview=()=>{
    const unpaid=purchases.filter(p=>p.payment_status==='unpaid'&&!['created','cancelled'].includes(p.status));
    return {total:purchases.length,created:purchases.filter(p=>p.status==='created').length,in_transit:purchases.filter(p=>p.status==='in_transit').length,unpaid:unpaid.length,company_payable:unpaid.reduce((sum,p)=>sum+Number(p.company_payable),0)};
  };
  await page.route('**/rest/v1/**',async route=>{
    const request=route.request();
    const path=new URL(request.url()).pathname.split('/').pop();
    const params=request.method()==='POST'?request.postDataJSON():{};
    let data=[];
    switch(path) {
      case 'user_profiles': data=[{tenant_id:tenant,email:user.email,full_name:'Purchase Operator',tenants:{business_name:'Purchase UI Verification'}}]; break;
      case 'get_my_permissions': data=role==='manage'?['purchases:view','purchases:manage','logistics:view','logistics:manage','inventory:view','dashboard:view']:['purchases:view']; break;
      case 'wallets': data=[{type:'dealership',balance:-1703906}]; break;
      case 'list_purchases': throw Error('Unbounded purchase read');
      case 'get_purchase_directory': purchasePageLimit=params.p_limit; data=purchasePage(params); break;
      case 'get_purchase_overview': data=purchaseOverview(); break;
      case 'get_purchases_by_ids': data=purchases.filter(p=>params.p_ids.includes(p.purchase_id)); break;
      case 'list_transits': data=transits; break;
      case 'list_gas_plants': data=[{plant_id:plant,plant_name:'Meghna Filling Plant',brand_id:brand,brand_name:'Beximco LPG',location:'Narayanganj',is_active:true}]; break;
      case 'list_trucks': data=[{truck_id:truck,name:'Dhaka Delivery Truck',serial_no:'Dhaka Metro 11-4520',status:purchases.some(p=>p.status==='in_transit')||transits.some(t=>t.status==='active')?'going':'idle',capacity:100}]; break;
      case 'items': data=[{item_id:sku,brand_id:brand,brand:'Beximco LPG',size_kg:12,mouth_size:'22mm',empty_quantity:emptyAvailable,lpg_brands:{brand_id:brand,brand_name:'Beximco LPG'}},
        {item_id:'second-sku',brand_id:brand,brand:'Beximco LPG',size_kg:25,mouth_size:'22mm',empty_quantity:0,lpg_brands:{brand_name:'Beximco LPG'}},
        {item_id:'other-sku',brand_id:'other-company',brand:'Other company',size_kg:12,mouth_size:'22mm',empty_quantity:10}]; break;
      case 'get_purchase_activity': {
        if(failActivity){await route.fulfill({status:503,json:{message:'Activity temporarily unavailable'}});return;}
        const url=new URL(request.url());
        const offset=Number(url.searchParams.get('offset')||0), limit=Number(url.searchParams.get('limit')||1000);
        activityRequests.push({offset,limit});
        data=(history.get(params.p_purchase_id)||[]).slice(offset,offset+limit);break;
      }
      case 'create_purchase': {
        calls.push(path);
        const d=params.p_payload;creationBodies.push(d);
        const prior=purchases.find(p=>p.request_id===d.request_id);
        if(prior){data={purchase_id:prior.purchase_id};break;}
        const p={...d,purchase_id:crypto.randomUUID(),brand_id:brand,company_name:'Beximco LPG',plant_name:'Meghna Filling Plant',truck_name:d.truck_id?'Dhaka Delivery Truck':null,status:'created',payment_status:'unpaid',created_at:new Date(Date.parse(now)+purchases.length*1000).toISOString(),dispatched_at:null,received_at:null,paid_at:null,receipt_notes:null,legacy_record:false,revision:1,items:[]};
        purchases.unshift(p); record(p,'created');recalculate(p);data={purchase_id:p.purchase_id};if(loseResponse){loseResponse=false;await route.abort('failed');return;}break;
      }
      case 'update_purchase': {
        calls.push(path);const p=purchases.find(p=>p.purchase_id===params.p_purchase_id);const d=params.p_payload;
        const before=structuredClone(p), saved=p.items;
        Object.assign(p,d);p.truck_name=p.truck_id?'Dhaka Delivery Truck':null;
        if(d.items)p.items=d.items.map(i=>{
          const old=saved.find(item=>item.purchase_item_id===i.purchase_item_id);
          const billed=p.status==='created'?i.quantity:old?.billed_quantity??i.quantity;
          return {...i,purchase_item_id:i.purchase_item_id||crypto.randomUUID(),brand_name:'Beximco LPG',size_kg:12,mouth_size:'22mm',received_quantity:old?.received_quantity??null,billed_quantity:billed,line_total:billed*i.unit_price};
        });
        p.revision++;recalculate(p);record(p,'updated',{before,after:structuredClone(p),items:structuredClone(p.items)});data={};break;
      }
      case 'dispatch_purchase': {
        calls.push(path);
        if(failDispatch){failDispatch=false;await route.fulfill({status:400,json:{message:'Not enough empty cylinders',code:'P0001',details:JSON.stringify([{item_id:sku,product:'Beximco LPG 12 kg 22mm',required:4,available:2,missing:2}])}});return;}
        const p=purchases.find(p=>p.purchase_id===params.p_purchase_id);p.status='in_transit';p.dispatched_at=now;p.revision++;record(p,'dispatched',{empty_cylinders:p.items.reduce((s,i)=>s+i.empty_dispatched,0)});break;
      }
      case 'pay_purchase': { calls.push(path);const p=purchases.find(p=>p.purchase_id===params.p_purchase_id);p.payment_status='paid';p.paid_at=now;p.revision++;record(p,'paid',{total_cost:p.total_cost});break; }
      case 'receive_purchase': {
        calls.push(path);const p=purchases.find(p=>p.purchase_id===params.p_purchase_id);
        for(const i of p.items)i.received_quantity=i.quantity;
        p.status='received';p.received_at=now;p.receipt_notes='';p.revision++;recalculate(p);record(p,'received',{notes:p.receipt_notes});break;
      }
      case 'cancel_purchase': { const p=purchases.find(p=>p.purchase_id===params.p_purchase_id);p.status='cancelled';p.revision++;record(p,'cancelled');break; }
      case 'create_custom_transit': { const d=params.p_payload; transits.unshift({tenant_id:tenant,transit_id:crypto.randomUUID(),truck_id:d.truck_id,truck_name:'Dhaka Delivery Truck',purchase_id:null,status:'active',transport_fee:d.fee,client_name:d.client_name,destination:d.destination,description:d.description,driver_cost:0,helper_cost:0,oil_cost:0,others_cost:0,additional_costs:[],total_cost:0,revision:1,closed_at:null,created_at:now,updated_at:now});break; }
      case 'save_transit_costs': {const t=transits.find(t=>t.transit_id===params.p_transit_id);Object.assign(t,params.p_costs);t.total_cost=t.driver_cost+t.helper_cost+t.oil_cost+t.others_cost+t.additional_costs.reduce((s,c)=>s+c.amount,0);t.revision++;break;}
      case 'transition_transit': {const t=transits.find(t=>t.transit_id===params.p_transit_id);if(params.p_action==='close')t.closed_at=now;else t.status=params.p_action==='complete'?'completed':'cancelled';t.revision++;break;}
      default: throw new Error('Unexpected fixture endpoint '+path);
    }
    await route.fulfill({json:data});
  });
  await page.setViewportSize({width:1440,height:1000});
  // A hash navigation alone does not execute the session init script.
  await page.reload();
  await page.goto(`${appUrl}/#/purchases`);

  await page.getByRole('button',{name:'New Purchase',exact:true}).click();
  await page.getByRole('combobox',{name:'Destination plant'}).selectOption(plant);
  await page.getByRole('dialog',{name:'New purchase',exact:true}).getByRole('button',{name:'Create purchase',exact:true}).click();
  await page.getByRole('dialog',{name:'Create this purchase?',exact:true}).getByRole('button',{name:'Create purchase',exact:true}).click();
  await page.getByRole('button',{name:'Recover purchase',exact:true}).waitFor();
  await page.reload();
  await page.setViewportSize({width:390,height:844});
  await page.getByRole('button',{name:'New Purchase',exact:true}).click();
  const modal=page.getByRole('dialog',{name:'New purchase',exact:true});
  if(!await modal.evaluate(e=>e.scrollWidth<=e.clientWidth+1))throw Error('Phone recovery dialog overflows');
  await page.getByRole('button',{name:'Recover purchase',exact:true}).click();
  await modal.waitFor({state:'hidden'});
  if(purchases.length!==1||creationBodies.length!==2||JSON.stringify(creationBodies[0])!==JSON.stringify(creationBodies[1]))throw Error('Lost creation response was not recovered with the original request');
  await page.getByRole('button',{name:'New Purchase',exact:true}).click();
  await modal.waitFor();
  if(await page.getByRole('button',{name:'Recover purchase',exact:true}).count())throw Error('Confirmed creation left a pending request');
  return {lostResponse:true,reloadRecovery:true,phoneDialogFits:true,sameCreationRequest:true,duplicatePurchases:0};
}
