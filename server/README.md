# NotifyGo publisher service

This is an operator-run Node.js 24+ service using SQLite and direct APNs HTTP/2. It can run as one supervised process on the publisher's Tencent Cloud LH host behind an HTTPS reverse proxy. It is not a Cloudflare Worker, and end users never configure or deploy it.

## Configuration

Install dependencies with `npm ci --omit=dev --ignore-scripts`. Set these values through the host's private environment/secret manager:

| Variable | Purpose |
| --- | --- |
| `PUBLIC_URL` | Public HTTPS origin, without a path/query |
| `APNS_TEAM_ID` | NotifyGo publisher's Apple team |
| `APNS_KEY_ID` | APNs authentication key identifier |
| `APNS_KEY_FILE` | Absolute path to the publisher's protected `.p8` file |
| `APNS_TOPIC` | NotifyGo app Bundle ID, default project identity `cn.aol.NotifyGo` |
| `DATABASE_PATH` | Persistent database file; default `./data/notifygo.sqlite` |
| `HOST` / `PORT` | Defaults `127.0.0.1` / `8080` |
| `TRUSTED_PROXY_CIDRS` | Comma-separated exact trusted proxy ranges; omit for direct access. For a local reverse proxy use `127.0.0.1/32,::1/128`; the proxy must overwrite forwarding headers. |
| `APPLE_ROOT_CA_FILES` | Comma-separated DER root certificate files; default `./certs/AppleRootCA-G3.cer` |

Run `npm start` with the working directory set to `server/`. Startup refuses missing APNs credentials or a non-HTTPS public origin. Bind only to loopback when using a local proxy. Use a service supervisor, persistent disk and an unprivileged service user. Keep one process per database: in-process delivery/config serialization is intentional; do not use a cluster or multiple replicas against the same file.

The app has no server URL input. The publisher supplies `NOTIFYGO_SERVICE_URL` at build time after provisioning this service. Deploying the service, adding DNS/TLS and signing/releasing the app are separate operator actions.

## API

Management endpoints use `Authorization: Bearer <installation token>`, except registration. No installation token is included in a Callback URL.

| Method / path | Result |
| --- | --- |
| `POST /v1/installations` with `{}` | New anonymous installation and one-time token |
| `PUT /v1/device` | `{token, environment: "development" or "production"}` |
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
- Request body limit: 64 KiB. APNs payload limit: 4 KiB of UTF-8. Max 20 Callbacks/installation, 30 rules/Callback, 20 conditions/rule. Limits per minute: 5 registrations/IP, 300 requests/IP, 120 management requests/installation, 60 push attempts/installation. At most 8 outstanding serialized operations per installation and 100 globally. Rate state is process-local.
- Protect the database and backups: it contains device tokens, notification content and transaction details. Installation tokens and Callback secrets are stored as SHA-256 hashes. The client keeps one-time URLs and credentials in Keychain; reset a key if its URL is lost.
- Application request logging is off. Configure the reverse proxy/APM to omit or redact `/c/...` URLs, query strings and authorization headers. Do not send Webhook URLs to analytics. Review proxy trust and rate limiting before public launch.
- Take consistent SQLite backups including WAL state using a SQLite backup facility; do not just copy an active main database file. Monitor disk usage, APNs failures and 429/503 rates. Configure operator-controlled retention/quotas before expanding beyond this MVP.

## Acceptance checklist

Local API tests use in-memory SQLite and an injected APNs sender. Run the repository's release checklist on the deployed service with a signed app and genuine Apple notifications before claiming the hosted MVP is ready for users.
