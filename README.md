# Loglinkr — Block 1 Deploy Guide (Vercel URL only)

**What you're deploying tonight:**
1. Coming-soon landing page on Vercel free URL (e.g., `loglinkr.vercel.app`)
2. Fresh Supabase project for Loglinkr backend
3. Base structure schema (14 universal tables) with RLS
4. GitHub repo `mechsterrd-maker/loglinkr`

**No custom domain tonight.** Add `loglinkr.com` later when you're ready.

**Total time:** 25-30 minutes.

---

## Step 1 — Free up Supabase project slot (5 min)

You have 2/2 free Supabase projects (CadNexa + Litro). Need to free one for Loglinkr.

**Recommended: pause Litro** (since it's in maintenance mode, no active growth).

1. Go to https://supabase.com/dashboard
2. Open the Litro project (`rksarkedopwvkilumxst`)
3. Settings → General → scroll to bottom → **Pause project**
4. Confirm

Data is preserved. Unpause anytime in one click.

If Litro is actively used by pump owners and pausing isn't safe, tell me and we'll pick another option.

---

## Step 2 — Create the GitHub repo (5 min)

1. Go to https://github.com/new
2. Owner: `mechsterrd-maker`
3. Repository name: `loglinkr`
4. Description: *Plant operations platform — Quality, Production, Transactions for Indian SME manufacturers.*
5. **Private**
6. Skip README, .gitignore, license
7. Click **Create repository**

Don't push anything yet.

---

## Step 3 — Create the Supabase project (5 min)

1. Go to https://supabase.com/dashboard
2. Click **New Project**
3. Organization: your existing one
4. Name: `loglinkr`
5. Database Password: generate strong, **save in password manager**
6. Region: **Mumbai (ap-south-1)**
7. Pricing Plan: Free tier
8. Click **Create new project**

Wait 2-3 minutes for provisioning.

Save these from **Settings → API**:
- Project URL (`https://xxxxx.supabase.co`)
- `anon` `public` key
- `service_role` key (secret, never commit)

---

## Step 4 — Run the base schema (5 min)

1. In Supabase dashboard → **SQL Editor** → **New query**
2. Open `schema.sql` from this folder, copy entire contents
3. Paste into SQL editor
4. Click **Run**
5. Should see "Success. No rows returned."

**Verify:**
- Go to **Table Editor**
- You should see: `plants`, `units`, `departments`, `users`, `shifts`, `chat_groups`, `chat_messages`, `chat_message_actions`, `pulse_cadences`, `pulse_tasks`, `actions`, `audit_log`, `mcp_registry`, `waitlist`
- Check `mcp_registry` — 1 row (`production_pdc_v1`)

If anything fails, copy the error and paste back to me.

---

## Step 5 — Push files to GitHub (5 min)

**Easiest path on mobile/laptop without git:**

1. Go to https://github.com/mechsterrd-maker/loglinkr
2. Click **Add file → Upload files**
3. Drag these files:
   - `index.html`
   - `vercel.json`
   - `schema.sql` (optional in repo — kept for reference)
   - `README.md` (this file, optional)
4. Commit message: "Initial commit: landing + base schema"
5. Click **Commit changes**

**With git on laptop:**
```bash
git clone https://github.com/mechsterrd-maker/loglinkr.git
cd loglinkr
# copy index.html, vercel.json, schema.sql, README.md into folder
git add .
git commit -m "Initial commit: landing + base schema"
git push origin main
```

---

## Step 6 — Deploy to Vercel (5 min)

1. Go to https://vercel.com/new
2. **Import Git Repository** → pick `mechsterrd-maker/loglinkr`
3. Framework Preset: **Other**
4. Root Directory: `./`
5. Build Command: leave empty
6. Output Directory: leave empty
7. Click **Deploy**

Wait ~30 seconds. You get a URL like `loglinkr-abc123.vercel.app` or `loglinkr-mechsterrd-maker.vercel.app`.

**Customize Vercel URL (optional but recommended):**
1. Project Dashboard → **Settings** → **Domains**
2. Edit the `.vercel.app` URL → try `loglinkr.vercel.app` if available
3. This becomes your launch URL for now

---

## Step 7 — Configure Supabase Auth (5 min)

In Supabase dashboard → **Authentication** → **URL Configuration**:

- **Site URL:** `https://loglinkr.vercel.app` (or whatever Vercel gave you)
- **Redirect URLs:** add these (one per line):
  ```
  https://loglinkr.vercel.app
  https://loglinkr.vercel.app/**
  ```

**Authentication → Providers:**
- **Enable Email** (for now)
- Phone OTP and Google OAuth — skip tonight, wire later when we build login UI

---

## Step 8 — Verify everything (3 min)

- [ ] `https://loglinkr.vercel.app` loads the landing page (or whatever URL Vercel gave you)
- [ ] Landing renders correctly on mobile (open on your phone)
- [ ] Email signup form accepts input → shows "✓ You're in"
- [ ] Supabase project alive, all 14 tables visible
- [ ] GitHub repo has files committed
- [ ] Vercel auto-deploys on every git push

---

## Done for tonight

Take rest. Don't build more.

**Tomorrow / next session:**
1. Wire email form → Supabase `waitlist` table
2. Build Auth UI (login page)
3. Build Plants/Units/Departments CRUD
4. Test by creating Krishnas Fittings as the first plant

**Future blocks (in order):**
- Users + Roles UI
- Shifts master
- Chat layer (groups, messages, AI parser)
- Pulse layer (cadences → tasks → escalations)
- Action Hub
- Cascade engine
- MCP socket
- Production-PDC MCP (first concrete proof)

Each piece reviewed before moving on. No skipping.

---

## When you buy loglinkr.com later

You don't need to redo anything. Just:
1. Vercel project → Settings → Domains → Add `loglinkr.com`
2. Add DNS records to your registrar (Vercel shows them)
3. Update Supabase Auth Site URL to `https://loglinkr.com`
4. Done. Old `.vercel.app` URL keeps working too.

---

## If something breaks

- **Schema fails** → copy error, send to me
- **Vercel deploy fails** → check build log, send error
- **Supabase tables missing after schema run** → run schema again, check for errors in SQL editor history
- **Auth not working** → verify Site URL matches Vercel URL exactly

Don't troubleshoot solo for an hour. Send the error and we fix together.

---

## File checklist for repo

```
loglinkr/
├── index.html       ← landing page (deploys to Vercel)
├── vercel.json      ← Vercel config
├── schema.sql       ← Supabase schema (run in SQL editor, NOT deployed via Vercel)
└── README.md        ← this file (reference only)
```

---

**Once Step 8 checks pass — sleep. We continue tomorrow.**
