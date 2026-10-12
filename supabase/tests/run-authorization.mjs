import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';

// The local Compose database is the configured application instance. No keys
// are needed or printed. --with-migration tests unapplied SQL and rolls it back.
const migration = process.argv.includes('--with-migration')
  ? ['20261004192158_tenant_permission_authorization.sql', '20261004194235_receipt_printer_upsert_authorization.sql']
    .map(name => readFileSync(new URL('../migrations/' + name, import.meta.url), 'utf8')).join('\n')
  : '';
for (const name of ['authorization.sql', 'receipt_printers.sql']) {
  const tests = readFileSync(new URL(name, import.meta.url), 'utf8');
  const input = migration ? tests.replace('begin;', () => `begin;\n${migration}`) : tests;
  const output = execFileSync('docker', [
    'compose', 'exec', '-T', 'db', 'psql', '-U', 'supabase_admin', '-d', 'postgres',
    '-v', 'ON_ERROR_STOP=1', '-q', '-t',
  ], { input, encoding: 'utf8', cwd: new URL('../../', import.meta.url) });
  const result = output.split('\n').find(line => line.includes('PASS:'));
  if (!result) throw new Error(`No success assertion returned by ${name}`);
  console.log(`${name}: ${result.trim()}`);
}
