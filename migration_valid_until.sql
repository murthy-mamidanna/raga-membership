-- ═══════════════════════════════════════════════════════════════
-- Raga Club — Migration: Add valid_until column + early renewal logic
-- Run in Supabase → SQL Editor
-- ═══════════════════════════════════════════════════════════════

-- ── Step 1: Add valid_until column to members table ────────────
ALTER TABLE members
  ADD COLUMN IF NOT EXISTS valid_until DATE;

-- ── Step 2: Function to calculate correct valid_until ──────────
-- Logic: sort payments oldest→newest. For each payment:
--   - If payment_date < current valid_until → early renewal
--     → new valid_until = current valid_until + 1 year
--   - Otherwise → new valid_until = payment_date + 1 year
CREATE OR REPLACE FUNCTION calculate_valid_until(p_member_id INTEGER)
RETURNS DATE
LANGUAGE plpgsql AS $$
DECLARE
  v_valid_until DATE := NULL;
  rec           RECORD;
BEGIN
  -- Process payments in chronological order (oldest first)
  FOR rec IN
    SELECT payment_date
    FROM payments
    WHERE member_id = p_member_id
    ORDER BY payment_date ASC
  LOOP
    IF v_valid_until IS NULL THEN
      -- First payment: valid_until = payment_date + 1 year
      v_valid_until := rec.payment_date + INTERVAL '1 year';
    ELSIF rec.payment_date < v_valid_until THEN
      -- Early renewal: extend from current expiry
      v_valid_until := v_valid_until + INTERVAL '1 year';
    ELSE
      -- Lapsed or on-time: start fresh from payment date
      v_valid_until := rec.payment_date + INTERVAL '1 year';
    END IF;
  END LOOP;

  RETURN v_valid_until;
END;
$$;

-- ── Step 3: Function to build renewal notes ────────────────────
CREATE OR REPLACE FUNCTION build_renewal_notes(p_member_id INTEGER)
RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
  v_valid_until DATE := NULL;
  v_notes       TEXT := '';
  rec           RECORD;
  renewal_num   INTEGER := 0;
BEGIN
  FOR rec IN
    SELECT payment_date
    FROM payments
    WHERE member_id = p_member_id
    ORDER BY payment_date ASC
  LOOP
    renewal_num := renewal_num + 1;
    IF v_valid_until IS NULL THEN
      v_valid_until := rec.payment_date + INTERVAL '1 year';
    ELSIF rec.payment_date < v_valid_until THEN
      -- Early renewal — log it
      v_notes := v_notes ||
        'Early renewal on ' || TO_CHAR(rec.payment_date, 'MM/DD/YYYY') ||
        ' — valid_until extended to ' ||
        TO_CHAR(v_valid_until + INTERVAL '1 year', 'MM/DD/YYYY') || '; ';
      v_valid_until := v_valid_until + INTERVAL '1 year';
    ELSE
      v_valid_until := rec.payment_date + INTERVAL '1 year';
    END IF;
  END LOOP;

  RETURN NULLIF(TRIM(v_notes), '');
END;
$$;

-- ── Step 4: Update all members with correct valid_until + notes ─
UPDATE members m
SET
  valid_until = calculate_valid_until(m.id),
  notes = CASE
    WHEN build_renewal_notes(m.id) IS NOT NULL
    THEN COALESCE(m.notes || ' | ', '') || build_renewal_notes(m.id)
    ELSE m.notes
  END,
  updated_at = NOW()
WHERE EXISTS (
  SELECT 1 FROM payments p WHERE p.member_id = m.id
);

-- ── Step 5: Verify results ─────────────────────────────────────
SELECT
  m.id,
  m.first_name,
  m.last_name,
  MAX(p.payment_date)  AS latest_payment,
  m.valid_until,
  m.notes
FROM members m
LEFT JOIN payments p ON p.member_id = m.id
GROUP BY m.id, m.first_name, m.last_name, m.valid_until, m.notes
ORDER BY m.last_name, m.first_name;


-- ═══════════════════════════════════════════════════════════════
-- Updated ingest_zeffy_payment function (early renewal aware)
-- Replace the old version by running this in SQL Editor
-- ═══════════════════════════════════════════════════════════════
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
  v_member_id   INTEGER;
  v_payment_id  INTEGER;
  v_valid_until DATE;
  v_new_until   DATE;
  v_note        TEXT;
BEGIN
  -- 1. Find or create member
  SELECT id INTO v_member_id
  FROM members WHERE LOWER(email) = LOWER(p_email) LIMIT 1;

  IF v_member_id IS NULL THEN
    INSERT INTO members (first_name, last_name, email)
    VALUES (p_first_name, p_last_name, p_email)
    RETURNING id INTO v_member_id;
  END IF;

  -- 2. Insert payment
  INSERT INTO payments (member_id, payment_date, amount, payment_method, notes)
  VALUES (v_member_id, p_payment_date, p_amount, p_method, p_notes)
  RETURNING id INTO v_payment_id;

  -- 3. Recalculate valid_until using early renewal logic
  v_valid_until := calculate_valid_until(v_member_id);

  -- 4. Check if this was an early renewal and build note
  SELECT valid_until INTO v_new_until FROM members WHERE id = v_member_id;
  IF v_new_until IS NOT NULL AND p_payment_date < v_new_until THEN
    v_note := 'Early renewal on ' || TO_CHAR(p_payment_date, 'MM/DD/YYYY') ||
              ' — valid_until extended to ' || TO_CHAR(v_valid_until, 'MM/DD/YYYY');
    UPDATE members SET
      valid_until = v_valid_until,
      notes = COALESCE(notes || ' | ', '') || v_note,
      updated_at = NOW()
    WHERE id = v_member_id;
  ELSE
    UPDATE members SET
      valid_until = v_valid_until,
      updated_at = NOW()
    WHERE id = v_member_id;
  END IF;

  RETURN jsonb_build_object(
    'success',     true,
    'member_id',   v_member_id,
    'payment_id',  v_payment_id,
    'valid_until', v_valid_until
  );
END;
$$;
