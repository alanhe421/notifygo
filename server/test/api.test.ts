import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createApp } from '../src/app.ts';
import { database } from '../src/database.ts';
import { callbackSchema } from '../src/domain.ts';
import type { Push } from '../src/apns.ts';

const config = () => callbackSchema.parse({ name: 'Sales', tags: ['Revenue'], rules: [{ id: 'first', name: 'Default', priority: 1, conditions: [], template: { title: '{{title}}', body: '{{body}}', badge: 'increment' } }] });
async function setup(send?: (push: Push) => Promise<void>) {
  const db = database(':memory:');
  const pushes: Push[] = [];
  const app = createApp({ db, publicURL: 'https://notify.example.com', roots: [readFileSync(new URL('../certs/AppleRootCA-G3.cer', import.meta.url))], send: async push => { await send?.(push); pushes.push(push); } });
  const installation = (await app.inject({ method: 'POST', url: '/v1/installations', payload: {} })).json();
  const headers = { authorization: `Bearer ${installation.token}` };
  await app.inject({ method: 'PUT', url: '/v1/device', headers, payload: { token: 'a'.repeat(64), environment: 'development' } });
  const create = async (body = config()) => {
    const response = await app.inject({ method: 'POST', url: '/v1/callbacks', headers, payload: body });
    assert.equal(response.statusCode, 201, response.body);
    return response.json();
  };
  return { app, db, headers, pushes, create, close: async () => { await app.close(); db.close(); } };
}

test('create, edit, list, GET/POST, history, pause, rotate and delete', async () => {
  const f = await setup();
  try {
    const c = await f.create();
    const callbackURL = new URL(c.callbackURL).pathname;
    assert.equal((await f.app.inject({ method: 'POST', url: callbackURL, payload: { title: 'Sale', body: '9.99 USD' } })).json().status, 'sent');
    assert.equal((await f.app.inject(`${callbackURL}?title=Renewal&body=Paid`)).statusCode, 200);
    assert.deepEqual(f.pushes.map(p => p.badge), [1, 2]);
    const history = (await f.app.inject({ url: `/v1/callbacks/${c.id}/history`, headers: f.headers })).json().events;
    assert.equal(history[0].status, 'sent');
    assert.equal(history[0].source.tags[0], 'Revenue');
    assert.equal(history[0].notification.title, 'Renewal');
    const listing = (await f.app.inject({ url: '/v1/callbacks', headers: f.headers })).json();
    assert.equal(listing.callbacks[0].callbackURL, undefined);
    assert.equal(JSON.stringify(listing).includes('secret'), false);
    await f.app.inject({ method: 'PUT', url: `/v1/callbacks/${c.id}`, headers: f.headers, payload: { ...c, enabled: false } });
    assert.equal((await f.app.inject(callbackURL)).statusCode, 410);
    await f.app.inject({ method: 'PUT', url: `/v1/callbacks/${c.id}`, headers: f.headers, payload: c });
    const rotated = (await f.app.inject({ method: 'POST', url: `/v1/callbacks/${c.id}/rotate`, headers: f.headers, payload: {} })).json();
    assert.equal((await f.app.inject(callbackURL)).statusCode, 404);
    assert.equal((await f.app.inject(`${new URL(rotated.callbackURL).pathname}?title=New&body=Key`)).statusCode, 200);
    await f.app.inject({ method: 'DELETE', url: `/v1/callbacks/${c.id}`, headers: f.headers });
    assert.equal((await f.app.inject(new URL(rotated.callbackURL).pathname)).statusCode, 404);
    assert.equal(f.db.prepare('SELECT count(*) AS n FROM events').get()!.n, 0);
  } finally { await f.close(); }
});

test('all management APIs isolate installations and require authentication', async () => {
  const f = await setup();
  try {
    const c = await f.create();
    const second = (await f.app.inject({ method: 'POST', url: '/v1/installations', payload: {} })).json();
    const headers = { authorization: `Bearer ${second.token}` };
    for (const [method, suffix, payload] of [['GET', '/history', undefined], ['POST', '/rotate', {}], ['POST', '/test', {}], ['PUT', '', config()], ['DELETE', '', undefined]] as const) {
      const response = await f.app.inject({ method, url: `/v1/callbacks/${c.id}${suffix}`, headers, payload });
      assert.equal(response.statusCode, 404, response.body);
    }
    assert.deepEqual((await f.app.inject({ url: '/v1/callbacks', headers })).json().callbacks, []);
    assert.equal((await f.app.inject({ url: '/v1/callbacks' })).statusCode, 401);
    assert.equal((await f.app.inject({ method: 'POST', url: `/c/${c.id}/wrong`, payload: {} })).statusCode, 404);
  } finally { await f.close(); }
});

