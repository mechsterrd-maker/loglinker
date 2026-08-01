-- Supersedes 20260801_supply_match_by_bill_date: adds a word-overlap fallback
-- (tier 5) so a bill item whose words match a schedule part in a different order
-- (e.g. "RPL_INSERT_BIG" vs "Big Insert") still matches. Requires >=2 shared
-- significant words (len>=3), so "Big Insert" is not confused with "Small Insert"
-- (they share only "insert"). Ranking: same-bill-month first, then match strength
-- (CPN exact > CPN substring > CPN digits > name-containment > word-overlap), then
-- most word overlap, then nearest required date. The bill date decides the month.
CREATE OR REPLACE FUNCTION public.find_open_line_for_item(p_plant_id uuid, p_customer_id uuid, p_item_name text, p_item_part_number text, p_dispatch_date date)
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_line_id UUID;
  v_item_lower TEXT;
  v_item_norm TEXT;
  v_item_alpha TEXT;
  v_cpn TEXT;
BEGIN
  IF p_customer_id IS NULL THEN RETURN NULL; END IF;
  v_item_lower := lower(coalesce(p_item_name, ''));
  v_item_norm  := btrim(regexp_replace(v_item_lower, '[^a-z0-9]+', ' ', 'g'));
  v_item_alpha := btrim(regexp_replace(v_item_lower, '[^a-z]+',   ' ', 'g'));
  v_cpn        := lower(coalesce(p_item_part_number, ''));
  IF v_item_norm = '' AND v_cpn = '' THEN RETURN NULL; END IF;

  WITH base AS (
    SELECT l.id, l.customer_part_number, l.part_name_raw,
      (sc.schedule_month = date_trunc('month', p_dispatch_date)::date) AS same_month,
      abs(coalesce(l.required_by_date, l.week_start_date) - p_dispatch_date) AS date_dist,
      (SELECT count(*) FROM (
         SELECT t FROM unnest(string_to_array(v_item_norm,' ')) t WHERE length(t) >= 3
         INTERSECT
         SELECT t FROM unnest(string_to_array(btrim(regexp_replace(lower(coalesce(l.part_name_raw,'')),'[^a-z0-9]+',' ','g')),' ')) t WHERE length(t) >= 3
       ) z) AS tok_overlap
    FROM mcp_sched_lines l
    JOIN mcp_sched_schedules sc ON sc.id = l.schedule_id
    LEFT JOIN (SELECT schedule_line_id, SUM(supplied_qty) sup FROM mcp_sched_supplies GROUP BY schedule_line_id) s
      ON s.schedule_line_id = l.id
    WHERE l.plant_id = p_plant_id AND sc.customer_id = p_customer_id
      AND sc.status IN ('active','open')
      AND COALESCE(s.sup, 0) < l.planned_qty
  ),
  cand AS (
    SELECT id, same_month, date_dist, tok_overlap,
      CASE
        WHEN v_cpn <> '' AND lower(coalesce(customer_part_number,'')) = v_cpn THEN 1
        WHEN coalesce(customer_part_number,'') <> '' AND length(customer_part_number) >= 4
             AND position(lower(customer_part_number) IN v_item_lower) > 0 THEN 2
        WHEN length(coalesce(customer_part_number,'')) >= 3 AND (
              (right(customer_part_number,3) ~ '^[0-9]{3}$'
               AND position(' '||right(customer_part_number,3)||' ' IN ' '||v_item_norm||' ') > 0)
           OR (length(customer_part_number) >= 4 AND right(customer_part_number,4) ~ '^[0-9]{4}$'
               AND position(' '||right(customer_part_number,4)||' ' IN ' '||v_item_norm||' ') > 0)
        ) THEN 3
        WHEN length(v_item_alpha) >= 4 AND coalesce(part_name_raw,'') <> ''
             AND length(btrim(regexp_replace(lower(part_name_raw),'[^a-z]+',' ','g'))) >= 4
             AND ( position(btrim(regexp_replace(lower(part_name_raw),'[^a-z]+',' ','g')) IN v_item_alpha) > 0
                OR position(v_item_alpha IN btrim(regexp_replace(lower(part_name_raw),'[^a-z]+',' ','g'))) > 0 ) THEN 4
        WHEN tok_overlap >= 2 THEN 5
        ELSE NULL
      END AS tier
    FROM base
  )
  SELECT id INTO v_line_id
  FROM cand
  WHERE tier IS NOT NULL
  ORDER BY same_month DESC, tier ASC, tok_overlap DESC, date_dist ASC
  LIMIT 1;

  RETURN v_line_id;
END $function$;
