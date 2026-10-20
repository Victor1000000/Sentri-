import { createHmac } from 'node:crypto';

/**
 * A stable secret for the Telegram webhook, made from TOKEN_SECRET, so nobody has to invent one by hand.
 * 43 characters of A-Z a-z 0-9 _ -, which is what Telegram accepts. Same TOKEN_SECRET gives the same value after a restart.
 */
export function deriveWebhookSecret(tokenSecret: string): string {
  return createHmac('sha256', tokenSecret).update('sentri:telegram-webhook').digest('base64url');
}
