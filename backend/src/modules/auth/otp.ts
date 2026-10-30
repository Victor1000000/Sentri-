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
  /** The `count` most recent challenges still open (unconsumed, unexpired) for one phone, newest first. */
  recentOpen(phoneHmac: Buffer, nowMs: number, count: number): Promise<OtpRecord[]>;
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

  /**
   * Creates a fresh code for `phone` and hands it to `deliver` (SMS, Telegram, ...).
   * Same checks every time: at most N codes per hour per number, and the spend guard when the delivery costs money
   * (`costKobo` > 0; free channels like Telegram pass 0 and never touch the SMS budget).
   * If delivery fails the reservation is returned.
   */
  async issue(phone: string, deliver: (code: string) => Promise<void>, costKobo: number = this.opts.smsCostKobo): Promise<OtpRequestResult> {
    const now = this.clock();
    const phoneHmac = this.fc.blindIndex(phone);
    if ((await this.store.countSince(phoneHmac, now - 3_600_000)) >= this.opts.maxRequestsPerHour) return 'rate_limited';
    // Guards against SMS-pumping fraud: OTP texts are routine spend and never touch the emergency reserve.
    if (costKobo > 0 && !this.budget.tryReserve('otp', costKobo, false)) return 'budget_exhausted';

    const code = String(randomInt(0, 1_000_000)).padStart(6, '0');
    const id = this.newId();
    await this.store.create({ id, phoneHmac, codeHash: this.hashCode(id, code), createdAt: now, expiresAt: now + this.opts.ttlMs });
    try {
      await deliver(code);
      return 'sent';
    } catch {
      if (costKobo > 0) this.budget.refund('otp', costKobo);
      return 'send_failed';
    }
  }

  /** Sends the code by SMS. */
  async request(phone: string): Promise<OtpRequestResult> {
    return this.issue(phone, async (code) => {
      await this.sms.send({ to: phone, text: `Sentri code: ${code}. Valid for 5 minutes. Never share it.` });
    });
  }

  /** The named number's newest, unexpired, unconsumed challenge with the right code: counts the guess BEFORE
   * checking it, so guesses sent together each get their own count. */
  async verify(phone: string, code: string): Promise<boolean> {
    const now = this.clock();
    if (!/^\d{6}$/.test(code)) return false;
    const latest = await this.store.latest(this.fc.blindIndex(phone));
    if (
      latest && !latest.consumedAt && latest.expiresAt > now && latest.attempts < this.opts.maxAttempts &&
      (await this.store.bumpAttempts(latest.id)) <= this.opts.maxAttempts
    ) {
      const given = this.hashCode(latest.id, code);
      if (given.length === latest.codeHash.length && timingSafeEqual(given, latest.codeHash)) {
        return this.store.consume(latest.id, now);
      }
    }
    // Telegram replaces a code when "Share my number" is tapped again, so the code being typed may be one
    // challenge old. Try this number's other open codes; each record keeps its own guess count. A code made
    // for one number still cannot sign in another: the records here all share the caller's phone HMAC.
    // Guesses stay bounded: 6 digits, a 5-minute life, and the per-IP limiter on the route.
    for (const rec of await this.store.recentOpen(this.fc.blindIndex(phone), now, 20)) {
      if (latest && rec.id === latest.id) continue;
      if (rec.attempts >= this.opts.maxAttempts) continue;
      const given = this.hashCode(rec.id, code);
      if (given.length === rec.codeHash.length && timingSafeEqual(given, rec.codeHash)) {
        return this.store.consume(rec.id, now);
      }
    }
    return false;
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

  async recentOpen(phoneHmac: Buffer, nowMs: number, count: number): Promise<OtpRecord[]> {
    return this.rows
      .filter((r) => r.phoneHmac.equals(phoneHmac) && !r.consumedAt && r.expiresAt > nowMs)
      .sort((a, b) => b.createdAt - a.createdAt)
      .slice(0, count);
  }
}
