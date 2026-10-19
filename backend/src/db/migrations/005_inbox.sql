-- In-app alerts. Contacts are alerted only inside the app, never by SMS or link.
ALTER TABLE users ADD COLUMN name_enc BYTEA;   -- what contacts see on an alert; encrypted like the phone number

CREATE TABLE inbox_items (
  id             UUID PRIMARY KEY,
  user_id        UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,   -- the contact who receives it
  from_user_id   UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,   -- the person who needs help
  from_name_enc  BYTEA,
  kind           TEXT NOT NULL CHECK (kind IN ('sos','duress','offline','low_battery','test','share_start','share_stop')),
  sos_id         UUID,
  share_id       UUID,
  locale         TEXT NOT NULL DEFAULT 'en' CHECK (locale IN ('en','ha','yo','ig','pcm')),
  geo            JSONB,                -- only for kinds with no live SOS to read the position from
  created_at     BIGINT NOT NULL,
  updated_at     BIGINT NOT NULL,
  read_at        BIGINT,
  purge_after    BIGINT NOT NULL
);
-- A repeating alert refreshes one row instead of filling the inbox.
CREATE UNIQUE INDEX inbox_items_alert_uq ON inbox_items (user_id, sos_id, kind) WHERE sos_id IS NOT NULL;
CREATE UNIQUE INDEX inbox_items_share_uq ON inbox_items (user_id, share_id, kind) WHERE share_id IS NOT NULL;
CREATE INDEX inbox_items_user_idx ON inbox_items (user_id, updated_at DESC);
CREATE INDEX inbox_items_purge_idx ON inbox_items (purge_after);

-- Live location sharing: the person picks contacts and shares until they stop (or the safety limit passes).
-- Only the latest position is kept, never a trail.
CREATE TABLE location_shares (
  id            UUID PRIMARY KEY,
  user_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  recipient_ids UUID[] NOT NULL,
  started_at    BIGINT NOT NULL,
  expires_at    BIGINT NOT NULL,
  ended_at      BIGINT,
  last_geo      JSONB,
  purge_after   BIGINT NOT NULL
);
CREATE INDEX location_shares_user_idx ON location_shares (user_id) WHERE ended_at IS NULL;
CREATE INDEX location_shares_purge_idx ON location_shares (purge_after);
