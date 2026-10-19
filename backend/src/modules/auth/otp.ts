import { randomInt, timingSafeEqual } from 'node:crypto';
import type { FieldCrypto } from '../../lib/field-crypto.js';
import type { SmsProvider } from '../../providers/sms/SmsProvider.js';
import type { SmsBudgetGuard } from '../budget/budget.js';

export interface OtpRecord {
  id: string;
  codeHash: Buffer;
  attempts: number;
  expiresAt: number;
  consumedAt?: number;
}

export interface OtpStore {
  create(c: { id: string; phoneHmac: Buffer; codeHash: Buffer; createdAt: number; expiresAt: number }): Promise<void>;
  latest(phoneHmac: Buffer): Promise<OtpRecord | null>;
  /** Adds one guess and returns the new total. Must be atomic, so guesses sent together can't each see the old count. */
  bumpAttempts(id: string): Promise<number>;
  /** Marks consumed; false if it was already consumed (so a code can't be used twice). */
  consume(id: string, at: number): Promise<boolean>;
  countSince(phoneHmac: Buffer, sinceMs: number): Promise<number>;
}

export interface OtpOptions {
  ttlMs: number;
  maxAttempts: number;
  maxRequestsPerHour: number;
  smsCostKobo: number;
}

export const DEFAULT_OTP_OPTIONS: OtpOptions = {
  ttlMs: 5 * 60_000,
  maxAttempts: 5,
  maxRequestsPerHour: 5,
  smsCostKobo: 500,
};

export type OtpRequestResult = 'sent' | 'rate_limited' | 'budget_exhausted' | 'send_failed';

export class OtpService {
  constructor(
    private readonly store: OtpStore,
    private readonly sms: SmsProvider,
    private readonly fc: FieldCrypto,
    private readonly budget: SmsBudgetGuard,
    private readonly newId: () => string,
    private readonly clock: () => number = Date.now,
    private readonly opts: OtpOptions = DEFAULT_OTP_OPTIONS,
  ) {}

  private hashCode(id: string, code: string): Buffer {
    return this.fc.blindIndex(`otp|${id}|${code}`);
  }

  async request(phone: string): Promise<OtpRequestResult> {
    const now = this.clock();
    const phoneHmac = this.fc.blindIndex(phone);
    if ((await this.store.countSince(phoneHmac, now - 3_600_000)) >= this.opts.maxRequestsPerHour) return 'rate_limited';
    // Guards against SMS-pumping fraud: OTP texts are routine spend and never touch the emergency reserve.
    if (!this.budget.tryReserve('otp', this.opts.smsCostKobo, false)) return 'budget_exhausted';

    const code = String(randomInt(0, 1_000_000)).padStart(6, '0');
    const id = this.newId();
    await this.store.create({ id, phoneHmac, codeHash: this.hashCode(id, code), createdAt: now, expiresAt: now + this.opts.ttlMs });
    try {
      await this.sms.send({ to: phone, text: `Sentri code: ${code}. Valid for 5 minutes. Never share it.` });
      return 'sent';
    } catch {
      this.budget.refund('otp', this.opts.smsCostKobo);
      return 'send_failed';
    }
  }

  /** True only for the latest, unexpired, unconsumed challenge with the right code. */
  async verify(phone: string, code: string): Promise<boolean> {
    const now = this.clock();
    const rec = await this.store.latest(this.fc.blindIndex(phone));
    if (!rec || rec.consumedAt || rec.expiresAt <= now || rec.attempts >= this.opts.maxAttempts) return false;
    // Count the guess BEFORE checking it, and act on the new total. Guesses sent at the same moment each get
    // their own number, so only the first few are ever compared, whatever the timing.
    if ((await this.store.bumpAttempts(rec.id)) > this.opts.maxAttempts) return false;
    if (!/^\d{6}$/.test(code)) return false;
    const given = this.hashCode(rec.id, code);
    if (given.length !== rec.codeHash.length || !timingSafeEqual(given, rec.codeHash)) return false;
    return this.store.consume(rec.id, now);
  }
}

/** In-memory OTP store for tests and dev. */
export class MemoryOtpStore implements OtpStore {
  rows: (OtpRecord & { phoneHmac: Buffer; createdAt: number })[] = [];

  async create(c: { id: string; phoneHmac: Buffer; codeHash: Buffer; createdAt: number; expiresAt: number }): Promise<void> {
    this.rows.push({ id: c.id, phoneHmac: c.phoneHmac, codeHash: c.codeHash, attempts: 0, createdAt: c.createdAt, expiresAt: c.expiresAt });
  }
  async latest(phoneHmac: Buffer): Promise<OtpRecord | null> {
    const mine = this.rows.filter((r) => r.phoneHmac.equals(phoneHmac));
    return mine.at(-1) ?? null;
  }
  async bumpAttempts(id: string): Promise<number> {
    const r = this.rows.find((x) => x.id === id);
    if (!r) return Infinity;
    r.attempts += 1;
    return r.attempts;
  }
  async consume(id: string, at: number): Promise<boolean> {
    const r = this.rows.find((x) => x.id === id);
    if (!r || r.consumedAt) return false;
    r.consumedAt = at;
    return true;
  }
  async countSince(phoneHmac: Buffer, sinceMs: number): Promise<number> {
    return this.rows.filter((r) => r.phoneHmac.equals(phoneHmac) && r.createdAt >= sinceMs).length;
  }
}
