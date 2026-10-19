import type { SmsMessage, SmsProvider, SmsSendResult } from './SmsProvider.js';

export interface TermiiOptions {
  apiKey: string;
  senderId: string;
  baseUrl: string;
  /** 'dnd' routes to numbers on Do-Not-Disturb lists, which transactional alerts need. */
  channel: 'generic' | 'dnd';
  /** Termii's response does not include cost; this is an estimate for budgeting. */
  estCostKobo: number;
  fetchImpl?: typeof fetch;
}

export class TermiiSmsProvider implements SmsProvider {
  constructor(private readonly o: TermiiOptions) {}

  async send(m: SmsMessage): Promise<SmsSendResult> {
    const doFetch = this.o.fetchImpl ?? fetch;
    const res = await doFetch(`${this.o.baseUrl}/api/sms/send`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        to: m.to.replace(/^\+/, ''),
        from: this.o.senderId,
        sms: m.text,
        type: 'plain',
        channel: this.o.channel,
        api_key: this.o.apiKey,
      }),
      signal: AbortSignal.timeout(8000),
    });
    // Error messages deliberately omit the request body (it holds the key, number and text).
    const json = (await res.json().catch(() => ({}))) as { message_id?: string; message?: string };
    const why = typeof json.message === 'string' ? `: ${json.message.slice(0, 120)}` : '';
    if (!res.ok) throw new Error(`termii http ${res.status}${why}`);
    if (!json.message_id) throw new Error(`termii response missing message_id${why}`);
    return { providerRef: json.message_id, costKobo: this.o.estCostKobo };
  }
}
