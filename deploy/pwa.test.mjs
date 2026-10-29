import test from 'node:test';
import assert from 'node:assert/strict';
import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { validatePWA } from './pwa.mjs';

function publication(t) {
  const directory = mkdtempSync(join(tmpdir(), 'lpg-pwa-'));
  t.after(() => {
    assert.ok(directory.startsWith(join(tmpdir(), 'lpg-pwa-')));
    rmSync(directory, { recursive: true, force: true });
  });
  cpSync(new URL('../public/', import.meta.url), directory, { recursive: true });
  cpSync(new URL('../index.html', import.meta.url), join(directory, 'index.html'));
  return directory;
}

test('published PWA has stable identity, root scope, standalone display and real install icons', t => {
  validatePWA(publication(t));
});

test('deployment refuses missing manifest links, changed identity/scope/display and missing icons', t => {
  const directory = publication(t);
  const htmlPath = join(directory, 'index.html');
  const html = readFileSync(htmlPath, 'utf8');
  writeFileSync(htmlPath, html.replace(/<link\s+rel="manifest"[^>]*>/, ''));
  assert.throws(() => validatePWA(directory), /manifest link/);
  writeFileSync(htmlPath, html);
  const path = join(directory, 'manifest.webmanifest');
  const original = JSON.parse(readFileSync(path, 'utf8'));
  for (const [key, value] of [['id', '/new-app'], ['scope', '/dashboard/'], ['start_url', '/pos'], ['display', 'browser'], ['icons', []]]) {
    writeFileSync(path, JSON.stringify({ ...original, [key]: value }));
    assert.throws(() => validatePWA(directory));
  }
  writeFileSync(path, JSON.stringify(original));
  rmSync(join(directory, original.icons[0].src.slice(1)));
  assert.throws(() => validatePWA(directory), /ENOENT/);
});
