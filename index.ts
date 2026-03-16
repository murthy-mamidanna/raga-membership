// Supabase Edge Function: verify-member  (v4 — 60-day early renewal window)
// File: supabase/functions/verify-member/index.ts
//
// Logic:
//   1. Find sustainer by email (exact) or name (DB ilike)
//   2. Fetch all payments and calculate correct valid_until:
//      - Within 60 days before expiry: new valid_until = old valid_until + 1 year
//      - More than 60 days before expiry or after expiry: payment_date + 1 year
//   3. If DB valid_until is missing or outdated → update it automatically
//   4. Sum payments in past 12 months → if >= $1000, sustainer is a Patron
//   5. Return ONLY status info — raw data never leaves the server

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const PATRON_THRESHOLD = 1000.00;

function levenshtein(a: string, b: string): number {
  a = a.toLowerCase(); b = b.toLowerCase();
  const m = a.length, n = b.length;
  const dp: number[][] = Array.from({ length: m + 1 }, (_, i) =>
    Array.from({ length: n + 1 }, (_, j) => (i === 0 ? j : j === 0 ? i : 0))
  );
  for (let i = 1; i <= m; i++)
    for (let j = 1; j <= n; j++)
      dp[i][j] = a[i-1] === b[j-1] ? dp[i-1][j-1]
        : 1 + Math.min(dp[i-1][j], dp[i][j-1], dp[i-1][j-1]);
  return dp[m][n];
}

function fuzzyMatch(input: string, target: string): boolean {
  if (!input || !target) return false;
  input = input.trim().toLowerCase();
  target = target.trim().toLowerCase();
  if (input === target) return true;
  const maxLen = Math.max(input.length, target.length);
  const allowed = Math.min(2, Math.floor(maxLen / 4));
  return levenshtein(input, target) <= allowed;
}

function formatDate(dateStr: string): string {
  const d = new Date(dateStr + "T12:00:00Z");
  return d.toLocaleDateString("en-US", { year: "numeric", month: "long", day: "numeric" });
}

function daysUntil(dateStr: string): number {
  const d = new Date(dateStr + "T12:00:00Z");
  return Math.ceil((d.getTime() - Date.now()) / (1000 * 60 * 60 * 24));
}

function addOneYear(dateStr: string): string {
  const d = new Date(dateStr + "T12:00:00Z");
  d.setFullYear(d.getFullYear() + 1);
  return d.toISOString().split("T")[0];
}

function subtractDays(dateStr: string, days: number): string {
  const d = new Date(dateStr + "T12:00:00Z");
  d.setDate(d.getDate() - days);
  return d.toISOString().split("T")[0];
}

// Calculate correct valid_until from full payment history (oldest → newest)
// Rule: only extend from current expiry if payment is within 60 days of expiry.
// Otherwise treat as a fresh gift: payment_date + 1 year.
function calculateValidUntil(payments: { payment_date: string }[]): string | null {
  if (!payments || payments.length === 0) return null;
  const sorted = [...payments].sort((a, b) =>
    a.payment_date.localeCompare(b.payment_date)
  );
  let validUntil: string | null = null;
  for (const p of sorted) {
    if (validUntil === null) {
      // First payment
      validUntil = addOneYear(p.payment_date);
    } else {
      // Calculate 60-day window start before current expiry
      const windowStart = subtractDays(validUntil, 60);
      if (p.payment_date >= windowStart && p.payment_date <= validUntil) {
        // Within 60-day early renewal window → extend from current expiry
        validUntil = addOneYear(validUntil);
      } else {
        // More than 60 days before expiry, or after expiry → fresh start
        validUntil = addOneYear(p.payment_date);
      }
    }
  }
  return validUntil;
}

