-- Every table is protected, buckets are private, anonymous users get nothing.
begin;

do $$
declare missing text;
begin
  select string_agg(c.relname, ', ') into missing
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;
  perform tst.ok(missing is null, 'tables without RLS: ' || coalesce(missing, ''));

  select string_agg(t.tablename, ', ') into missing
    from pg_tables t
   where t.schemaname = 'public'
     and not exists (select 1 from pg_policies p where p.schemaname = 'public' and p.tablename = t.tablename);
  perform tst.ok(missing is null, 'tables with RLS but no policy at all: ' || coalesce(missing, ''));

  perform tst.ok(not exists (select 1 from storage.buckets where public), 'a storage bucket is public');
  perform tst.ok((select count(*) from storage.buckets) = 4, 'expected 4 private buckets');
  perform tst.ok(not exists (select 1 from pg_policies where schemaname = 'storage'),
                 'storage must have no policies for signed-in users (server-minted signed URLs only)');
end $$;

-- Anonymous: no table access at all.
set local role anon;
select tst.fails('select * from public.profiles', 'permission denied');
select tst.fails('select * from public.org_settings', 'permission denied');
select tst.fails('select * from public.tax_slabs', 'permission denied');
reset role;

-- Signed-in user with no profile (e.g. a stray auth account) sees nothing personal.
select tst.claims(gen_random_uuid());
set local role authenticated;
select tst.ok(tst.n('select * from public.profiles') = 0, 'stranger sees profiles');
select tst.ok(tst.n('select * from public.salary_records') = 0, 'stranger sees salaries');
select tst.ok(tst.n('select * from public.screenshots') = 0, 'stranger sees screenshots');
reset role;

rollback;