test('preview and delivery share rule selection; preview never sends', async () => {
  const f = await setup();
  try {
    const c = await f.create();
    const payload = { title: 'Sale', body: 'Paid' };
    const preview = await f.app.inject({ method: 'POST', url: '/v1/preview', headers: f.headers, payload: { config: c, payload } });
    assert.equal(preview.statusCode, 200);
    assert.equal(f.pushes.length, 0);
    const sent = await f.app.inject({ method: 'POST', url: `/v1/callbacks/${c.id}/test`, headers: f.headers, payload });
    assert.equal(sent.statusCode, 200, sent.body);
    assert.deepEqual(sent.json().notification, preview.json().notification);
    assert.equal(sent.json().matchedRuleId, preview.json().matchedRuleId);
  } finally { await f.close(); }
});

test('concurrent callbacks serialize installation badge and failed delivery does not increment', async () => {
  let failed = true;
  const f = await setup(async () => { if (failed) throw new Error('APNs unavailable'); });
  try {
    const a = await f.create(), b = await f.create();
    const send = (id: string) => f.app.inject({ method: 'POST', url: `/v1/callbacks/${id}/test`, headers: f.headers, payload: { title: 'ok', body: '' } });
    assert.equal((await send(a.id)).statusCode, 502);
    failed = false;
    const results = await Promise.all([send(a.id), send(b.id), send(a.id)]);
    assert.deepEqual(results.map(r => r.statusCode), [200, 200, 200]);
    assert.deepEqual(f.pushes.map(p => p.badge), [1, 2, 3]);
    for (const [mode, value] of [['set', 9], ['unchanged', undefined], ['clear', 0], ['increment', 1]] as const) {
      const c = config(); c.rules[0].template.badge = mode; c.rules[0].template.badgeValue = 9;
      await f.app.inject({ method: 'PUT', url: `/v1/callbacks/${a.id}`, headers: f.headers, payload: c });
      await send(a.id);
      assert.equal(f.pushes.at(-1)?.badge, value);
    }
  } finally { await f.close(); }
});

test('idempotency survives history truncation and failed requests can retry', async () => {
  let fail = true;
  const f = await setup(async () => { if (fail) throw new Error('Temporary'); });
  try {
    const c = await f.create();
    const send = (key: string) => f.app.inject({ method: 'POST', url: new URL(c.callbackURL).pathname, headers: { 'idempotency-key': key }, payload: { title: 'ok', body: '' } });
    assert.equal((await send('original')).statusCode, 502);
    fail = false;
    assert.equal((await send('original')).json().status, 'sent');
    for (let i = 0; i < 51; i++) assert.equal((await send(String(i))).json().status, 'sent');
    assert.equal((await send('original')).json().status, 'duplicate');
    assert.equal(f.pushes.length, 52);
    assert.equal(f.db.prepare('SELECT count(*) AS n FROM events').get()!.n, 50);
  } finally { await f.close(); }
});

test('rejects forged Apple signedPayload; only explicit preview can accept unsigned Apple sample', async () => {
  const f = await setup();
  try {
    const c = config(); c.parser = 'apple'; c.appleBundleId = 'com.example.app';
    c.rules[0].template.title = '{{type}}'; c.rules[0].template.body = '{{amount}} {{currency}}';
    const saved = await f.create(c);
    const sample = { type: 'DID_RENEW', amount: 9.99, currency: 'USD' };
    const preview = await f.app.inject({ method: 'POST', url: '/v1/preview', headers: f.headers, payload: { config: c, payload: sample, appleSample: true } });
    assert.equal(preview.json().sampleOnly, true);
    assert.equal(preview.json().verified, false);
    assert.equal(preview.json().notification.body, '9.99 USD');
    for (const payload of [sample, { signedPayload: 'e30.e30.ZmFrZQ' }, { ...sample, appleSample: true }]) {
      const response = await f.app.inject({ method: 'POST', url: new URL(saved.callbackURL).pathname, payload });
      assert.equal(response.statusCode, 422, response.body);
    }
    assert.equal(f.pushes.length, 0);
    assert.equal(f.db.prepare('SELECT count(*) AS n FROM events').get()!.n, 0);
    c.appleEnvironment = 'Production';
    assert.equal((await f.app.inject({ method: 'POST', url: '/v1/callbacks', headers: f.headers, payload: c })).statusCode, 400);
  } finally { await f.close(); }
});

test('invalid payloads, missing template fields and oversized bodies cannot send', async () => {
  const f = await setup();
  try {
    const c = await f.create();
    const url = new URL(c.callbackURL).pathname;
    assert.equal((await f.app.inject({ method: 'POST', url, payload: [] })).statusCode, 400);
    assert.equal((await f.app.inject({ method: 'POST', url, payload: { title: 'x' } })).json().status, 'missing_fields');
    assert.equal((await f.app.inject({ method: 'POST', url, payload: { title: 'x'.repeat(70000) } })).statusCode, 413);
    assert.equal(f.pushes.length, 0);
  } finally { await f.close(); }
});
