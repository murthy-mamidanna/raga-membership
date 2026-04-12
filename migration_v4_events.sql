-- ═══════════════════════════════════════════════════════════════
-- Raga Club — Migration v4: Events & Check-ins
-- Run in Supabase → SQL Editor
-- ═══════════════════════════════════════════════════════════════

-- ── Step 1: Events table ───────────────────────────────────────
CREATE TABLE IF NOT EXISTS events (
  id          SERIAL PRIMARY KEY,
  title       TEXT NOT NULL,
  event_date  DATE NOT NULL,
  notes       TEXT,
  created_at  TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON events FROM anon, authenticated;

-- ── Step 2: Checkins table ─────────────────────────────────────
-- attendee_type: 'sustainer' | 'guest' | 'walkin'
-- member_id: set for sustainers (links to members table)
-- alias_id: set when guest is found/added via member_aliases
-- guest_of_member_id: for guests, the sustainer they came with
-- name / email: always captured for all types
CREATE TABLE IF NOT EXISTS checkins (
  id                  SERIAL PRIMARY KEY,
  event_id            INTEGER NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  attendee_type       TEXT NOT NULL CHECK (attendee_type IN ('sustainer','guest','walkin')),
  member_id           INTEGER REFERENCES members(id) ON DELETE SET NULL,
  alias_id            INTEGER REFERENCES member_aliases(id) ON DELETE SET NULL,
  guest_of_member_id  INTEGER REFERENCES members(id) ON DELETE SET NULL,
  name                TEXT NOT NULL,
  email               TEXT,
  checkin_time        TIMESTAMPTZ DEFAULT NOW(),
  notes               TEXT,

  -- Prevent double check-in: same person at same event
  CONSTRAINT uq_checkin_member_event
    UNIQUE (event_id, member_id)
    DEFERRABLE INITIALLY DEFERRED
);

-- Partial unique: one walk-in row per email per event (if email provided)
CREATE UNIQUE INDEX IF NOT EXISTS idx_checkin_walkin_email
  ON checkins (event_id, LOWER(email))
  WHERE email IS NOT NULL AND attendee_type = 'walkin';

CREATE INDEX IF NOT EXISTS idx_checkins_event    ON checkins (event_id);
CREATE INDEX IF NOT EXISTS idx_checkins_member   ON checkins (member_id);
CREATE INDEX IF NOT EXISTS idx_checkins_time     ON checkins (checkin_time);

ALTER TABLE checkins ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON checkins FROM anon, authenticated;

-- ── Step 3: Helpful view — event attendance summary ────────────
CREATE OR REPLACE VIEW event_attendance_summary
  WITH (security_invoker = true)
AS
SELECT
  e.id            AS event_id,
  e.title,
  e.event_date,
  COUNT(c.id)                                              AS total_attended,
  COUNT(c.id) FILTER (WHERE c.attendee_type = 'sustainer') AS sustainers,
  COUNT(c.id) FILTER (WHERE c.attendee_type = 'guest')     AS guests,
  COUNT(c.id) FILTER (WHERE c.attendee_type = 'walkin')    AS walkins
FROM events e
LEFT JOIN checkins c ON c.event_id = e.id
GROUP BY e.id, e.title, e.event_date
ORDER BY e.event_date DESC;

REVOKE ALL ON event_attendance_summary FROM anon, authenticated, public;

-- ── Step 4: Verify ─────────────────────────────────────────────
SELECT 'events and checkins tables created successfully' AS status;
