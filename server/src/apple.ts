import { Environment, SignedDataVerifier } from '@apple/app-store-server-library';
import type { Callback, Fields } from './domain.ts';
import type { ResponseBodyV2DecodedPayload, JWSTransactionDecodedPayload, JWSRenewalInfoDecodedPayload } from '@apple/app-store-server-library';

// Keep the official verifier's bounded certificate/OCSP cache across requests.
const verifiers = new Map<string, SignedDataVerifier>();

export async function parseApple(callback: Callback, payload: Fields, roots: Buffer[]): Promise<Fields> {
  if (!roots.length) throw new Error('Apple trust roots are not configured');
  if (typeof payload.signedPayload !== 'string') throw new Error('signedPayload is required');
  const environment = callback.appleEnvironment === 'Production' ? Environment.PRODUCTION : Environment.SANDBOX;
  const cacheKey = JSON.stringify([environment, callback.appleBundleId, callback.appleAppId, roots.map(root => root.toString('base64'))]);
  let verifier = verifiers.get(cacheKey);
  if (!verifier) {
    verifier = new SignedDataVerifier(roots, true, environment, callback.appleBundleId, callback.appleAppId);
    if (verifiers.size >= 128) verifiers.delete(verifiers.keys().next().value!);
    verifiers.set(cacheKey, verifier);
  }
  const event = await verifier.verifyAndDecodeNotification(payload.signedPayload);
  const transaction = event.data?.signedTransactionInfo
    ? await verifier.verifyAndDecodeTransaction(event.data.signedTransactionInfo) : undefined;
  const renewal = event.data?.signedRenewalInfo
    ? await verifier.verifyAndDecodeRenewalInfo(event.data.signedRenewalInfo) : undefined;
  return normalizeApple(callback.appleEnvironment, event, transaction, renewal);
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
