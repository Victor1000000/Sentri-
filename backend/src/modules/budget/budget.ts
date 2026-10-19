export interface BudgetConfig {
  /** Total SMS spend allowed per UTC day, in kobo. */
  dailyLimitKobo: number;
  /** Share of the daily limit kept back for critical sends (first alerts, duress, offline). */
  emergencyReservePct: number;
  /** Max routine spend per user per day. Critical sends ignore this. */
  perUserDailyKobo: number;
}

/**
 * SMS budget guard. Routine repeats stop when the routine budget is used up,
 * but the first alert of every SOS can still go out from the reserved share.
 * In-memory for now; the Postgres/Redis version follows in step 1b.
 */
export class SmsBudgetGuard {
  private day = '';
  private spent = 0;
  private perUser = new Map<string, number>();

  constructor(
    private readonly cfg: BudgetConfig,
    private readonly clock: () => number = Date.now,
  ) {}

  private roll(): void {
    const d = new Date(this.clock()).toISOString().slice(0, 10);
    if (d !== this.day) {
      this.day = d;
      this.spent = 0;
      this.perUser.clear();
    }
  }

  /** Reserves the cost if allowed. Returns false when the send should be skipped. */
  tryReserve(userId: string, costKobo: number, critical: boolean): boolean {
    this.roll();
    const routineCeiling = this.cfg.dailyLimitKobo * (1 - this.cfg.emergencyReservePct / 100);
    const ceiling = critical ? this.cfg.dailyLimitKobo : routineCeiling;
    if (this.spent + costKobo > ceiling) return false;
    const user = this.perUser.get(userId) ?? 0;
    if (!critical && user + costKobo > this.cfg.perUserDailyKobo) return false;
    this.spent += costKobo;
    this.perUser.set(userId, user + costKobo);
    return true;
  }

  /** Gives the reservation back when the provider call failed. */
  refund(userId: string, costKobo: number): void {
    this.roll();
    this.spent = Math.max(0, this.spent - costKobo);
    this.perUser.set(userId, Math.max(0, (this.perUser.get(userId) ?? 0) - costKobo));
  }

  get spentKobo(): number {
    this.roll();
    return this.spent;
  }
}
