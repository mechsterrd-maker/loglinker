-- Founder approval gate. Every NEW plant lands as 'pending' and the
-- shell shows a waiting screen until the founder flips it to 'approved'.
-- Existing plants are backfilled to 'approved' so nothing breaks live.
alter table public.plants
  add column if not exists approval_status text not null default 'pending'
    check (approval_status in ('pending','approved','rejected')),
  add column if not exists approval_decided_at timestamptz,
  add column if not exists approval_decided_by uuid references public.users(id) on delete set null,
  add column if not exists approval_note text;

update public.plants
  set approval_status = 'approved',
      approval_decided_at = coalesce(approval_decided_at, created_at)
  where approval_status = 'pending';

create index if not exists idx_plants_approval_pending
  on public.plants(created_at desc)
  where approval_status = 'pending';

create or replace function public.founder_set_plant_approval(
  p_plant_id uuid,
  p_status text,
  p_note text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_email text;
begin
  if v_uid is null then
    return jsonb_build_object('success', false, 'error', 'not_authenticated');
  end if;
  select lower(trim(email)) into v_email from public.users where id = v_uid;
  if v_email not in ('rajadurai92r@gmail.com') then
    return jsonb_build_object('success', false, 'error', 'forbidden_not_founder');
  end if;
  if p_status not in ('pending','approved','rejected') then
    return jsonb_build_object('success', false, 'error', 'invalid_status');
  end if;
  update public.plants
    set approval_status = p_status,
        approval_decided_at = now(),
        approval_decided_by = v_uid,
        approval_note = p_note
    where id = p_plant_id;
  return jsonb_build_object('success', true);
end $$;

grant execute on function public.founder_set_plant_approval(uuid, text, text) to authenticated;
