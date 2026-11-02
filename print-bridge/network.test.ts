import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer, type AddressInfo } from 'node:net';
import { mkdtemp, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { request } from 'node:http';
import { networkInterfaces } from 'node:os';
import { discoverNetwork, localSubnets, networkPrinter, privateIPv4, probeNetwork, sendNetwork, validateNetworkTarget } from './network.ts';
import { createPrintServer } from './server.ts';

test('network targets require canonical RFC1918 IPv4 and bounded RAW TCP ports', () => {
  for (const ip of ['10.0.0.1', '172.16.0.1', '172.31.255.254', '192.168.1.100']) assert(privateIPv4(ip));
  for (const ip of ['127.0.0.1','169.254.169.254','8.8.8.8','172.32.1.1','10.printer.example','192.168.300.1','::1','192.168.01.1']) assert(!privateIPv4(ip));
  for (const port of [0,80,443,1023,65536,9100.5,'9100']) assert.throws(() => validateNetworkTarget({ ip_address:'192.168.1.10',port }));
  assert.equal(networkPrinter('192.168.1.20').queue_id,'tcp:192.168.1.20:9100');
});
test('network discovery is capped to attached adapter subnets, with a manual fallback', async () => {
  const data = { lan: [{ address:'192.168.12.15',netmask:'255.255.0.0',family:'IPv4' as const,mac:'00:00:00:00:00:00',internal:false,cidr:'192.168.12.15/16' }] };
  assert.deepEqual(localSubnets(data),['192.168.12.0/24']);
  assert.deepEqual(localSubnets({}),[]);
  await assert.rejects(discoverNetwork('8.8.8.0/24'),/attached/);
  await assert.rejects(discoverNetwork('192.168.1.0/16'),/attached/);
});
test('LAN bridge refuses an unpaired or unencrypted listener', () => {
  const before = process.env.LPG_PRINT_HOST;
  try { process.env.LPG_PRINT_HOST='192.168.1.10'; assert.throws(() => createPrintServer(),/32\+ character/); }
  finally { if(before === undefined) delete process.env.LPG_PRINT_HOST; else process.env.LPG_PRINT_HOST=before; }
});
test('actual TCP connectivity sends no probe bytes and sends receipt bytes exactly once', async t => {
  const ip = Object.values(networkInterfaces()).flat().find(a => a && !a.internal && privateIPv4(a.address))?.address;
  if (!ip) return t.skip('No private local network adapter available');
  const receipts: Buffer[] = [];
  const server = createServer(socket => { const chunks:Buffer[]=[];socket.on('data',chunk=>chunks.push(chunk));socket.on('end',()=>{receipts.push(Buffer.concat(chunks));socket.end();}); });
  await new Promise<void>(resolve => server.listen(0,ip,resolve));
  const port = (server.address() as AddressInfo).port;
  try {
    assert((await probeNetwork({ip_address:ip,port})).connected);
    const bytes = Uint8Array.of(0x1b,0x40,0x1d,0x76,0x30,0,1,0,1,0,255,10);
    await sendNetwork(networkPrinter(ip,port),bytes);
    await new Promise(resolve=>setTimeout(resolve,30));
    assert.deepEqual(receipts.filter(b=>b.length),[Buffer.from(bytes)]);
    assert(receipts.some(b=>b.length===0),'Probe must not print or send protocol commands');
  } finally { await new Promise<void>(resolve=>server.close(()=>resolve())); }
  assert.equal((await probeNetwork({ip_address:ip,port},300)).connected,false);
  await assert.rejects(sendNetwork(networkPrinter(ip,port),Uint8Array.of(1)),/failed/);
});

test('full bridge request renders the saved receipt to Ethernet and deduplicates the original request ID', async t => {
  if(process.platform!=='win32')return t.skip('Unicode raster renderer requires Windows');
  const ip=Object.values(networkInterfaces()).flat().find(a=>a&&!a.internal&&privateIPv4(a.address))?.address;
  if(!ip)return t.skip('No private adapter available');
  const bytes:Buffer[]=[];const endpoint=createServer(socket=>{socket.on('data',chunk=>bytes.push(chunk));socket.on('end',()=>socket.end());});
  await new Promise<void>(resolve=>endpoint.listen(0,ip,resolve));
  const folder=await mkdtemp(join(tmpdir(),'lpg-ethernet-test-'));const previous=process.env.LOCALAPPDATA;process.env.LOCALAPPDATA=folder;
  const bridge=createPrintServer(async()=>{throw Error('Network printing must not require USB discovery');});
  await new Promise<void>(resolve=>bridge.listen(0,'127.0.0.1',resolve));
  const payload={request_id:crypto.randomUUID(),config:{tenant_id:crypto.randomUUID(),printer:networkPrinter(ip,(endpoint.address() as AddressInfo).port),paper_width_mm:58,printable_width_dots:384,auto_cut:false},
    receipt:{sale_id:crypto.randomUUID(),created_at:new Date().toISOString(),shop_name:'Bridge test বাংলা',customer_name:'Not a business sale',customer_phone:'',customer_tier:'retail',items:[{name:'Test receipt',type:'package',quantity:1,unit_price:100,line_total:100}],subtotal:100,discount_amount:0,exchange_fee:0,total_amount:100,paid_amount:0,due_amount:100,payments:[],unattributed_paid:0}};
  const url=`http://127.0.0.1:${(bridge.address() as AddressInfo).port}/print`;
  const send=()=>new Promise<Response>((resolve,reject)=>{
    const req=request(url,{method:'POST',headers:{Host:'127.0.0.1:17891',Origin:'http://127.0.0.1:5173','X-LPG-Print-Client':'1','Content-Type':'application/json'}},res=>{
      let text='';res.setEncoding('utf8');res.on('data',chunk=>{text+=chunk;});res.on('end',()=>resolve(new Response(text,{status:res.statusCode})));res.on('error',reject);
    });req.on('error',reject);req.end(JSON.stringify(payload));
  });
  try{
    const first=await send();assert.equal(first.status,200,await first.clone().text());const result=await first.json();
    await new Promise(resolve=>setTimeout(resolve,40));const length=Buffer.concat(bytes).length;assert(length>100,'Rendered raster receipt reached the TCP endpoint');assert.deepEqual([...Buffer.concat(bytes).subarray(0,2)],[0x1b,0x40]);
    const again=await send();assert.equal(again.status,200);assert.equal((await again.json()).job_id,result.job_id);assert.equal(Buffer.concat(bytes).length,length,'A repeated request must not resend bytes');
    payload.receipt.total_amount=101;payload.receipt.due_amount=101;const conflict=await send();assert.equal(conflict.status,409);
  }finally{
    await new Promise<void>(resolve=>bridge.close(()=>resolve()));await new Promise<void>(resolve=>endpoint.close(()=>resolve()));
    if(previous===undefined)delete process.env.LOCALAPPDATA;else process.env.LOCALAPPDATA=previous;
    await rm(folder,{recursive:true,force:true});
  }
});
