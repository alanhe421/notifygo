import { vi } from 'vitest';

// APNs itself is always intercepted: the Durable Object's #sender() calls the real global fetch(), and
// everything under vitest-pool-workers (test file, main worker, Durable Objects) shares one JS realm, so
// vi.stubGlobal here is visible to Durable Object code without needing runInDurableObject().
export function mockAPNs(handler: (req: Request) => Response | Promise<Response>) {
  vi.stubGlobal('fetch', (input: RequestInfo | URL, init?: RequestInit) => Promise.resolve(handler(new Request(input, init))));
}
