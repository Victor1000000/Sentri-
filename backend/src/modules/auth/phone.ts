import { z } from 'zod';
import type { Locale } from '../../domain/types.js';

/**
 * Normalises a phone number to E.164. Nigerian local format (0803 123 4567) becomes +234803...
 * Returns null for anything that isn't plausibly a phone number.
 */
export function normalizePhone(input: string, defaultCountryCode = '234'): string | null {
  const s = input.replace(/[\s\-().]/g, '');
  let e164: string;
  if (/^\+\d+$/.test(s)) e164 = s;
  else if (/^00\d+$/.test(s)) e164 = `+${s.slice(2)}`;
  else if (/^0\d+$/.test(s)) e164 = `+${defaultCountryCode}${s.slice(1)}`;
  else if (new RegExp(`^${defaultCountryCode}\\d+$`).test(s)) e164 = `+${s}`;
  else return null;
  if (!/^\+[1-9]\d{7,14}$/.test(e164)) return null;
  // Nigeria: +234 followed by a 10-digit national number.
  if (e164.startsWith('+234') && e164.length !== 14) return null;
  return e164;
}

export const LocaleSchema = z.enum(['en', 'ha', 'yo', 'ig', 'pcm', 'fr', 'es']);

export const MIN_CONTACTS = 2;
export const MAX_CONTACTS = 10;

export class ContactError extends Error {}

/** The common dial codes, for guessing a country from the owner's own number.
 *  Longest-prefix match: '+234…' matches '234' before '23' before '2'. Not a
 *  libphonenumber replacement - just enough to pick the right default for
 *  contacts typed in local format, anywhere in the world. */
const DIAL_CODES = new Set<string>([
  // 4-digit NANP-style overseas codes
  '1242', '1246', '1264', '1268', '1441', '1473', '1664', '1758', '1809', '1868', '1869', '1876',
  // 3-digit codes (Africa, Europe, Asia, Americas, Oceania)
  '212', '213', '216', '218', '220', '221', '222', '223', '224', '225', '226', '227', '228', '229',
  '230', '231', '232', '233', '234', '235', '236', '237', '238', '239', '240', '241', '242', '243',
  '244', '245', '248', '249', '250', '251', '252', '253', '254', '255', '256', '257', '258', '260',
  '261', '262', '263', '264', '265', '266', '267', '268', '269', '290', '291', '297', '298', '299',
  '350', '351', '352', '353', '354', '355', '356', '357', '358', '359', '370', '371', '372', '373',
  '374', '375', '376', '377', '378', '380', '381', '382', '383', '385', '386', '387', '389',
  '420', '421', '423',
  '501', '502', '503', '504', '505', '506', '507', '508', '509',
  '590', '591', '592', '593', '594', '595', '596', '597', '598', '599',
  '670', '673', '674', '675', '676', '677', '678', '679', '680', '682', '685', '686', '687', '688',
  '689', '691', '692',
  '850', '852', '853', '855', '856', '880', '886',
  '960', '961', '962', '963', '964', '965', '966', '968', '971', '972', '973', '974', '975', '976',
  '977', '992', '993', '994', '995', '996', '998',
  // 2-digit codes
  '20', '27', '30', '31', '32', '33', '34', '36', '39', '40', '41', '43', '44', '45', '46', '47',
  '48', '49', '51', '52', '53', '54', '55', '56', '57', '58', '60', '61', '62', '63', '64', '65',
  '66', '81', '82', '84', '86', '90', '91', '92', '93', '94', '95', '98',
  // 1-digit codes
  '1', '7',
]);

/** Best-effort dial code from the owner's own E.164 number: '+234803…' → '234'.
 *  Longest prefix first (3, then 2, then 1 digits). Null when there is no match. */
export function defaultCountryCodeFromOwn(ownPhone: string): string | null {
  if (!ownPhone.startsWith('+')) return null;
  const digits = ownPhone.slice(1);
  if (!/^\d+$/.test(digits)) return null;
  for (let n = 3; n >= 1; n--) {
    const cand = digits.slice(0, n);
    if (DIAL_CODES.has(cand)) return cand;
  }
  return null;
}

/** Contacts cannot change while an alert is live: their response links would be deleted mid-emergency. */
export class LiveSosError extends Error {
  constructor() {
    super('An alert is active. Contacts can be changed once it has ended.');
  }
}

/** Validates the contact list: 2-10 distinct, valid numbers, none of them the user's own.
 *  Two are enough at sign-up; the user can add the rest from the app later. */
export function validateContacts(
  input: { phone: string; locale?: Locale }[],
  ownPhone: string,
  defaultCountryCode = '234',
): { phone: string; locale: Locale }[] {
  if (input.length < MIN_CONTACTS || input.length > MAX_CONTACTS) {
    throw new ContactError(`Add ${MIN_CONTACTS} to ${MAX_CONTACTS} emergency contacts`);
  }
  // Global app: contacts typed in local format (0803...) almost always belong to the
  // OWNER's own country, so the owner's own dial prefix is a better default than any
  // single hardcoded one. Longest-prefix match over the common dial codes; unknown
  // prefixes keep the configured default.
  const localDefault = defaultCountryCodeFromOwn(ownPhone) ?? defaultCountryCode;
  const seen = new Set<string>();
  return input.map((c) => {
    const phone = normalizePhone(c.phone, localDefault);
    if (!phone) throw new ContactError('One of the contact numbers is not valid');
    if (phone === ownPhone) throw new ContactError('You cannot add your own number as a contact');
    if (seen.has(phone)) throw new ContactError('Each contact must have a different number');
    seen.add(phone);
    return { phone, locale: c.locale ?? 'en' };
  });
}
