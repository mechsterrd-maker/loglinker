-- =============================================================================
-- LOGLINKR — BASE STRUCTURE SCHEMA
-- =============================================================================
-- Block 1: Universal base tables for all plants.
-- Multi-tenant shared with strict Row-Level Security.
-- Every table has plant_id and RLS policies from day one.
-- =============================================================================

-- Run this in Supabase SQL Editor.
-- Order matters: types → tables → indexes → RLS policies → functions.

-- =============================================================================
-- 1. ENUMS
-- =============================================================================

CREATE TYPE subscription_tier AS ENUM ('lite', 'pro', 'plus');
CREATE TYPE user_role AS ENUM ('plant_head', 'admin', 'supervisor', 'qa', 'operator', 'store', 'driver', 'toolroom');
CREATE TYPE user_status AS ENUM ('active', 'inactive', 'pending');
CREATE TYPE chat_group_type AS ENUM ('all_hands', 'unit_supervisors', 'department', 'custom', 'auto_thread');
CREATE TYPE pulse_status AS ENUM ('pending', 'in_progress', 'completed', 'overdue', 'escalated_l1', 'escalated_l2', 'escalated_l3');
CREATE TYPE action_source AS ENUM ('pulse', 'chat', 'mom', 'customer_complaint', 'audit_finding', 'ncr', 'manual');
CREATE TYPE action_status AS ENUM ('open', 'in_progress', 'completed', 'cancelled');

-- =============================================================================
-- 2. CORE BUILT-IN MASTERS
-- =============================================================================

-- 2.1 Plants ----------------------------------------------------------------

