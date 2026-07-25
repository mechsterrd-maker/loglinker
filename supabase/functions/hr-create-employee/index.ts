// hr-create-employee/index.ts
//
// Creates a record-only employee for the HR app. public.users.id is a FK to
// auth.users(id), so an employee needs an auth account even though they never
// log in. Only an admin / plant_head / manager of the plant may call this.
//
// Flow (service role): verify caller -> auth.admin.createUser (synthetic email,
// no password = cannot sign in) -> insert the public.users profile row. If the
// profile insert fails, the just-created auth user is deleted (no orphans).

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const cors = {
  "Access-Control-Allow-Origin":  "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ ok: false, error: "method_not_allowed" }, 405);

  const jwt = (req.headers.get("Authorization") || "").replace("Bearer ", "").trim();
  if (!jwt) return json({ ok: false, error: "not_authenticated" }, 401);

  let b: Record<string, unknown> = {};
  try { b = await req.json(); } catch { return json({ ok: false, error: "bad_json" }, 400); }

  const plant_id = String(b.plant_id || "");
  const full_name = String(b.full_name || "").trim();
  if (!plant_id) return json({ ok: false, error: "missing_plant_id" }, 400);
  if (!full_name) return json({ ok: false, error: "missing_name" }, 400);

  const admin = createClient(SUPABASE_URL, SERVICE_KEY);

  // Who is calling, and are they allowed to add staff to THIS plant?
  const { data: got } = await admin.auth.getUser(jwt);
  const caller = got?.user;
  if (!caller) return json({ ok: false, error: "not_authenticated" }, 401);
  const { data: me } = await admin.from("users").select("role, plant_id").eq("id", caller.id).maybeSingle();
  if (!me || me.plant_id !== plant_id || !["admin", "plant_head", "manager"].includes(me.role)) {
    return json({ ok: false, error: "not_authorized" }, 403);
  }

  // Mint an auth user with a synthetic, unmonitored email and NO password —
  // the employee can never sign in; they exist only to satisfy the FK.
  const email = `emp_${crypto.randomUUID()}@employees.loglinkr.app`;
  const { data: made, error: authErr } = await admin.auth.admin.createUser({
    email, email_confirm: true, user_metadata: { full_name, kind: "employee", plant_id },
  });
  if (authErr || !made?.user) return json({ ok: false, error: authErr?.message || "auth_create_failed" }, 500);
  const id = made.user.id;

  const profile = {
    id, plant_id, role: "operator", login_enabled: false, status: "active",
    full_name,
    phone: b.phone ? String(b.phone).trim() : null,
    blood_group: b.blood_group ? String(b.blood_group) : null,
    date_of_joining: b.date_of_joining ? String(b.date_of_joining) : null,
    address: b.address ? String(b.address).trim() : null,
  };
  const { data: row, error: insErr } = await admin.from("users").insert(profile).select().single();
  if (insErr) {
    await admin.auth.admin.deleteUser(id);   // rollback — no orphan auth user
    return json({ ok: false, error: insErr.message }, 500);
  }
  return json({ ok: true, user: row });
});
