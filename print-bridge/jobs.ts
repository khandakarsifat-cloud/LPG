import { mkdir, readFile, writeFile, rename } from 'node:fs/promises';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { PrintError } from './errors.ts';

interface JobRecord {
  fingerprint: string;
  result?: { job_id: number };
  error?: { code: string; message: string; status: number };
}

// Reserve a request on disk BEFORE sending bytes. Restart/timeouts never replay a job automatically.
export class PrintJobs {
  readonly directory: string;
  private active = false;
  constructor(directory: string) { this.directory = directory; }

  async submit(id: string, payload: unknown, send: () => Promise<{ job_id: number }>): Promise<{ job_id: number }> {
    if (!/^[0-9a-f-]{36}$/i.test(id)) throw new PrintError('INVALID_REQUEST', 'Invalid print request identifier.');
    const fingerprint = createHash('sha256').update(JSON.stringify(payload)).digest('hex');
    await mkdir(this.directory, { recursive: true });
    const path = join(this.directory, `${id}.json`);
    try {
      const existing: JobRecord = JSON.parse(await readFile(path, 'utf8'));
      if (existing.fingerprint !== fingerprint) throw new PrintError('REQUEST_CONFLICT', 'Print request identifier was already used for different content.', 409);
      if (existing.result) return existing.result;
      if (existing.error) throw new PrintError(existing.error.code, existing.error.message, existing.error.status);
      throw new PrintError('RESULT_UNKNOWN', 'This request was already started. Check the printer before explicitly reprinting.', 409);
    } catch (error) {
      if (!(error instanceof Error) || !('code' in error) || error.code !== 'ENOENT') throw error;
    }
    if (this.active) throw new PrintError('PRINTER_BUSY', 'Another receipt is being printed. Wait for it to finish, then reprint the saved sale.', 409);
    this.active = true;
    try {
      await writeFile(path, JSON.stringify({ fingerprint }), { flag: 'wx' });
      try {
        const result = await send();
        await this.finish(path, { fingerprint, result });
        return result;
      } catch (error) {
        const failure = error instanceof PrintError ? error : new PrintError('PRINT_FAILED', 'Printing failed. Check the printer before reprinting.', 503);
        await this.finish(path, { fingerprint, error: { code: failure.code, message: failure.message, status: failure.status } });
        throw failure;
      }
    } finally { this.active = false; }
  }
  private async finish(path: string, record: JobRecord) {
    await writeFile(`${path}.tmp`, JSON.stringify(record));
    await rename(`${path}.tmp`, path);
  }
}
