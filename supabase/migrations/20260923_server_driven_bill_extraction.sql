-- Server-driven bill OCR extraction (fixes "bill not uploading for some users").
--
-- Background: the extract-document worker used to be fired only by the uploader's
-- browser/phone as a fire-and-forget fetch. If that device disconnected mid-run
-- (mobile backgrounding, navigating away, flaky network) the worker was killed and
-- the queue row stayed stuck in 'processing' forever — the batch path only ever
-- picked 'pending' rows, so it never retried. Separately, the worker rotated large
-- rotated photos in-process with a pure-JS codec, which blew the edge function's
-- CPU/memory budget and silently killed it (that fix is in the worker itself, v30).
--
-- This migration makes extraction independent of the uploader's device:
--   A) reclaim — every 2 min, rows stuck in 'processing' (dead worker) are reset to
--      'pending' to retry, or marked 'failed' after 5 attempts so a genuinely
--      un-processable image can't cycle forever.
--   B) drain — every minute, invoke the extract-document edge function to process
--      pending rows server-side. The Authorization bearer uses the public anon key
--      purely to satisfy verify_jwt at the gateway; the function itself uses the
--      service-role key internally.
--
-- Requires the pg_cron and pg_net extensions (already enabled on this project).

do $do$ begin perform cron.unschedule('reclaim-stale-bill-extractions'); exception when others then null; end $do$;
do $do$ begin perform cron.unschedule('drain-bill-extractions'); exception when others then null; end $do$;

select cron.schedule('reclaim-stale-bill-extractions', '*/2 * * * *', $cmd$
  update mcp_logistics_extraction_queue
  set status = case when attempts < 5 then 'pending' else 'failed' end,
      error_message = case when attempts >= 5
        then coalesce(error_message,'') || ' [gave up after 5 attempts — worker kept dying mid-run]'
        else error_message end,
      processed_at = case when attempts >= 5 then now() else processed_at end
  where status = 'processing' and last_attempted_at < now() - interval '3 minutes'
$cmd$);

select cron.schedule('drain-bill-extractions', '* * * * *', $cmd$
  select net.http_post(
    url := 'https://wzxowvrvuecybdxymjvi.supabase.co/functions/v1/extract-document',
    headers := jsonb_build_object(
      'Content-Type','application/json',
      'Authorization','Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Ind6eG93dnJ2dWVjeWJkeHltanZpIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzc3MjMzMTQsImV4cCI6MjA5MzI5OTMxNH0.GyvHnBtlJTWs8HqMvu0VyRhjme5jbTUWzz9vOAxXhO8'
    ),
    body := jsonb_build_object('batch_size', 5),
    timeout_milliseconds := 150000
  )
$cmd$);
