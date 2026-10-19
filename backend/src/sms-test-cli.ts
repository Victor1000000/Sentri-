/**
 * Sends one real test text with the SMS provider from your .env, so you can check Termii before relying on
 * sign-in codes:
 *
 *   npm run sms:test -- 08031234567
 *
 * With SMS_PROVIDER=mock it only prints the text. With termii it sends it and prints Termii's reference, or
 * the reason it failed (wrong key, unregistered sender ID, no balance, DND route not enabled).
 */
import { loadConfig } from './config/env.js';
import { normalizePhone } from './modules/auth/phone.js';
import { MockSmsProvider, type SmsProvider } from './providers/sms/SmsProvider.js';
import { TermiiSmsProvider } from './providers/sms/TermiiProvider.js';

const raw = process.argv[2];
if (!raw) {
  console.error('usage: npm run sms:test -- <phone number, e.g. 08031234567>');
  process.exit(1);
}
const env = loadConfig();
const to = normalizePhone(raw, env.DEFAULT_COUNTRY_CODE);
if (!to) {
  console.error('that is not a valid phone number');
  process.exit(1);
}
const sms: SmsProvider =
  env.SMS_PROVIDER === 'termii'
    ? new TermiiSmsProvider({
        apiKey: env.TERMII_API_KEY!,
        senderId: env.TERMII_SENDER_ID!,
        baseUrl: env.TERMII_BASE_URL,
        channel: env.TERMII_CHANNEL,
        estCostKobo: env.SMS_COST_KOBO_ESTIMATE,
      })
    : new MockSmsProvider();
const code = String(Math.floor(100000 + Math.random() * 900000));
try {
  const r = await sms.send({ to, text: `Sentri test code: ${code}. This is only a test.` });
  console.log(`provider=${env.SMS_PROVIDER} channel=${env.TERMII_CHANNEL} to=${to} ref=${r.providerRef}`);
  if (env.SMS_PROVIDER === 'mock') console.log('mock provider: nothing was sent. Set SMS_PROVIDER=termii to send for real.');
  else console.log(`sent. The phone should show: Sentri test code: ${code}`);
} catch (e) {
  console.error('failed:', e instanceof Error ? e.message : e);
  process.exit(2);
}
