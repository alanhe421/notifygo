import { hash } from './crypto.ts';

export type Owner = { id: string; auth_hash: string; device_key_hash: string | null; device_token: string | null; environment: string; badge: number };
export type Row = { id: string; owner: string; secret_hash: string; config: string };

export const view = (row: Row) => ({ id: row.id, ...JSON.parse(row.config) });

export async function findOwnerByAuth(db: D1Database, authToken: string): Promise<Owner | null> {
  return db.prepare('SELECT * FROM installations WHERE auth_hash = ?').bind(await hash(authToken)).first<Owner>();
}
export async function findOwnerByDeviceKey(db: D1Database, deviceKey: string): Promise<Owner | null> {
  return db.prepare('SELECT * FROM installations WHERE device_key_hash = ?').bind(await hash(deviceKey)).first<Owner>();
}
export async function findCallback(db: D1Database, id: string): Promise<Row | null> {
  return db.prepare('SELECT * FROM callbacks WHERE id = ?').bind(id).first<Row>();
}
export async function findOwnedCallback(db: D1Database, id: string, ownerId: string): Promise<Row | null> {
  return db.prepare('SELECT * FROM callbacks WHERE id = ? AND owner = ?').bind(id, ownerId).first<Row>();
}
export async function listCallbacks(db: D1Database, ownerId: string): Promise<Row[]> {
  const { results } = await db.prepare('SELECT * FROM callbacks WHERE owner = ? ORDER BY rowid DESC').bind(ownerId).all<Row>();
  return results;
}
