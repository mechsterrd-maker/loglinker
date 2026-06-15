-- Three seeded pending GRNs (Jindal x2, Tata Steel on test plant e28989f4)
-- had reception headers but no grn_lines, so the verify modal opened with an
-- empty body and looked stuck. Backfill plausible lines so the workflow has
-- something to verify against.

insert into public.mcp_logistics_grn_lines
  (id, grn_id, plant_id, stock_item_id, item_name_raw, doc_qty, uom)
values
  (gen_random_uuid(), 'a47f93a8-203d-4978-beff-a897db5c6095',
   'e28989f4-4174-4bcd-9382-19a36af77092',
   'cccc1111-0000-0000-0000-000000000001',
   'MS Plate 10mm 1250x2500', 20, 'sheet'),
  (gen_random_uuid(), 'a47f93a8-203d-4978-beff-a897db5c6095',
   'e28989f4-4174-4bcd-9382-19a36af77092',
   'cccc1111-0000-0000-0000-000000000002',
   'MS Plate 12mm 1250x2500', 15, 'sheet'),
  (gen_random_uuid(), '5265a8d8-6457-4a18-8d83-8196e2275821',
   'e28989f4-4174-4bcd-9382-19a36af77092',
   'cccc1111-0000-0000-0000-000000000001',
   'TATA MS Plate 10mm', 25, 'sheet'),
  (gen_random_uuid(), '7149fbf5-937e-4ce8-907c-eacd1204a31f',
   'e28989f4-4174-4bcd-9382-19a36af77092',
   'cccc1111-0000-0000-0000-000000000002',
   'MS Plate 12mm', 10, 'sheet'),
  (gen_random_uuid(), '7149fbf5-937e-4ce8-907c-eacd1204a31f',
   'e28989f4-4174-4bcd-9382-19a36af77092',
   'cccc1111-0000-0000-0000-000000000003',
   'Welding rod E6013 2.5mm', 50, 'kg')
on conflict do nothing;
