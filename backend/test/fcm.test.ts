import { createVerify, generateKeyPairSync } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import { FcmPushSender, type PushTokenStore } from '../src/modules/notify/fcm.js';

const { privateKey, publicKey } = generateKeyPairSync('rsa', {
  modulusLength: 2048,
  privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
  publicKeyEncoding: { type: 'spki', format: 'pem' },
});
const account = { project_id: 'sentri-test', client_email: 'svc@sentri-test.iam.gserviceaccount.com', private_key: privateKey };

function rig(opts: { sendStatus?: number; sendBody?: unknown } = {}) {
  const forgotten: string[] = [];
  const store: PushTokenStore = {
    tokensForUser: async () => [{ deviceId: 'd1', token: 'tok1' }, { deviceId: 'd2', token: 'tok2' }],
    tokensForContact: async (id) => (id === 'none' ? [] : [{ deviceId: 'd9', token: 'tok9' }]),
    forgetToken: async (id) => void forgotten.push(id),
  };
  const calls: { url: string; body?: string; auth?: string }[] = [];
  let tokenCalls = 0;
  let now = 1_000_000;
  const fetchFn = (async (url: string, init: RequestInit) => {
    calls.push({ url, body: String(init.body), auth: (init.headers as Record<string, string>)?.authorization });
    if (url.includes('oauth2')) {
      tokenCalls++;
      return new Response(JSON.stringify({ access_token: `at${tokenCalls}`, expires_in: 3600 }), { status: 200 });
    }
    return new Response(JSON.stringify(opts.sendBody ?? {}), { status: opts.sendStatus ?? 200 });
  }) as unknown as typeof fetch;
  const sender = new FcmPushSender(store, account, fetchFn, () => now);
  return { sender, calls, forgotten, tick: (ms: number) => (now += ms), tokenCalls: () => tokenCalls };
}

describe('FcmPushSender', () => {
  it('signs a valid RS256 JWT for the token exchange', async () => {
    const r = rig();
    await r.sender.sendToUser('u1', { kind: 'sos', text: 'hi' });
    const form = new URLSearchParams(r.calls[0].body);
    const [h, c, s] = form.get('assertion')!.split('.');
    expect(JSON.parse(Buffer.from(h, 'base64url').toString())).toEqual({ alg: 'RS256', typ: 'JWT' });
    const claim = JSON.parse(Buffer.from(c, 'base64url').toString());
    expect(claim.iss).toBe(account.client_email);
    expect(claim.scope).toContain('firebase.messaging');
    expect(createVerify('RSA-SHA256').update(`${h}.${c}`).verify(publicKey, Buffer.from(s, 'base64url'))).toBe(true);
  });

  it('sends a data-only, high-priority message to every device and reuses the access token', async () => {
    const r = rig();
    expect(await r.sender.sendToUser('u1', { kind: 'sos', text: 'help', sosId: 's1', inboxId: 'i-1' })).toBe(true);
    await r.sender.sendToUser('u1', { kind: 'sos', text: 'again' });
    expect(r.tokenCalls()).toBe(1);
    const sends = r.calls.filter((c) => c.url.includes('messages:send'));
    expect(sends).toHaveLength(4);
    const m = JSON.parse(sends[0].body!).message;
    expect(m.data).toEqual({ kind: 'sos', text: 'help', sosId: 's1', inboxId: 'i-1' });
    expect(m.notification).toBeUndefined();
    expect(m.android.priority).toBe('HIGH');
    expect(sends[0].auth).toBe('Bearer at1');
  });

  it('refreshes the access token when it is about to expire', async () => {
    const r = rig();
    await r.sender.sendToUser('u1', { kind: 'sos', text: 'a' });
    r.tick(3_600_000);
    await r.sender.sendToUser('u1', { kind: 'sos', text: 'b' });
    expect(r.tokenCalls()).toBe(2);
  });

  it('returns false when there is nothing to send to', async () => {
    const r = rig();
    expect(await r.sender.sendToContact('none', { kind: 'sos', text: 'x' })).toBe(false);
    expect(r.calls).toHaveLength(0);
  });

  it('forgets tokens FCM says are gone, and never throws on failures', async () => {
    const r = rig({ sendStatus: 404, sendBody: { error: { status: 'UNREGISTERED' } } });
    expect(await r.sender.sendToUser('u1', { kind: 'sos', text: 'x' })).toBe(false);
    expect(r.forgotten.sort()).toEqual(['d1', 'd2']);
  });

  it('keeps tokens on a server error', async () => {
    const r = rig({ sendStatus: 503 });
    expect(await r.sender.sendToUser('u1', { kind: 'sos', text: 'x' })).toBe(false);
    expect(r.forgotten).toEqual([]);
  });
});
