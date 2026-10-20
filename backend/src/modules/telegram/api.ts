/** A button under the chat box that asks the user to share their own phone number. */
export interface ShareButton {
  text: string;
}

/** What the login bot needs from Telegram. Kept small so tests can stand in for it. */
export interface TelegramApi {
  sendMessage(chatId: number, html: string, shareButton?: ShareButton): Promise<void>;
  setWebhook(url: string, secret: string): Promise<void>;
}

type FetchLike = (url: string, init: { method: string; headers: Record<string, string>; body: string; signal: AbortSignal }) => Promise<{
  ok: boolean;
  status: number;
  json(): Promise<unknown>;
}>;

/**
 * Thin client for the Telegram Bot API (built-in fetch, 8 s timeout).
 * The bot token is part of every request URL, so errors here never include the URL, the token or the original message.
 */
export class TelegramBotApi implements TelegramApi {
  constructor(
    private readonly token: string,
    private readonly doFetch: FetchLike = fetch as unknown as FetchLike,
    private readonly timeoutMs = 8000,
  ) {}

  private async call(method: string, body: Record<string, unknown>): Promise<void> {
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), this.timeoutMs);
    try {
      let res;
      try {
        res = await this.doFetch(`https://api.telegram.org/bot${this.token}/${method}`, {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify(body),
          signal: ctl.signal,
        });
      } catch {
        throw new Error(`telegram ${method} failed: network`);
      }
      let ok = res.ok;
      if (ok) {
        try {
          ok = (await res.json() as { ok?: boolean }).ok === true;
        } catch {
          ok = false;
        }
      }
      if (!ok) throw new Error(`telegram ${method} failed: status ${res.status}`);
    } finally {
      clearTimeout(timer);
    }
  }

  async sendMessage(chatId: number, html: string, shareButton?: ShareButton): Promise<void> {
    await this.call('sendMessage', {
      chat_id: chatId,
      text: html,
      parse_mode: 'HTML',
      disable_web_page_preview: true,
      ...(shareButton
        ? { reply_markup: { keyboard: [[{ text: shareButton.text, request_contact: true }]], resize_keyboard: true, one_time_keyboard: false } }
        : {}),
    });
  }

  async setWebhook(url: string, secret: string): Promise<void> {
    await this.call('setWebhook', { url, secret_token: secret, allowed_updates: ['message'], drop_pending_updates: true });
  }
}
