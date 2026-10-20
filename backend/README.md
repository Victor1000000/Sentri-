# Sentri backend

Step 1a: SOS engine, PIN logic, SMS provider, budget guard, police directory, HTTP API.
Step 1b: Postgres/PostGIS store + migrations, phone verification (OTP), device auth (JWT + rotating refresh tokens),
onboarding endpoints, BullMQ scheduler, encrypted phone numbers at rest, hash-chained audit log in Postgres.

## Run in memory (no services needed)
    cp .env.example .env     # set TOKEN_SECRET, PIN_PEPPER, JWT_SECRET (openssl rand -hex 32)
    npm install
    npm run typecheck && npm test
    set -a; . ./.env; set +a
    DEV_SEED=true OTP_DEV_ECHO=true npm run dev

## Run for real (Postgres + Redis)
    docker compose up -d                      # from the repo root: PostGIS + Redis
    # in .env: STORE=postgres, DATA_KEY and PHONE_HMAC_KEY (openssl rand -hex 32 each)
    npm run migrate                           # also runs automatically on start
    npm run dev

## Sign-up flow (what the app will call)
    POST /v1/auth/otp/request   {phone}
    POST /v1/auth/otp/verify    {phone, code, platform, publicKey, boxPublicKey}  -> accessToken, refreshToken, deviceId
    POST /v1/auth/refresh       {deviceId, refreshToken}
    PUT  /v1/me/contacts        {contacts:[{phone, locale?} x3..5]}
    PUT  /v1/me/pins            {cancelPin, duressPin}
    PUT  /v1/me/profile         {locale?, dataSaver?}
    PUT  /v1/me/push-token      {token}
    POST /v1/sos                {trigger, lat?, lon?}      (Authorization: Bearer <accessToken>)
    POST /v1/sos/:id/pin        {pin}
    POST /v1/sos/:id/location   {lat, lon, accuracyM?}
    POST /v1/alerts/low-battery {lat?, lon?}
    GET/POST /r/:token          contact "I'm responding" page

Keys (publicKey, boxPublicKey) are base64 of 32 raw bytes.

## Sign-up codes through Telegram (free alternative to SMS)
Set `OTP_PROVIDER=telegram` plus `TELEGRAM_BOT_TOKEN` and `TELEGRAM_BOT_USERNAME`
(create the bot with @BotFather; the server registers its webhook at `PUBLIC_BASE_URL/v1/telegram/webhook` on start).
`TELEGRAM_WEBHOOK_SECRET` is optional: when it is not set, a secret is derived from `TOKEN_SECRET`.

1. `POST /v1/auth/otp/request {phone}` sends nothing and answers `202 {ok:true, telegramUrl:"https://t.me/<bot>?start=login"}`. The app opens that link.
2. In Telegram the person taps Start, then "Share my number".
3. The bot accepts only the person's own contact (`contact.user_id` must equal the sender), makes a code for that number and sends it in the chat.
4. The person types the code into the app. `POST /v1/auth/otp/verify` is unchanged.

Only the sign-up code uses Telegram. SOS alerts keep using `SMS_PROVIDER` (and push) and never go through the bot.
With `SMS_PROVIDER=mock` alerts are only logged, so use it for private tests only.

## Not yet verified
PgSosStore, PgAudit, PgDirectory, PgUserRepo and BullScheduler have no automated tests yet: they need a live
Postgres/Redis. Run the app against `docker compose` once and exercise the sign-up flow above before trusting them.
EOF

## Private test deploy on Render (free)
`render.yaml` at the repo root is a Render Blueprint. In Render choose **New > Blueprint**, pick this repo, and enter the two Telegram values it asks for.
Render generates `TOKEN_SECRET` and `PIN_PEPPER`, and the server uses Render's own address (`RENDER_EXTERNAL_URL`) as `PUBLIC_BASE_URL`.
It runs in development mode with `STORE=memory` and `SMS_PROVIDER=mock`, which is for private testing only:
- a free Render service sleeps after 15 minutes without traffic and forgets everything held in memory (accounts, contacts, PINs), so people have to sign up again;
- SOS alerts are only logged, never delivered.

For real use: `NODE_ENV=production`, `STORE=postgres`, a real `SMS_PROVIDER`, and an always-on instance.
