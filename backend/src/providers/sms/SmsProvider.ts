export interface SmsMessage {
  /** E.164, e.g. +2348012345678 */
  to: string;
  text: string;
}

export interface SmsSendResult {
  providerRef: string;
  costKobo: number;
}

/** Providers are swappable: Termii today, anything else tomorrow. */
export interface SmsProvider {
  send(m: SmsMessage): Promise<SmsSendResult>;
}

/** Records messages instead of sending them. Used in tests and local development. */
export class MockSmsProvider implements SmsProvider {
  readonly sent: SmsMessage[] = [];
  failNext = false;

  constructor(private readonly costKobo = 0) {}

  async send(m: SmsMessage): Promise<SmsSendResult> {
    if (this.failNext) {
      this.failNext = false;
      throw new Error('mock sms failure');
    }
    this.sent.push(m);
    return { providerRef: `mock-${this.sent.length}`, costKobo: this.costKobo };
  }
}
