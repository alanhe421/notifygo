import { SELF, env } from 'cloudflare:test';
import { expect, test } from 'vitest';

let ip = 0;
const call = (path: string, init: RequestInit & { auth?: string } = {}) => {
  const headers = new Headers(init.headers);
  headers.set('CF-Connecting-IP', `10.0.0.${++ip}`);
  headers.set('Content-Type', 'application/json');
  if (init.auth) headers.set('Authorization', `Bearer ${init.auth}`);
  return SELF.fetch(`https://notifygo.test${path}`, { ...init, headers });
};
const post = (path: string, body: unknown, auth?: string) => call(path, { method: 'POST', body: JSON.stringify(body), auth });
const install = async () => (await post('/v1/installations', {})).json<{ id: string; token: string; pushURL: string }>();
const callback = (name: string) => ({ name, rules: [{ id: 'all', name: 'All', priority: 0, conditions: [], template: { title: '{{title}}', body: '' } }] });
const lookup = (seed: string) => seed.padEnd(64, '0');

test('migration hands the installation, its callbacks and push URL to the redeeming device', async () => {
  const old = await install(), fresh = await install();
  expect((await call('/v1/device', { method: 'PUT', auth: old.token, body: JSON.stringify({ token: 'a'.repeat(64), environment: 'development' }) })).status).toBe(200);
  const createdResponse = await post('/v1/callbacks', callback('Sales'), old.token);
  expect(createdResponse.status).toBe(201);
  const created = await createdResponse.json<{ id: string }>();

  expect((await post('/v1/transfers', { lookup: lookup('1'), payload: 'Y2lwaGVy' }, old.token)).status).toBe(201);
  expect(await (await call('/v1/transfers', { auth: old.token })).json()).toMatchObject({ pending: true });
  expect((await post('/v1/transfers/redeem', { lookup: lookup('1') }, old.token)).status).toBe(409);

  const redeemed = await post('/v1/transfers/redeem', { lookup: lookup('1') }, fresh.token);
  expect(redeemed.status).toBe(200);
  const moved = await redeemed.json<{ id: string; token: string; payload: string }>();
  expect(moved).toMatchObject({ id: old.id, payload: 'Y2lwaGVy' });

  // Single use; old credential and the redeeming device's empty installation are gone.
  expect((await post('/v1/transfers/redeem', { lookup: lookup('1') }, fresh.token)).status).toBe(404);
  expect((await call('/v1/callbacks', { auth: old.token })).status).toBe(401);
  expect((await call('/v1/callbacks', { auth: fresh.token })).status).toBe(401);
  expect(await env.DB.prepare('SELECT 1 FROM installations WHERE id = ?').bind(fresh.id).first()).toBeNull();

  const listing = await (await call('/v1/callbacks', { auth: moved.token })).json<{ callbacks: { id: string }[] }>();
  expect(listing.callbacks.map(c => c.id)).toEqual([created.id]);
  const row = await env.DB.prepare('SELECT device_token, device_key_hash FROM installations WHERE id = ?').bind(old.id).first<{ device_token: string | null; device_key_hash: string }>();
  expect(row?.device_token).toBeNull();
  expect(row?.device_key_hash).toBeTruthy();
  expect((await call('/v1/device', { method: 'PUT', auth: moved.token, body: JSON.stringify({ token: 'b'.repeat(64), environment: 'development' }) })).status).toBe(200);
});

test('migration codes expire, can be cancelled and never overwrite a device with callbacks', async () => {
  const old = await install(), busy = await install();
  await post('/v1/callbacks', callback('Existing'), busy.token);
  await post('/v1/transfers', { lookup: lookup('2'), payload: 'eA==' }, old.token);
  expect((await post('/v1/transfers/redeem', { lookup: lookup('2') }, busy.token)).status).toBe(409);

  expect((await call('/v1/transfers', { method: 'DELETE', auth: old.token })).status).toBe(200);
  expect((await post('/v1/transfers/redeem', { lookup: lookup('2') })).status).toBe(404);

  await post('/v1/transfers', { lookup: lookup('3'), payload: 'eA==' }, old.token);
  await env.DB.prepare('UPDATE transfers SET expires_at = ? WHERE owner = ?').bind(new Date(Date.now() - 1000).toISOString(), old.id).run();
  expect((await post('/v1/transfers/redeem', { lookup: lookup('3') })).status).toBe(404);
  expect((await post('/v1/transfers', { lookup: 'nothex', payload: 'eA==' }, old.token)).status).toBe(400);
  expect((await call('/v1/callbacks', { auth: old.token })).status).toBe(200);
});
