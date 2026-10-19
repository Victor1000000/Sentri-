import { createHmac, createHash } from 'node:crypto';

/**
 * Short, deterministic link tokens (16 chars, 96 bits).
 * Short on purpose: the URL travels by SMS, where length drives cost.
 * Deterministic so the server can re-send the same link on every repeat
 * without storing the raw token; only sha256(token) is stored.
 */
export function linkToken(
  secret: string,
  kind: 'ack' | 'loc' | 'consent',
  subject: string,
  contactId: string,
): string {
  return createHmac('sha256', secret)
    .update(`${kind}|${subject}|${contactId}`)
    .digest('base64url')
    .slice(0, 16);
}

export function hashToken(token: string): string {
  return createHash('sha256').update(token).digest('hex');
}
