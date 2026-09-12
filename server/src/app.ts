import Fastify from 'fastify';
import { randomUUID, timingSafeEqual } from 'node:crypto';
import type { DatabaseSync } from 'node:sqlite';
import { z, ZodError } from 'zod';
import { callbackSchema, evaluate } from './domain.ts';
import type { Callback, Fields } from './domain.ts';
import { hash, token } from './database.ts';
import { parseApple } from './apple.ts';
import type { Push } from './apns.ts';

type Owner = { id: string; device_token: string | null; environment: string; badge: number };
type Row = { id: string; owner: string; secret_hash: string; config: string };
export function createApp(options: {
  db: DatabaseSync; publicURL: string; roots: Buffer[]; send: (push: Push) => Promise<void>;
  trustedProxy?: string[];
}) {
  const { db } = options;
  const app = Fastify({ logger: false, bodyLimit: 65536, requestTimeout: 15000, trustProxy: options.trustedProxy ?? false });
  const locks = new Map<string, Promise<unknown>>();
  const pendingByOwner = new Map<string, number>();
  let pendingTotal = 0;
  // One installation's badge, config mutations and deliveries are serialized, including rotation.
  async function locked<T>(owner: string, fn: () => Promise<T>): Promise<T> {
    if (pendingTotal >= 100 || (pendingByOwner.get(owner) ?? 0) >= 8)
      throw Object.assign(new Error('Service busy; retry shortly'), { statusCode: 503 });
    pendingTotal++;
    pendingByOwner.set(owner, (pendingByOwner.get(owner) ?? 0) + 1);
    const previous = locks.get(owner) ?? Promise.resolve();
    const next = previous.catch(() => {}).then(fn);
    locks.set(owner, next);
    try { return await next; } finally {
      pendingTotal--;
      const remaining = pendingByOwner.get(owner)! - 1;
      if (remaining) pendingByOwner.set(owner, remaining); else pendingByOwner.delete(owner);
      if (locks.get(owner) === next) locks.delete(owner);
    }
  }
  const buckets = new Map<string, { count: number; expiry: number }>();
  function limit(key: string, max: number) {
    const now = Date.now();
    for (const [k, b] of buckets) if (b.expiry < now) buckets.delete(k);
    const bucket = buckets.get(key) ?? { count: 0, expiry: now + 60000 };
    if (buckets.size >= 10000 && !buckets.has(key)) throw Object.assign(new Error('Service busy'), { statusCode: 503 });
    buckets.set(key, bucket);
    if (++bucket.count > max) throw Object.assign(new Error('Too many requests; retry in a minute'), { statusCode: 429 });
  }
  function owner(auth?: string): Owner {
    const result = auth?.startsWith('Bearer ') && db.prepare('SELECT * FROM installations WHERE auth_hash = ?').get(hash(auth.slice(7)));
    if (!result) throw Object.assign(new Error('Authentication required'), { statusCode: 401 });
    limit(`owner:${result.id}`, 120);
    return result as Owner;
  }
  function callback(id: string, ownerId: string): Row {
    const row = db.prepare('SELECT * FROM callbacks WHERE id = ? AND owner = ?').get(id, ownerId);
    if (!row) throw Object.assign(new Error('Callback not found'), { statusCode: 404 });
    return row as Row;
  }
  const view = (row: Row) => ({ id: row.id, ...JSON.parse(row.config) });
  const url = (id: string, secret: string) => `${options.publicURL}/c/${id}/${secret}`;
  app.setErrorHandler((error, _req, reply) => {
    const status = error instanceof ZodError ? 400 : (error as { statusCode?: number }).statusCode ?? 500;
    reply.code(status).send({ error: status === 500 ? 'Request could not be completed' : status === 400 ? 'Invalid request or callback configuration' : (error as Error).message });
  });
  app.addHook('onRequest', async (req, reply) => {
    reply.header('Cache-Control', 'no-store');
    limit(`ip:${req.ip}`, 300);
  });
  app.get('/health', async () => ({ status: 'ok' }));
  app.post('/v1/installations', async (req, reply) => {
    limit(`signup:${req.ip}`, 5);
    const id = randomUUID(), authToken = token();
    db.prepare('INSERT INTO installations(id, auth_hash) VALUES (?, ?)').run(id, hash(authToken));
    return reply.code(201).send({ id, token: authToken });
  });
  app.put('/v1/device', async req => {
    const o = owner(req.headers.authorization);
    const body = z.object({ token: z.string().regex(/^[a-f0-9]{64,200}$/), environment: z.enum(['development', 'production']) }).parse(req.body);
    return locked(o.id, async () => {
      db.prepare('UPDATE installations SET device_token = ?, environment = ? WHERE id = ?').run(body.token, body.environment, o.id);
      return { ok: true };
    });
  });
  app.get('/v1/callbacks', async req => {
    const o = owner(req.headers.authorization);
    return { callbacks: (db.prepare('SELECT * FROM callbacks WHERE owner = ? ORDER BY rowid DESC').all(o.id) as Row[]).map(view) };
  });
  app.post('/v1/callbacks', async (req, reply) => {
    const o = owner(req.headers.authorization), config = callbackSchema.parse(req.body);
    return locked(o.id, async () => {
      const count = db.prepare('SELECT count(*) AS n FROM callbacks WHERE owner = ?').get(o.id)!;
      if (Number(count.n) >= 20) return reply.code(409).send({ error: 'Maximum 20 callbacks' });
      const id = randomUUID(), secret = token();
      db.prepare('INSERT INTO callbacks VALUES (?, ?, ?, ?)').run(id, o.id, hash(secret), JSON.stringify(config));
      return reply.code(201).send({ id, ...config, callbackURL: url(id, secret) });
    });
  });
  app.put<{ Params: { id: string } }>('/v1/callbacks/:id', async req => {
    const o = owner(req.headers.authorization), config = callbackSchema.parse(req.body);
    return locked(o.id, async () => {
      callback(req.params.id, o.id);
      db.prepare('UPDATE callbacks SET config = ? WHERE id = ?').run(JSON.stringify(config), req.params.id);
      return { id: req.params.id, ...config };
    });
  });
  app.delete<{ Params: { id: string } }>('/v1/callbacks/:id', async req => {
    const o = owner(req.headers.authorization);
    return locked(o.id, async () => {
      callback(req.params.id, o.id);
      db.prepare('DELETE FROM callbacks WHERE id = ?').run(req.params.id);
      return { ok: true };
    });
  });
  app.post<{ Params: { id: string } }>('/v1/callbacks/:id/rotate', async req => {
    const o = owner(req.headers.authorization);
    return locked(o.id, async () => {
      callback(req.params.id, o.id);
      const secret = token();
      db.prepare('UPDATE callbacks SET secret_hash = ? WHERE id = ?').run(hash(secret), req.params.id);
      return { callbackURL: url(req.params.id, secret) };
    });
  });
  app.get<{ Params: { id: string } }>('/v1/callbacks/:id/history', async req => {
    const o = owner(req.headers.authorization);
    callback(req.params.id, o.id);
    const events = db.prepare('SELECT * FROM events WHERE callback_id = ? AND created_at >= ? ORDER BY rowid DESC LIMIT 50')
      .all(req.params.id, new Date(Date.now() - 30 * 86400000).toISOString());
    return { events: events.map(e => ({ ...JSON.parse(String(e.detail)), id: e.id, createdAt: e.created_at, status: e.status })) };
  });
  async function fields(config: Callback, payload: Fields) {
    if (config.parser !== 'apple') return payload;
    try { return await parseApple(config, payload, options.roots); }
    catch { throw Object.assign(new Error('Apple signature or app identity verification failed'), { statusCode: 422 }); }
  }
  const payloadSchema = z.record(z.string(), z.unknown());
  app.post('/v1/preview', async req => {
    const o = owner(req.headers.authorization);
    const body = z.object({ config: callbackSchema, payload: payloadSchema, appleSample: z.boolean().default(false) }).parse(req.body);
    // Unverified samples are allowed only in this authenticated, non-delivering preview endpoint.
    return locked(o.id, async () => {
      const parsed = body.config.parser === 'apple' && body.appleSample ? body.payload : await fields(body.config, body.payload);
      return { ...evaluate(body.config, parsed), verified: body.config.parser === 'apple' && !body.appleSample, sampleOnly: body.appleSample };
    });
  });
  async function deliver(row: Row, payload: Fields, test: boolean, dedup?: string) {
    const config = callbackSchema.parse(JSON.parse(row.config));
    const parsed = await fields(config, payload);
    const rawKey = test ? undefined : config.parser === 'apple' ? parsed.notificationUUID : dedup;
    const key = typeof rawKey === 'string' ? `${config.parser}:${rawKey}` : undefined;
    db.prepare('DELETE FROM receipts WHERE created_at < ?').run(new Date(Date.now() - 30 * 86400000).toISOString());
    if (typeof key === 'string') {
      const previous = db.prepare('SELECT 1 FROM receipts WHERE callback_id = ? AND dedup_key = ?').get(row.id, key);
      if (previous) return { status: 'duplicate' };
      db.prepare('DELETE FROM events WHERE callback_id = ? AND dedup_key = ?').run(row.id, key);
    }
    const result = evaluate(config, parsed);
    const id = randomUUID();
    const detail = { ...result, source: { name: config.name, symbol: config.symbol, emoji: config.emoji, imageURL: config.imageURL, color: config.color, tags: config.tags }, test };
    const createdAt = new Date().toISOString();
    db.prepare('INSERT INTO events VALUES (?, ?, ?, ?, ?, ?)').run(id, row.id, createdAt, result.notification ? 'sending' : result.status, JSON.stringify(detail), typeof key === 'string' ? key : null);
    // Bounded retention; raw signedPayload/device tokens are never stored in history.
    db.prepare('DELETE FROM events WHERE callback_id = ? AND id NOT IN (SELECT id FROM events WHERE callback_id = ? ORDER BY rowid DESC LIMIT 50)').run(row.id, row.id);
    db.prepare("DELETE FROM events WHERE created_at < ?").run(new Date(Date.now() - 30 * 86400000).toISOString());
    const recordReceipt = () => {
      if (key) db.prepare('INSERT INTO receipts VALUES (?, ?, ?)').run(row.id, key, createdAt);
    };
    if (!result.notification) { recordReceipt(); return { ...result, id }; }
    const o = db.prepare('SELECT * FROM installations WHERE id = ?').get(row.owner) as Owner;
    let badge: number | undefined;
    switch (result.notification.badge) {
      case 'set': badge = result.notification.badgeValue; break;
      case 'clear': badge = 0; break;
      case 'increment': badge = Math.min(99999, o.badge + 1); break;
    }
    try {
      if (!o.device_token) throw new Error('Allow notifications and register this device first');
      await options.send({ deviceToken: o.device_token, environment: o.environment, callback: config, callbackId: row.id, notification: result.notification, badge, eventId: id });
      db.prepare('UPDATE events SET status = ? WHERE id = ?').run('sent', id);
      if (badge !== undefined) db.prepare('UPDATE installations SET badge = ? WHERE id = ?').run(badge, o.id);
      recordReceipt();
      return { ...result, id, status: 'sent' };
    } catch {
      db.prepare('UPDATE events SET status = ? WHERE id = ?').run('failed', id);
      throw Object.assign(new Error('Push delivery failed; check device registration and service configuration'), { statusCode: 502 });
    }
  }
  app.post<{ Params: { id: string } }>('/v1/callbacks/:id/test', async req => {
    const o = owner(req.headers.authorization), payload = payloadSchema.parse(req.body);
    limit(`push:${o.id}`, 60);
    return locked(o.id, async () => deliver(callback(req.params.id, o.id), payload, true));
  });
  app.route<{ Params: { id: string; secret: string } }>({
    method: ['GET', 'POST'], url: '/c/:id/:secret', handler: async (req, reply) => {
      const initial = db.prepare('SELECT * FROM callbacks WHERE id = ?').get(req.params.id) as Row | undefined;
      if (!initial) return reply.code(404).send({ error: 'Callback unavailable' });
      limit(`push:${initial.owner}`, 60);
      return locked(initial.owner, async () => {
        const row = db.prepare('SELECT * FROM callbacks WHERE id = ?').get(req.params.id) as Row | undefined;
        if (!row || !timingSafeEqual(Buffer.from(row.secret_hash), Buffer.from(hash(req.params.secret))))
          return reply.code(404).send({ error: 'Callback unavailable' });
        if (!JSON.parse(row.config).enabled) return reply.code(410).send({ error: 'Callback disabled' });
        const payload = payloadSchema.parse(req.method === 'GET' ? req.query : req.body);
        const dedup = z.string().min(1).max(128).optional().parse(req.headers['idempotency-key']);
        const result = await deliver(row, payload, false, dedup);
        return { status: result.status };
      });
    }
  });
  return app;
}
