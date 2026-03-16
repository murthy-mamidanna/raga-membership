-- ═══════════════════════════════════════════════════════════════
-- Raga Club of Connecticut — Migration v2
-- Run entirely in Supabase → SQL Editor
--
-- What this does:
--   1. Updates calculate_valid_until() with 60-day early renewal window
--   2. Updates build_renewal_notes() to match new logic
--   3. Adds payments trigger to auto-recalculate valid_until on insert/update/delete
--   4. Adds duplicate email prevention on members table
--   5. Recalculates valid_until + notes for ALL existing members
--   6. Updates ingest_zeffy_payment() with new logic
-- ═══════════════════════════════════════════════════════════════


-- ── Step 1: Ensure valid_until column exists ───────────────────
ALTER TABLE members
  ADD COLUMN IF NOT EXISTS valid_until DATE;


-- ── Step 2: Updated calculate_valid_until() ───────────────────
-- New rule: only extend from current expiry if payment is within
-- 60 days of expiry. Otherwise treat as fresh: payment_date + 1yr.
CREATE OR REPLACE FUNCTION calculate_valid_until(p_member_id INTEGER)
RETURNS DATE
LANGUAGE plpgsql AS $$
DECLARE
  v_valid_until DATE := NULL;
  rec           RECORD;
BEGIN
  FOR rec IN
    SELECT payment_date
    FROM payments
    WHERE member_id = p_member_id
    ORDER BY payment_date ASC
  LOOP
    IF v_valid_until IS NULL THEN
      -- First payment ever
      v_valid_until := rec.payment_date + INTERVAL '1 year';

    ELSIF rec.payment_date >= (v_valid_until - INTERVAL '60 days')
      AND rec.payment_date <= v_valid_until THEN
      -- Within 60-day early renewal window → extend from current expiry
      v_valid_until := v_valid_until + INTERVAL '1 year';

    ELSE
      -- More than 60 days before expiry, or after expiry → fresh start
      v_valid_until := rec.payment_date + INTERVAL '1 year';
    END IF;
  END LOOP;

  RETURN v_valid_until;
END;
$$;


-- ── Step 3: Updated build_renewal_notes() ─────────────────────
CREATE OR REPLACE FUNCTION build_renewal_notes(p_member_id INTEGER)
RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
  v_valid_until DATE := NULL;
  v_notes       TEXT := '';
  rec           RECORD;
BEGIN
  FOR rec IN
    SELECT payment_date
    FROM payments
    WHERE member_id = p_member_id
    ORDER BY payment_date ASC
  LOOP
    IF v_valid_until IS NULL THEN
      v_valid_until := rec.payment_date + INTERVAL '1 year';

    ELSIF rec.payment_date >= (v_valid_until - INTERVAL '60 days')
      AND rec.payment_date <= v_valid_until THEN
      -- Early renewal within window — log it
      v_notes := v_notes ||
        'Early renewal on ' || TO_CHAR(rec.payment_date, 'MM/DD/YYYY') ||
        ' (within 60 days of expiry ' || TO_CHAR(v_valid_until, 'MM/DD/YYYY') ||
        ') — extended to ' ||
        TO_CHAR(v_valid_until + INTERVAL '1 year', 'MM/DD/YYYY') || '; ';
      v_valid_until := v_valid_until + INTERVAL '1 year';

    ELSE
      -- Fresh start — note if there was a prior active period
      IF v_valid_until IS NOT NULL AND rec.payment_date < v_valid_until THEN
        v_notes := v_notes ||
          'New gift on ' || TO_CHAR(rec.payment_date, 'MM/DD/YYYY') ||
          ' (more than 60 days before expiry — treated as new gift, valid until ' ||
          TO_CHAR(rec.payment_date + INTERVAL '1 year', 'MM/DD/YYYY') || '); ';
      END IF;
      v_valid_until := rec.payment_date + INTERVAL '1 year';
    END IF;
  END LOOP;

  RETURN NULLIF(TRIM(v_notes), '');
