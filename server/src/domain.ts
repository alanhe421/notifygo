import { z } from 'zod';

const path = z.string().min(1).max(120).regex(/^[a-zA-Z0-9_-]+(?:\.[a-zA-Z0-9_-]+)*$/)
  .refine(p => !p.split('.').some(k => ['__proto__', 'prototype', 'constructor'].includes(k)));
const webURL = z.string().max(2048).refine(s => {
  if (!s) return true;
  try { return ['https:', 'http:'].includes(new URL(s.replace(/\{\{[^{}]+\}\}/g, 'value')).protocol); }
  catch { return false; }
});
export const templateSchema = z.object({
  title: z.string().min(1).max(200), body: z.string().max(1500), url: webURL.default(''),
  sound: z.enum(['default', 'none']).default('default'),
  level: z.enum(['passive', 'active', 'time-sensitive']).default('active'),
  badge: z.enum(['unchanged', 'set', 'increment', 'clear']).default('unchanged'),
  badgeValue: z.number().int().min(0).max(99999).default(0)
});
export const conditionSchema = z.object({
  field: path, op: z.enum(['eq', 'ne', 'contains', 'gt', 'lt']),
  value: z.union([z.string().max(500), z.number().finite(), z.boolean()])
}).refine(c => !['gt', 'lt'].includes(c.op) || typeof c.value === 'number', { message: 'Numeric comparisons require a numeric value' })
  .refine(c => c.op !== 'contains' || typeof c.value === 'string', { message: 'Contains requires text' });
export const callbackSchema = z.object({
  name: z.string().trim().min(1).max(40), enabled: z.boolean().default(true),
  parser: z.enum(['json', 'apple']).default('json'),
  appleBundleId: z.string().max(200).default(''),
  appleAppId: z.number().int().positive().optional(),
  appleEnvironment: z.enum(['Sandbox', 'Production']).default('Sandbox'),
  symbol: z.string().max(100).default('bell.badge.fill'), emoji: z.string().max(16).default(''),
  imageURL: z.string().max(2048).default('').refine(s => !s || /^https:\/\//.test(s)),
  color: z.enum(['blue', 'indigo', 'purple', 'pink', 'orange', 'green']).default('blue'),
  tags: z.array(z.string().trim().min(1).max(30)).max(10).default([]),
  mappings: z.array(z.object({ field: path.refine(p => !p.includes('.')), source: path })).max(30).default([]),
  rules: z.array(z.object({
    id: z.string().min(1).max(80), name: z.string().min(1).max(80),
    priority: z.number().int().min(0).max(9999), enabled: z.boolean().default(true),
    send: z.boolean().default(true), conditions: z.array(conditionSchema).max(20),
    template: templateSchema
  })).min(1).max(30)
}).superRefine((c, ctx) => {
  if (new Set(c.rules.map(r => r.id)).size !== c.rules.length)
    ctx.addIssue({ code: 'custom', message: 'Rule IDs must be unique' });
  if (new Set(c.mappings.map(m => m.field)).size !== c.mappings.length)
    ctx.addIssue({ code: 'custom', message: 'Mapping aliases must be unique' });
  if (c.parser === 'apple' && (!c.appleBundleId || (c.appleEnvironment === 'Production' && !c.appleAppId)))
    ctx.addIssue({ code: 'custom', message: 'Apple parser requires bundle ID and production App Apple ID' });
});
export type Callback = z.infer<typeof callbackSchema>;
export type NotificationTemplate = z.infer<typeof templateSchema>;
export type Fields = Record<string, unknown>;

export function fieldAt(value: unknown, path: string): unknown {
  for (const key of path.split('.')) {
    if (['__proto__', 'constructor', 'prototype'].includes(key) || value === null || typeof value !== 'object' ||
        !Object.prototype.hasOwnProperty.call(value, key)) return undefined;
    value = (value as Fields)[key];
  }
  return value;
}
export function matches(fields: Fields, c: z.infer<typeof conditionSchema>): boolean {
  const actual = fieldAt(fields, c.field);
  if (actual === undefined || actual === null) return false;
  switch (c.op) {
    case 'eq': return actual === c.value;
    case 'ne': return actual !== c.value;
    case 'contains': return typeof actual === 'string' && typeof c.value === 'string' && actual.includes(c.value);
    case 'gt': return typeof actual === 'number' && typeof c.value === 'number' && actual > c.value;
    case 'lt': return typeof actual === 'number' && typeof c.value === 'number' && actual < c.value;
  }
}
export function evaluate(callback: Callback, payload: Fields) {
  const fields: Fields = { ...payload, mapped: Object.fromEntries(callback.mappings.map(m => [m.field, fieldAt(payload, m.source)])) };
  const trace = [...callback.rules].sort((a, b) => a.priority - b.priority || a.id.localeCompare(b.id)).map(rule => ({
    id: rule.id, name: rule.name, matched: rule.enabled && rule.conditions.every(c => matches(fields, c))
  }));
  const hit = callback.enabled ? trace.find(t => t.matched) : undefined;
  const rule = callback.rules.find(r => r.id === hit?.id);
  const missing = new Set<string>();
  function render(text: string, url = false) {
    return text.replace(/\{\{\s*([\w.-]+)\s*\}\}/g, (_, p: string) => {
      const value = fieldAt(fields, p);
      if (!['string', 'number', 'boolean'].includes(typeof value)) { missing.add(p); return ''; }
      return url ? encodeURIComponent(String(value)) : String(value);
    });
  }
  const notification = rule?.send ? {
    ...rule.template, title: render(rule.template.title), body: render(rule.template.body), url: render(rule.template.url, true)
  } : null;
  if (notification && notification.url && !webURL.safeParse(notification.url).success) throw new Error('Invalid rendered URL');
  return {
    fields, trace, matchedRuleId: hit?.id ?? null, missing: [...missing],
    notification: missing.size === 0 ? notification : null,
    status: !callback.enabled ? 'disabled' : !rule ? 'unmatched' : !rule.send ? 'suppressed' : missing.size ? 'missing_fields' : 'ready'
  };
}
