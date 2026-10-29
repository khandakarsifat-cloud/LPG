import { readFileSync, writeFileSync, mkdirSync, openSync, existsSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { state, backend, remote, save } from './common.mjs';

remote('umask 077; cat > /tmp/lpg-capacity-sample.py', readFileSync(new URL('./sample.py',import.meta.url),'utf8'));
const tools=join(state,'tools');
const provisioning=join(state,'provisioning');
for (const dir of ['datasources','dashboards']) mkdirSync(join(provisioning,dir),{recursive:true});
mkdirSync(join(state,'dashboards'),{recursive:true});
writeFileSync(join(state,'prometheus.yml'),`global:\n  scrape_interval: 5s\nscrape_configs:\n  - job_name: lpg-capacity\n    static_configs:\n      - targets: ['127.0.0.1:9917']\n`);
writeFileSync(join(provisioning,'datasources','capacity.yaml'),JSON.stringify({apiVersion:1,datasources:[{
  name:'LPG Capacity',type:'prometheus',uid:'lpg-capacity',access:'proxy',url:'http://127.0.0.1:19090',isDefault:true,
}]}));
writeFileSync(join(provisioning,'dashboards','capacity.yaml'),JSON.stringify({apiVersion:1,providers:[{
  name:'LPG Capacity',type:'file',options:{path:join(state,'dashboards').replaceAll('\\','/')},disableDeletion:true,
}]}));
const specs=[
  ['Active independent businesses','lpg_active_businesses','short'],
  ['VPS CPU busy and steal','lpg_cpu_busy_pct','percent'],
  ['VPS steal','lpg_cpu_steal_pct','percent'],
  ['VPS available memory','lpg_server_MemAvailable_bytes','bytes'],
  ['Containers memory','lpg_container_memory_bytes','bytes'],
  ['PostgreSQL CPU (100% = one core)','lpg_lpg_db_1_cpu_pct','percent'],
  ['Disk utilization','lpg_disk_util_pct','percent'],
  ['Disk await','lpg_disk_await_ms','ms'],
  ['PostgreSQL active/blocked','{__name__=~"lpg_postgres_(active|blocked|connections)"}','short'],
  ['PostgreSQL commits per second','lpg_postgres_xact_commit_per_s','ops'],
  ['VPS network','{__name__=~"lpg_network_(rx|tx)_Bps"}','Bps'],
  ['Windows CPU','lpg_windows_cpu_pct','percent'],
  ['Windows available memory','lpg_windows_available','bytes'],
  ['HTTP mean / p95 / p99','{__name__=~"k6_http_req_duration_(avg|p95|p99)"}','s'],
  ['HTTP request throughput','sum(rate(k6_http_reqs_total[30s]))','reqps'],
  ['Operation error rate','k6_operation_errors_rate','percentunit'],
];
const dashboard={uid:'lpg-vps-capacity',title:'LPG VPS Capacity — isolated businesses',schemaVersion:39,version:1,
  timezone:'Asia/Dhaka',refresh:'5s',time:{from:'now-1h',to:'now'},panels:specs.map(([title,expr,unit],i)=>({
    id:i+1,title,type:'timeseries',datasource:{type:'prometheus',uid:'lpg-capacity'},
    gridPos:{x:(i%2)*12,y:Math.floor(i/2)*8,w:12,h:8},
    targets:[{refId:'A',expr,legendFormat:'{{name}} {{endpoint}} {{container}} {{__name__}}'}],fieldConfig:{defaults:{unit},overrides:[]},
  }))};
writeFileSync(join(state,'dashboards','capacity.json'),JSON.stringify(dashboard,null,2));
const grafana=join(tools,'grafana-13.3.0');
mkdirSync(join(state,'grafana-data'),{recursive:true});
mkdirSync(join(state,'grafana-logs'),{recursive:true});
writeFileSync(join(state,'grafana.ini'),`[server]\nhttp_addr=127.0.0.1\nhttp_port=13000\n[paths]\ndata=${join(state,'grafana-data').replaceAll('\\','/')}\nlogs=${join(state,'grafana-logs').replaceAll('\\','/')}\nprovisioning=${provisioning.replaceAll('\\','/')}\n[auth.anonymous]\nenabled=true\norg_role=Viewer\n[security]\nadmin_password=${randomUUID()}\n[analytics]\nreporting_enabled=false\ncheck_for_updates=false\ncheck_for_plugin_updates=false\n[plugins]\npreinstall_disabled=true\n`);
const processes=[];
function start(name,command,args,env=process.env) {
  const process=spawn(command,args,{windowsHide:true,detached:true,env,
    stdio:['ignore',openSync(join(state,name+'.stdout'),'a'),openSync(join(state,name+'.stderr'),'a')]});
  process.unref(); processes.push({name,pid:process.pid});
}
start('monitor','python',['supabase/tests/vps-capacity/monitor.py','--state',state,'--host',`${backend.VPS_USER}@${backend.VPS_HOST}`,'--port',backend.VPS_PORT,...(backend.VPS_SSH_KEY?['--key',backend.VPS_SSH_KEY]:[])],
  {...process.env,PYTHONPATH:join(state,'python')});
start('prometheus',join(tools,'prometheus-3.15.1.windows-amd64','prometheus.exe'),[
  '--config.file='+join(state,'prometheus.yml'),'--storage.tsdb.path='+join(state,'prometheus-data'),
  '--storage.tsdb.retention.time=14d','--web.listen-address=127.0.0.1:19090','--web.enable-remote-write-receiver']);
const executable=existsSync(join(grafana,'bin','grafana.exe'))?'grafana.exe':'grafana-server.exe';
start('grafana',join(grafana,'bin',executable),['server','--homepath',grafana,'--config',join(state,'grafana.ini')]);
save('monitor-processes.json',processes);
console.log('Started Windows monitoring, Prometheus 127.0.0.1:19090, Grafana 127.0.0.1:13000.');
