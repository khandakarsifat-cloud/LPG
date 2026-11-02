// Run once on the VPS with credentials supplied through stdin, never argv/logs.
// No HTTP bootstrap endpoint is exposed. The database permanently consumes the bootstrap.
import { readFileSync } from 'node:fs';
const config = process.env.ACCOUNT_API_URL ? {apiURL:process.env.ACCOUNT_API_URL,publicKey:process.env.ACCOUNT_PUBLIC_KEY,serviceKey:process.env.ACCOUNT_SERVICE_KEY} : JSON.parse(readFileSync('/run/account-service.json', 'utf8'));
let input = '';for await (const chunk of process.stdin) { input += chunk; if (input.includes('\n')) break; }
const { email, password } = JSON.parse(input);
if (typeof email !== 'string' || typeof password !== 'string' || password.length < 8) throw Error('Bootstrap credentials are required on stdin');
async function call(path, body) {
 const response = await fetch(config.apiURL + path, { method: 'POST', headers: { apikey: config.publicKey, Authorization: 'Bearer ' + config.serviceKey, 'Content-Type': 'application/json' }, body: JSON.stringify(body), signal: AbortSignal.timeout(20_000) });
 const value=await response.json().catch(()=>null);if(!response.ok)throw Error('Bootstrap refused; inspect account/one-time bootstrap state privately.');return value;
}
if(!await call('/rest/v1/rpc/platform_bootstrap_available',{}))throw Error('Platform bootstrap has already been consumed; no account was changed.');
const user=await call('/auth/v1/admin/users',{email,password,email_confirm:true,user_metadata:{full_name:'Platform administrator'}});
await call('/rest/v1/rpc/bootstrap_platform_superadmin',{p_user_id:user.id});
console.log('One-time platform bootstrap completed; password change is required before administrative access.');
