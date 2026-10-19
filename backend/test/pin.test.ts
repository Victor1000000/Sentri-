import { describe, expect, it } from 'vitest';
import { PinError, createPinPair, evaluatePin, hashPin, validatePinFormat, verifyPin } from '../src/lib/pin.js';
import { PEPPER } from './helpers.js';

describe('PIN logic', () => {
  it('accepts 4-8 digits only', () => {
    for (const ok of ['1234', '123456', '12345678']) expect(() => validatePinFormat(ok)).not.toThrow();
    for (const bad of ['', '123', '123456789', 'abcd', '12 34', '12.4']) {
      expect(() => validatePinFormat(bad)).toThrow(PinError);
    }
  });

  it('verifies the right PIN and rejects others', async () => {
    const rec = await hashPin('2468', PEPPER);
    expect(await verifyPin('2468', rec, PEPPER)).toBe(true);
    expect(await verifyPin('2469', rec, PEPPER)).toBe(false);
    expect(await verifyPin('abc', rec, PEPPER)).toBe(false);
  });

  it('salts every hash, and the pepper matters', async () => {
    const a = await hashPin('2468', PEPPER);
    const b = await hashPin('2468', PEPPER);
    expect(a.hash).not.toBe(b.hash);
    expect(await verifyPin('2468', a, Buffer.from('x'.repeat(32)))).toBe(false);
  });

  it('refuses identical cancel and duress PINs', async () => {
    await expect(createPinPair('1234', '1234', PEPPER)).rejects.toThrow(PinError);
    await expect(createPinPair('1234', '12', PEPPER)).rejects.toThrow(PinError);
  });

  it('classifies cancel, duress and wrong', async () => {
    const pins = await createPinPair('1234', '4321', PEPPER);
    expect(await evaluatePin('1234', pins, PEPPER)).toBe('cancel');
    expect(await evaluatePin('4321', pins, PEPPER)).toBe('duress');
    expect(await evaluatePin('0000', pins, PEPPER)).toBe('wrong');
    expect(await evaluatePin('', pins, PEPPER)).toBe('wrong');
  });

  it('never stores the PIN in the record', async () => {
    const rec = await hashPin('13572468', PEPPER);
    expect(JSON.stringify(rec)).not.toContain('13572468');
  });
});
