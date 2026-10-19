import { describe, expect, it } from 'vitest';
import { SmsBudgetGuard } from '../src/modules/budget/budget.js';
import { InMemoryDirectory } from '../src/modules/dispatch/directory.js';
import {
  LogOnlyChannel,
  PoliceDispatcher,
  SmsDispatchChannel,
  buildDispatchText,
} from '../src/modules/dispatch/dispatcher.js';
import { HashChainAudit } from '../src/modules/audit/audit.js';
import { MockSmsProvider } from '../src/providers/sms/SmsProvider.js';
import { TermiiSmsProvider } from '../src/providers/sms/TermiiProvider.js';

describe('SMS budget guard', () => {
  const cfg = { dailyLimitKobo: 1000, emergencyReservePct: 20, perUserDailyKobo: 600 };

  it('keeps a reserve: routine sends stop at 80%, critical sends continue to 100%', () => {
    const g = new SmsBudgetGuard(cfg);
    for (let i = 0; i < 8; i++) expect(g.tryReserve(`u${i}`, 100, false)).toBe(true);
    expect(g.tryReserve('x', 100, false)).toBe(false);
    expect(g.tryReserve('x', 100, true)).toBe(true);
    expect(g.tryReserve('y', 100, true)).toBe(true);
    expect(g.tryReserve('z', 100, true)).toBe(false);
  });

  it('caps routine spend per user but never blocks a critical send for that reason', () => {
    const g = new SmsBudgetGuard({ ...cfg, dailyLimitKobo: 100000 });
    for (let i = 0; i < 6; i++) expect(g.tryReserve('u', 100, false)).toBe(true);
    expect(g.tryReserve('u', 100, false)).toBe(false);
    expect(g.tryReserve('u', 100, true)).toBe(true);
  });

  it('refund returns the reservation, and a new UTC day resets it', () => {
    let now = Date.UTC(2026, 9, 12, 12);
    const g = new SmsBudgetGuard(cfg, () => now);
    g.tryReserve('u', 500, true);
    g.refund('u', 500);
    expect(g.spentKobo).toBe(0);
    g.tryReserve('u', 500, true);
    now += 24 * 3_600_000;
    expect(g.spentKobo).toBe(0);
  });
});

describe('Termii provider', () => {
  const opts = { apiKey: 'KEY', senderId: 'Sentri', baseUrl: 'https://api.example', channel: 'dnd' as const, estCostKobo: 500 };

  it('posts the expected request and returns the message id', async () => {
    let seen: { url: string; body: Record<string, unknown> } | undefined;
    const fetchImpl = (async (url: string, init: { body: string }) => {
      seen = { url, body: JSON.parse(init.body) };
      return new Response(JSON.stringify({ message_id: 'm-1' }), { status: 200 });
    }) as unknown as typeof fetch;
    const r = await new TermiiSmsProvider({ ...opts, fetchImpl }).send({ to: '+2348012345678', text: 'hi' });
    expect(r).toEqual({ providerRef: 'm-1', costKobo: 500 });
    expect(seen!.url).toBe('https://api.example/api/sms/send');
    expect(seen!.body).toMatchObject({ to: '2348012345678', from: 'Sentri', sms: 'hi', channel: 'dnd', api_key: 'KEY' });
  });

  it('errors do not leak the key, number or text', async () => {
    const fetchImpl = (async () => new Response('nope', { status: 401 })) as unknown as typeof fetch;
    const p = new TermiiSmsProvider({ ...opts, fetchImpl });
    await expect(p.send({ to: '+2348012345678', text: 'secret text' })).rejects.toThrow(/^termii http 401$/);
  });
});

describe('police dispatch', () => {
  const lga = { id: 'r-lga', name: 'Ikeja Area Command', kind: 'area_command' as const, officialSms: '+2340000000100' };
  const state = { id: 'r-state', name: 'Lagos State Command', kind: 'state_command' as const };
  const fallback = { id: 'r-112', name: 'National emergency line', kind: 'emergency_line' as const };
  const dir = new InMemoryDirectory(
    [
      { room: state, bbox: [6.3, 2.7, 6.7, 4.4], level: 1 },
      { room: lga, bbox: [6.55, 3.3, 6.7, 3.4], level: 2 },
    ],
    fallback,
  );

  it('picks the most specific area, then the state, then the fallback line', async () => {
    expect((await dir.resolve({ lat: 6.6, lon: 3.35, at: 0 }))!.id).toBe('r-lga');
    expect((await dir.resolve({ lat: 6.4, lon: 3.0, at: 0 }))!.id).toBe('r-state');
    expect((await dir.resolve({ lat: 9.0, lon: 7.4, at: 0 }))!.id).toBe('r-112');
    expect((await dir.resolve(undefined))!.id).toBe('r-112');
  });

  it('log-only mode sends nothing but records the routing decision', async () => {
    const audit = new HashChainAudit();
    const d = new PoliceDispatcher(dir, new LogOnlyChannel(), audit, { includeUserPhone: true });
    await d.dispatch({ sosId: 'abcdef123456', geo: { lat: 6.6, lon: 3.35, at: 0 }, duress: false, update: false, at: 0 });
    expect(audit.entries[0]!.action).toBe('dispatch.logged_only');
    expect(audit.entries[0]!.target).toContain('r-lga');
  });

  it('SMS mode uses the control room official line and a minimal ASCII payload', async () => {
    const sms = new MockSmsProvider();
    const d = new PoliceDispatcher(dir, new SmsDispatchChannel(sms), new HashChainAudit(), { includeUserPhone: true });
    await d.dispatch({ sosId: 'abcdef123456', geo: { lat: 6.6, lon: 3.35, accuracyM: 8, at: 0 }, duress: true, update: false, userPhone: '+2348000000000', at: 0 });
    expect(sms.sent).toHaveLength(1);
    expect(sms.sent[0]!.to).toBe('+2340000000100');
    expect(sms.sent[0]!.text).toMatch(/PRIORITY-DURESS/);
    expect(sms.sent[0]!.text).toMatch(/^[\x20-\x7E]+$/);
  });

  it('can leave the user phone out, and says so when there is no location', () => {
    const text = buildDispatchText({ sosId: 'abcdef123456', duress: false, update: false, userPhone: '+2348000000000', at: 0 }, false);
    expect(text).not.toContain('+234');
    expect(text).toContain('loc:unavailable');
  });

  it('a room with no official SMS line is logged, not texted', async () => {
    const sms = new MockSmsProvider();
    const d = new PoliceDispatcher(new InMemoryDirectory([], fallback), new SmsDispatchChannel(sms), new HashChainAudit(), { includeUserPhone: false });
    await d.dispatch({ sosId: 'abcdef123456', duress: false, update: false, at: 0 });
    expect(sms.sent).toHaveLength(0);
  });
});