END;
$$;


-- ── Step 4: Trigger function — auto-recalculate valid_until ───
-- Fires after any INSERT, UPDATE, or DELETE on payments table.
-- Keeps valid_until and notes always in sync automatically.
CREATE OR REPLACE FUNCTION payments_update_member_validity()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
  v_member_id   INTEGER;
  v_valid_until DATE;
  v_notes       TEXT;
  v_old_notes   TEXT;
  v_clean_notes TEXT;
BEGIN
  -- Determine which member_id to update
  IF TG_OP = 'DELETE' THEN
    v_member_id := OLD.member_id;
  ELSE
    v_member_id := NEW.member_id;
  END IF;

  -- Recalculate valid_until from scratch
  v_valid_until := calculate_valid_until(v_member_id);

  -- Get fresh renewal notes
  v_notes := build_renewal_notes(v_member_id);

  -- Preserve any manually written notes (strip old auto-generated renewal notes)
  -- Auto-notes are identified by starting with "Early renewal on" or "New gift on"
  SELECT notes INTO v_old_notes FROM members WHERE id = v_member_id;

  -- Clean out old auto-generated segments, keep manual notes
  IF v_old_notes IS NOT NULL THEN
    -- Remove previously auto-appended renewal note blocks
    v_clean_notes := TRIM(
      REGEXP_REPLACE(
        v_old_notes,
        '(Early renewal on [^;]+; ?|New gift on [^;]+; ?)',
        '',
        'g'
      )
    );
    -- Remove trailing pipe separators left behind
    v_clean_notes := TRIM(REGEXP_REPLACE(v_clean_notes, '\s*\|\s*$', ''));
    v_clean_notes := TRIM(REGEXP_REPLACE(v_clean_notes, '^\s*\|\s*', ''));
    v_clean_notes := NULLIF(v_clean_notes, '');
  END IF;

  -- Combine manual notes + fresh auto notes
  IF v_clean_notes IS NOT NULL AND v_notes IS NOT NULL THEN
    v_notes := v_clean_notes || ' | ' || v_notes;
  ELSIF v_clean_notes IS NOT NULL THEN
    v_notes := v_clean_notes;
  END IF;

  -- Update the member record
  UPDATE members
  SET
    valid_until = v_valid_until,
    notes       = v_notes,
    updated_at  = NOW()
  WHERE id = v_member_id;

  RETURN NULL; -- AFTER trigger, return value is ignored
END;
$$;

-- Attach trigger to payments table
DROP TRIGGER IF EXISTS trg_payments_update_validity ON payments;
CREATE TRIGGER trg_payments_update_validity
  AFTER INSERT OR UPDATE OR DELETE ON payments
  FOR EACH ROW
  EXECUTE FUNCTION payments_update_member_validity();


-- ── Step 5: Duplicate email prevention on members ─────────────

-- 5a. Unique index (case-insensitive) — blocks silent duplicates at DB level
CREATE UNIQUE INDEX IF NOT EXISTS idx_members_email_unique
  ON members (LOWER(email))
  WHERE email IS NOT NULL;

-- 5b. Function used by Zapier ingest to safely find-or-create
--     Also used to check before manual inserts
CREATE OR REPLACE FUNCTION find_member_by_email(p_email TEXT)
RETURNS TABLE(id INTEGER, first_name TEXT, last_name TEXT, email TEXT)
LANGUAGE sql AS $$
  SELECT id, first_name, last_name, email
  FROM members
  WHERE LOWER(members.email) = LOWER(p_email)
  LIMIT 1;
$$;

-- 5c. Informative error on duplicate email insert attempts
CREATE OR REPLACE FUNCTION members_prevent_duplicate_email()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
  v_existing_name TEXT;
