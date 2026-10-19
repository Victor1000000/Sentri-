import { describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.js';
import { FixedWindowLimiter } from '../src/lib/rate-limit.js';
import { CachedGeocoder, NominatimGeocoder, placeFromNominatim, type ReverseGeocoder } from '../src/modules/geo/geocoder.js';
import { harness } from './helpers.js';

describe('placeFromNominatim', () => {
  it('maps a Lagos address to street, area, LGA and state', () => {
    const p = placeFromNominatim({ road: 'Allen Avenue', suburb: 'Ikeja', county: 'Ikeja', state: 'Lagos State' });
    expect(p).toEqual({ street: 'Allen Avenue', area: 'Ikeja', lga: 'Ikeja', state: 'Lagos', label: 'Allen Avenue, Ikeja, Lagos' });
  });
  it('returns null when nothing usable is there', () => {
    expect(placeFromNominatim({})).toBeNull();
    expect(placeFromNominatim(undefined)).toBeNull();
  });
});

describe('NominatimGeocoder', () => {
  it('calls /reverse and parses the address', async () => {
    let seen = '';
    const fake = (async (u: URL) => {
      seen = u.toString();
      return new Response(JSON.stringify({ address: { road: 'Aba Road', state: 'Rivers State' } }), { status: 200 });
    }) as unknown as typeof fetch;
    const g = new NominatimGeocoder('http://geo.internal', 500, fake);
    expect((await g.reverse(4.8, 7.01))?.label).toBe('Aba Road, Rivers');
    expect(seen).toContain('/reverse?');
    expect(seen).toContain('lat=4.8');
  });
  it('returns null on errors and timeouts instead of throwing', async () => {
    const boom = (async () => { throw new Error('down'); }) as unknown as typeof fetch;
    expect(await new NominatimGeocoder('http://x', 500, boom).reverse(1, 1)).toBeNull();
    const bad = (async () => new Response('no', { status: 500 })) as unknown as typeof fetch;
    expect(await new NominatimGeocoder('http://x', 500, bad).reverse(1, 1)).toBeNull();
  });
});

describe('CachedGeocoder', () => {
  it('serves nearby repeat lookups from cache until the TTL passes', async () => {
    let calls = 0;
    let now = 0;
    const inner: ReverseGeocoder = { reverse: async () => { calls++; return { label: 'X' }; } };
    const g = new CachedGeocoder(inner, 1000, 10, () => now);
    await g.reverse(6.52441, 3.37921);
    await g.reverse(6.52442, 3.37922); // same ~11 m cell
    expect(calls).toBe(1);
    now = 2000;
    await g.reverse(6.52441, 3.37921);
    expect(calls).toBe(2);
  });
});

describe('GET /v1/geo/reverse', () => {
  async function appWith(geocoder?: ReverseGeocoder) {
    const h = await harness({});
    return buildApp({
      engine: h.engine,
      authenticate: async (req) => (req.headers['x-user'] as string | undefined) ?? null,
      startLimiter: new FixedWindowLimiter(5, 60_000),
      ackLimiter: new FixedWindowLimiter(5, 60_000),
      geocoder,
      geoLimiter: new FixedWindowLimiter(2, 60_000),
    });
  }
  const hdr = { 'x-user': 'u1' };

  it('needs a signed-in user, valid numbers, and a configured geocoder', async () => {
    const app = await appWith({ reverse: async () => ({ label: 'Allen Avenue, Ikeja, Lagos' }) });
    expect((await app.inject({ url: '/v1/geo/reverse?lat=6.5&lon=3.3' })).statusCode).toBe(401);
    expect((await app.inject({ url: '/v1/geo/reverse?lat=999&lon=3.3', headers: hdr })).statusCode).toBe(400);
    const ok = await app.inject({ url: '/v1/geo/reverse?lat=6.5&lon=3.3', headers: hdr });
    expect(ok.json()).toEqual({ place: { label: 'Allen Avenue, Ikeja, Lagos' } });
    expect((await (await appWith()).inject({ url: '/v1/geo/reverse?lat=6.5&lon=3.3', headers: hdr })).statusCode).toBe(404);
  });

  it('rate limits per user', async () => {
    const app = await appWith({ reverse: async () => null });
    for (let i = 0; i < 2; i++) await app.inject({ url: '/v1/geo/reverse?lat=6.5&lon=3.3', headers: hdr });
    expect((await app.inject({ url: '/v1/geo/reverse?lat=6.5&lon=3.3', headers: hdr })).statusCode).toBe(429);
  });
});
