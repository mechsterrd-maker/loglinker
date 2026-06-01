// redeem-password-reset/index.ts
//
// Two-stage password-reset flow used by /app when ?reset=<token> is present:
//   POST {action: "check", token}              -> { ok, expires_at, full_name, email? }
//   POST {action: "set",   token, new_password}-> { ok }
//
// Tokens are issued by issue_password_reset() (RPC, plant_head/manager only),
// stored on public.users.reset_token with a 24h expiry, and are MULTI-USE
// within that window (per product decision — forgiving for SME users who
// fumble; the security trade-off is bounded by the expiry).
//
// Writes the new password via supabase.auth.admin.updateUserById, which
// requires the service role — that's the whole reason this function exists.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const cors = {
  "Access-Control-Allow-Origin":  "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ ok: false, error: "method_not_allowed" }, 405);

  let body: { action?: string; token?: string; new_password?: string } = {};
  try { body = await req.json(); } catch { return json({ ok: false, error: "bad_json" }, 400); }

  const action = body.action;
  const token = (body.token || "").trim();
  if (!token || token.length < 16 || token.length > 64) {
    return json({ ok: false, error: "invalid_token_format" }, 400);
  }

  const sb = createClient(SUPABASE_URL, SERVICE_KEY);

  // Resolve the token → user_id (returns null if expired/missing). Single source
  // of truth, server-side; never trust a token shipped from the client.
  const { data: userId, error: rpcErr } = await sb.rpc("lookup_password_reset", { p_token: token });
  if (rpcErr) return json({ ok: false, error: "lookup_failed" }, 500);
  if (!userId) return json({ ok: false, error: "invalid_or_expired" }, 410);

  // CHECK: the /app reset screen calls this first to render "Setting a new
  // password for X" before asking for the password. No side effects.
  if (action === "check") {
    const { data: row } = await sb
      .from("users")
      .select("id, full_name, email, reset_token_expires_at")
      .eq("id", userId)
      .maybeSingle();
    if (!row) return json({ ok: false, error: "user_gone" }, 410);
    return json({
      ok: true,
      full_name: row.full_name,
      email: row.email,
      expires_at: row.reset_token_expires_at,
    });
  }

  // SET: actually update the password.
  if (action === "set") {
    const newPassword = body.new_password || "";
    if (newPassword.length < 6) {
      return json({ ok: false, error: "password_too_short" }, 400);
    }
    if (newPassword.length > 128) {
      return json({ ok: false, error: "password_too_long" }, 400);
    }

    // The Supabase auth user id IS the same as public.users.id (they're linked
    // 1-1 via the create_plant_and_signup / redeem_invite_code flows).
    const { error: updErr } = await sb.auth.admin.updateUserById(userId as string, {
      password: newPassword,
    });
    if (updErr) {
      console.warn("updateUserById failed:", updErr.message);
      return json({ ok: false, error: updErr.message }, 500);
    }

    // Token stays valid for the rest of the 24h window (multi-use per product
    // decision). The window itself is the bound; nothing to clear here.

    return json({ ok: true });
  }

  return json({ ok: false, error: "unknown_action" }, 400);
});
