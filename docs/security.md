# Sentri security notes

No app can be made unhackable. This page says what is in place, what was tightened in the last review,
and what is still open, so nothing is assumed.

## In place

- **Who sees what.** Every route needs a signed-in user, and every read or change of an alert, inbox item or
  location share is limited to its owner or its recipient in the database query itself.
- **Phone numbers at rest.** Encrypted (AES-256-GCM). Lookups use a keyed hash, so the database alone does not reveal numbers.
- **PINs.** scrypt plus a server-side secret, lockout after repeated wrong tries, and the duress PIN is checked in the same time as the cancel PIN.
- **Sign-in.** 6-digit codes, 5-minute life, 5 guesses per code, 5 codes per number per hour, limits per IP address, and an SMS budget guard against SMS-pumping fraud.
- **Tokens.** Access tokens last 15 minutes. Refresh tokens are stored as hashes and replaced on every use.
- **Database access.** All queries are parameterised. The two places that build column lists use fixed allow-lists.
- **Inputs.** Every request body is checked with a schema, bodies over 4 KB are refused, and unknown fields are rejected on admin requests.
- **Logs.** Request logging is off. Logs carry no phone numbers, locations, tokens or codes.
- **Location.** Only the latest point is kept, never a trail, and it is deleted after the retention window (72 hours by default).
- **Admin.** Separate secret, password plus authenticator code, and two-person approval for anything sensitive. Every action goes to a hash-chained audit log.
- **Startup safety.** In production the server refuses to start with the dev code echo, the demo user, the memory store or the mock SMS provider.
- **Phone app.** Tokens in Android's encrypted storage, backups off, plain HTTP refused except for local development, and (new) a release build refuses any server address that is not HTTPS.

## Tightened in the last review

1. **Rate limits behind a hosting proxy.** Without `TRUST_PROXY_HOPS`, every caller looks like the proxy's address and the per-IP limits would lock out everyone at once. Set it to the number of proxies in front (usually 1). Setting it too high lets callers fake their address.
2. **Overall per-IP cap** (`GLOBAL_RATE_PER_MIN`, default 600) applied before anything else.
3. **Limiter memory.** Expired entries are dropped, and a flood of different keys can no longer grow memory without limit.
4. **Code-guess counting** is now atomic: guesses sent at the same moment each use an attempt, so the right code cannot slip in after the fifth try.
5. **HSTS** header in production, and a permissions policy that turns off sensors for any page the server serves.
6. **Slow-connection timeouts** (30 s) and a parameter length limit.

Each of these has a test in `backend/test/security.test.ts`. The forwarded-address test needs the real Fastify, so it runs in CI and on your machine.

## Still open (be honest with yourself about these)

- **Access tokens are not checked against a revoked device.** A stolen token works for up to 15 minutes. Fix: check the device on each request, at a small speed cost.
- **No theft detection on refresh tokens.** An old token is simply refused. Fix: revoke the device when an old token is replayed.
- **No certificate pinning** in the app. A phone with a hostile certificate installed could read traffic.
- **Map tiles.** The public OpenStreetMap server sees which area a phone is viewing. Use your own tile server before a public launch.
- **If your hosting account, database host or secret manager is compromised,** the code cannot protect the data. Use two-factor sign-in on GitHub and your host, and keep keys only in the host's secret store.
- **Limits are in memory.** With more than one server copy, each keeps its own counts. Move them to Redis before scaling out.
- **Not yet tested by an outside expert.** Pay for an independent penetration test before a public launch, and run `npm audit` in CI.
- **Never compiled or run against a real database in this review.** The checks above ran against in-memory stores.

## Your side of the work

- Keep the GitHub repository private, turn on two-factor sign-in, and never paste keys into code or chat.
- Generate every secret fresh (`openssl rand -hex 32`) and keep it only in the host's secret settings.
- Turn off `OTP_DEV_ECHO` and `DEV_SEED` anywhere real people sign up (the server already refuses to start otherwise).
- Keep police SMS dispatch off (`DISPATCH_MODE=log_only`) until each number is verified.
