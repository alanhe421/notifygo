import { test } from 'node:test';
import assert from 'node:assert/strict';
import { callbackSchema, evaluate, fieldAt, matches } from '../src/domain.ts';
import { apnsPayload } from '../src/apns.ts';
import { normalizeApple } from '../src/apple.ts';

export const config = () => callbackSchema.parse({ name: 'Sales', rules: [{
  id: 'default', name: 'Default', priority: 100, conditions: [],
  template: { title: '{{title}}', body: '{{body}}', badge: 'increment' }
}] });

test('Apple normalization converts milliunits, preserves currency/storefront and handles events without transactions', () => {
  const fields = normalizeApple('Production', { notificationType: 'DID_RENEW', notificationUUID: 'event' }, {
    productId: 'premium', price: 9990, currency: 'USD', storefront: 'USA'
  });
  assert.equal(fields.amount, 9.99);
  assert.equal(fields.country, 'USA');
  assert.equal(fields.product, 'premium');
  assert.equal(fields.environment, 'Production');
  assert.equal(normalizeApple('Sandbox', { notificationType: 'TEST' }).amount, undefined);
  assert.equal(normalizeApple('Sandbox', {}, { price: 0 }).amount, 0);
});

test('maps nested fields, renders scalars, and encodes only URL variables', () => {
  const c = config();
  c.mappings = [{ field: 'product', source: 'event.product' }];
  c.rules[0].template = { ...c.rules[0].template, title: '{{mapped.product}}', body: '{{amount}} {{currency}}', url: 'https://example.com/item/{{mapped.product}}?currency={{currency}}' };
  const result = evaluate(c, { event: { product: 'A/B & C' }, amount: 9.99, currency: 'USD' });
  assert.equal(result.notification?.title, 'A/B & C');
  assert.equal(result.notification?.body, '9.99 USD');
  assert.equal(result.notification?.url, 'https://example.com/item/A%2FB%20%26%20C?currency=USD');
});

test('all five operators preserve types and missing fields never match', () => {
  const fields = { amount: 10, name: 'Monthly Premium', enabled: false };
  for (const [field, op, value] of [['amount', 'eq', 10], ['amount', 'ne', 2], ['name', 'contains', 'Premium'], ['amount', 'gt', 9], ['amount', 'lt', 11], ['enabled', 'eq', false]] as const)
    assert.equal(matches(fields, { field, op, value }), true);
  assert.equal(matches(fields, { field: 'amount', op: 'eq', value: '10' }), false);
  assert.equal(matches(fields, { field: 'missing', op: 'ne', value: 'x' }), false);
  assert.equal(fieldAt({}, 'constructor.name'), undefined);
  assert.equal(fieldAt({ list: [{ name: 'ok' }] }, 'list.0.name'), 'ok');
});

test('first matching priority wins, suppression stops fallback, and AND is required', () => {
  const c = config();
  c.rules.unshift({ ...c.rules[0], id: 'suppress', priority: 10, send: false, conditions: [{ field: 'environment', op: 'eq', value: 'Sandbox' }, { field: 'amount', op: 'gt', value: 0 }] });
  assert.equal(evaluate(c, { environment: 'Sandbox', amount: 2 }).status, 'suppressed');
  assert.equal(evaluate(c, { environment: 'Sandbox', amount: 0, title: 'ok', body: '' }).matchedRuleId, 'default');
  c.rules[0].enabled = false;
  assert.equal(evaluate(c, { environment: 'Sandbox', amount: 2, title: 'ok', body: '' }).matchedRuleId, 'default');
  c.enabled = false;
  assert.equal(evaluate(c, { title: 'ok', body: '' }).notification, null);
});

test('equal priorities tie-break by ID, not input order', () => {
  const c = config();
  c.rules.push({ ...c.rules[0], id: 'a', send: false });
  assert.equal(evaluate(c, {}).matchedRuleId, 'a');
});

test('missing fields suppress delivery and are reported', () => {
  const result = evaluate(config(), { title: 'ok' });
  assert.equal(result.notification, null);
  assert.equal(result.status, 'missing_fields');
  assert.deepEqual(result.missing, ['body']);
});

test('rejects prototype aliases, duplicate rules, invalid numeric comparisons and unsafe URL schemes', () => {
  const c = config();
  assert.equal(callbackSchema.safeParse({ ...c, mappings: [{ field: '__proto__', source: 'name' }] }).success, false);
  assert.equal(callbackSchema.safeParse({ ...c, rules: [c.rules[0], c.rules[0]] }).success, false);
  c.rules[0].conditions = [{ field: 'amount', op: 'gt', value: '9' }];
  assert.equal(callbackSchema.safeParse(c).success, false);
  c.rules[0].conditions = [];
  c.rules[0].template.url = 'javascript:alert(1)';
  assert.equal(callbackSchema.safeParse(c).success, false);
});

test('APNs payload keeps source metadata separate and honors sound, level and badge', () => {
  const c = config();
  const n = { ...c.rules[0].template, title: 'Hello', body: 'World', sound: 'none' as const, level: 'passive' as const };
  const push = { callback: c, callbackId: 'callback', deviceToken: 'a'.repeat(64), environment: 'development', notification: n, eventId: 'event' };
  assert.equal('badge' in apnsPayload(push).aps, false);
  const p = apnsPayload({ ...push, badge: 0 });
  assert.equal(p.aps.badge, 0);
  assert.equal('sound' in p.aps, false);
  assert.equal(p.aps['interruption-level'], 'passive');
  assert.equal(p.aps['mutable-content'], 1);
  assert.equal(p.notifygo.name, 'Sales');
});
