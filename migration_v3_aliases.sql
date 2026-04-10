-- ═══════════════════════════════════════════════════════════════
-- Raga Club — Migration v3: Member Aliases
-- Run in Supabase → SQL Editor
--
-- Allows multiple emails and/or names to be associated with a
-- single sustainer donor record. Useful for:
--   - Family memberships (spouse uses different email)
--   - Name variations (maiden name, nickname)
--   - Alternate email addresses
--
-- Lookup order:
--   1. Primary email on members table (existing)
--   2. Primary name on members table (existing)
--   3. Alias email on member_aliases table (new)
--   4. Alias name on member_aliases table (new)
-- ═══════════════════════════════════════════════════════════════


-- ── Step 1: Create member_aliases table ───────────────────────
CREATE TABLE IF NOT EXISTS member_aliases (
  id          SERIAL PRIMARY KEY,
  member_id   INTEGER NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  first_name  TEXT,
  last_name   TEXT,
  email       TEXT,
  notes       TEXT,          -- e.g. "spouse", "maiden name", "work email"
  created_at  TIMESTAMPTZ DEFAULT NOW(),

  -- At least one of email or last_name must be provided
  CONSTRAINT chk_alias_has_identifier
    CHECK (email IS NOT NULL OR last_name IS NOT NULL)
);

-- Indexes for fast lookup
CREATE INDEX IF NOT EXISTS idx_aliases_member   ON member_aliases (member_id);
CREATE INDEX IF NOT EXISTS idx_aliases_email    ON member_aliases (LOWER(email)) WHERE email IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_aliases_lastname ON member_aliases (LOWER(last_name)) WHERE last_name IS NOT NULL;

-- Unique email across aliases (case-insensitive), NULLs allowed
CREATE UNIQUE INDEX IF NOT EXISTS idx_aliases_email_unique
  ON member_aliases (LOWER(email))
  WHERE email IS NOT NULL;

-- Also prevent alias email duplicating a primary member email
-- (handled by trigger below)


-- ── Step 2: Security — same as members/payments ────────────────
ALTER TABLE member_aliases ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON member_aliases FROM anon, authenticated;


-- ── Step 3: Prevent alias email conflicting with primary emails ─
CREATE OR REPLACE FUNCTION aliases_prevent_duplicate_email()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
  v_existing TEXT;
BEGIN
  IF NEW.email IS NOT NULL THEN
    -- Check against primary member emails
    SELECT first_name || ' ' || last_name INTO v_existing
    FROM members
    WHERE LOWER(email) = LOWER(NEW.email)
    LIMIT 1;

    IF v_existing IS NOT NULL THEN
      RAISE EXCEPTION
        'Email % is already the primary email of %.',
        NEW.email, v_existing
        USING ERRCODE = 'unique_violation';
    END IF;

    -- Check against other aliases (excluding self on update)
    SELECT m.first_name || ' ' || m.last_name INTO v_existing
    FROM member_aliases a
    JOIN members m ON m.id = a.member_id
    WHERE LOWER(a.email) = LOWER(NEW.email)
      AND a.id != COALESCE(NEW.id, -1)
    LIMIT 1;

    IF v_existing IS NOT NULL THEN
      RAISE EXCEPTION
        'Email % is already an alias for %.',
        NEW.email, v_existing
        USING ERRCODE = 'unique_violation';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_aliases_no_duplicate_email ON member_aliases;
CREATE TRIGGER trg_aliases_no_duplicate_email
  BEFORE INSERT OR UPDATE ON member_aliases
  FOR EACH ROW
  EXECUTE FUNCTION aliases_prevent_duplicate_email();


-- ── Step 4: Helpful view — aliases with member context ─────────
CREATE OR REPLACE VIEW member_aliases_summary
  WITH (security_invoker = true)
AS
SELECT
  a.id           AS alias_id,
  a.member_id,
  m.first_name   AS primary_first_name,
  m.last_name    AS primary_last_name,
  m.email        AS primary_email,
  a.first_name   AS alias_first_name,
  a.last_name    AS alias_last_name,
  a.email        AS alias_email,
  a.notes        AS alias_notes,
  m.valid_until,
  a.created_at
FROM member_aliases a
JOIN members m ON m.id = a.member_id
ORDER BY m.last_name, m.first_name, a.last_name;

REVOKE ALL ON member_aliases_summary FROM anon, authenticated, public;


-- ── Step 5: Verify ─────────────────────────────────────────────
SELECT 'member_aliases table created successfully' AS status;

SELECT
  'To add an alias, insert a row into member_aliases:' AS instructions,
  'member_id: the id from the members table'           AS field_1,
  'first_name: alias first name (optional)'            AS field_2,
  'last_name: alias last name (required if no email)'  AS field_3,
  'email: alias email (required if no last_name)'      AS field_4,
  'notes: e.g. spouse, maiden name, work email'        AS field_5;
