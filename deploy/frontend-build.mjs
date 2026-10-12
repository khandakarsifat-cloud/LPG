// Called by deploy.mjs with a minimal environment. Vite cannot load local .env files.
import { build } from 'vite';
await build({ envDir: false, build: { outDir: 'dist' } });
