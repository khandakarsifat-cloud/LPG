import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

// Validate the actual publication directory before Wrangler can upload it.
export function validatePWA(directory) {
  const html = readFileSync(join(directory, 'index.html'), 'utf8');
  // Vite's existing relative base rewrites /manifest.webmanifest to ./manifest.webmanifest.
  assert.match(html, /<link\s+rel="manifest"\s+href="(?:\/|\.\/)manifest.webmanifest"\s*\/>/, 'Missing stable manifest link');
  const manifest = JSON.parse(readFileSync(join(directory, 'manifest.webmanifest'), 'utf8'));
  for (const key of ['id', 'start_url', 'scope']) assert.equal(manifest[key], '/', `PWA ${key} must remain /`);
  assert.equal(manifest.display, 'standalone', 'PWA must use standalone display');
  assert.ok(manifest.name && manifest.short_name, 'PWA requires a name');
  for (const size of [192, 512]) {
    const icon = manifest.icons.find(icon => icon.sizes === `${size}x${size}` && icon.type === 'image/png' && (icon.purpose ?? 'any').split(' ').includes('any'));
    assert.ok(icon, `Missing ${size}px install icon`);
    assert.match(icon.src, /^\/icons\/[a-z0-9-]+\.png$/, 'Install icons must use stable same-origin paths');
    const png = readFileSync(join(directory, icon.src.slice(1)));
    assert.equal(png.subarray(0, 8).toString('hex'), '89504e470d0a1a0a', 'Install icon must be PNG');
    assert.equal(png.readUInt32BE(16), size, 'Install icon width mismatch');
    assert.equal(png.readUInt32BE(20), size, 'Install icon height mismatch');
  }
}
