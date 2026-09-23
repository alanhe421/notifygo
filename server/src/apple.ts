import type { Callback, Fields } from './domain.ts';
import type { ResponseBodyV2DecodedPayload, JWSTransactionDecodedPayload, JWSRenewalInfoDecodedPayload, SignedDataVerifier } from '@apple/app-store-server-library';

// Keep the official verifier's bounded certificate/OCSP cache across requests.
const verifiers = new Map<string, SignedDataVerifier>();

export async function parseApple(_callback: Callback, payload: Fields, roots: Buffer[]): Promise<Fields> {
  if (!roots.length) throw new Error('Apple trust roots are not configured');
  if (typeof payload.signedPayload !== 'string') throw new Error('signedPayload is required');
  // jsrsasign initializes randomness while loading. Workers only permits that inside a request handler,
  // so keep the Apple verifier out of module-global evaluation.
  const { Environment, SignedDataVerifier } = await import('@apple/app-store-server-library');
  const identity = notificationIdentity(payload.signedPayload);
  const environment = identity.environment === 'Production' ? Environment.PRODUCTION : Environment.SANDBOX;
  const cacheKey = JSON.stringify([environment, identity.bundleId, identity.appAppleId, roots.map(root => root.toString('base64'))]);
  let verifier = verifiers.get(cacheKey);
  if (!verifier) {
    verifier = new SignedDataVerifier(roots, true, environment, identity.bundleId, identity.appAppleId);
    if (verifiers.size >= 128) verifiers.delete(verifiers.keys().next().value!);
    verifiers.set(cacheKey, verifier);
  }
  const event = await verifier.verifyAndDecodeNotification(payload.signedPayload);
  const transaction = event.data?.signedTransactionInfo
    ? await verifier.verifyAndDecodeTransaction(event.data.signedTransactionInfo) : undefined;
  const renewal = event.data?.signedRenewalInfo
    ? await verifier.verifyAndDecodeRenewalInfo(event.data.signedRenewalInfo) : undefined;
  return {
    ...normalizeApple(identity.environment, event, transaction, renewal),
    bundleId: identity.bundleId,
    appAppleId: identity.appAppleId
  };
}

type NotificationIdentity = { bundleId: string; appAppleId?: number; environment: 'Sandbox' | 'Production' };

// Identity values select the official Apple verifier. They remain untrusted until
// verifyAndDecodeNotification validates the JWS signature, certificate chain, and
// the same bundle/app/environment values against the verified payload.
export function notificationIdentity(signedPayload: string): NotificationIdentity {
  const parts = signedPayload.split('.');
  if (parts.length !== 3) throw new Error('signedPayload is malformed');
  let payload: Record<string, any>;
  try { payload = JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8')); }
  catch { throw new Error('signedPayload is malformed'); }

  const source = payload.data ?? payload.summary ?? payload.externalPurchaseToken ?? payload.appData;
  const bundleId = source?.bundleId;
  const externalPurchaseId = source?.externalPurchaseId;
  const environment = source?.environment ??
    (typeof externalPurchaseId === 'string' && externalPurchaseId.startsWith('SANDBOX') ? 'Sandbox' : 'Production');
  const appAppleId = source?.appAppleId;

  if (typeof bundleId !== 'string' || !bundleId || !['Sandbox', 'Production'].includes(environment))
    throw new Error('signedPayload is missing app identity');
  if (environment === 'Production' && (!Number.isInteger(appAppleId) || appAppleId <= 0))
    throw new Error('signedPayload is missing production app identity');
  return { bundleId, appAppleId: Number.isInteger(appAppleId) ? appAppleId : undefined, environment };
}

export function normalizeApple(environment: string, event: ResponseBodyV2DecodedPayload,
  transaction?: JWSTransactionDecodedPayload, renewal?: JWSRenewalInfoDecodedPayload): Fields {
  return {
    notificationUUID: event.notificationUUID,
    type: event.notificationType, subtype: event.subtype,
    product: transaction?.productId,
    amount: transaction?.price === undefined ? undefined : transaction.price / 1000,
    currency: transaction?.currency, country: transaction?.storefront,
    environment, transaction, renewal
  };
}
