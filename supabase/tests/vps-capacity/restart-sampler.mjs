import { spawn } from 'node:child_process';
import { readFileSync, writeFileSync, openSync } from 'node:fs';
import { join } from 'node:path';
import { state, backend, remote, read, save } from './common.mjs';

const processes=read('monitor-processes.json');
// Exact command identity protects unrelated system/app Python processes.
remote('sudo -n python3 -',`import pathlib,os,signal\nfor p in pathlib.Path('/proc').iterdir():\n if p.name.isdigit():\n  try:\n   cmd=(p/'cmdline').read_bytes().split(b'\\x00')\n   if len(cmd)>2 and cmd[0].endswith(b'python3') and cmd[1:3]==[b'-u',b'/tmp/lpg-capacity-sample.py']:\n    os.kill(int(p.name),signal.SIGTERM)\n  except (FileNotFoundError,ProcessLookupError,PermissionError): pass\n`);
for(const p of processes.filter(p=>p.name==='monitor')) {
  try { process.kill(p.pid); } catch { /* already stopped */ }
}
remote('umask 077; cat > /tmp/lpg-capacity-sample.py',readFileSync(new URL('./sample.py',import.meta.url),'utf8'));
const child=spawn('python',['supabase/tests/vps-capacity/monitor.py','--state',state,'--host',`${backend.VPS_USER}@${backend.VPS_HOST}`,
  '--port',backend.VPS_PORT,...(backend.VPS_SSH_KEY?['--key',backend.VPS_SSH_KEY]:[])],{windowsHide:true,detached:true,
  env:{...process.env,PYTHONPATH:join(state,'python')},
  stdio:['ignore',openSync(join(state,'monitor.stdout'),'a'),openSync(join(state,'monitor.stderr'),'a')]});
child.unref();
save('monitor-processes.json',[...processes.filter(p=>p.name!=='monitor'),{name:'monitor',pid:child.pid}]);
console.log('Updated only the exact capacity sampler and Windows bridge.');
