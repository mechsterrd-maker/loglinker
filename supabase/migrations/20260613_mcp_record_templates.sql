-- AI-built record format templates. Each plant uploads photos/scans of the
-- record formats they already use; Claude vision extracts the layout and
-- field-label mappings; the JSON config is stored here and is used as a
-- layout when the user generates reports from the corresponding module.
create table public.mcp_record_templates (
  id uuid primary key default gen_random_uuid(),
  plant_id uuid not null references public.plants(id) on delete cascade,
  name text not null,
  description text,
  source text not null check (source in (
    'petty_cash', 'expenses', 'shots', 'ncrs', 'documents', 'projects', 'mom', 'custom'
  )),
  config jsonb not null default '{}'::jsonb,
  source_image_url text,
  ai_model text,
  ai_confidence text check (ai_confidence in ('high','medium','low')),
  active boolean not null default true,
  created_by uuid references public.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index mcp_record_templates_plant_idx
  on public.mcp_record_templates(plant_id) where active = true;
create index mcp_record_templates_source_idx
  on public.mcp_record_templates(plant_id, source) where active = true;

alter table public.mcp_record_templates enable row level security;

create policy record_templates_select on public.mcp_record_templates
  for select to authenticated
  using (plant_id in (select u.plant_id from public.users u where u.id = auth.uid()));

create policy record_templates_insert on public.mcp_record_templates
  for insert to authenticated
  with check (plant_id in (select u.plant_id from public.users u where u.id = auth.uid()));

create policy record_templates_update on public.mcp_record_templates
  for update to authenticated
  using (plant_id in (select u.plant_id from public.users u where u.id = auth.uid()))
  with check (plant_id in (select u.plant_id from public.users u where u.id = auth.uid()));

create policy record_templates_delete on public.mcp_record_templates
  for delete to authenticated
  using (plant_id in (select u.plant_id from public.users u where u.id = auth.uid()));

drop trigger if exists tg_record_templates_touch on public.mcp_record_templates;
create trigger tg_record_templates_touch before update on public.mcp_record_templates
  for each row execute function public.tg_touch_updated_at();
