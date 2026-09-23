import { defineConfig } from 'vitest/config';
import { cloudflareTest, readD1Migrations } from '@cloudflare/vitest-pool-workers';
import { generateKeyPairSync } from 'node:crypto';
import path from 'node:path';

export default defineConfig({
  test: {
    setupFiles: ['./test/apply-migrations.ts']
  },
  plugins: [
    cloudflareTest(async () => {
      // A real (but disposable) EC P-256 key so createAPNsSender() can produce a well-formed ES256 JWT
      // in tests; APNs itself is always mocked (see test/apns-mock.ts), so nothing verifies this key.
      const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
      return {
        wrangler: { configPath: './wrangler.toml' },
        miniflare: {
          bindings: {
            TEST_MIGRATIONS: await readD1Migrations(path.join(import.meta.dirname, 'migrations')),
            APNS_TEAM_ID: 'TEST_TEAM', APNS_KEY_ID: 'TEST_KEY', APNS_TOPIC: 'cn.aol.NotifyGo',
            APNS_PRIVATE_KEY: privateKey.export({ type: 'pkcs8', format: 'pem' }).toString()
          }
        }
      };
    })
  ]
});
