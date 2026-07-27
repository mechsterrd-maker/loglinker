-- Lightweight funnel analytics: page views, APK downloads, trial clicks.
CREATE TABLE IF NOT EXISTS public.analytics_events (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  event      text NOT NULL,
  path       text,
  ref        text,
  session_id text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS analytics_events_event_time_idx ON public.analytics_events (event, created_at DESC);
CREATE INDEX IF NOT EXISTS analytics_events_time_idx ON public.analytics_events (created_at DESC);
ALTER TABLE public.analytics_events ENABLE ROW LEVEL SECURITY;
-- No RLS policies → no direct table access; the two RPCs below are the only gateway.

-- Public event logger (safe to call from the marketing site with the anon key).
CREATE OR REPLACE FUNCTION public.log_event(p_event text, p_path text DEFAULT NULL, p_ref text DEFAULT NULL, p_session text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
begin
  if p_event is null or length(p_event) > 40 then return; end if;
  insert into analytics_events(event, path, ref, session_id)
  values (p_event, left(coalesce(p_path, ''), 300), left(coalesce(p_ref, ''), 300), left(coalesce(p_session, ''), 64));
end $$;
GRANT EXECUTE ON FUNCTION public.log_event(text, text, text, text) TO anon, authenticated;

-- Founder growth dashboard aggregates (platform admin only).
CREATE OR REPLACE FUNCTION public.founder_analytics(p_days int DEFAULT 30)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
declare
  v_from timestamptz := now() - (greatest(coalesce(p_days, 30), 1)::text || ' days')::interval;
  result jsonb;
begin
  if not coalesce(public.is_platform_admin(), false) then
    return jsonb_build_object('error', 'not authorized');
  end if;
  result := jsonb_build_object(
    'range_days', p_days,
    'events', (select coalesce(jsonb_object_agg(event, cnt), '{}'::jsonb)
                 from (select event, count(*) cnt from analytics_events where created_at >= v_from group by event) e),
    'unique_visitors', (select count(distinct session_id) from analytics_events where event = 'page_view' and created_at >= v_from and session_id <> ''),
    'companies_total', (select count(*) from plants),
    'companies_hr', (select count(*) from plants where app_mode = 'hr'),
    'companies_range', (select count(*) from plants where created_at >= v_from),
    'trialing', (select count(*) from plants where subscription_status = 'trialing'),
    'paying', (select count(*) from plants where subscription_status = 'active'),
    'daily', (select coalesce(jsonb_agg(row_to_json(d) order by d.dt desc), '[]'::jsonb) from (
        select to_char(date_trunc('day', created_at), 'YYYY-MM-DD') as dt,
               count(*) filter (where event = 'page_view')   as visits,
               count(*) filter (where event = 'apk_download') as downloads,
               count(*) filter (where event = 'trial_click')  as trials
        from analytics_events where created_at >= v_from group by 1) d),
    'signups_by_day', (select coalesce(jsonb_object_agg(dt, cnt), '{}'::jsonb) from (
        select to_char(date_trunc('day', created_at), 'YYYY-MM-DD') as dt, count(*) as cnt
        from plants where created_at >= v_from group by 1) s)
  );
  return result;
end $$;
GRANT EXECUTE ON FUNCTION public.founder_analytics(int) TO authenticated;
