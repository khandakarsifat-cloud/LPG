import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';

// Current suites require the complete migrated application schema. Unapplied
// migrations can be verified through the disposable purchase replay runner.
if (process.argv.includes('--with-migration')) {
  throw new Error('Use purchase:db:test -- --replay-module <PGlite package directory> for unapplied migration replay. auth:db:test requires the migrated local schema.');
}
for (const name of ['authorization.sql', 'receipt_printers.sql']) {
  const tests = readFileSync(new URL(name, import.meta.url), 'utf8');
  const output = execFileSync('docker', [
    'compose', 'exec', '-T', 'db', 'psql', '-U', 'supabase_admin', '-d', 'postgres',
    '-v', 'ON_ERROR_STOP=1', '-q', '-t',
  ], { input: tests, encoding: 'utf8', cwd: new URL('../../', import.meta.url) });
  const result = output.split('\n').find(line => line.includes('PASS:'));
  if (!result) throw new Error(`No success assertion returned by ${name}`);
  console.log(`${name}: ${result.trim()}`);
}
