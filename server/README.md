# NotifyGo publisher service

The production service runs on Cloudflare Workers with D1 and a Durable Object per installation. It exposes a Bark-style Device Push URL for direct custom notifications and separate Callback URLs for Generic JSON or verified App Store Server Notifications with rules and templates.

## Configuration

Install dependencies with `npm ci --ignore-scripts`. Public bindings are defined in `wrangler.toml`; set APNs credentials through `wrangler secret put` and never commit them:

| Variable | Purpose |
| --- | --- |
| `PUBLIC_URL` | Public HTTPS origin, currently `https://notifygo.1991421.cn` |
| `APNS_TEAM_ID` | NotifyGo publisher's Apple team |
| `APNS_KEY_ID` | APNs authentication key identifier |
| `APNS_PRIVATE_KEY` | Full contents of the publisher's protected `.p8` file |
| `APNS_TOPIC` | NotifyGo app Bundle ID, default project identity `cn.alanhe.notifygo` |

Deploy with `npx wrangler d1 migrations apply notifygo --remote` followed by `npx wrangler deploy`. Per-installation serialization is provided by `InstallationLock`; persistent configuration and history live in D1.

The app has no server URL input. The publisher supplies `NOTIFYGO_SERVICE_URL` at build time after provisioning this service. Deploying the service, adding DNS/TLS and signing/releasing the app are separate operator actions.

## API

Management endpoints use `Authorization: Bearer <installation token>`, except registration. No installation token is included in a Callback URL.

| Method / path | Result |
| --- | --- |
| `POST /v1/installations` with `{}` | New anonymous installation and one-time token |
| `PUT /v1/device` | `{token, environment: "development" or "production"}` |
| `POST /v1/device/rotate` | Rotate and return this installation's Device Push URL |
| `GET/POST /push/:deviceKey` | Send a custom notification directly to the registered device |
| `GET /v1/callbacks` | Installation's configurations; never secrets |
| `POST /v1/callbacks` | Create, returning configuration, ID and one-time `callbackURL` |
| `PUT /v1/callbacks/:id` | Replace validated configuration, including enabled state |
| `DELETE /v1/callbacks/:id` | Delete configuration, history and replay receipts |
| `POST /v1/callbacks/:id/rotate` with `{}` | New URL; invalidates old secret |
| `POST /v1/preview` | `{config, payload, appleSample?}`; no delivery or history write |
| `POST /v1/callbacks/:id/test` | JSON payload; uses saved configuration and real APNs |
| `GET /v1/callbacks/:id/history` | Most recent 50 results, at most 30 days |
| `GET /c/:id/:secret` | Query string fields become a JSON object of strings |
| `POST /c/:id/:secret` | JSON object; optional `Idempotency-Key` for generic senders |

POST is required for numeric/boolean/nested fields. GET query values remain strings and are not coerced. Responses are marked `no-store`. Callback responses expose only processing status; detailed business fields and rule traces require installation authentication.

Example Generic JSON configuration (omitted settings take schema defaults):

```json
{
  "name": "Sales",
  "parser": "json",
  "mappings": [{"field": "product", "source": "event.product"}],
  "rules": [{
    "id": "paid",
    "name": "Paid transactions",
    "priority": 10,
    "conditions": [{"field": "amount", "op": "gt", "value": 0}],
    "template": {
      "title": "Sold {{mapped.product}}",
      "body": "{{amount}} {{currency}}",
      "url": "https://example.com/products/{{mapped.product}}",
      "badge": "increment"
    }
  }]
}
```

Send `{"event":{"product":"premium"},"amount":9.99,"currency":"USD"}` to the generated URL. Apple mode instead uses `parser: "apple"`, `appleBundleId`, `appleEnvironment` and (production) `appleAppId`, and accepts `{"signedPayload":"…"}`. The monitored app's identity is independent of NotifyGo's APNs topic.

## Apple trust and fields

The [official Apple server library](https://github.com/apple/app-store-server-library-node) verifies the outer notification against trusted roots, the configured app identity and environment, with online certificate checks enabled. It separately verifies inner transaction and renewal JWS values. The verifier cache is bounded and never accepts an unverified sample in a delivery endpoint.

Exposed fields: `notificationUUID`, `type`, `subtype`, `product`, `amount`, `currency`, `country`, `environment`, plus verified `transaction` and `renewal` objects. Apple's transaction price is in milliunits; `amount` divides it by 1,000. `country` is the three-letter storefront code. Missing price/currency/storefront remain absent; they are not invented or replaced with zero.

The bundled root is downloaded unchanged from [Apple Root CA G3](https://www.apple.com/certificateauthority/AppleRootCA-G3.cer). Review Apple's [PKI](https://www.apple.com/certificateauthority/) when rotating trusted roots. Trust roots are public certificates, not secret keys. Production/sandbox positive verification still requires integration testing with genuine events.

## Delivery and operations

- APNs uses token authentication and [HTTP/2 delivery](https://developer.apple.com/documentation/usernotifications/setting-up-a-remote-notification-server). Only a successful APNs response marks history `sent`; that means APNs accepted it, not that a device displayed it.
- Synchronous delivery has a 10-second APNs deadline. On failure the service returns 502 and records `failed`; the webhook provider must retry. There is no hidden background queue. Apple online verification may take additional time.
- Apple notification UUIDs and explicit generic idempotency keys deduplicate successful/suppressed events for 30 days, independently of the 50-entry history limit. Generic requests without a key and manual test requests are separate events.
- Delivery is **at least once**, not exactly once: an APNs acceptance followed by a process/database failure can be repeated on retry. On restart, incomplete `sending` entries are marked failed. A sender that does not retry can lose an event after a crash; a durable outbox is outside this synchronous MVP.
- Badge changes, key rotation, config updates and delivery serialize per installation. Rotation waits for already-started deliveries; once reset returns, old-key requests cannot start a delivery. A previously accepted APNs notification can still arrive later.
- Request body limit: 64 KiB. APNs payload limit: 4 KiB of UTF-8. Max 20 Callbacks/installation, 30 rules/Callback, 20 conditions/rule. Limits per minute: 5 registrations/IP, 300 requests/IP, 120 management requests/installation and 60 push attempts/installation.
- Protect the database and backups: it contains device tokens, notification content and transaction details. Installation tokens and Callback secrets are stored as SHA-256 hashes. The client keeps one-time URLs and credentials in Keychain; reset a key if its URL is lost.
- Application request logging is off. Any observability integration must redact `/c/...` and `/push/...` URLs, query strings and authorization headers. Do not send webhook or Device Push URLs to analytics.
- Use D1 backups/time travel according to the Cloudflare account retention policy. Monitor APNs failures and 429/503 rates before expanding beyond this MVP.

## Acceptance checklist

Local API tests use in-memory SQLite and an injected APNs sender. Run the repository's release checklist on the deployed service with a signed app and genuine Apple notifications before claiming the hosted MVP is ready for users.
