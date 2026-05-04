-- ═══════════════════════════════════════════════════════════════
-- Raga Club — Fix: RLS policies for events & checkins
-- Run in Supabase → SQL Editor
--
-- The check-in app calls Supabase REST API directly with the
-- anon key. Events and checkins tables need RLS policies that
-- allow the anon role to read and write them.
--
-- members and payments remain fully locked — no change there.
-- ═══════════════════════════════════════════════════════════════

-- ── Events table: grant anon full access ──────────────────────
GRANT SELECT, INSERT, UPDATE, DELETE ON events TO anon;

CREATE POLICY "anon can read events"
  ON events FOR SELECT TO anon
  USING (true);

CREATE POLICY "anon can insert events"
  ON events FOR INSERT TO anon
  WITH CHECK (true);

CREATE POLICY "anon can update events"
  ON events FOR UPDATE TO anon
  USING (true);

CREATE POLICY "anon can delete events"
  ON events FOR DELETE TO anon
  USING (true);


-- ── Checkins table: grant anon full access ────────────────────
GRANT SELECT, INSERT, UPDATE, DELETE ON checkins TO anon;

CREATE POLICY "anon can read checkins"
  ON checkins FOR SELECT TO anon
  USING (true);

CREATE POLICY "anon can insert checkins"
  ON checkins FOR INSERT TO anon
  WITH CHECK (true);

CREATE POLICY "anon can update checkins"
  ON checkins FOR UPDATE TO anon
  USING (true);

CREATE POLICY "anon can delete checkins"
  ON checkins FOR DELETE TO anon
  USING (true);


-- ── member_aliases: grant anon read + insert ──────────────────
-- Check-in app needs to read aliases (for lookup) and insert
-- new ones when guests are added for the first time.
GRANT SELECT, INSERT ON member_aliases TO anon;

CREATE POLICY "anon can read aliases"
  ON member_aliases FOR SELECT TO anon
  USING (true);

CREATE POLICY "anon can insert aliases"
  ON member_aliases FOR INSERT TO anon
  WITH CHECK (true);


-- ── Also grant sequence access for serial IDs ─────────────────
GRANT USAGE, SELECT ON SEQUENCE events_id_seq    TO anon;
GRANT USAGE, SELECT ON SEQUENCE checkins_id_seq  TO anon;
GRANT USAGE, SELECT ON SEQUENCE member_aliases_id_seq TO anon;


-- ── Verify ────────────────────────────────────────────────────
SELECT
  schemaname,
  tablename,
  policyname,
  roles,
  cmd
FROM pg_policies
WHERE tablename IN ('events', 'checkins', 'member_aliases')
ORDER BY tablename, cmd;
