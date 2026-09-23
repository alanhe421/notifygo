# NotifyGo

NotifyGo turns a hosted Callback URL into configurable iOS notifications. The app creates an anonymous installation, registers its APNs token, and manages Callbacks through the publisher's service. Users do not deploy a backend or enter server credentials.

This branch contains the iOS client, a Node.js service and validation workflows. **A production service has not been deployed, and physical-device delivery has not been accepted yet.** The publisher must configure the HTTPS origin, Apple signing and APNs credentials before distributing a usable build. See [operator setup](server/README.md).

## User flow

1. Allow notifications, then create a Callback.
2. Choose Generic JSON or App Store transactions. Apple Callbacks require the monitored app's Bundle ID, environment, and production App Apple ID; no App Store signing key is needed to receive notifications.
3. Edit conditions and templates, then paste a sample to preview parsed fields and rule matching.
4. Save, send a test, and copy the URL to the third-party service.
5. View recent results, pause a Callback, or reset its key. The previous URL stops authorizing new deliveries when reset returns.

Source icons, color and tags appear in the app's history. The notification service extension provides a source attachment (HTTPS PNG/JPEG, Emoji or SF Symbol, with a default bell). The system notification's App Icon remains NotifyGo, and iOS controls its background and presentation.

## iOS development

- Xcode 16+, iOS 17+, shared `NotifyGo` scheme.
- Set the app target's `NOTIFYGO_SERVICE_URL` to the **publisher's** HTTPS origin. An empty value produces an explicit unavailable state, never a fake Callback URL.
- Set your development team for the app and `NotifyGoNotificationService` extension. Enable Push Notifications and Time Sensitive Notifications for the app's identifier.
- Match `APNS_TOPIC` to the app's `PRODUCT_BUNDLE_IDENTIFIER` (`cn.alanhe.notifygo` by default). Debug uses the development entitlement and APNs environment; Release uses production. If signing differently, override `APS_ENVIRONMENT` consistently.
- Installation credentials and Callback URLs are stored in this device's Keychain. Reinstalling on another device does not restore the installation; multi-device accounts/recovery are outside this MVP.
- The previous local-only prototype's endpoint storage remains untouched. Those records were never live service Callbacks and are not automatically uploaded.

The production origin and APNs key are publisher configuration, not app settings. Never put a `.p8` file or APNs credentials inside an app bundle.

## Rule semantics

- Lower priority numbers run first; equal numbers are ordered by rule ID. The **first matching enabled rule** wins, including a suppression rule. No match means no push.
- Conditions use AND. Empty conditions match all payloads. Equality is type-sensitive; numeric comparisons require numbers; missing/null fields never match, including `not equal`.
- JSON fields use dot paths and numeric array indices. Mappings expose aliases as `mapped.alias`.
- Title, body and URL accept `{{field.path}}`. Missing or non-scalar variables prevent delivery and appear in the preview result. URL substitutions are percent-encoded; the template must have a fixed HTTP(S) URL scheme.
- Sounds: system default or silent. Levels: passive, active, time-sensitive (subject to iOS permission/Focus). Badge: unchanged, set, increment, clear. Increment is based on the last server-accepted badge for the installation and is serialized across its Callbacks.
- Apple presets include a transaction template and a fallback for events without a transaction, including `TEST`. A decoded Apple sample is explicitly unverified and **preview-only**; actual pushes require the original `signedPayload`.

## Validation

```sh
cd server
npm ci --ignore-scripts
npm run typecheck
npm test
```

Tests cover HTTP API isolation/lifecycle, reset during delivery, rule and template behavior, APNs payload construction, badge concurrency, replay handling, malformed/oversized input and forged Apple payload rejection. Apple field normalization tests cover milliunits and absent transactions. HTTP tests inject a fake APNs sender; they do not prove delivery to a real device or acceptance of a genuine Apple-signed event.

GitHub Actions runs server checks and iOS unit tests plus extension compilation on a macOS runner. This small Linux workspace does not run Xcode/Gradle/full device builds. Swift syntax parsing and Xcode project parsing are static checks only.

## Release acceptance still required

- Deploy the publisher service and bake its origin into a signed iOS build.
- On a fresh physical device, create a Generic JSON Callback and receive a test within three minutes.
- Exercise genuine App Store sandbox `TEST` and transaction events, then production identity verification; confirm amount/currency/storefront and rule choice.
- Confirm notification attachment fallback, tap URL, sound, interruption level, all badge strategies and VoiceOver/Dynamic Type on device.
- Verify old URL rejection after key reset against the deployed service, restart persistence, backups and TLS/proxy log redaction.

No merge, deployment or app release is performed by this code change.
