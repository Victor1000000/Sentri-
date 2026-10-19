import { describe, expect, it } from 'vitest';
import { PEPPER, GEO, harness, tokenOf } from './helpers.js';

describe('repeat / acknowledge loop', () => {
  it('waits out the 5 s cancel window, alerts everyone, then repeats every 25 s', async () => {
    const h = await harness();
    const v = await h.engine.start('u1', 'shake', GEO);
    expect(v.state).toBe('countdown');

    await h.sched.advance(4999);
    expect(h.notifier.messages).toHaveLength(0);

    await h.sched.advance(1); // t = 5 s: window ends
    expect(h.notifier.messages).toHaveLength(3);
    expect(h.dispatcher.calls).toHaveLength(1);
    expect(h.dispatcher.calls[0]).toMatchObject({ duress: false, update: false, userPhone: '+2348000000000' });

    await h.sched.advance(25000); // repeat 1
    expect(h.notifier.messages).toHaveLength(6);
    await h.sched.advance(50000); // repeats 2 and 3
    expect(h.notifier.messages).toHaveLength(12);
    expect(h.notifier.messages.map((m) => m.repeat).slice(-3)).toEqual([3, 3, 3]);
    expect(h.dispatcher.calls).toHaveLength(1); // police are alerted once, not every 25 s
  });

  it('is idempotent: a second trigger while one is running returns the same SOS', async () => {
    const h = await harness();
    const a = await h.engine.start('u1', 'shake', GEO);
    const b = await h.engine.start('u1', 'volume', GEO);
    expect(b.sosId).toBe(a.sosId);
    await h.sched.advance(5000);
    expect(h.notifier.messages).toHaveLength(3);
  });

  it('stops as soon as ANY contact taps the link, and tells the user', async () => {
    const h = await harness();
    const { sosId } = await h.engine.start('u1', 'shake', GEO);
    await h.sched.advance(5000);
    const token = tokenOf(h.notifier.messages[1]!.ackUrl);

    expect(await h.engine.acknowledge(token)).toBe('ok');
    expect((await h.store.getEvent(sosId))!.state).toBe('acknowledged');
    expect(h.notifier.userNotices).toEqual([{ userId: 'u1', sosId }]);
    expect(h.sched.pending()).not.toContain(`repeat:${sosId}`);

    const before = h.notifier.messages.length;
    await h.sched.advance(200000);
    expect(h.notifier.messages).toHaveLength(before);
  });

  it('a second tap says someone is already responding', async () => {
    const h = await harness();
    await h.engine.start('u1', 'shake', GEO);
    await h.sched.advance(5000);
    expect(await h.engine.acknowledge(tokenOf(h.notifier.messages[0]!.ackUrl))).toBe('ok');
    expect(await h.engine.acknowledge(tokenOf(h.notifier.messages[1]!.ackUrl))).toBe('already_acknowledged');
    expect(h.notifier.userNotices).toHaveLength(1);
  });

  it('rejects unknown tokens and does not acknowledge from peekAck', async () => {
    const h = await harness();
    const { sosId } = await h.engine.start('u1', 'shake', GEO);
    await h.sched.advance(5000);
    expect(await h.engine.acknowledge('not-a-real-token')).toBe('invalid');
    const token = tokenOf(h.notifier.messages[0]!.ackUrl);
    expect(await h.engine.peekAck(token)).toBe(true);
    expect((await h.store.getEvent(sosId))!.state).toBe('active'); // peeking changed nothing
  });

  it('an ack link stops working once the retention window has passed', async () => {
    const h = await harness({ retentionMs: 60_000, maxRepeats: 1000 });
    await h.engine.start('u1', 'shake', GEO);
    await h.sched.advance(5000);
    const token = tokenOf(h.notifier.messages[0]!.ackUrl);
    await h.sched.advance(61_000);
    expect(await h.engine.acknowledge(token)).toBe('invalid');
  });

  it('expires after the repeat cap instead of running (and costing money) forever', async () => {
    const h = await harness({ maxRepeats: 3 });
    const { sosId } = await h.engine.start('u1', 'shake', GEO);
    await h.sched.advance(5000 + 25000 * 4);
    expect((await h.store.getEvent(sosId))!.state).toBe('expired');
    expect(h.sched.pending()).toEqual([]);
    expect(h.notifier.messages).toHaveLength(9); // 3 rounds x 3 contacts
  });

  it('one failing contact does not stop the others', async () => {
    const h = await harness();
    const orig = h.notifier.sendToContact.bind(h.notifier);
    h.notifier.sendToContact = async (m) => {
      if (m.contact.id === 'c1') throw new Error('boom');
      return orig(m);
    };
    await h.engine.start('u1', 'shake', GEO);
    await h.sched.advance(5000);
    expect(h.notifier.messages.map((m) => m.contact.id)).toEqual(['c2', 'c3']);
  });
});

