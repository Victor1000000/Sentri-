import { z } from 'zod';
import type { FixedWindowLimiter } from '../../lib/rate-limit.js';
import type { OtpService } from '../auth/otp.js';
import { normalizePhone } from '../auth/phone.js';
import type { TelegramApi } from './api.js';

/** Only the parts of a Telegram update we use. Anything else is ignored. */
const UpdateSchema = z.object({
  message: z
    .object({
      chat: z.object({ id: z.number().int(), type: z.string() }),
      from: z.object({ id: z.number().int(), is_bot: z.boolean().optional() }).optional(),
      text: z.string().optional(),
      contact: z.object({ phone_number: z.string(), user_id: z.number().int().optional() }).optional(),
    })
    .optional(),
});

const SHARE = { text: 'Share my number' } as const;
const NEW_CODE = { text: 'Get a new code' } as const;

export interface LoginBotDeps {
  api: TelegramApi;
  otp: OtpService;
  defaultCountryCode: string;
  /** Per-person cap on how often the bot answers, so nobody can make it spam. */
  chatLimiter: FixedWindowLimiter;
  log?: { warn: (o: Record<string, unknown>, m?: string) => void };
}

/**
 * Sign-in codes over Telegram. The person opens the bot, taps Start, then "Share my number".
 * The code is made for the number Telegram itself reports for that account. Only the person's own contact is accepted
 * (contact.user_id must equal the sender), so nobody can ask for a code for a number they do not own.
 */
export class TelegramLoginBot {
  constructor(private readonly d: LoginBotDeps) {}

  /** Handles one update from the webhook. Never throws. */
  async handle(update: unknown): Promise<void> {
    try {
      await this.process(update);
    } catch {
      this.d.log?.warn({}, 'telegram update failed');
    }
  }

  private async process(update: unknown): Promise<void> {
    const parsed = UpdateSchema.safeParse(update);
    const m = parsed.success ? parsed.data.message : undefined;
    // Private chats with a real person only: no groups, no bots, nothing without a sender.
    if (!m || !m.from || m.from.is_bot || m.chat.type !== 'private') return;
    if (!this.d.chatLimiter.allow(`tg:${m.from.id}`)) return;
    const chatId = m.chat.id;

    if (m.contact) {
      if (m.contact.user_id !== m.from.id) {
        await this.d.api.sendMessage(chatId, 'For your safety, please share your <b>own</b> number with the button below.', SHARE);
        return;
      }
      const digits = m.contact.phone_number.replace(/\D/g, '');
      const phone = normalizePhone(`+${digits}`, this.d.defaultCountryCode);
      if (!phone) {
        await this.d.api.sendMessage(chatId, 'Sorry, we cannot use that number.');
        return;
      }
      const result = await this.d.otp.issue(
        phone,
        (code) =>
          this.d.api.sendMessage(
            chatId,
            `Your Sentri code: <code>${code}</code>\nIt works for 5 minutes. Type it into the Sentri app. Never share it.`,
            NEW_CODE,
          ),
        0,
      );
      if (result === 'rate_limited') await this.d.api.sendMessage(chatId, 'Too many codes. Please try again in an hour.');
      else if (result === 'send_failed') this.d.log?.warn({}, 'telegram code could not be delivered');
      return;
    }

    // /start or anything else: explain and show the button.
    await this.d.api.sendMessage(
      chatId,
      'Welcome to Sentri. Tap <b>Share my number</b> below and we will send your sign-in code here. Only share your own number.',
      SHARE,
    );
  }
}
