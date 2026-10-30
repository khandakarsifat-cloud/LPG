import test from 'node:test';
import assert from 'node:assert/strict';
import { createReceiver, parseAttendance, options, ProtocolError } from './server.mjs';

const line = '12\t2026-10-29 09:00:00\t0\t1\t0\t0';
test('MB20-VL eleven-column uploads accept optional fields without retaining them', () => {
 const extended = line + '\t0\t0\t0\t0\t0';
 assert.equal(extended.split('\t').length, 11);
 assert.deepEqual(parseAttendance(extended), parseAttendance(line));
 assert.deepEqual(Object.keys(parseAttendance(extended)[0]).sort(), ['key', 'pin', 'status', 'timestamp', 'verify', 'workcode']);
});
test('tab records retain repeated scans, stable retry keys, leading zero IDs and device time', () => {
 const body = line + '\r\n' + line + '\n012\t2026-10-29 16:20:00\t1\t1\t0';
 const records = parseAttendance(body);
 assert.equal(records.length, 3); assert.notEqual(records[0].key, records[1].key);
 assert.deepEqual(parseAttendance(body), records);
 assert.equal(records[2].pin, '012'); assert.equal(records[0].timestamp, '2026-10-29 09:00:00');
 assert.equal(parseAttendance(line)[0].key, records[0].key);
});
test('malformed input and oversized batches fail instead of silently dropping rows', () => {
 for (const body of ['USER PIN=1 Name=private', '1\tbad-date', line + '\ninvalid', '1\t2026-10-29 00:00:00\tbiometric data']) assert.throws(() => parseAttendance(body), ProtocolError);
 assert.throws(() => parseAttendance(Array(2001).fill(line).join('\n')), /Too many/);
 assert.deepEqual(parseAttendance('\r\n'), []);
});
test('options request attendance only and return a committed resume stamp', () => {
 const body = options('TEST01', '123');
 assert.match(body, /^GET OPTION FROM: TEST01\n/); assert.match(body, /ATTLOGStamp=123/);
 assert.match(body, /TransFlag=TransData AttLog/); assert.doesNotMatch(body, /EnrollUser|BioPhoto|FP/);
 assert.match(body, /TimeZone=6/); assert.match(body, /ServerVer=2.2.14/);
});
test('HTTP protocol checks approved registration first, commits before ack, supports polling and rejects unknown routes', async t => {
 const calls = [], logs = []; let fail = false, denied = false;
 const server = createReceiver(async input => { calls.push(input); if (denied) throw new ProtocolError(403, 'Unregistered device'); if (fail && input.p_action === 'upload') throw Error('private database error'); return { stamp: '123' }; }, entry => logs.push(entry));
 server.listen(0, '127.0.0.1'); await new Promise(resolve => server.once('listening', resolve));
 t.after(() => server.close());
 const base = `http://127.0.0.1:${server.address().port}`;
 const request = (path, init = {}) => fetch(base + path, { ...init, headers: { 'x-adms-source': '203.0.113.10', ...init.headers } });
 let response = await request('/iclock/cdata?SN=TEST01&options=all'); assert.equal(response.status, 200); assert(response.headers.get('content-length')); assert.match(await response.text(), /Stamp=123/);
 response = await request('/iclock/cdata.aspx?SN=TEST01&table=ATTLOG&Stamp=456', { method: 'POST', body: line });
 assert.equal(response.status, 200); assert.equal(await response.text(), 'OK: 1');
 assert.equal(calls.at(-1).p_stamp, '456'); assert.equal(calls.at(-1).p_records.length, 1);
 fail = true;
 response = await request('/iclock/cdata?SN=TEST01&table=ATTLOG', { method: 'POST', body: line }); assert.equal(response.status, 503); assert.equal(await response.text(), 'RETRY'); fail = false;
 for (const path of ['getrequest', 'ping', 'devicecmd']) { response = await request(`/iclock/${path}?SN=TEST01`); assert.equal(await response.text(), 'OK'); }
 const count = calls.length;
 response = await request('/iclock/cdata?SN=TEST01&table=OPERLOG', { method: 'POST', body: 'FP PIN=1 Template=private' });
 assert.equal(await response.text(), 'OK'); assert.equal(calls.length, count + 1); assert.equal(calls.at(-1).p_action, 'heartbeat');
 response = await request('/iclock/cdata?SN=TEST01&table=rtlog', { method: 'POST', body: 'unsupported access-control transaction' }); assert.equal(response.status, 422);
 denied = true;
 response = await request('/iclock/cdata?SN=UNKNOWN&table=ATTLOG', { method: 'POST', body: line }); assert.equal(response.status, 403); denied = false;
 response = await request('/iclock/cdata?SN=', { headers: { authorization: '' } }); assert.equal(response.status, 403);
 response = await request('/iclock/ping?SN=TEST01', { headers: { 'x-adms-source': '203.0.113.99' } }); assert.equal(response.status, 200);
 assert(!JSON.stringify(logs).includes('a'.repeat(64)));
 response = await request('/iclock/unknown?SN=TEST01'); assert.equal(response.status, 404);
 response = await request('/iclock/cdata?SN=TEST01&table=ATTLOG', { method: 'POST', body: 'x'.repeat(512 * 1024 + 1) }); assert.equal(response.status, 413);
 assert(!JSON.stringify(logs).includes('private')); assert(!JSON.stringify(logs).includes('2026-10-29'));
});