describe('PIN handling in the SOS flow', () => {
  it('cancel PIN during the window: nothing is ever sent', async () => {
    const h = await harness();
    const { sosId } = await h.engine.start('u1', 'shake', GEO);
    await h.sched.advance(2000);
    expect(await h.engine.submitPin('u1', sosId, '1234')).toEqual({ result: 'cancelled', keepTracking: false });
    await h.sched.advance(120000);
    expect(h.notifier.messages).toHaveLength(0);
    expect(h.dispatcher.calls).toHaveLength(0);
    expect((await h.store.getEvent(sosId))!.state).toBe('cancelled');
  });

  it('cancel PIN after the alert went out stops the loop', async () => {
    const h = await harness();
    const { sosId } = await h.engine.start('u1', 'shake', GEO);
    await h.sched.advance(30000);
    const sent = h.notifier.messages.length;
    await h.engine.submitPin('u1', sosId, '1234');
    await h.sched.advance(120000);
    expect(h.notifier.messages).toHaveLength(sent);
  });

  it('duress PIN in the window: looks cancelled, but the alert goes out marked duress', async () => {
    const h = await harness();
    const { sosId } = await h.engine.start('u1', 'shake', GEO);
    await h.sched.advance(2000);
    expect(await h.engine.submitPin('u1', sosId, '4321')).toEqual({ result: 'cancelled', keepTracking: true });
    await h.sched.advance(3000);
    expect(h.notifier.messages).toHaveLength(3);
    expect(h.notifier.messages.every((m) => m.kind === 'duress')).toBe(true);
    expect(h.dispatcher.calls[0]).toMatchObject({ duress: true });
  });

  it('duress PIN while active: switches repeats to duress, updates police, hides the ack from the user', async () => {
    const h = await harness();
    const { sosId } = await h.engine.start('u1', 'shake', GEO);
    await h.sched.advance(5000);
    expect(h.notifier.ofKind('sos')).toHaveLength(3);

    expect((await h.engine.submitPin('u1', sosId, '4321')).result).toBe('cancelled');
    expect((await h.store.getEvent(sosId))!.state).toBe('active'); // still running
    expect(h.dispatcher.calls).toHaveLength(2);
    expect(h.dispatcher.calls[1]).toMatchObject({ duress: true, update: true });

    await h.sched.advance(25000);
    expect(h.notifier.ofKind('duress')).toHaveLength(3);

    expect(await h.engine.acknowledge(tokenOf(h.notifier.ofKind('duress')[0]!.ackUrl))).toBe('ok');
    expect(h.notifier.userNotices).toHaveLength(0); // a watched phone must not buzz
  });

  it('wrong PIN keeps the alert going; repeated wrong PINs lock entry, then it recovers', async () => {
    const h = await harness();
    const { sosId } = await h.engine.start('u1', 'shake', GEO);
    await h.sched.advance(5000);

    for (let i = 0; i < 4; i++) {
      expect((await h.engine.submitPin('u1', sosId, '9999')).result).toBe('wrong');
    }
    expect((await h.engine.submitPin('u1', sosId, '9999')).result).toBe('locked');
    // even the right PIN is refused while locked
    expect((await h.engine.submitPin('u1', sosId, '1234')).result).toBe('locked');
    expect((await h.store.getEvent(sosId))!.state).toBe('active');

    await h.sched.advance(300_001);
    expect((await h.engine.submitPin('u1', sosId, '1234')).result).toBe('cancelled');
    expect((await h.store.getEvent(sosId))!.state).toBe('cancelled');
  });

  it("another user's PIN attempt on this SOS is not found", async () => {
    const h = await harness();
    const { sosId } = await h.engine.start('u1', 'shake', GEO);
    expect((await h.engine.submitPin('someone-else', sosId, '1234')).result).toBe('not_found');
  });
});

