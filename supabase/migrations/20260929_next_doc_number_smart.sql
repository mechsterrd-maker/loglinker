-- Manual-numbering plants (e.g. MMPL) keep their own running series per unit
-- (…/RDC/26-27/595). The auto counter (peek/get_next) drifted out of sync with
-- that series, so the form suggested a stale number and fast/continuous DC
-- creation collided on idx_docs_unique ("duplicate key").
--
-- next_doc_number_smart returns the TRUE next number: max(existing numeric
-- suffix in this exact prefix series) + 1, formatted like the counter peek.
-- Falls back to the counter-based peek when the series has no docs yet.
create or replace function public.next_doc_number_smart(
  p_plant_id uuid, p_doc_kind text, p_date date default current_date, p_unit_id uuid default null
) returns text language plpgsql stable security definer set search_path to 'public' as $function$
declare v_peek text; v_last text; v_prefix text; v_max int;
begin
  -- Reuse peek to build the correctly-formatted prefix (…/RDC/26-27/) + fallback.
  v_peek := peek_next_logistics_doc_number(p_plant_id, p_doc_kind, p_date, p_unit_id);
  v_last := split_part(v_peek, '/', array_length(string_to_array(v_peek, '/'), 1));
  v_prefix := left(v_peek, length(v_peek) - length(v_last));
  -- Highest existing all-numeric suffix among docs already using this prefix.
  select max((substring(d.doc_number from char_length(v_prefix) + 1))::int)
    into v_max
  from mcp_logistics_documents d
  where d.plant_id = p_plant_id
    and d.doc_number like v_prefix || '%'
    and substring(d.doc_number from char_length(v_prefix) + 1) ~ '^[0-9]+$';
  if v_max is null then
    return v_peek;  -- no docs in this series yet → counter-based peek
  end if;
  return v_prefix || lpad((v_max + 1)::text, 3, '0');
end $function$;

grant execute on function public.next_doc_number_smart(uuid, text, date, uuid) to authenticated, anon, service_role;
