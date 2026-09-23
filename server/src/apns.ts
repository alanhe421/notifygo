import { sign } from 'node:crypto';
import type { Callback, NotificationTemplate } from './domain.ts';

export type Push = {
  deviceToken: string; environment: string; callback: Callback; callbackId: string;
  notification: NotificationTemplate; badge?: number; eventId: string;
};

let providerTokenCache: { key: string; jwt: string; issuedAt: number } | undefined;

export function apnsPayload(push: Push) {
  const n = push.notification;
  return {
    aps: {
      alert: { title: n.title, ...(n.subtitle ? { subtitle: n.subtitle } : {}), body: n.body },
      ...(n.sound === 'none' ? {} : { sound: 'default' }),
      ...(push.badge === undefined ? {} : { badge: push.badge }),
      'interruption-level': n.level, 'mutable-content': 1, 'thread-id': n.group || push.callbackId
    },
    notifygo: {
      eventId: push.eventId, callbackId: push.callbackId, url: n.url,
      name: push.callback.name, symbol: push.callback.symbol, emoji: push.callback.emoji,
      color: push.callback.color, imageURL: n.icon || push.callback.imageURL, tags: push.callback.tags
    }
  };
}
export function createAPNsSender(config: { teamId: string; keyId: string; privateKey: string; topic: string }) {
  return async (push: Push) => {
    const now = Math.floor(Date.now() / 1000);
    const cacheKey = `${config.teamId}:${config.keyId}`;
    if (!providerTokenCache || providerTokenCache.key !== cacheKey || now - providerTokenCache.issuedAt > 3000) {
      const header = Buffer.from(JSON.stringify({ alg: 'ES256', kid: config.keyId })).toString('base64url');
      const claims = Buffer.from(JSON.stringify({ iss: config.teamId, iat: now })).toString('base64url');
      const input = `${header}.${claims}`;
      const jwt = `${input}.${sign('sha256', Buffer.from(input), { key: config.privateKey, dsaEncoding: 'ieee-p1363' }).toString('base64url')}`;
      providerTokenCache = { key: cacheKey, jwt, issuedAt: now };
    }
    const payload = JSON.stringify(apnsPayload(push));
    if (Buffer.byteLength(payload) > 4096) throw new Error('Notification exceeds APNs payload limit');
    const origin = push.environment === 'development'
      ? 'https://api.sandbox.push.apple.com'
      : 'https://api.push.apple.com';
    const response = await fetch(`${origin}/3/device/${push.deviceToken}`, {
      method: 'POST',
      headers: {
        authorization: `bearer ${providerTokenCache.jwt}`,
        'apns-topic': config.topic,
        'apns-push-type': 'alert',
        'apns-priority': push.notification.level === 'passive' ? '5' : '10',
        'apns-id': push.eventId,
        'content-type': 'application/json'
      },
      body: payload,
      signal: AbortSignal.timeout(10_000)
    });
    if (!response.ok) {
      const detail = await response.text();
      let reason = 'Unknown';
      try { reason = String((JSON.parse(detail) as { reason?: unknown }).reason ?? reason); } catch {}
      console.error('APNs rejected notification', { status: response.status, reason, environment: push.environment });
      throw new Error(`APNs rejected notification (${response.status}: ${reason})`);
    }
  };
}
