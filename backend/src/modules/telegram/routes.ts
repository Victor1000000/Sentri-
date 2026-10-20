import { createHash, timingSafeEqual } from 'node:crypto';
import type { FastifyInstance } from 'fastify';
import type { TelegramLoginBot } from './bot.js';

export interface TelegramRouteDeps {
  bot: TelegramLoginBot;
  /** Sent back by Telegram in a header on every webhook call. */
  secret: string;
}

const digest = (s: string) => createHash('sha256').update(s).digest();

/** Constant-time comparison, so the secret cannot be guessed from response timing. */
function sameSecret(given: unknown, expected: string): boolean {
  if (typeof given !== 'string') return false;
  return timingSafeEqual(digest(given), digest(expected));
}

export function registerTelegramRoutes(app: FastifyInstance, d: TelegramRouteDeps): void {
  app.post('/v1/telegram/webhook', { bodyLimit: 64 * 1024 }, async (req, reply) => {
    if (!sameSecret(req.headers['x-telegram-bot-api-secret-token'], d.secret)) return reply.code(401).send({ error: 'unauthorized' });
    await d.bot.handle(req.body);
    // Always 200 for a valid call, so Telegram does not keep retrying an update we chose to ignore.
    return reply.code(200).send({ ok: true });
  });
}
