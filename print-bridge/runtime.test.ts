import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { loadSettings } from './runtime.ts';

test('saved bridge settings load exact allowed keys and reject malformed/unsupported configuration', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'lpg-settings-'));
  const before = process.env.LPG_PRINT_ORIGINS;
  try {
    loadSettings(directory);
    await writeFile(join(directory, 'settings.json'), JSON.stringify({ LPG_PRINT_ORIGINS: 'https://test.example' }));
    loadSettings(directory); assert.equal(process.env.LPG_PRINT_ORIGINS, 'https://test.example');
    for (const value of ['[]', 'null', '{bad', '{"NODE_OPTIONS":"--inspect"}', '{"LPG_PRINT_TOKEN":32}']) {
      await writeFile(join(directory, 'settings.json'), value);
      assert.throws(() => loadSettings(directory));
    }
  } finally {
    if (before === undefined) delete process.env.LPG_PRINT_ORIGINS; else process.env.LPG_PRINT_ORIGINS = before;
    await rm(directory, { recursive: true, force: true });
  }
});
