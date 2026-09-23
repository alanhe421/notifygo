import type { InstallationLock } from './installation-lock.ts';

export interface Env {
  DB: D1Database;
  LOCKS: DurableObjectNamespace<InstallationLock>;
  RATE_IP: RateLimit;
  RATE_SIGNUP: RateLimit;
  RATE_OWNER: RateLimit;
  PUBLIC_URL: string;
  APNS_TEAM_ID: string;
  APNS_KEY_ID: string;
  APNS_TOPIC: string;
  APNS_PRIVATE_KEY: string;
}

// InstallationLock's own base class stores `env: DOEnv` as an (inspectable, TS-`protected`) property.
// Using the full Env here would make that property's type reference DurableObjectNamespace<InstallationLock>,
// which circularly re-embeds InstallationLock into its own RPC surface and blows up type instantiation depth.
export type DOEnv = Omit<Env, 'LOCKS'>;
