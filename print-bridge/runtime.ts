import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

export const settingNames = ['LPG_PRINT_ORIGINS', 'LPG_PRINT_HOST', 'LPG_PRINT_TLS_CERT', 'LPG_PRINT_TLS_KEY', 'LPG_PRINT_TOKEN', 'LPG_PRINT_DIAGNOSTICS'] as const;

export function loadSettings(directory = process.env.LPG_PRINT_DATA_DIR || join(process.env.LOCALAPPDATA || homedir(), 'LPGManager', 'PrintBridge')) {
  let value: unknown;
  try { value = JSON.parse(readFileSync(join(directory, 'settings.json'), 'utf8').replace(/^\uFEFF/, '')); }
  catch (error) {
    if (error instanceof Error && 'code' in error && error.code === 'ENOENT') return;
    // JSON parse errors can quote the file's private pairing token. Never attach/log that cause.
    // eslint-disable-next-line preserve-caught-error
    throw new Error('Cannot read bridge settings.json. Restore valid JSON and restart.');
  }
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Bridge settings.json must be an object.');
  for (const [key, setting] of Object.entries(value)) {
    if (!settingNames.includes(key as typeof settingNames[number]) || typeof setting !== 'string') throw new Error('Bridge settings.json contains an unsupported setting or non-string value.');
    process.env[key] = setting;
  }
}
