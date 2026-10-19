-- Consent links: an emergency contact accepts or declines being added.
ALTER TABLE links DROP CONSTRAINT IF EXISTS links_kind_check;
ALTER TABLE links ADD CONSTRAINT links_kind_check CHECK (kind IN ('ack','loc','consent'));
