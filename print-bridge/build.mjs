import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile, copyFile, readdir } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { rolldown } from 'rolldown';

const root = fileURLToPath(new URL('../', import.meta.url));
const work = join(root, '.temp', 'print-bridge-build');
const release = join(root, 'print-bridge', 'release');
const packaging = join(root, 'print-bridge', 'packaging');
// Build-only download: no Node/npm installation is required on the receiving computer.
const version = '24.20.0';
const archiveName = `node-v${version}-win-x64.zip`;
const archiveHash = '6cac9ffbca8f6a47091e4b5c772e0606049c3871cb67d900c0cedde630e545ba';
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
function run(command, args) {
  const result = spawnSync(command, args, { cwd: root, encoding: 'utf8', windowsHide: true });
  if (result.status !== 0) throw new Error(`${command} failed: ${result.stderr || result.stdout || result.error?.message}`);
}
function powershell(code) {
  run('powershell.exe', ['-NoProfile', '-NonInteractive', '-EncodedCommand', Buffer.from(code, 'utf16le').toString('base64')]);
}
const quote = value => `'${value.replaceAll("'", "''")}'`;

if (process.platform !== 'win32') throw new Error('Build the Windows bridge on Windows with .NET Framework 4.8.');
await mkdir(work, { recursive: true });
await mkdir(release, { recursive: true });
const archive = join(work, archiveName);
let download;
try { download = await readFile(archive); } catch (error) { if (error.code !== 'ENOENT') throw error; }
if (!download || hash(download) !== archiveHash) {
  const response = await fetch(`https://nodejs.org/dist/v${version}/${archiveName}`);
  if (!response.ok) throw new Error(`Node runtime download failed: ${response.status}`);
  download = Buffer.from(await response.arrayBuffer());
  if (hash(download) !== archiveHash) throw new Error('Node runtime checksum failed.');
  await writeFile(archive, download);
}
const extracted = join(work, `node-v${version}-win-x64`);
powershell(`$ErrorActionPreference='Stop'; Expand-Archive -LiteralPath ${quote(archive)} -DestinationPath ${quote(work)} -Force`);
const payload = join(work, 'payload');
await mkdir(payload, { recursive: true });
await copyFile(join(extracted, 'node.exe'), join(payload, 'node.exe'));
await copyFile(join(extracted, 'LICENSE'), join(payload, 'NODE-LICENSE.txt'));
for (const name of ['windows.ps1', 'WindowsPrinting.cs']) await copyFile(join(root, 'print-bridge', name), join(payload, name));
const bundle = await rolldown({ input: join(root, 'print-bridge', 'main.ts'), platform: 'node', external: [/^node:/], tsconfig: join(root, 'print-bridge', 'tsconfig.json') });
await bundle.write({ file: join(payload, 'bridge.mjs'), format: 'esm', minify: true, sourcemap: false });
await bundle.close();
const digest = createHash('sha256');
for (const name of (await readdir(payload)).sort()) { digest.update(name); digest.update(await readFile(join(payload, name))); }
const idFile = join(work, 'runtime.id');
await writeFile(idFile, digest.digest('hex'));
const zip = join(work, 'runtime.zip');
powershell(`$ErrorActionPreference='Stop'; Add-Type -AssemblyName System.IO.Compression.FileSystem; if(Test-Path -LiteralPath ${quote(zip)}) { Remove-Item -LiteralPath ${quote(zip)} }; [IO.Compression.ZipFile]::CreateFromDirectory(${quote(payload)}, ${quote(zip)}, [IO.Compression.CompressionLevel]::Optimal, $false)`);
const compiler = resolve(process.env.WINDIR || 'C:\\Windows', 'Microsoft.NET', 'Framework64', 'v4.0.30319', 'csc.exe');
const references = ['System.ServiceProcess.dll', 'System.IO.Compression.dll', 'System.IO.Compression.FileSystem.dll', 'System.Web.Extensions.dll', 'System.Windows.Forms.dll'];
function compile(source, filename, resources = [], admin = false) {
  run(compiler, ['/nologo', '/optimize+', '/target:winexe', '/platform:x64', `/out:${join(release, filename)}`,
    ...references.map(name => `/reference:${name}`), ...(admin ? [`/win32manifest:${join(packaging, 'admin.manifest')}`] : []),
    ...resources.map(([file, name]) => `/resource:${file},${name}`), join(packaging, 'Common.cs'), join(packaging, source)]);
}
compile('BridgeHost.cs', 'LPG Print Bridge.exe', [[zip, 'runtime.zip'], [idFile, 'runtime.id']]);
compile('Restart.cs', 'Restart LPG Print Bridge.exe', [], true);
compile('Installer.cs', 'LPG Print Bridge Setup.exe', [
  [join(release, 'LPG Print Bridge.exe'), 'bridge.exe'], [join(release, 'Restart LPG Print Bridge.exe'), 'restart.exe'],
  [join(root, 'print-bridge', 'README.md'), 'installation.md'], [join(payload, 'NODE-LICENSE.txt'), 'node-license'], [idFile, 'runtime.id'],
], true);
await copyFile(join(root, 'print-bridge', 'README.md'), join(release, 'INSTALLATION.md'));
await copyFile(join(payload, 'NODE-LICENSE.txt'), join(release, 'NODE-LICENSE.txt'));
await copyFile(join(packaging, 'verify-service.ps1'), join(release, 'verify-service.ps1'));
const files = ['LPG Print Bridge.exe', 'LPG Print Bridge Setup.exe', 'Restart LPG Print Bridge.exe', 'INSTALLATION.md', 'NODE-LICENSE.txt', 'verify-service.ps1'];
await writeFile(join(release, 'SHA256SUMS.txt'), (await Promise.all(files.map(async name => `${hash(await readFile(join(release, name)))}  ${name}`))).join('\n') + '\n');
console.log(`Windows x64 bridge, installer and restart launcher built in ${release}. Embedded Node ${version}; runtime archive SHA256 verified.`);
