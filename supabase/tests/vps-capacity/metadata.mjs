import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { remote, sql, save, frontend, read } from './common.mjs';

const applied=JSON.parse(sql("select jsonb_agg(version order by version) from supabase_migrations.schema_migrations;"));
const source=readdirSync('supabase/migrations').filter(n=>n.endsWith('.sql')).sort();
assert.deepEqual(applied,source.map(n=>n.split('_')[0]),'Resolve pending or divergent migrations before testing');
const deployed=JSON.parse(remote('sudo -n python3 -',`import hashlib,json,pathlib\nroot=pathlib.Path('/opt/lpg/supabase/migrations')\nprint(json.dumps({p.name:hashlib.sha256(p.read_text(encoding='utf-8-sig').replace('\\r\\n','\\n').encode()).hexdigest() for p in root.glob('*.sql')}))`));
for (const filename of source) {
  const local=createHash('sha256').update(readFileSync('supabase/migrations/'+filename,'utf8').replace(/^\uFEFF/,'').replaceAll('\r\n','\n')).digest('hex');
  assert.equal(local,deployed[filename],`Applied migration source changed: ${filename}`);
}
const server=JSON.parse(remote('sudo -n python3 -',`import json,subprocess,os,pathlib,platform\ncontainers=json.loads(subprocess.check_output(['docker','inspect']+subprocess.check_output(['docker','ps','--format','{{.Names}}'],text=True).split()))\nprint(json.dumps({'host':platform.node(),'kernel':platform.release(),'cores':os.cpu_count(),'cpuinfo':subprocess.check_output(['lscpu'],text=True),'storage':subprocess.check_output(['lsblk','-b','-o','NAME,SIZE,FSTYPE,MOUNTPOINTS'],text=True),'network':subprocess.check_output(['ip','-s','link'],text=True),'services':[{'name':c['Name'],'image':c['Config']['Image'],'memory_limit':c['HostConfig']['Memory'],'status':c['State']['Status'],'health':c['State'].get('Health',{}).get('Status'),'oom_killed':c['State']['OOMKilled'],'restart_count':c['RestartCount']} for c in containers if c['Name'].startswith('/lpg-')]}))`));
const settings=JSON.parse(sql(`select jsonb_build_object('version',version(),'settings',(select jsonb_object_agg(name,setting) from pg_settings where name in ('shared_buffers','work_mem','effective_cache_size','max_connections','track_io_timing','pg_stat_statements.track','log_min_duration_statement','statement_timeout')),'database_bytes',pg_database_size(current_database()));`));
save(process.argv[2]||'environment.json',{time:new Date().toISOString(),api:frontend.VITE_SUPABASE_URL,server,postgres:settings,
  migrations:{count:applied.length,pending:[],latest:applied.at(-1),source_checksums_match:true},
  source_commit:execFileSync('git',['rev-parse','HEAD'],{encoding:'utf8'}).trim(),
  note:'Working tree contains pre-existing changes; artifact hashes identify workload used.',
  tools:{k6:'2.3.0',grafana:'13.3.0',prometheus:'3.15.1'},
  workload_sha256:createHash('sha256').update(readFileSync('supabase/tests/vps-capacity/workload.js')).digest('hex')});
console.log(`Verified ${applied.length} applied migrations, no pending migrations, identical deployed migration source and target metadata.`);
