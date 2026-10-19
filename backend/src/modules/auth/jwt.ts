import { createHmac, timingSafeEqual } from 'node:crypto';

/** Minimal HS256 JWT. Only HS256 is accepted, so "alg: none" and algorithm-swap tricks don't apply. */

export interface AccessClaims {
  /** user id */
  sub: string;
  /** device id */
  did: string;
}

const b64u = (b: Buffer | string) => Buffer.from(b).toString('base64url');
const HEADER = b64u(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));

function mac(data: string, secret: string): Buffer {
  return createHmac('sha256', secret).update(data).digest();
}

export function signAccessToken(claims: AccessClaims, secret: string, ttlSec: number, nowMs: number): string {
  const iat = Math.floor(nowMs / 1000);
  const body = b64u(JSON.stringify({ ...claims, iat, exp: iat + ttlSec }));
  const data = `${HEADER}.${body}`;
  return `${data}.${b64u(mac(data, secret))}`;
}

export function verifyAccessToken(token: string, secret: string, nowMs: number): AccessClaims | null {
  const parts = token.split('.');
  if (parts.length !== 3 || parts[0] !== HEADER) return null;
  const given = Buffer.from(parts[2]!, 'base64url');
  const expected = mac(`${parts[0]}.${parts[1]}`, secret);
  if (given.length !== expected.length || !timingSafeEqual(given, expected)) return null;
  try {
    const p = JSON.parse(Buffer.from(parts[1]!, 'base64url').toString('utf8')) as Partial<AccessClaims> & { exp?: number };
    if (typeof p.sub !== 'string' || typeof p.did !== 'string' || typeof p.exp !== 'number') return null;
    if (p.exp * 1000 <= nowMs) return null;
    return { sub: p.sub, did: p.did };
  } catch {
    return null;
  }
}