describe('offline and low battery', () => {
  it('tells contacts once if the phone goes quiet during an SOS', async () => {
    const h = await harness();
    await h.engine.start('u1', 'shake', GEO);
    await h.sched.advance(80_000);
    expect(h.notifier.ofKind('offline')).toHaveLength(0);
    await h.sched.advance(30_000); // > 90 s since last heartbeat
    expect(h.notifier.ofKind('offline')).toHaveLength(3);
    expect(h.notifier.ofKind('offline')[0]!.locationUrl).toMatch(/^https:\/\/sentri\.example\/l\//);
    await h.sched.advance(100_000);
    expect(h.notifier.ofKind('offline')).toHaveLength(3); // once, not every tick
  });

  it('location heartbeats keep the offline notice away', async () => {
    const h = await harness();
    const { sosId } = await h.engine.start('u1', 'shake', GEO);
    for (let i = 0; i < 6; i++) {
      await h.sched.advance(20_000);
      expect(await h.engine.updateLocation('u1', sosId, GEO)).toEqual({ state: 'active' });
    }
    expect(h.notifier.ofKind('offline')).toHaveLength(0);
  });

  it('tells the phone when a contact is responding, but hides it under duress', async () => {
    const h = await harness();
    const { sosId } = await h.engine.start('u1', 'shake', GEO);
    await h.sched.advance(5000);
    await h.engine.acknowledge(tokenOf(h.notifier.messages[0]!.ackUrl));
    expect(await h.engine.updateLocation('u1', sosId, GEO)).toEqual({ state: 'acknowledged' });

    const d = await harness();
    const s = await d.engine.start('u1', 'shake', GEO);
    await d.sched.advance(5000);
    await d.engine.submitPin('u1', s.sosId, '4321'); // duress
    await d.engine.acknowledge(tokenOf(d.notifier.ofKind('sos')[0]!.ackUrl));
    expect(await d.engine.updateLocation('u1', s.sosId, GEO)).toEqual({ state: 'active' });
  });

  it('stops accepting location once the alert is cancelled', async () => {
    const h = await harness();
    const { sosId } = await h.engine.start('u1', 'shake', GEO);
    await h.engine.submitPin('u1', sosId, '1234');
    expect(await h.engine.updateLocation('u1', sosId, GEO)).toBeNull();
    expect(await h.engine.updateLocation('someone-else', sosId, GEO)).toBeNull();
  });

  it('low battery sends one "last known location" alert and is rate limited', async () => {
    const h = await harness();
    expect(await h.engine.lowBattery('u1', GEO)).toEqual({ sent: true });
    expect(h.notifier.ofKind('low_battery')).toHaveLength(3);
    expect(h.notifier.ofKind('low_battery')[0]).toMatchObject({ sosId: null, repeat: 0 });
    expect(await h.engine.lowBattery('u1', GEO)).toEqual({ sent: false });
    expect(h.notifier.ofKind('low_battery')).toHaveLength(3);
  });
});

describe('audit trail', () => {
  it('records the lifecycle without PII, and the hash chain verifies', async () => {
    const h = await harness();
    const { sosId } = await h.engine.start('u1', 'shake', GEO);
    await h.sched.advance(5000);
    await h.engine.submitPin('u1', sosId, '1234');
    expect(h.audit.entries.map((e) => e.action)).toEqual(['sos.start', 'sos.active', 'sos.cancel']);
    expect(JSON.stringify(h.audit.entries)).not.toMatch(/\+234|6\.5244/);
    expect(h.audit.verify()).toBe(true);
    h.audit.entries[1]!.action = 'tampered';
    expect(h.audit.verify()).toBe(false);
  });
});

void PEPPER;

describe('what contacts can see', () => {
  it('shows the latest position and updates as the phone reports', async () => {
    const h = await harness();
    const { sosId } = await h.engine.start('u1', 'shake', GEO);
    await h.sched.advance(5000);
    const token = tokenOf(h.notifier.messages[0]!.ackUrl);
    const first = await h.engine.viewAlert(token, 'ack');
    expect(first).toMatchObject({ responding: false, geo: { lat: GEO.lat, lon: GEO.lon } });
    await h.engine.updateLocation('u1', sosId, { ...GEO, lat: GEO.lat + 0.01 });
    expect(await h.engine.viewAlert(token, 'ack')).toMatchObject({ geo: { lat: GEO.lat + 0.01 } });
  });

  it('reports "responding" after a contact taps, and "ended" once it is over', async () => {
    const h = await harness();
    const { sosId } = await h.engine.start('u1', 'shake', GEO);
    await h.sched.advance(5000);
    const token = tokenOf(h.notifier.messages[0]!.ackUrl);
    await h.engine.acknowledge(token);
    expect(await h.engine.viewAlert(token, 'ack')).toMatchObject({ responding: true });
    await h.engine.submitPin('u1', sosId, '1234');
    expect(await h.engine.viewAlert(token, 'ack')).toBe('ended');
  });

  it('refuses the wrong kind of link and unknown tokens', async () => {
    const h = await harness();
    await h.engine.start('u1', 'shake', GEO);
    await h.sched.advance(5000);
    const token = tokenOf(h.notifier.messages[0]!.ackUrl);
    expect(await h.engine.viewAlert(token, 'loc')).toBe('invalid');
    expect(await h.engine.viewAlert('nope', 'ack')).toBe('invalid');
  });

  it('the low-battery text carries a working map link for the last position, or says unknown', async () => {
    const h = await harness();
    await h.engine.lowBattery('u1', GEO);
    const m = h.notifier.ofKind('low_battery');
    expect(m).toHaveLength(3);
    expect(m[0]!.locationUrl).toBe(`https://osm.org/?mlat=${GEO.lat.toFixed(3)}&mlon=${GEO.lon.toFixed(3)}`);
    const h2 = await harness();
    await h2.engine.lowBattery('u1');
    expect(h2.notifier.ofKind('low_battery')[0]!.locationUrl).toBe('unknown');
  });
});
