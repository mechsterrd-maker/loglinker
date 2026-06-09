# RBAC Design — Custom Roles & Per-Project Access

**Status:** Proposal, awaiting founder sign-off
**Author:** Claude, session 013eBRgUdQAphNZJyiXza7LT
**Date:** 2026-06-01
**Triggering request:** Marvel Machines (plant `b1f10825-…`) — custom roles, per-role module access, per-project access restriction.

---

## 1. What we decided (so this doc has a memory)

Six product/architecture decisions made before writing this design:

| Decision | Choice |
|---|---|
| Commitment level | **Full RBAC, all three phases** (~4–6 weeks) |
| Pricing | **Part of Pro plan — no upcharge** |
| Marvel-specific scope | **Generic system — no Marvel-specific code** |
| Existing 5-role enum | **Keep + add custom roles on top** |
| Per-project access default | **Closed (must be explicitly added)** |
| Initial RBAC data scope | **Documents + module visibility only** — not row-level production data |

Anything below that contradicts these gets fixed, not the decisions.

---

## 2. Why this matters (the strategic frame)

Marvel is the **first paying customer to ask for RBAC**. Three implications:

1. **The retrofit cost grows with every customer.** One customer asking now is the cheapest moment.
2. **This is the enterprise-tier story.** Plants >50 employees need this; without it Loglinkr can't credibly compete with SAP B1.
3. **A leaky permission system is worse than none.** Once we say "Supervisor can't see Sales," it had better be true at the DB level, not just the UI. Customers losing trust in permissions = losing trust in the whole product.

That's why this is a 4–6 week project, not a 2-day patch.

---

## 3. Data model

### 3.1 New tables

```sql
-- A role definition. Built-in roles (slug in BUILTIN_ROLE_SLUGS) exist as
-- read-only seeded rows per plant; custom ones are created by admins.
create table plant_roles (
  id              uuid primary key default gen_random_uuid(),
  plant_id        uuid not null references plants(id) on delete cascade,
  slug            text not null,            -- 'plant_head','manager','supervisor', or 'site_engineer', etc.
  display_name    text not null,            -- "Plant Head", "Site Engineer"
  description     text,
  is_builtin      boolean not null default false,
  is_active       boolean not null default true,
  created_by      uuid references users(id),
  created_at      timestamptz not null default now(),
  unique (plant_id, slug)
);
-- Seed on plant creation: one row per built-in role.

-- A permission grant: role → module → action(s).
-- module_key matches the existing tab keys ('documents','stocks','quality',…)
-- action is from a fixed vocabulary: view, create, edit, delete, approve, export.
-- A row's absence means "no permission". Wildcard '*' for action == all actions.
create table role_permissions (
  role_id         uuid not null references plant_roles(id) on delete cascade,
  module_key      text not null,            -- 'documents','sales_docs','stocks','schedules',…
  action          text not null,            -- 'view','create','edit','delete','approve','export','*'
  -- Optional column-level discriminator for fine-grained slices, e.g.
  -- module='documents' + filter='doc_type:in:invoice_in,dc_in' means
  -- "this role can VIEW documents but only purchase ones, not sales."
  filter          jsonb,
  primary key (role_id, module_key, action, coalesce(filter, '{}'::jsonb))
);

-- A user can hold multiple roles in a plant. Permissions union together
-- (most-permissive wins; explicit DENY is not modeled in Phase 1–2).
create table user_plant_roles (
  user_id   uuid not null references users(id) on delete cascade,
  role_id   uuid not null references plant_roles(id) on delete cascade,
  granted_by uuid references users(id),
  granted_at timestamptz not null default now(),
  primary key (user_id, role_id)
);

-- Project membership for Phase 3. Closed-by-default per the decision above.
create table project_members (
  project_id    uuid not null references mcp_projects(id) on delete cascade,
  user_id       uuid not null references users(id) on delete cascade,
  -- Per-project role override; if NULL, user's plant-level roles apply
  -- but restricted to this project's data.
  project_role_id uuid references plant_roles(id),
  added_by      uuid references users(id),
  added_at      timestamptz not null default now(),
  primary key (project_id, user_id)
);
```

### 3.2 Coexistence with `users.role` enum

The existing `users.role` enum (`plant_head`, `admin`, `manager`, `supervisor`, `operator`) **stays exactly where it is.** It becomes the *default seed* role assigned at signup. The migration:

