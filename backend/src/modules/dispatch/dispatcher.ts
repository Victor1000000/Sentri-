import type { AuditSink, DispatchInfo, Dispatcher, Logger } from '../../domain/types.js';
import { noopLogger } from '../../domain/types.js';
import type { SmsProvider } from '../../providers/sms/SmsProvider.js';
import type { ControlRoom, Directory } from './directory.js';

export type DispatchOutcome = 'sent' | 'logged_only' | 'failed';

export interface DispatchChannel {
  send(room: ControlRoom, text: string): Promise<DispatchOutcome>;
}

/** Default until an MOU exists: records that a dispatch WOULD have gone out, sends nothing. */
export class LogOnlyChannel implements DispatchChannel {
  async send(): Promise<DispatchOutcome> {
    return 'logged_only';
  }
}

/** Sends to a control room's verified official SMS line, if it has one. */
export class SmsDispatchChannel implements DispatchChannel {
  constructor(private readonly sms: SmsProvider) {}

  async send(room: ControlRoom, text: string): Promise<DispatchOutcome> {
    if (!room.officialSms) return 'logged_only';
    try {
      await this.sms.send({ to: room.officialSms, text });
      return 'sent';
    } catch {
      return 'failed';
    }
  }
}

/** Minimal, ASCII-only text for a control room. No names. */
export function buildDispatchText(i: DispatchInfo, includePhone: boolean): string {
  const parts = ['SENTRI SOS', `ref:${i.sosId.slice(0, 8)}`];
  if (i.update) parts.push('UPDATE');
  if (i.duress) parts.push('PRIORITY-DURESS');
  parts.push(
    i.geo
      ? `loc:${i.geo.lat.toFixed(5)},${i.geo.lon.toFixed(5)}${i.geo.accuracyM ? ` acc:${Math.round(i.geo.accuracyM)}m` : ''}`
      : 'loc:unavailable',
  );
  parts.push(`time:${new Date(i.at).toISOString()}`);
  if (includePhone && i.userPhone) parts.push(`call:${i.userPhone}`);
  return parts.join(' ');
}

export class PoliceDispatcher implements Dispatcher {
  constructor(
    private readonly directory: Directory,
    private readonly channel: DispatchChannel,
    private readonly audit: AuditSink,
    private readonly opts: { includeUserPhone: boolean },
    private readonly log: Logger = noopLogger,
  ) {}

  async dispatch(i: DispatchInfo): Promise<void> {
    const room = await this.directory.resolve(i.geo);
    if (!room) {
      await this.audit.append('system', 'dispatch.no_route', i.sosId);
      this.log.warn({ sosId: i.sosId }, 'no control room resolved');
      return;
    }
    const outcome = await this.channel.send(room, buildDispatchText(i, this.opts.includeUserPhone));
    await this.audit.append('system', `dispatch.${outcome}${i.update ? '.update' : ''}`, `${i.sosId} room:${room.id}`);
  }
}
