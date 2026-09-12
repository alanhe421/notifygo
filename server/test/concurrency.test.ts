import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createApp } from '../src/app.ts';
import { database } from '../src/database.ts';
import { generateKeyPairSync } from 'node:crypto';
import { createAPNsSender } from '../src/apns.ts';
import { callbackSchema } from '../src/domain.ts';

const config = callbackSchema.parse({ name: 'Test', rules: [{ id: 'a', name: 'A', priority: 1, conditions: [], template: { title: 'ok', body: 'body' } }] });

test('rotation waits for in-flight delivery; no old-key delivery starts after reset returns', async () => {
  const db = database(':memory:');
  let release!: () => void, started!: () => void;
  const gate = new Promise<void>(resolve => { release = resolve; });
  const signal = new Promise<void>(resolve => { started = resolve; });
  let pushes = 0;
  const app = createApp({ db, publicURL: 'https://example.com', roots: [], send: async () => { started(); await gate; pushes++; } });
  try {
    const account = (await app.inject({ method: 'POST', url: '/v1/installations', payload: {} })).json();
    const headers = { authorization: `Bearer ${account.token}` };
    await app.inject({ method: 'PUT', url: '/v1/device', headers, payload: { token: 'a'.repeat(64), environment: 'development' } });
    const callback = (await app.inject({ method: 'POST', url: '/v1/callbacks', headers, payload: config })).json();
    const url = new URL(callback.callbackURL).pathname;
    const sending = app.inject({ method: 'POST', url, payload: {} });
    await signal;
    const rotating = app.inject({ method: 'POST', url: `/v1/callbacks/${callback.id}/rotate`, headers, payload: {} });
    release();
    assert.equal((await sending).statusCode, 200);
    assert.equal((await rotating).statusCode, 200);
    assert.equal((await app.inject({ method: 'POST', url, payload: {} })).statusCode, 404);
    assert.equal(pushes, 1);
  } finally { release(); await app.close(); db.close(); }
});

test('APNs rejects oversized UTF-8 payload before network access', async () => {
  const pair = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const sender = createAPNsSender({ teamId: 'TEST', keyId: 'TEST', topic: 'cn.aol.NotifyGo', privateKey: pair.privateKey.export({ type: 'pkcs8', format: 'pem' }).toString() });
  await assert.rejects(sender({
    callback: config, callbackId: 'a', deviceToken: 'a'.repeat(64), environment: 'development', eventId: 'test',
    notification: { ...config.rules[0].template, body: '中'.repeat(1500) }
  }), /payload limit/);
});
