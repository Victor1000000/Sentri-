-- Admin accounts and two-person approval. No admin can act alone on anything sensitive.
CREATE TABLE admins (
  id               UUID PRIMARY KEY,
  email            TEXT NOT NULL UNIQUE,
  password         JSONB NOT NULL,        -- {salt, hash}
  totp_enc         BYTEA NOT NULL,
  failed_logins    INT NOT NULL DEFAULT 0,
  locked_until     BIGINT NOT NULL DEFAULT 0,
  last_totp_step   BIGINT NOT NULL DEFAULT 0,
  created_at       BIGINT NOT NULL,
  disabled_at      BIGINT
);

CREATE TABLE admin_requests (
  id                UUID PRIMARY KEY,
  kind              TEXT NOT NULL CHECK (kind IN ('directory_verify','data_access','admin_add','admin_remove')),
  payload           JSONB NOT NULL,
  reason            TEXT NOT NULL CHECK (length(reason) >= 10),
  requested_by      UUID NOT NULL REFERENCES admins(id),
  state             TEXT NOT NULL CHECK (state IN ('pending','approved','rejected','executed','expired')),
  created_at        BIGINT NOT NULL,
  expires_at        BIGINT NOT NULL,
  executed_at       BIGINT,
  grant_expires_at  BIGINT
);
CREATE INDEX admin_requests_state_idx ON admin_requests(state, created_at DESC);

CREATE TABLE admin_approvals (
  request_id  UUID NOT NULL REFERENCES admin_requests(id) ON DELETE CASCADE,
  admin_id    UUID NOT NULL REFERENCES admins(id),
  decision    TEXT NOT NULL CHECK (decision IN ('approve','reject')),
  at          BIGINT NOT NULL,
  PRIMARY KEY (request_id, admin_id)
);

-- Defence in depth: even a bug or a hand-written SQL statement cannot let someone approve their own request.
CREATE FUNCTION admin_no_self_approval() RETURNS trigger AS $$
BEGIN
  IF NEW.admin_id = (SELECT requested_by FROM admin_requests WHERE id = NEW.request_id) THEN
    RAISE EXCEPTION 'an admin cannot answer their own request';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER admin_no_self_approval_trg BEFORE INSERT ON admin_approvals
  FOR EACH ROW EXECUTE FUNCTION admin_no_self_approval();
