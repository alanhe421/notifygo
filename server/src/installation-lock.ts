import { DurableObject } from 'cloudflare:workers';
import { z } from 'zod';
import { callbackSchema, evaluate } from './domain.ts';
import { templateSchema } from './domain.ts';
import type { Callback, Fields } from './domain.ts';
import { hash, token, secretsMatch } from './crypto.ts';
import { parseApple } from './apple.ts';
import { createAPNsSender } from './apns.ts';
import rootCA from '../certs/AppleRootCA-G3.cer';
import type { DOEnv } from './env.ts';

type Owner = { id: string; auth_hash: string; device_token: string | null; environment: string; badge: number };
type Row = { id: string; owner: string; secret_hash: string; config: string };
type Result = { status: number; body: any };
const ok = (body: any, status = 200): Result => ({ status, body });
const fail = (status: number, message: string): Result => ({ status, body: { error: message } });
// Public RPC methods return a pre-serialized JSON string, not a Result object: Durable Object RPC
// return types must satisfy a Serializable<T> check that recurses through the type structurally, and
// an open type like Result's `any` body never bottoms out there (TS evaluates every branch of the
// check for `any`), which blows up type instantiation depth for every caller. A `string` return
// trivially satisfies the check, so callers JSON.parse the wire string themselves.
const wire = async (result: Result | Promise<Result>): Promise<string> => JSON.stringify(await result);
const payloadSchema = z.record(z.string(), z.unknown());

// One instance per installation (Durable Object id = installation id). All config mutations, badge
// changes and deliveries for that installation run through this single-threaded object, replacing the
// original process's in-memory per-owner Map lock with a guarantee that holds across Workers' many isolates.
// Internals use real (#-prefixed) private fields, not TypeScript's `private` keyword: only ECMAScript
// private members are excluded from the RPC surface the Durable Object stub type walks over `keyof`;
// a merely type-private method still shows up there and blows up type instantiation depth.
export class InstallationLock extends DurableObject<DOEnv> {
  #recovered = false;
  #pending = 0;
  #queue: Promise<unknown> = Promise.resolve();
  #pushBucket = { count: 0, expiry: 0 };
  #senderCache?: ReturnType<typeof createAPNsSender>;

