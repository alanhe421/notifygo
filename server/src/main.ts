import { readFileSync, mkdirSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { createApp } from './app.ts';
import { database } from './database.ts';
import { createAPNsSender } from './apns.ts';

function required(name: string) {
  const value = process.env[name];
  if (!value) throw new Error(`Missing ${name}`);
  return value;
}
const publicURL = new URL(required('PUBLIC_URL'));
if (publicURL.protocol !== 'https:' || publicURL.pathname !== '/' || publicURL.search || publicURL.hash)
  throw new Error('PUBLIC_URL must be an HTTPS origin');
process.umask(0o077);
const filename = resolve(process.env.DATABASE_PATH ?? './data/notifygo.sqlite');
mkdirSync(dirname(filename), { recursive: true, mode: 0o700 });
const db = database(filename);
const roots = (process.env.APPLE_ROOT_CA_FILES ?? './certs/AppleRootCA-G3.cer').split(',').map(path => readFileSync(path));
const send = createAPNsSender({
  teamId: required('APNS_TEAM_ID'), keyId: required('APNS_KEY_ID'),
  privateKey: readFileSync(required('APNS_KEY_FILE'), 'utf8'), topic: required('APNS_TOPIC')
});
const app = createApp({ db, publicURL: publicURL.origin, roots, send,
  trustedProxy: process.env.TRUSTED_PROXY_CIDRS?.split(',').filter(Boolean)
});
await app.listen({ port: Number(process.env.PORT ?? 8080), host: process.env.HOST ?? '127.0.0.1' });
for (const signal of ['SIGTERM', 'SIGINT'] as const) process.on(signal, async () => {
  await app.close(); db.close(); process.exit(0);
});