CREATE TABLE plants (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  legal_name TEXT,
  gstin TEXT,
  iatf_certified BOOLEAN NOT NULL DEFAULT false,
  iatf_cert_number TEXT,
  iatf_expiry DATE,
  address TEXT NOT NULL,
  city TEXT NOT NULL,
  state TEXT NOT NULL,
  pincode TEXT NOT NULL,
  primary_contact_user_id UUID,
  subscription_tier subscription_tier NOT NULL DEFAULT 'lite',
  installed_mcps JSONB NOT NULL DEFAULT '[]'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_plants_gstin ON plants(gstin) WHERE gstin IS NOT NULL;

-- 2.2 Units -----------------------------------------------------------------

CREATE TABLE units (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id UUID NOT NULL REFERENCES plants(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  address TEXT,
  installed_mcps JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_units_plant ON units(plant_id);

-- 2.3 Departments -----------------------------------------------------------

CREATE TABLE departments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id UUID NOT NULL REFERENCES plants(id) ON DELETE CASCADE,
  unit_id UUID NOT NULL REFERENCES units(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  head_user_id UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_departments_plant ON departments(plant_id);
CREATE INDEX idx_departments_unit ON departments(unit_id);

-- 2.4 Users -----------------------------------------------------------------
-- Note: id matches auth.users.id from Supabase Auth

CREATE TABLE users (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  plant_id UUID NOT NULL REFERENCES plants(id) ON DELETE CASCADE,
  primary_unit_id UUID REFERENCES units(id) ON DELETE SET NULL,
  full_name TEXT NOT NULL,
  phone TEXT NOT NULL,
  email TEXT,
  pin_hash TEXT,
  role user_role NOT NULL,
  status user_status NOT NULL DEFAULT 'active',
  can_install_mcps BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_users_plant ON users(plant_id);
CREATE INDEX idx_users_phone ON users(phone);
CREATE UNIQUE INDEX idx_users_phone_per_plant ON users(plant_id, phone);

-- Add the FK back to plants now that users exists
ALTER TABLE plants
  ADD CONSTRAINT fk_plants_primary_contact
  FOREIGN KEY (primary_contact_user_id) REFERENCES users(id) ON DELETE SET NULL;

ALTER TABLE departments
  ADD CONSTRAINT fk_departments_head
  FOREIGN KEY (head_user_id) REFERENCES users(id) ON DELETE SET NULL;

-- 2.5 Shifts ----------------------------------------------------------------

CREATE TABLE shifts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id UUID NOT NULL REFERENCES plants(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  start_time TIME NOT NULL,
  end_time TIME NOT NULL,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_shifts_plant ON shifts(plant_id);

-- =============================================================================
-- 3. CHAT LAYER
-- =============================================================================

CREATE TABLE chat_groups (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id UUID NOT NULL REFERENCES plants(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  type chat_group_type NOT NULL DEFAULT 'custom',
  unit_id UUID REFERENCES units(id) ON DELETE CASCADE,
  members UUID[] NOT NULL DEFAULT '{}',
  metadata JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_chat_groups_plant ON chat_groups(plant_id);
CREATE INDEX idx_chat_groups_members ON chat_groups USING gin(members);

CREATE TABLE chat_messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id UUID NOT NULL REFERENCES plants(id) ON DELETE CASCADE,
  group_id UUID NOT NULL REFERENCES chat_groups(id) ON DELETE CASCADE,
  sender_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  body TEXT,
  attachments JSONB DEFAULT '[]'::jsonb,
  parsed_intent JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_chat_messages_group ON chat_messages(group_id, created_at DESC);
CREATE INDEX idx_chat_messages_plant ON chat_messages(plant_id);

CREATE TABLE chat_message_actions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id UUID NOT NULL REFERENCES plants(id) ON DELETE CASCADE,
  message_id UUID NOT NULL REFERENCES chat_messages(id) ON DELETE CASCADE,
  suggested_mcp_id TEXT NOT NULL,
  suggested_action TEXT NOT NULL,
  suggested_payload JSONB NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending', -- pending / confirmed / edited / ignored
  resulting_record_id UUID,
  resulting_record_table TEXT,
  resolved_by UUID REFERENCES users(id),
  resolved_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_chat_actions_message ON chat_message_actions(message_id);
CREATE INDEX idx_chat_actions_plant ON chat_message_actions(plant_id);

-- =============================================================================
-- 4. PULSE LAYER (Compliance Pulse)
-- =============================================================================

CREATE TABLE pulse_cadences (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id UUID NOT NULL REFERENCES plants(id) ON DELETE CASCADE,
  mcp_id TEXT NOT NULL,
  entity_type TEXT NOT NULL,
  entity_id UUID NOT NULL,
  cadence_type TEXT NOT NULL, -- 'daily', 'weekly', 'monthly', 'on_event', 'on_threshold'
  frequency JSONB NOT NULL, -- {days: 7} or {strokes: 25000} etc
  owner_role user_role NOT NULL,
  escalation_chain JSONB NOT NULL, -- [{level: 1, after_hours: 48, to_role: 'plant_head'}, ...]
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_pulse_cadences_plant ON pulse_cadences(plant_id);
CREATE INDEX idx_pulse_cadences_entity ON pulse_cadences(entity_type, entity_id);

CREATE TABLE pulse_tasks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id UUID NOT NULL REFERENCES plants(id) ON DELETE CASCADE,
  cadence_id UUID NOT NULL REFERENCES pulse_cadences(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  description TEXT,
  owner_id UUID REFERENCES users(id) ON DELETE SET NULL,
  due_at TIMESTAMPTZ NOT NULL,
  status pulse_status NOT NULL DEFAULT 'pending',
  completed_at TIMESTAMPTZ,
  completed_by UUID REFERENCES users(id),
  completion_evidence JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_pulse_tasks_plant ON pulse_tasks(plant_id);
CREATE INDEX idx_pulse_tasks_owner ON pulse_tasks(owner_id, status);
CREATE INDEX idx_pulse_tasks_due ON pulse_tasks(due_at) WHERE status IN ('pending', 'in_progress');

-- =============================================================================
-- 5. ACTION HUB (universal commitment tracker)
-- =============================================================================

CREATE TABLE actions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id UUID NOT NULL REFERENCES plants(id) ON DELETE CASCADE,
  source_type action_source NOT NULL,
  source_id UUID, -- pointer to originating record (pulse_task, chat_message, etc.)
  source_label TEXT,
  title TEXT NOT NULL,
  description TEXT,
  owner_id UUID REFERENCES users(id) ON DELETE SET NULL,
  assigned_by UUID REFERENCES users(id) ON DELETE SET NULL,
  due_at TIMESTAMPTZ,
  status action_status NOT NULL DEFAULT 'open',
  escalated_to_id UUID REFERENCES users(id) ON DELETE SET NULL,
  escalated_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  completion_evidence JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_actions_plant ON actions(plant_id, status);
CREATE INDEX idx_actions_owner ON actions(owner_id, status);
CREATE INDEX idx_actions_due ON actions(due_at) WHERE status IN ('open', 'in_progress');
CREATE INDEX idx_actions_source ON actions(source_type, source_id);

-- =============================================================================
-- 6. AUDIT TRAIL (every write logged)
-- =============================================================================

CREATE TABLE audit_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id UUID NOT NULL,
  user_id UUID,
  mcp_id TEXT,
  table_name TEXT NOT NULL,
  row_id UUID NOT NULL,
  action TEXT NOT NULL, -- 'insert', 'update', 'delete'
  before JSONB,
  after JSONB,
  ip_address TEXT,
  user_agent TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_audit_plant ON audit_log(plant_id, created_at DESC);
CREATE INDEX idx_audit_row ON audit_log(table_name, row_id);
CREATE INDEX idx_audit_user ON audit_log(user_id, created_at DESC);

-- =============================================================================
-- 7. MCP REGISTRY (which MCPs are available + which are installed where)
-- =============================================================================

CREATE TABLE mcp_registry (
  id TEXT PRIMARY KEY, -- e.g., 'production_pdc_v1'
  name TEXT NOT NULL,
  version TEXT NOT NULL,
  category TEXT NOT NULL, -- 'production', 'quality', 'maintenance', etc.
  manifest JSONB NOT NULL, -- full MCP manifest as per spec
  is_official BOOLEAN NOT NULL DEFAULT true, -- shipped by Loglinkr team
  created_by UUID REFERENCES users(id),
  is_published BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_mcp_registry_category ON mcp_registry(category) WHERE is_published = true;

-- =============================================================================
-- 8. WAITLIST (for pre-launch email signups from loglinkr.com)
-- =============================================================================

CREATE TABLE waitlist (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email TEXT NOT NULL UNIQUE,
  source TEXT, -- 'landing', 'referral', etc.
  metadata JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- =============================================================================
-- 9. HELPER FUNCTIONS
-- =============================================================================

-- Returns the plant_id of the currently authenticated user
CREATE OR REPLACE FUNCTION current_plant_id()
RETURNS UUID
LANGUAGE sql STABLE SECURITY DEFINER
AS $$
  SELECT plant_id FROM users WHERE id = auth.uid();
$$;

-- Returns the role of the currently authenticated user
CREATE OR REPLACE FUNCTION current_user_role()
RETURNS user_role
LANGUAGE sql STABLE SECURITY DEFINER
AS $$
  SELECT role FROM users WHERE id = auth.uid();
$$;

-- Auto-update updated_at timestamps
CREATE OR REPLACE FUNCTION update_timestamp()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER plants_updated_at BEFORE UPDATE ON plants FOR EACH ROW EXECUTE FUNCTION update_timestamp();
CREATE TRIGGER units_updated_at BEFORE UPDATE ON units FOR EACH ROW EXECUTE FUNCTION update_timestamp();
CREATE TRIGGER users_updated_at BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION update_timestamp();
CREATE TRIGGER actions_updated_at BEFORE UPDATE ON actions FOR EACH ROW EXECUTE FUNCTION update_timestamp();

-- =============================================================================
-- 10. ROW-LEVEL SECURITY POLICIES
-- =============================================================================
-- CRITICAL: Every table gets RLS enabled. Every table gets policies. No exceptions.

-- 10.1 Plants ---------------------------------------------------------------

ALTER TABLE plants ENABLE ROW LEVEL SECURITY;

CREATE POLICY "users_see_own_plant" ON plants
  FOR SELECT USING (id = current_plant_id());

CREATE POLICY "plant_head_updates_own_plant" ON plants
  FOR UPDATE USING (
    id = current_plant_id()
    AND current_user_role() IN ('plant_head', 'admin')
  );

-- INSERT and DELETE on plants happens via signup/onboarding flow only (service role)

-- 10.2 Units ----------------------------------------------------------------

ALTER TABLE units ENABLE ROW LEVEL SECURITY;

CREATE POLICY "users_see_own_units" ON units
  FOR SELECT USING (plant_id = current_plant_id());

CREATE POLICY "plant_head_inserts_units" ON units
  FOR INSERT WITH CHECK (
    plant_id = current_plant_id()
    AND current_user_role() IN ('plant_head', 'admin')
  );

CREATE POLICY "plant_head_updates_units" ON units
  FOR UPDATE USING (
    plant_id = current_plant_id()
    AND current_user_role() IN ('plant_head', 'admin')
  );

CREATE POLICY "plant_head_deletes_units" ON units
  FOR DELETE USING (
    plant_id = current_plant_id()
    AND current_user_role() IN ('plant_head', 'admin')
  );

-- 10.3 Departments ----------------------------------------------------------

ALTER TABLE departments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "users_see_own_departments" ON departments
  FOR SELECT USING (plant_id = current_plant_id());

CREATE POLICY "managers_manage_departments" ON departments
  FOR ALL USING (
    plant_id = current_plant_id()
    AND current_user_role() IN ('plant_head', 'admin')
  );

-- 10.4 Users ----------------------------------------------------------------

ALTER TABLE users ENABLE ROW LEVEL SECURITY;

CREATE POLICY "users_see_own_plant_users" ON users
  FOR SELECT USING (plant_id = current_plant_id());

CREATE POLICY "users_update_self" ON users
  FOR UPDATE USING (id = auth.uid());

CREATE POLICY "managers_manage_users" ON users
  FOR ALL USING (
    plant_id = current_plant_id()
    AND current_user_role() IN ('plant_head', 'admin')
  );

-- 10.5 Shifts ---------------------------------------------------------------

ALTER TABLE shifts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "users_see_own_shifts" ON shifts
  FOR SELECT USING (plant_id = current_plant_id());

CREATE POLICY "managers_manage_shifts" ON shifts
  FOR ALL USING (
    plant_id = current_plant_id()
    AND current_user_role() IN ('plant_head', 'admin')
  );

-- 10.6 Chat ------------------------------------------------------------------

ALTER TABLE chat_groups ENABLE ROW LEVEL SECURITY;

CREATE POLICY "members_see_own_groups" ON chat_groups
  FOR SELECT USING (
    plant_id = current_plant_id()
    AND auth.uid() = ANY(members)
  );

CREATE POLICY "managers_create_groups" ON chat_groups
  FOR INSERT WITH CHECK (
    plant_id = current_plant_id()
    AND current_user_role() IN ('plant_head', 'admin', 'supervisor')
  );

CREATE POLICY "managers_manage_groups" ON chat_groups
  FOR UPDATE USING (
    plant_id = current_plant_id()
    AND current_user_role() IN ('plant_head', 'admin', 'supervisor')
  );

ALTER TABLE chat_messages ENABLE ROW LEVEL SECURITY;

CREATE POLICY "members_see_own_messages" ON chat_messages
  FOR SELECT USING (
    plant_id = current_plant_id()
    AND group_id IN (
      SELECT id FROM chat_groups WHERE auth.uid() = ANY(members)
    )
  );

CREATE POLICY "members_send_messages" ON chat_messages
  FOR INSERT WITH CHECK (
    plant_id = current_plant_id()
    AND sender_id = auth.uid()
    AND group_id IN (
      SELECT id FROM chat_groups WHERE auth.uid() = ANY(members)
    )
  );

ALTER TABLE chat_message_actions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "users_see_chat_actions" ON chat_message_actions
  FOR SELECT USING (plant_id = current_plant_id());

CREATE POLICY "users_resolve_chat_actions" ON chat_message_actions
  FOR UPDATE USING (plant_id = current_plant_id());

-- 10.7 Pulse ----------------------------------------------------------------

ALTER TABLE pulse_cadences ENABLE ROW LEVEL SECURITY;

CREATE POLICY "users_see_cadences" ON pulse_cadences
  FOR SELECT USING (plant_id = current_plant_id());

CREATE POLICY "managers_manage_cadences" ON pulse_cadences
  FOR ALL USING (
    plant_id = current_plant_id()
    AND current_user_role() IN ('plant_head', 'admin')
  );

ALTER TABLE pulse_tasks ENABLE ROW LEVEL SECURITY;

CREATE POLICY "users_see_pulse_tasks" ON pulse_tasks
  FOR SELECT USING (plant_id = current_plant_id());

CREATE POLICY "users_complete_own_tasks" ON pulse_tasks
  FOR UPDATE USING (
    plant_id = current_plant_id()
    AND (owner_id = auth.uid() OR current_user_role() IN ('plant_head', 'admin'))
  );

-- 10.8 Action Hub -----------------------------------------------------------

ALTER TABLE actions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "users_see_own_plant_actions" ON actions
  FOR SELECT USING (plant_id = current_plant_id());

CREATE POLICY "users_create_actions" ON actions
  FOR INSERT WITH CHECK (plant_id = current_plant_id());

CREATE POLICY "users_update_own_actions" ON actions
  FOR UPDATE USING (
    plant_id = current_plant_id()
    AND (owner_id = auth.uid() OR assigned_by = auth.uid() OR current_user_role() IN ('plant_head', 'admin'))
  );

-- 10.9 Audit Log ------------------------------------------------------------

ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY "managers_read_audit" ON audit_log
  FOR SELECT USING (
    plant_id = current_plant_id()
    AND current_user_role() IN ('plant_head', 'admin', 'qa')
  );

-- audit_log inserts happen via triggers (service role) only

-- 10.10 MCP Registry --------------------------------------------------------

ALTER TABLE mcp_registry ENABLE ROW LEVEL SECURITY;

CREATE POLICY "anyone_reads_published_mcps" ON mcp_registry
  FOR SELECT USING (is_published = true);

-- 10.11 Waitlist ------------------------------------------------------------

ALTER TABLE waitlist ENABLE ROW LEVEL SECURITY;

CREATE POLICY "anyone_can_signup_waitlist" ON waitlist
  FOR INSERT WITH CHECK (true);

-- Only service role can read waitlist (for now; admin dashboard later)

-- =============================================================================
-- 11. SEED DATA — first MCP registry entry (Production-PDC manifest)
-- =============================================================================

INSERT INTO mcp_registry (id, name, version, category, manifest, is_official, is_published)
VALUES (
  'production_pdc_v1',
  'Production — Pressure Die Casting',
  '1.0.0',
  'production',
  '{
    "id": "production_pdc_v1",
    "name": "Production — Pressure Die Casting",
    "version": "1.0.0",
    "plant_types": ["pdc", "die_casting", "aluminum_casting"],
    "iatf_clauses": ["8.5.1", "8.5.2", "8.5.6", "9.1.1.2"],
    "dependencies": ["base"],
    "optional_dependencies": ["quality_iatf_v1", "maintenance_die_heavy_v1", "stocks_general_v1"],
    "tables": ["mcp_pdc_machines", "mcp_pdc_dies", "mcp_pdc_die_history", "mcp_pdc_shots"],
    "description": "Captures shots, dies, machines, and die history for Pressure Die Casting plants. Auto-cascades stroke counts, raw material consumption, and reject thresholds."
  }'::jsonb,
  true,
  false
);

-- =============================================================================
-- DONE. Block 1 base schema ready.
-- Next blocks add MCP-specific tables (mcp_pdc_*, mcp_quality_*, etc.)
-- =============================================================================