// Build notes for any special renewals detected
function buildRenewalNotes(payments: { payment_date: string }[]): string {
  if (!payments || payments.length === 0) return "";
  const sorted = [...payments].sort((a, b) =>
    a.payment_date.localeCompare(b.payment_date)
  );
  let validUntil: string | null = null;
  const notes: string[] = [];
  for (const p of sorted) {
    if (validUntil === null) {
      validUntil = addOneYear(p.payment_date);
    } else {
      const windowStart = subtractDays(validUntil, 60);
      if (p.payment_date >= windowStart && p.payment_date <= validUntil) {
        const newExpiry = addOneYear(validUntil);
        notes.push(
          `Early renewal on ${formatDate(p.payment_date)} (within 60 days of expiry ${formatDate(validUntil)}) — extended to ${formatDate(newExpiry)}`
        );
        validUntil = newExpiry;
      } else {
        if (p.payment_date < validUntil) {
          notes.push(
            `New gift on ${formatDate(p.payment_date)} (more than 60 days before expiry — treated as new gift, valid until ${formatDate(addOneYear(p.payment_date))})`
          );
        }
        validUntil = addOneYear(p.payment_date);
      }
    }
  }
  return notes.join("; ");
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const { email, firstName, lastName } = await req.json();

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SERVICE_ROLE_KEY") ?? ""
    );

    let member: any = null;

    // 1a. Exact email match
    if (email?.trim()) {
      const { data } = await supabase
        .from("members")
        .select("id, first_name, last_name, valid_until, notes")
        .ilike("email", email.trim())
        .limit(1)
        .single();
      if (data) member = data;
    }

    // 1b. Name match — DB ilike on last name, optional first name fuzzy filter
    let lastNameOnly = false;
    const hasFirst = typeof firstName === "string" && firstName.trim().length > 0;
    const hasLast  = typeof lastName  === "string" && lastName.trim().length > 0;

    if (!member && hasLast) {
      const lastTrimmed  = lastName.trim();
      const firstTrimmed = hasFirst ? firstName.trim() : "";

      const { data: lastMatches } = await supabase
        .from("members")
        .select("id, first_name, last_name, valid_until, notes")
        .ilike("last_name", lastTrimmed);

      if (lastMatches && lastMatches.length > 0) {
        const hits = hasFirst
          ? lastMatches.filter((m: any) =>
              fuzzyMatch(firstTrimmed, m.first_name ?? "") ||
              fuzzyMatch(firstTrimmed, (m.first_name ?? "").split(" ")[0])
            )
          : lastMatches;

        if (hits.length === 1) {
          member = hits[0];
          lastNameOnly = !hasFirst;
        } else if (hits.length > 1) {
          const ids = hits.map((h: any) => h.id);
          const { data: payCheck } = await supabase
            .from("payments")
            .select("member_id")
            .in("member_id", ids);
          const withPayments = new Set((payCheck ?? []).map((p: any) => p.member_id));
          const payingHits = hits.filter((h: any) => withPayments.has(h.id));
          if (payingHits.length >= 1) {
            member = payingHits[0];
            lastNameOnly = !hasFirst;
          }
        }
      }
    }

    if (!member) {
      return respond({ status: "not_found" });
    }

    // 2. Fetch all payments
    const { data: payments } = await supabase
      .from("payments")
      .select("payment_date, amount")
      .eq("member_id", member.id)
      .order("payment_date", { ascending: false });

    const displayName  = [member.first_name, member.last_name].filter(Boolean).join(" ") || "Member";
    const firstName_db = member.first_name ?? "";

    if (!payments || payments.length === 0) {
      return respond({ status: "expired", displayName, lastRenewal: null, lastNameOnly, firstName: firstName_db });
    }

    // 3. Calculate correct valid_until using early renewal logic
    const calculatedValidUntil = calculateValidUntil(payments);

    // If DB valid_until is missing or different, update it now
    if (calculatedValidUntil && calculatedValidUntil !== member.valid_until) {
      const renewalNotes = buildRenewalNotes(payments);
      const updatedNotes = renewalNotes
        ? (member.notes ? member.notes + " | " : "") + renewalNotes
        : member.notes;
      await supabase
        .from("members")
        .update({ valid_until: calculatedValidUntil, notes: updatedNotes, updated_at: new Date().toISOString() })
        .eq("id", member.id);
    }

    const validUntil = calculatedValidUntil!;
    const today  = new Date().toISOString().split("T")[0];
    const active = validUntil >= today;
    const days   = daysUntil(validUntil);

    // 4. Patron check — sum payments in last 12 months
    const oneYearAgoStr = new Date(Date.now() - 365 * 24 * 60 * 60 * 1000).toISOString().split("T")[0];
    const totalPaidThisYear = payments
      .filter((p: any) => p.payment_date >= oneYearAgoStr)
      .reduce((sum: number, p: any) => sum + (parseFloat(p.amount) || 0), 0);
    const isPatron = totalPaidThisYear >= PATRON_THRESHOLD;

    // 5. Return status only
    if (active) {
      return respond({
        status:       "active",
        displayName,
        expiryDate:   formatDate(validUntil),
        expiringSoon: days > 0 && days <= 90,
        isPatron,
        lastNameOnly,
        firstName:    firstName_db,
      });
    } else {
      return respond({
        status:      "expired",
        displayName,
        lastRenewal: formatDate(payments[0].payment_date),
        isPatron,
        lastNameOnly,
        firstName:   firstName_db,
      });
    }

  } catch (_err) {
    return respond({ status: "error" }, 500);
  }
});

function respond(body: object, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
