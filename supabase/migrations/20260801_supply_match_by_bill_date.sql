-- Supply -> schedule-line matching now prefers the schedule whose MONTH matches the
-- bill (dispatch) date, THEN the strongest part match, THEN nearest date.
--
-- Bug it fixes: the old function ran the match tiers sequentially and returned on the
-- first (customer-part-number) hit. When an older month's line carried the part number
-- but the current month's line did not (blank CPN from image extraction), a bill dated
-- in the current month attached to the OLD month's line — so it never showed in the
-- current month's plan-vs-supply. Rule per the user: the bill date decides the month.
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

  WITH cand AS (
    SELECT l.id,
      (sc.schedule_month = date_trunc('month', p_dispatch_date)::date) AS same_month,
      abs(coalesce(l.required_by_date, l.week_start_date) - p_dispatch_date) AS date_dist,
      CASE
        WHEN v_cpn <> '' AND lower(coalesce(l.customer_part_number,'')) = v_cpn THEN 1
        WHEN coalesce(l.customer_part_number,'') <> '' AND length(l.customer_part_number) >= 4
             AND position(lower(l.customer_part_number) IN v_item_lower) > 0 THEN 2
        WHEN length(coalesce(l.customer_part_number,'')) >= 3 AND (
              (right(l.customer_part_number,3) ~ '^[0-9]{3}$'
               AND position(' '||right(l.customer_part_number,3)||' ' IN ' '||v_item_norm||' ') > 0)
           OR (length(l.customer_part_number) >= 4 AND right(l.customer_part_number,4) ~ '^[0-9]{4}$'
               AND position(' '||right(l.customer_part_number,4)||' ' IN ' '||v_item_norm||' ') > 0)
        ) THEN 3
        WHEN length(v_item_alpha) >= 4 AND coalesce(l.part_name_raw,'') <> ''
             AND length(btrim(regexp_replace(lower(l.part_name_raw),'[^a-z]+',' ','g'))) >= 4
             AND ( position(btrim(regexp_replace(lower(l.part_name_raw),'[^a-z]+',' ','g')) IN v_item_alpha) > 0
                OR position(v_item_alpha IN btrim(regexp_replace(lower(l.part_name_raw),'[^a-z]+',' ','g'))) > 0 ) THEN 4
        ELSE NULL
      END AS tier
    FROM mcp_sched_lines l
    JOIN mcp_sched_schedules sc ON sc.id = l.schedule_id
    LEFT JOIN (SELECT schedule_line_id, SUM(supplied_qty) sup FROM mcp_sched_supplies GROUP BY schedule_line_id) s
      ON s.schedule_line_id = l.id
    WHERE l.plant_id = p_plant_id AND sc.customer_id = p_customer_id
      AND sc.status IN ('active','open')
      AND COALESCE(s.sup, 0) < l.planned_qty
  )
  SELECT id INTO v_line_id
  FROM cand
  WHERE tier IS NOT NULL
  ORDER BY same_month DESC, tier ASC, date_dist ASC
  LIMIT 1;

  RETURN v_line_id;
END $function$;