- On plant creation, seed five `plant_roles` rows (built-in, `is_builtin=true`) corresponding to the enum.
- On user creation (signup, invite redemption), assign the matching `plant_roles` row to `user_plant_roles` automatically.
- Every existing `users.role = 'supervisor'` becomes a `user_plant_roles` link to that plant's built-in `supervisor` role.

**Existing code that checks `me.role === 'plant_head'` keeps working.** New code uses the permissions system. We migrate call sites incrementally — never in a single big-bang rewrite.

The enum eventually becomes a denormalized hint (we keep it because notifications, audit logs, UI labels all use it). Source of truth for *access decisions* moves to `role_permissions`.

---

## 4. Permission model

### 4.1 The matrix

A permission is `(module, action, optional filter)`. The decision rule:

> "Does user U have a `plant_roles` (via `user_plant_roles`) whose `role_permissions` contains a row matching `(module=X, action=Y, filter satisfied)`? If yes, allow."

Module keys reuse the existing tab keys from `MORE_GROUPS` (`documents`, `sales_docs`, `stocks`, `schedules`, `quality`, `maintenance`, etc.) — that's the surface customers already understand.

Actions are deliberately small:

| Action | Meaning |
|---|---|
| `view` | Can see the module's tab and list pages |
| `create` | Can add new records |
| `edit` | Can modify own records (or any, depending on filter) |
| `delete` | Can soft-delete or remove |
| `approve` | Can move records into a terminal/locked state (verified GRN, signed NCR, approved invoice) |
| `export` | Can download CSV/PDF of the module's data |
| `*` | Wildcard — all of the above |

### 4.2 Concrete example: Marvel's "Purchase Officer"

```
role: purchase_officer (display: "Purchase Officer")
  permissions:
    documents       view   filter: {doc_type: [invoice_in, dc_in, bill]}
    documents       create filter: {doc_type: [invoice_in, dc_in]}
    stocks          view
    movements       view
    sales_docs      —  (no row, no access)
    quality         —
    chat            view   (chat stays universal — kills the workflow if restricted)
```

A supervisor assigned to a specific project additionally has `project_members.project_id = <X>`, and Phase 3 enforces that every `documents` row read filters on `project_id = X` (with allowlist).

### 4.3 The "filter" field is the secret sauce

This is what makes "Documents but only Purchase, not Sales" possible without inventing a whole new module per slice. Filters are evaluated server-side and added to the SQL WHERE clause. Plant admins won't write them directly — the UI gives them checkboxes that compile down to filter JSON.

---

## 5. Enforcement layers

Defense in depth — UI hides, API checks, DB enforces. **All three matter.**

### 5.1 UI layer (Phase 1)

- A `usePermissions()` hook returns `{can: (module, action, ctx?) => boolean, accessibleModules: [...], accessibleProjects: [...]}`.
- `MORE_GROUPS` rendering filters items by `can('documents','view')`, etc.
- Buttons (Edit, Delete, Approve) wrap with `<IfCan module="documents" action="edit">`.
- List queries pass user permissions to the URL/RPC so they get back already-filtered data.

This is "visibility" — fast to ship, immediately useful, but **not security** alone. A sophisticated user with browser dev tools could still call APIs directly. That's what Phase 2 fixes.

### 5.2 API / RPC layer (Phase 2)

Every existing RPC gets a `check_permission(auth.uid(), p_module, p_action)` call at the top:

```sql
create or replace function some_existing_rpc(...) returns ... as $$
begin
  if not check_permission(auth.uid(), 'documents', 'create') then
    raise exception 'permission_denied';
  end if;
  -- existing body
end $$;
```

Lists return only allowed rows. Mutations reject unauthorized writes. **This is where the security guarantee actually lives.**

### 5.3 Database / RLS layer (Phase 2)

For the tables in scope (`mcp_logistics_documents`, `mcp_logistics_payments`, `mcp_logistics_grn_*`, `mcp_logistics_vendors`, plus project-scoped tables in Phase 3), enable Postgres Row Level Security:

```sql
alter table mcp_logistics_documents enable row level security;

create policy doc_select on mcp_logistics_documents for select
  using (
    plant_id = current_plant_id()
    and (
      -- has unrestricted view permission
      check_permission(auth.uid(), 'documents', 'view') and not has_doc_type_filter(auth.uid())
      -- or has filtered view permission and this row matches the filter
      or check_permission_with_filter(auth.uid(), 'documents', 'view', doc_type)
    )
    -- Phase 3: project gate (only if RBAC project policy enabled for this plant)
    and (project_id is null or project_visible_to(auth.uid(), project_id))
  );
```

RLS makes the database itself reject unauthorized rows, even if a bug in the app code or a future feature forgets to check. **Belt + braces + zip tie.**

### 5.4 What is OUT of scope per the decisions

Production logs (`mcp_pdc_shots`, etc.), quality records (`mcp_quality_*`), maintenance logs — **no row-level restriction in Phase 1–2**. Anyone with `view` on the module sees all rows in the plant. We can add row-level later when a customer specifically asks.

---

## 6. Phasing — what ships when

### Phase 1 — UI-level RBAC + custom roles (Week 1)

**Goal:** Marvel can create custom roles and Druva (plant_head) can hide modules from users. Honest framing: "visibility, not security yet."

- Migration: create `plant_roles`, `role_permissions`, `user_plant_roles` tables; seed builtin roles for all existing plants; backfill `user_plant_roles` from current `users.role`.
- Admin UI in **People → Roles** tab: create role, set display name, check boxes for module + action grid.
- Admin UI in user row: assign roles (multi-select).
- Frontend hook `usePermissions()` reading from the new tables.
- `MORE_GROUPS` + per-module list filters honoring permissions.
- Big yellow banner in the role-edit UI: *"This controls what users SEE. Backend enforcement ships in Phase 2 (2–3 weeks)."*

**Marvel sees:** Custom roles, per-role module visibility, doc_type filter on Documents (Purchase vs Sales). 70% of their ask.

### Phase 2 — Backend enforcement (Weeks 2–4)

**Goal:** What the UI hides, the API and DB also block. The yellow banner comes down.

- `check_permission(uid, module, action)` SQL function and `check_permission_with_filter()`.
- Every existing RPC that touches in-scope modules gets a permission check at the top. List of RPCs identified in advance (see §10 — open questions).
- RLS policies on `mcp_logistics_*` tables.
- Edge functions (`extract-document`, `loglinkr-chat`, etc.) inherit the user's JWT and respect RLS automatically. Functions using service_role bypass RLS — those get explicit `check_permission` calls instead.
- Migration of every list query in `app.html` that fetches in-scope data to use RLS-respecting queries.

**Marvel sees:** No visible change, but security is now real. The banner comes down. Sales pitch: "audit-ready permissions."

### Phase 3 — Per-project access (Weeks 4–6)

**Goal:** Supervisor on Project A genuinely cannot read Project B's records.

- Migration: `project_members` table; UI for "Add team member" on each project page.
- Per-project role override (optional).
- RLS extension: project-scoped tables filter by `project_visible_to(uid, project_id)`.
- New user invite → admin chooses which projects (closed by default per the decision).

**Marvel sees:** Full RBAC, project-scoped data, the complete enterprise feature.

---

## 7. Migration plan for existing plants

Six plants exist as of this writing (Marvel + 5 others). The migration must not break any of them.

1. **Schema changes are additive only** — new tables, no destructive changes to `users`, `plants`, `mcp_*`.
2. **Seed step in the migration:**
   - For each existing plant: insert 5 `plant_roles` rows (built-in) and grant the "full" permission set to those roles. Effectively: existing behavior, no change.
   - For each existing user: insert `user_plant_roles` row matching `users.role`.
3. **The legacy `users.role` enum keeps working** — every legacy code path that checks it still passes, because the seeded built-in roles match the enum semantics 1-to-1.
4. **RLS policies use a "RBAC-enforced" plant flag** — a column `plants.rbac_enforced boolean default false`. Existing plants stay `false`; their behavior is unchanged. Marvel opts in (`true`); their policies activate.
5. **Once we're confident** (probably 30 days, several plants opted in voluntarily), we default `rbac_enforced = true` for new plants. Eventually backfill the rest.

This is the **opt-in migration pattern** — same one used by Stripe for API version upgrades. Customers who want the new behavior get it now; nobody else is disrupted.

---

## 8. UI design (sketch, not pixel-perfect)

### People → Roles tab (new)

