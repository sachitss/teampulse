-- =============================================================================
-- Removes ALL demo data loaded by demo_load.sql.
-- The audit log keeps its entries about demo rows (it is append-only by design).
-- =============================================================================
begin;

-- Children that reference demo users without ON DELETE CASCADE.
delete from public.salary_allowances where salary_record_id in
  (select id from public.salary_records where user_id in (select id from public.profiles where is_demo));
delete from public.salary_records   where user_id in (select id from public.profiles where is_demo);
delete from public.tasks            where project_id in (select id from public.projects where is_demo);
delete from public.projects         where is_demo;
delete from public.assets           where is_demo;
delete from public.announcements    where is_demo;
delete from public.holiday_calendar where is_demo;
delete from public.allowance_types  where code like 'demo\_%';

-- Users (cascades to profiles and all per-user rows).
delete from auth.users where id in (select id from public.profiles where is_demo);
delete from public.teams where is_demo;

do $$
begin
  if exists (select 1 from public.profiles where is_demo)
     or exists (select 1 from auth.users where email like '%@demo.invalid') then
    raise exception 'Demo removal incomplete';
  end if;
end $$;

commit;