  get #ownerId(): string {
    return this.ctx.id.name!;
  }
  #sender() {
    this.#senderCache ??= createAPNsSender({
      teamId: this.env.APNS_TEAM_ID, keyId: this.env.APNS_KEY_ID,
      privateKey: this.env.APNS_PRIVATE_KEY, topic: this.env.APNS_TOPIC
    });
    return this.#senderCache;
  }
  async #recover() {
    if (this.#recovered) return;
    this.#recovered = true;
    await this.env.DB.prepare(
      `UPDATE events SET status = 'failed' WHERE status = 'sending' AND callback_id IN (SELECT id FROM callbacks WHERE owner = ?)`
    ).bind(this.#ownerId).run();
  }
  #pushAllowed(max = 60): boolean {
    const now = Date.now();
    if (this.#pushBucket.expiry < now) this.#pushBucket = { count: 0, expiry: now + 60000 };
    return ++this.#pushBucket.count <= max;
  }
  async #guard(fn: () => Promise<Result>): Promise<Result> {
    await this.#recover();
    if (this.#pending >= 8) return fail(503, 'Service busy; retry shortly');
    this.#pending++;
    // Chained onto this instance's single queue, not just counted: JS's cooperative concurrency means
    // two concurrent RPC calls' handlers can otherwise interleave at their own await points (e.g. both
    // reading the same pre-increment badge before either writes it back), even though the Durable Object
    // itself only ever runs one JS callback at a time. This mirrors the original single-process design's
    // per-owner Map of chained promises, scoped to this DO instance (one instance = one owner already).
    const run = this.#queue.catch(() => {}).then(fn);
    this.#queue = run;
    try { return await run; } finally { this.#pending--; }
  }
  async #row(id: string): Promise<Row | null> {
    return this.env.DB.prepare('SELECT * FROM callbacks WHERE id = ? AND owner = ?').bind(id, this.#ownerId).first<Row>();
  }

  // authHash pins the update to the credential that was checked before queuing, so a registration
  // from a device that has just been migrated away cannot overwrite the new device's token.
  async setDevice(deviceToken: string, environment: string, authHash: string): Promise<string> {
    return wire(this.#guard(async () => {
      const result = await this.env.DB.prepare('UPDATE installations SET device_token = ?, environment = ? WHERE id = ? AND auth_hash = ?')
        .bind(deviceToken, environment, this.#ownerId, authHash).run();
      return result.meta.changes ? ok({ ok: true }) : fail(401, 'Authentication required');
    }));
  }
  // Hands this installation to a new device: the old credential and APNs registration stop working at once.
  async transferOwnership(authHash: string): Promise<string> {
    return wire(this.#guard(async () => {
      await this.env.DB.prepare('UPDATE installations SET auth_hash = ?, device_token = NULL, badge = 0 WHERE id = ?')
        .bind(authHash, this.#ownerId).run();
      return ok({ ok: true });
    }));
  }
  async directPush(notificationJson: string): Promise<string> {
    if (!this.#pushAllowed()) return wire(fail(429, 'Too many requests; retry in a minute'));
    const notification = templateSchema.parse(JSON.parse(notificationJson));
    return wire(this.#guard(async () => {
      const owner = await this.env.DB.prepare('SELECT * FROM installations WHERE id = ?').bind(this.#ownerId).first<Owner>();
      if (!owner?.device_token) return fail(502, 'Push delivery failed; check device registration and service configuration');
      let badge: number | undefined;
      switch (notification.badge) {
        case 'set': badge = notification.badgeValue; break;
        case 'clear': badge = 0; break;
        case 'increment': badge = Math.min(99999, owner.badge + 1); break;
      }
      const callback = callbackSchema.parse({
        name: 'Direct Push', symbol: 'paperplane.fill', rules: [{ id: 'direct', name: 'Direct', priority: 0, conditions: [], template: notification }]
      });
      try {
        await this.#sender()({ deviceToken: owner.device_token, environment: owner.environment, callback, callbackId: 'direct', notification, badge, eventId: crypto.randomUUID() });
        if (badge !== undefined) await this.env.DB.prepare('UPDATE installations SET badge = ? WHERE id = ?').bind(badge, this.#ownerId).run();
        return ok({ status: 'sent' });
      } catch (error) {
        console.error('Direct APNs delivery failed', error instanceof Error ? error.message : String(error));
        return fail(502, 'Push delivery failed; check device registration and service configuration');
      }
    }));
  }
  async createCallback(configJson: string): Promise<string> {
    const config = callbackSchema.parse(JSON.parse(configJson));
    return wire(this.#guard(async () => {
      const count = await this.env.DB.prepare('SELECT count(*) AS n FROM callbacks WHERE owner = ?').bind(this.#ownerId).first<{ n: number }>();
      if ((count?.n ?? 0) >= 20) return fail(409, 'Maximum 20 callbacks');
      const id = crypto.randomUUID(), secret = token();
      await this.env.DB.prepare('INSERT INTO callbacks VALUES (?, ?, ?, ?)').bind(id, this.#ownerId, await hash(secret), JSON.stringify(config)).run();
      return ok({ id, ...config, secret }, 201);
    }));
  }
  async updateCallback(id: string, configJson: string): Promise<string> {
    const config = callbackSchema.parse(JSON.parse(configJson));
    return wire(this.#guard(async () => {
      if (!(await this.#row(id))) return fail(404, 'Callback not found');
      await this.env.DB.prepare('UPDATE callbacks SET config = ? WHERE id = ?').bind(JSON.stringify(config), id).run();
      return ok({ id, ...config });
    }));
  }
  async deleteCallback(id: string): Promise<string> {
    return wire(this.#guard(async () => {
      if (!(await this.#row(id))) return fail(404, 'Callback not found');
      await this.env.DB.prepare('DELETE FROM callbacks WHERE id = ?').bind(id).run();
      return ok({ ok: true });
    }));
  }
  async rotateCallback(id: string): Promise<string> {
    return wire(this.#guard(async () => {
      if (!(await this.#row(id))) return fail(404, 'Callback not found');
      const secret = token();
      await this.env.DB.prepare('UPDATE callbacks SET secret_hash = ? WHERE id = ?').bind(await hash(secret), id).run();
      return ok({ secret });
    }));
  }
  async preview(configJson: string, payloadJson: string, appleSample: boolean): Promise<string> {
    const config = callbackSchema.parse(JSON.parse(configJson));
    const payload = payloadSchema.parse(JSON.parse(payloadJson));
    return wire(this.#guard(async () => {
      const parsed = config.parser === 'apple' && appleSample ? payload : await this.#fields(config, payload);
      return ok({ ...evaluate(config, parsed), verified: config.parser === 'apple' && !appleSample, sampleOnly: appleSample });
    }));
  }
  async testPush(id: string, payloadJson: string): Promise<string> {
    if (!this.#pushAllowed()) return wire(fail(429, 'Too many requests; retry in a minute'));
    const payload = payloadSchema.parse(JSON.parse(payloadJson));
    return wire(this.#guard(async () => {
      const row = await this.#row(id);
      if (!row) return fail(404, 'Callback not found');
      return this.#deliver(row, payload, true);
    }));
  }
  async deliverPublic(id: string, secret: string, payloadJson: string, dedup?: string): Promise<string> {
    if (!this.#pushAllowed()) return wire(fail(429, 'Too many requests; retry in a minute'));
    return wire(this.#guard(async () => {
      const row = await this.env.DB.prepare('SELECT * FROM callbacks WHERE id = ?').bind(id).first<Row>();
      if (!row || !secretsMatch(row.secret_hash, await hash(secret))) return fail(404, 'Callback unavailable');
      if (!(JSON.parse(row.config) as Callback).enabled) return fail(410, 'Callback disabled');
      let payload: unknown;
      try { payload = JSON.parse(payloadJson); } catch { return fail(400, 'Invalid request or callback configuration'); }
      const parsed = payloadSchema.safeParse(payload);
      if (!parsed.success) return fail(400, 'Invalid request or callback configuration');
      const dedupKey = z.string().min(1).max(128).optional().safeParse(dedup);
      if (!dedupKey.success) return fail(400, 'Invalid request or callback configuration');
      const result = await this.#deliver(row, parsed.data, false, dedupKey.data);
      return result.status >= 400 ? result : ok({ status: (result.body as { status: string }).status });
    }));
  }

  async #fields(config: Callback, payload: Fields): Promise<Fields> {
    if (config.parser !== 'apple') return payload;
    try { return await parseApple(config, payload, [Buffer.from(rootCA)]); }
    catch { throw Object.assign(new Error('Apple signature or app identity verification failed'), { statusCode: 422 }); }
  }
  async #deliver(row: Row, payload: Fields, test: boolean, dedup?: string): Promise<Result> {
    const config = callbackSchema.parse(JSON.parse(row.config));
    let parsed: Fields;
    try { parsed = await this.#fields(config, payload); }
    catch (e) { return fail((e as { statusCode?: number }).statusCode ?? 500, (e as Error).message); }
    const rawKey = test ? undefined : config.parser === 'apple' ? parsed.notificationUUID : dedup;
    const key = typeof rawKey === 'string' ? `${config.parser}:${rawKey}` : undefined;
    const cutoff = new Date(Date.now() - 30 * 86400000).toISOString();
    await this.env.DB.prepare('DELETE FROM receipts WHERE created_at < ?').bind(cutoff).run();
    if (typeof key === 'string') {
      const previous = await this.env.DB.prepare('SELECT 1 FROM receipts WHERE callback_id = ? AND dedup_key = ?').bind(row.id, key).first();
      if (previous) return ok({ status: 'duplicate' });
      await this.env.DB.prepare('DELETE FROM events WHERE callback_id = ? AND dedup_key = ?').bind(row.id, key).run();
    }
    const result = evaluate(config, parsed);
    const id = crypto.randomUUID();
    const detail = { ...result, source: { name: config.name, symbol: config.symbol, emoji: config.emoji, imageURL: config.imageURL, color: config.color, tags: config.tags }, test };
    const createdAt = new Date().toISOString();
    await this.env.DB.prepare('INSERT INTO events VALUES (?, ?, ?, ?, ?, ?)')
      .bind(id, row.id, createdAt, result.notification ? 'sending' : result.status, JSON.stringify(detail), typeof key === 'string' ? key : null).run();
    // Bounded retention; raw signedPayload/device tokens are never stored in history.
    await this.env.DB.prepare('DELETE FROM events WHERE callback_id = ? AND id NOT IN (SELECT id FROM events WHERE callback_id = ? ORDER BY rowid DESC LIMIT 50)').bind(row.id, row.id).run();
    await this.env.DB.prepare('DELETE FROM events WHERE created_at < ?').bind(cutoff).run();
    const recordReceipt = () => key ? this.env.DB.prepare('INSERT INTO receipts VALUES (?, ?, ?)').bind(row.id, key, createdAt).run() : Promise.resolve();
    if (!result.notification) { await recordReceipt(); return ok({ ...result, id }); }
    const owner = await this.env.DB.prepare('SELECT * FROM installations WHERE id = ?').bind(row.owner).first<Owner>();
    let badge: number | undefined;
    switch (result.notification.badge) {
      case 'set': badge = result.notification.badgeValue; break;
      case 'clear': badge = 0; break;
      case 'increment': badge = Math.min(99999, (owner?.badge ?? 0) + 1); break;
    }
    try {
      if (!owner?.device_token) throw new Error('Allow notifications and register this device first');
      await this.#sender()({ deviceToken: owner.device_token, environment: owner.environment, callback: config, callbackId: row.id, notification: result.notification, badge, eventId: id });
      await this.env.DB.prepare('UPDATE events SET status = ? WHERE id = ?').bind('sent', id).run();
      if (badge !== undefined) await this.env.DB.prepare('UPDATE installations SET badge = ? WHERE id = ?').bind(badge, this.#ownerId).run();
      await recordReceipt();
      return ok({ ...result, id, status: 'sent' });
    } catch (error) {
      console.error('Callback APNs delivery failed', error instanceof Error ? error.message : String(error));
      await this.env.DB.prepare('UPDATE events SET status = ? WHERE id = ?').bind('failed', id).run();
      return fail(502, 'Push delivery failed; check device registration and service configuration');
    }
  }
}