```
ROLES · Marvel Machines

Built-in roles (cannot be deleted)
  Plant Head     · 1 user · all permissions      [view]
  Admin          · 0 users · all permissions     [view]
  Manager        · 0 users · operational         [view]
  Supervisor     · 0 users · floor + verify      [view]
  Operator       · 0 users · no login            [view]

Custom roles
  Purchase Officer  · 0 users · purchase docs + stocks  [edit] [×]
  Site Engineer     · 0 users · projects + quality      [edit] [×]
  [+ Create role]
```

### Role editor

```
Role: Purchase Officer
Display name: [Purchase Officer]
Description:  [Handles incoming vendor bills and stock receipts]

PERMISSIONS                view  create  edit  delete  approve  export
🏭 Production              ☐     ☐       ☐     ☐       ☐        ☐
📦 Stocks                  ☑     ☐       ☐     ☐       ☐        ☐
📄 Documents · Bills       ☑     ☑       ☐     ☐       ☐        ☐
   └ filter: doc types     ☑ Purchase invoices  ☑ Delivery challans
                           ☐ Sales invoices     ☐ Quotes
📤 Make Documents          ☐ ☐ ☐ ☐ ☐ ☐
🛡 Quality                 ☐ ☐ ☐ ☐ ☐ ☐
[ Save role ]
```

### User-row role assignment

```
Selvam K · supervisor [legacy]
  Roles: [Supervisor ×]  [+ Add role]
  Projects: All projects (no restriction)  [Change]
```

### Project-members page (Phase 3)

```
Project: Tank Fabrication for ACME
  Members:
    Druva Lakshman   plant_head        all access
    Selvam K         supervisor        view+create on this project only [×]
    [+ Add member]
```

---

## 9. Risks and how I'll handle them

| Risk | Mitigation |
|---|---|
| **Leaky permission system** (UI says no, API says yes) | The yellow banner in Phase 1 sets expectation honestly. Phase 2 closes the gap before we promote it as "secure." |
| **Performance regression** from RLS on every read | Indexes on `(plant_id, project_id)`, materialized `user_permissions` cache, monitor query times before/after. If RLS is slow on a hot path we move that check into an RPC. |
| **Plant admin locks themselves out** by removing their own role | Hard guard: can't remove a permission that would leave the plant with zero `*` users. Plant Head is undeletable. |
| **Existing code that uses `me.role === 'plant_head'`** silently breaks | We keep the enum populated. The migration backfills it consistently. We grep for every callsite and add tests before Phase 2. |
| **A bug in a Phase 2 RLS policy** blocks all reads from some table | Plant-level `rbac_enforced` flag means existing plants are unaffected by policy changes until they opt in. |
| **The 4–6 week timeline slips** to 8–10 weeks | Realistic. Software always does. We tell Marvel "Q3 2026" not "in 6 weeks." Phase 1 ships first so they see progress. |

---

## 10. Open questions — I need your input before starting

These are the things I genuinely don't know yet:

1. **Approve as separate action, or fold into edit?**
   I lean toward separate. NCR closure, GRN verification, invoice approval all feel like they deserve their own permission. But it's one more column in the matrix.

