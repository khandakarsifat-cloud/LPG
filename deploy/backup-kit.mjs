// Private recovery secrets go directly from SSH into an ACL-restricted local file.
import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { parseEnv } from 'node:util';

if (process.platform !== 'win32') throw new Error('This exporter targets the owner’s Windows recovery directory.');
const settings = parseEnv(readFileSync(new URL('./.env.backend', import.meta.url), 'utf8'));
if (settings.VPS_HOST !== '144.79.249.4' || settings.VPS_PROJECT_DIR !== '/opt/lpg') throw new Error('Unexpected recovery target.');
const folder = join(process.env.LOCALAPPDATA, 'LPG', 'Recovery', 'google-drive');
mkdirSync(folder, { recursive: true });
const identity = execFileSync('whoami', [], { encoding: 'utf8', windowsHide: true }).trim();
execFileSync('icacls', [folder, '/inheritance:r', '/grant:r', `${identity}:(OI)(CI)F`], { windowsHide: true, stdio: 'ignore' });
const ssh = [...(settings.VPS_SSH_KEY ? ['-i', settings.VPS_SSH_KEY] : []), '-p', settings.VPS_PORT,
  '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', `${settings.VPS_USER}@${settings.VPS_HOST}`];
const script = `import io,json,os,sys,tarfile,datetime
from pathlib import Path
root=Path('/opt/lpg/deploy')
with tarfile.open(fileobj=sys.stdout.buffer,mode='w|') as archive:
 for name in ['restic-password','google-client.json','rclone.conf']:
  path=root/'backup-secrets'/name
  if path.exists():archive.add(path,arcname=name)
 generation=Path('/opt/lpg/backups/cloud/generation.json')
 if generation.exists():archive.add(generation,arcname='generation.json')
 archive.add(root/'backup',arcname='backup',filter=lambda i:None if '__pycache__' in i.name else i)
 archive.add(root/'backup/recovery.md',arcname='recovery.md')
`;
const archive = execFileSync('ssh', [...ssh, 'sudo -n python3 -B -'], { input: script, maxBuffer: 4 * 1024 * 1024, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
const file = join(folder, 'recovery-kit.tar');
writeFileSync(file, archive);
execFileSync('icacls', [file, '/inheritance:r', '/grant:r', `${identity}:F`], { windowsHide: true, stdio: 'ignore' });
execFileSync('ssh', [...ssh, 'sudo -n python3 -B -'], { input: `from pathlib import Path
import datetime,json
p=Path('/opt/lpg/backups/cloud/key-exported.json')
p.write_text(json.dumps({'exported_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'destination':'owner Windows recovery kit'}))
p.chmod(0o600)
`, windowsHide: true, stdio: ['pipe', 'ignore', 'pipe'] });
console.log('Private recovery kit saved to ' + folder + '. Keep a second secure copy outside this PC.');
