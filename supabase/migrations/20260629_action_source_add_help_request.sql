-- "Ask for Help" creates a task with action_source = 'help_request', but the
-- enum lacked that value → 'invalid input value for enum action_source:
-- "help_request"'. Add it. (Applied to prod; recorded here.)
ALTER TYPE public.action_source ADD VALUE IF NOT EXISTS 'help_request';