2. **How to handle Chat?**
   Restricting chat is operationally risky — it's the team's lifeline. I propose: Chat stays universal (every plant member sees plant-wide groups they're in). Per-group permissions might come later but not in this design.

3. **OCR / Document auto-extraction** — when a Supervisor uploads a bill image, who "owns" it for permission purposes?
   I propose: the uploader. They can always see what they uploaded; admins always see everything; others see based on `doc_type` filters.

4. **Should "approve" gate auto-progressing workflows?**
   Today, a GRN is auto-created from an OCR'd invoice. Should that auto-creation respect permissions? I propose yes — if the user doesn't have `documents:create`, the queue row goes to `pending_approval` instead.

5. **External users (vendors, customers) via RFQ links** — does RBAC touch them?
   No. External flows stay separate, anonymous, link-token-gated. RBAC is internal-team only.

6. **A "view as this role" debug mode** for plant admins?
   Very valuable when designing roles. Adds maybe a day. Worth it.

7. **Audit log of role changes**
   Required. Every role create/edit/assignment goes into `audit_logs` so the plant has a trail.

---

## 11. What I'm NOT planning to do

To set expectations honestly:

- **Not** building a generic permission DSL. The matrix is fixed (module × action × optional filter). No free-form expressions.
- **Not** implementing explicit DENY rules. Permissions are additive ("most permissive wins"). DENY adds enormous complexity for marginal value.
- **Not** doing field-level (column-level) restrictions in this round. *"Supervisor can see invoice total but not vendor address"* — possible later, not now.
- **Not** building per-unit RBAC in this round. Multi-unit access stays as today (user has access to their assigned unit; nothing finer).
- **Not** building delegation ("Supervisor X can grant permissions on Y's behalf"). Only plant_head/admin can change roles.

---

## 12. The honest one-liner for Marvel

> *"You're right — this is the right next step for Loglinkr. We're starting work now. You'll see custom roles and module-level access within ~1 week. Backend enforcement within ~4 weeks. Per-project access within ~6 weeks. Want to be the first plant on the beta? You'll help shape it."*

Ship Phase 1. Sit with Druva for an afternoon. Watch them configure it for their actual workflow. Iterate.

---

## 13. Next actions

If this design is approved:

- [ ] **Founder review and sign-off** (or push back on specific decisions in §10)
- [ ] **Next session: Phase 1 implementation** starting with the schema migration and the People → Roles tab
- [ ] **Mid-Phase-1: 30-minute call with Druva** to confirm role names/permissions match their mental model before we hardcode the seed permissions
- [ ] **End-of-Phase-1: demo build to Marvel**, get feedback before starting Phase 2

If not approved: tell me what to change. Better to spend two more days on this doc than two weeks on the wrong implementation.

---

## 14. Phase 3 addendum — per-project bill/expense isolation + project-aware OCR

Added after Marvel asked specifically: *"a supervisor assigned to a project cannot see other projects' bills or expenses, and how does he update bills via OCR?"*

### 14.1 The blocker found in the schema (2026-06)

| Table | `project_id` today? |
|---|---|
| `mcp_expenses` | ✅ yes |
| `mcp_logistics_documents` (bills/DCs) | ❌ **no** |
| `mcp_logistics_extraction_queue` (OCR) | ❌ **no** |

So bills currently have **no project link at all** — per-project bill isolation is impossible to enforce until that's added. This is the single biggest piece of Phase 3.

### 14.2 The build, in order

1. **Schema:** add `project_id uuid references mcp_projects(id)` to
   `mcp_logistics_documents` AND `mcp_logistics_extraction_queue`. Backfill
   existing rows to NULL (plant-wide, owner-visible).
2. **OCR attribution — "inferred + fallback picker" (decided):**
   - When a project-scoped supervisor uploads a bill, the system looks at
     their `project_members` rows.
     - Exactly **one** project → the queue row + resulting document auto-tag
       to that project. Zero extra taps — they snap the bill in chat exactly
       as today.
     - **Multiple** projects → a "Which project?" picker appears at upload
       time (one tap), written into the queue row.
     - Plant_head / admin / unassigned users → bill stays plant-wide
       (`project_id = NULL`), visible to all, as today.
   - `enqueue_chat_image_for_extraction` gains a `p_project_id` arg; the
     edge function copies it from the queue row onto the created document.
3. **Enforcement (depends on Phase 2 RLS):** RLS policy on
   `mcp_logistics_documents` and `mcp_expenses` —
   `project_id is null OR project_visible_to(auth.uid(), project_id)` where
   `project_visible_to` checks `project_members`. Owners bypass.
4. **UI:** Documents + Expenses lists filter by accessible projects; a
   project-scoped supervisor simply never receives other projects' rows from
   the DB (not just hidden — never sent).

### 14.3 Hard dependency

This **cannot ship securely before Phase 2** (RLS enforcement). Until the DB
enforces permissions, "hiding" project B's bills in the UI is cosmetic — a
determined user could still query them. Sequence is firm: **Phase 2 (RLS) →
Phase 3 (project scoping + project-aware OCR).** Estimate 3–5 weeks combined.

### 14.4 Decisions locked for Phase 3

- Project access default: **closed** (supervisor sees no project until added) — §10 / earlier.
- OCR attribution: **inferred from single project membership, picker when multiple**.
- Owners (plant_head/admin): **never project-filtered**.
- Expenses: reuse the existing `mcp_expenses.project_id`; only add the RLS gate.
