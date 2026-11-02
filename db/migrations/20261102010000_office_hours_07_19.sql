-- =============================================================================
-- Monitoring recording window set to 07:00-19:00, Sunday-Friday (PEACE, 2026-11-02).
--   * Only the daily start/end change. Days are unchanged -- Saturday stays the
--     weekly day off -- and WHAT is captured is unchanged (application name and
--     website domain only).
--   * Recording still happens only inside this window (or a manual session) and
--     still requires the published notice plus each employee's consent.
--   * policies is append-only: add a new version that carries forward the latest
--     settings with just the window changed. On a fresh install no policy exists
--     when migrations run (the seed creates it, already at 07:00-19:00), so this
--     no-ops there and only updates an existing deployment.
-- =============================================================================

insert into public.policies (settings, note)
select jsonb_set(
         jsonb_set(latest.settings, '{monitoring,work_schedule,windows,0,start}', '"07:00"'::jsonb, true),
         '{monitoring,work_schedule,windows,0,end}', '"19:00"'::jsonb, true),
       'Office hours (recording window) set to 07:00-19:00, Sunday-Friday'
from (select settings from public.policies order by version desc limit 1) latest
where (latest.settings #>> '{monitoring,work_schedule,windows,0,start}') is distinct from '07:00'
   or (latest.settings #>> '{monitoring,work_schedule,windows,0,end}')   is distinct from '19:00';
