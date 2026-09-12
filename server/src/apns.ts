import { connect } from 'node:http2';
import { createPrivateKey, sign } from 'node:crypto';
import type { Callback, NotificationTemplate } from './domain.ts';

export type Push = {
  deviceToken: string; environment: string; callback: Callback; callbackId: string;
  notification: NotificationTemplate; badge?: number; eventId: string;
};
export function apnsPayload(push: Push) {
  const n = push.notification;
  return {
    aps: {
      alert: { title: n.title, body: n.body },
      ...(n.sound === 'none' ? {} : { sound: 'default' }),
      ...(push.badge === undefined ? {} : { badge: push.badge }),
      'interruption-level': n.level, 'mutable-content': 1, 'thread-id': push.callbackId
    },
    notifygo: {
      eventId: push.eventId, callbackId: push.callbackId, url: n.url,
      name: push.callback.name, symbol: push.callback.symbol, emoji: push.callback.emoji,
      color: push.callback.color, imageURL: push.callback.imageURL, tags: push.callback.tags
    }
  };
}
export function createAPNsSender(config: { teamId: string; keyId: string; privateKey: string; topic: string }) {
  const key = createPrivateKey(config.privateKey);
  let jwt = '', issuedAt = 0;
  return async (push: Push) => {
    const now = Math.floor(Date.now() / 1000);
    if (now - issuedAt > 3000) {
      const header = Buffer.from(JSON.stringify({ alg: 'ES256', kid: config.keyId })).toString('base64url');
      const claims = Buffer.from(JSON.stringify({ iss: config.teamId, iat: now })).toString('base64url');
      const input = `${header}.${claims}`;
      jwt = `${input}.${sign('sha256', Buffer.from(input), { key, dsaEncoding: 'ieee-p1363' }).toString('base64url')}`;
      issuedAt = now;
    }
    const payload = JSON.stringify(apnsPayload(push));
    if (Buffer.byteLength(payload) > 4096) throw new Error('Notification exceeds APNs payload limit');
    await new Promise<void>((resolve, reject) => {
      const session = connect(push.environment === 'development' ? 'https://api.sandbox.push.apple.com' : 'https://api.push.apple.com');
      const timer = setTimeout(() => finish(new Error('APNs request timed out')), 10000);
      let finished = false;
      function finish(error?: Error) {
        if (finished) return;
        finished = true;
        clearTimeout(timer);
        session.destroy();
        error ? reject(error) : resolve();
      }
      session.on('error', () => finish(new Error('APNs connection failed')));
      const request = session.request({
        ':method': 'POST', ':path': `/3/device/${push.deviceToken}`,
        authorization: `bearer ${jwt}`, 'apns-topic': config.topic,
        'apns-push-type': 'alert', 'apns-priority': push.notification.level === 'passive' ? '5' : '10',
        'apns-id': push.eventId
      });
      let status = 0;
      request.on('response', headers => { status = Number(headers[':status']); });
      request.on('data', () => {});
      request.on('error', () => finish(new Error('APNs stream failed')));
      request.on('end', () => finish(status === 200 ? undefined : new Error(`APNs rejected notification (${status})`)));
      request.end(payload);
    });
  };
}