BEGIN
  IF NEW.email IS NOT NULL THEN
    SELECT first_name || ' ' || last_name
    INTO v_existing_name
    FROM members
    WHERE LOWER(email) = LOWER(NEW.email)
      AND id != COALESCE(NEW.id, -1)
    LIMIT 1;

    IF v_existing_name IS NOT NULL THEN
      RAISE EXCEPTION
        'Duplicate email: % is already registered to %.',
        NEW.email, v_existing_name
        USING ERRCODE = 'unique_violation';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_members_no_duplicate_email ON members;
CREATE TRIGGER trg_members_no_duplicate_email
  BEFORE INSERT OR UPDATE ON members
  FOR EACH ROW
  EXECUTE FUNCTION members_prevent_duplicate_email();


-- ── Step 6: Wipe auto-generated notes and recalculate all ─────
-- Clears previously auto-appended renewal notes then recalculates
-- so we start fresh with the new 60-day logic.
UPDATE members
SET
  notes = NULLIF(TRIM(
    REGEXP_REPLACE(
      COALESCE(notes, ''),
      '(Early renewal on [^;]+; ?|New gift on [^;]+; ?)',
      '',
      'g'
    )
  ), ''),
  updated_at = NOW();

-- Now recalculate valid_until and append fresh notes for all members
UPDATE members m
SET
  valid_until = calculate_valid_until(m.id),
  notes = CASE
    WHEN build_renewal_notes(m.id) IS NOT NULL THEN
      COALESCE(NULLIF(TRIM(m.notes), '') || ' | ', '') || build_renewal_notes(m.id)
    ELSE m.notes
  END,
  updated_at = NOW()
WHERE EXISTS (
  SELECT 1 FROM payments p WHERE p.member_id = m.id
);


-- ── Step 7: Updated ingest_zeffy_payment() ────────────────────
-- Now relies on the trigger to update valid_until automatically.
-- Just needs to find-or-create the member and insert the payment.
CREATE OR REPLACE FUNCTION ingest_zeffy_payment(
  p_email        TEXT,
  p_first_name   TEXT,
  p_last_name    TEXT,
  p_amount       NUMERIC,
  p_payment_date DATE,
  p_method       TEXT DEFAULT 'online',
  p_notes        TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_member_id  INTEGER;
  v_payment_id INTEGER;
  v_valid_until DATE;
BEGIN
  -- 1. Find existing member by email (case-insensitive)
  SELECT id INTO v_member_id
  FROM members
  WHERE LOWER(email) = LOWER(p_email)
  LIMIT 1;

  -- 2. Create new member if not found
  IF v_member_id IS NULL THEN
    INSERT INTO members (first_name, last_name, email)
    VALUES (p_first_name, p_last_name, p_email)
    RETURNING id INTO v_member_id;
  END IF;

  -- 3. Insert payment — trigger will auto-update valid_until on members
  INSERT INTO payments (member_id, payment_date, amount, payment_method, notes)
  VALUES (v_member_id, p_payment_date, p_amount, p_method, p_notes)
  RETURNING id INTO v_payment_id;

  -- 4. Read back the valid_until that the trigger just set
  SELECT valid_until INTO v_valid_until
  FROM members WHERE id = v_member_id;

  RETURN jsonb_build_object(
    'success',     true,
    'member_id',   v_member_id,
    'payment_id',  v_payment_id,
    'valid_until', v_valid_until
  );
END;
$$;


-- ── Step 8: Verify — review all members with valid_until ───────
SELECT
  m.id,
  m.first_name,
  m.last_name,
  m.email,
  COUNT(p.id)          AS total_payments,
  MIN(p.payment_date)  AS first_payment,
  MAX(p.payment_date)  AS latest_payment,
  m.valid_until,
  m.notes
FROM members m
LEFT JOIN payments p ON p.member_id = m.id
GROUP BY m.id, m.first_name, m.last_name, m.email, m.valid_until, m.notes
ORDER BY m.last_name, m.first_name;
