import { ZodError } from 'zod';
import { callbackSchema, templateSchema } from './domain.ts';
import { findCallback, findOwnedCallback, findOwnerByAuth, findOwnerByDeviceKey, listCallbacks, view } from './db.ts';
import { hash, token } from './crypto.ts';
import type { Env } from './env.ts';

export { InstallationLock } from './installation-lock.ts';

const json = (body: unknown, status = 200) => Response.json(body, { status, headers: { 'Cache-Control': 'no-store' } });

async function body(request: Request): Promise<unknown> {
  const text = await request.text();
  if (new TextEncoder().encode(text).byteLength > 65_536) throw Object.assign(new Error('Request body too large'), { status: 413 });
  if (!text) return {};
  try { return JSON.parse(text); }
  catch { throw Object.assign(new Error('Invalid request or callback configuration'), { status: 400 }); }
}

async function rpc(value: Promise<string>): Promise<Response> {
  const result = JSON.parse(await value) as { status: number; body: unknown };
  return json(result.body, result.status);
}

async function owner(request: Request, env: Env) {
  const authorization = request.headers.get('Authorization');
  if (!authorization?.startsWith('Bearer ')) throw Object.assign(new Error('Authentication required'), { status: 401 });
  const value = await findOwnerByAuth(env.DB, authorization.slice(7));
  if (!value) throw Object.assign(new Error('Authentication required'), { status: 401 });
  if (!(await env.RATE_OWNER.limit({ key: value.id })).success) throw Object.assign(new Error('Too many requests; retry in a minute'), { status: 429 });
  return value;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      const url = new URL(request.url);
      const ip = request.headers.get('CF-Connecting-IP') ?? 'unknown';
      if (!(await env.RATE_IP.limit({ key: ip })).success) return json({ error: 'Too many requests; retry in a minute' }, 429);
      if (request.method === 'GET' && url.pathname === '/health') return json({ status: 'ok' });
      if (request.method === 'POST' && url.pathname === '/v1/installations') {
        if (!(await env.RATE_SIGNUP.limit({ key: ip })).success) return json({ error: 'Too many requests; retry in a minute' }, 429);
        await body(request);
        const id = crypto.randomUUID(), authToken = token(), deviceKey = token();
        await env.DB.prepare('INSERT INTO installations(id, auth_hash, device_key_hash) VALUES (?, ?, ?)').bind(id, await hash(authToken), await hash(deviceKey)).run();
        return json({ id, token: authToken, pushURL: `${env.PUBLIC_URL}/push/${deviceKey}` }, 201);
      }
      const pushMatch = url.pathname.match(/^\/push\/([^/]+)$/);
      if (pushMatch && (request.method === 'GET' || request.method === 'POST')) {
        const target = await findOwnerByDeviceKey(env.DB, decodeURIComponent(pushMatch[1]));
        if (!target) return json({ error: 'Device unavailable' }, 404);
        const value = request.method === 'GET' ? Object.fromEntries(url.searchParams) : await body(request);
        const source = value as Record<string, unknown>;
        const notification = templateSchema.parse({
          title: source.title ?? 'NotifyGo', body: source.body ?? '', url: source.url ?? '',
          sound: source.sound ?? 'default', level: source.level ?? 'active',
          badge: source.badge ?? 'unchanged', badgeValue: Number(source.badgeValue ?? 0)
        });
        return rpc(env.LOCKS.getByName(target.id).directPush(JSON.stringify(notification)));
      }
      const publicMatch = url.pathname.match(/^\/c\/([^/]+)\/([^/]+)$/);
      if (publicMatch && (request.method === 'GET' || request.method === 'POST')) {
        const row = await findCallback(env.DB, decodeURIComponent(publicMatch[1]));
        if (!row) return json({ error: 'Callback unavailable' }, 404);
        const payload = request.method === 'GET' ? Object.fromEntries(url.searchParams) : await body(request);
        return rpc(env.LOCKS.getByName(row.owner).deliverPublic(row.id, decodeURIComponent(publicMatch[2]), JSON.stringify(payload), request.headers.get('Idempotency-Key') ?? undefined));
      }
      const current = await owner(request, env), lock = env.LOCKS.getByName(current.id);
      if (request.method === 'PUT' && url.pathname === '/v1/device') {
        const value = await body(request) as { token?: unknown; environment?: unknown };
        if (typeof value.token !== 'string' || !/^[a-f0-9]{64,200}$/.test(value.token) || !['development', 'production'].includes(String(value.environment)))
          return json({ error: 'Invalid request or callback configuration' }, 400);
        return rpc(lock.setDevice(value.token, String(value.environment)));
      }
      if (request.method === 'POST' && url.pathname === '/v1/device/rotate') {
        await body(request);
        const deviceKey = token();
        await env.DB.prepare('UPDATE installations SET device_key_hash = ? WHERE id = ?').bind(await hash(deviceKey), current.id).run();
        return json({ pushURL: `${env.PUBLIC_URL}/push/${deviceKey}` });
      }
      if (request.method === 'GET' && url.pathname === '/v1/callbacks') return json({ callbacks: (await listCallbacks(env.DB, current.id)).map(view) });
      if (request.method === 'POST' && url.pathname === '/v1/callbacks') {
        const config = callbackSchema.parse(await body(request));
        const result = JSON.parse(await lock.createCallback(JSON.stringify(config))) as { status: number; body: Record<string, unknown> };
        if (result.status === 201) { const secret = String(result.body.secret); delete result.body.secret; result.body.callbackURL = `${env.PUBLIC_URL}/c/${result.body.id}/${secret}`; }
        return json(result.body, result.status);
      }
      if (request.method === 'POST' && url.pathname === '/v1/preview') {
        const value = await body(request) as { config?: unknown; payload?: unknown; appleSample?: unknown };
        return rpc(lock.preview(JSON.stringify(callbackSchema.parse(value.config)), JSON.stringify(value.payload), value.appleSample === true));
      }
      const match = url.pathname.match(/^\/v1\/callbacks\/([^/]+)(?:\/(history|rotate|test))?$/);
      if (match) {
        const id = decodeURIComponent(match[1]), action = match[2];
        if (!(await findOwnedCallback(env.DB, id, current.id))) return json({ error: 'Callback not found' }, 404);
        if (request.method === 'GET' && action === 'history') {
          const cutoff = new Date(Date.now() - 30 * 86_400_000).toISOString();
          const { results } = await env.DB.prepare('SELECT * FROM events WHERE callback_id = ? AND created_at >= ? ORDER BY rowid DESC LIMIT 50').bind(id, cutoff).all();
          return json({ events: results.map((event: Record<string, unknown>) => ({ ...JSON.parse(String(event.detail)), id: event.id, createdAt: event.created_at, status: event.status })) });
        }
        if (request.method === 'PUT' && !action) return rpc(lock.updateCallback(id, JSON.stringify(callbackSchema.parse(await body(request)))));
        if (request.method === 'DELETE' && !action) return rpc(lock.deleteCallback(id));
        if (request.method === 'POST' && action === 'test') return rpc(lock.testPush(id, JSON.stringify(await body(request))));
        if (request.method === 'POST' && action === 'rotate') {
          await body(request);
          const result = JSON.parse(await lock.rotateCallback(id)) as { status: number; body: Record<string, unknown> };
          if (result.status === 200) { const secret = String(result.body.secret); result.body = { callbackURL: `${env.PUBLIC_URL}/c/${id}/${secret}` }; }
          return json(result.body, result.status);
        }
      }
      return json({ error: 'Not found' }, 404);
    } catch (error) {
      const status = error instanceof ZodError ? 400 : (error as { status?: number; statusCode?: number }).status ?? (error as { statusCode?: number }).statusCode ?? 500;
      return json({ error: status === 500 ? 'Request could not be completed' : status === 400 ? 'Invalid request or callback configuration' : (error as Error).message }, status);
    }
  }
};
