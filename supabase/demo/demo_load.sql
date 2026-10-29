-- =============================================================================
-- DEMO DATA — for development and staging ONLY. Never load into production.
--
--   load:    psql -f supabase/demo/demo_load.sql
--   remove:  psql -f supabase/demo/demo_remove.sql
--
-- Everything here is clearly labelled: names start with "[DEMO]", emails end in
-- @demo.invalid (a domain that can never receive mail), and rows carry is_demo = true
-- where the table has that flag. Holiday dates are EXAMPLES, not the gazetted list.
-- Salaries are invented.
-- =============================================================================

do $$
declare
  has_aud  boolean := exists (select 1 from information_schema.columns where table_schema = 'auth' and table_name = 'users' and column_name = 'aud');
  has_pw   boolean := exists (select 1 from information_schema.columns where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password');
  ids uuid[] := array[]::uuid[];
  i int;
  names text[] := array[
    'Aarati Sharma','Bikash Thapa','Chandra Gurung','Deepa Rai','Era Shrestha','Gopal Karki','Hari Adhikari',
    'Ishwor Tamang','Januka Magar','Kiran Basnet','Laxmi Poudel','Manish Khadka','Nisha Bhandari','Om Lama',
    'Pramila KC','Rajesh Maharjan','Sabina Ghimire','Tek Bahadur Bista','Usha Pandey','Bijay Shahi','Yamuna Rana',
    'Anil Dahal','Sita Koirala','Ramesh Joshi','Kamala Neupane'];
  genders text[] := array['female','male','male','female','female','male','male','male','female','male','female','male',
                          'female','male','female','male','female','male','female','male','female','male','female','male','female'];
  admin_id uuid := '00000000-0000-4000-8000-00000000d001';
  hr_id    uuid := '00000000-0000-4000-8000-00000000d002';
  team_dev uuid; team_ops uuid; proj1 uuid; proj2 uuid; uid uuid; mgr1 uuid; mgr2 uuid;
begin
  if exists (select 1 from public.profiles where is_demo) then
    raise notice 'Demo data already loaded — run demo_remove.sql first to reload.';
    return;
  end if;

  -- auth users (works on plain Postgres test shim and on Supabase)
  -- Employees: …-0000000e0001 … 0000000e0025; admin …d001; HR …d002.
  for i in 1..27 loop ids := ids || ('00000000-0000-4000-8000-0000000e' || lpad(i::text, 4, '0'))::uuid; end loop;
  ids[26] := admin_id; ids[27] := hr_id;
  for i in 1..27 loop
    execute format('insert into auth.users (id, email%s%s) values ($1, $2%s%s)',
                   case when has_aud then ', aud, role' else '' end,
                   case when has_pw  then ', encrypted_password, email_confirmed_at' else '' end,
                   case when has_aud then ', ''authenticated'', ''authenticated''' else '' end,
                   case when has_pw  then ', crypt(''demo-password-CHANGE-ME'', gen_salt(''bf'')), now()' else '' end)
      using ids[i], case when i = 26 then 'demo.admin@demo.invalid'
                         when i = 27 then 'demo.hr@demo.invalid'
                         else 'demo.employee' || lpad(i::text, 2, '0') || '@demo.invalid' end;
  end loop;

  insert into public.teams (name, is_demo) values ('[DEMO] BIM & Engineering', true) returning id into team_dev;
  insert into public.teams (name, is_demo) values ('[DEMO] Operations', true) returning id into team_ops;

  insert into public.profiles (id, email, full_name, role, job_title, join_date, is_demo) values
    (admin_id, 'demo.admin@demo.invalid', '[DEMO] Admin', 'admin', 'Director', date '2020-01-15', true),
    (hr_id,    'demo.hr@demo.invalid',    '[DEMO] HR & Accounts', 'hr', 'HR and Accounts Officer', date '2021-03-01', true);

  mgr1 := ids[1]; mgr2 := ids[2];
  for i in 1..25 loop
    uid := ids[i];
    insert into public.profiles (id, email, full_name, role, manager_id, team_id, job_title, employment_type,
                                 join_date, probation_end, is_demo)
    values (uid, 'demo.employee' || lpad(i::text, 2, '0') || '@demo.invalid', '[DEMO] ' || names[i],
            case when i <= 2 then 'manager'::public.user_role else 'employee'::public.user_role end,
            case when i <= 2 then admin_id when i % 2 = 0 then mgr2 else mgr1 end,
            case when i % 2 = 0 then team_ops else team_dev end,
            case when i <= 2 then 'Team Lead' when i % 3 = 0 then 'BIM Modeller' when i % 3 = 1 then 'Design Engineer' else 'Data Analyst' end,
            case when i = 25 then 'probation'::public.employment_type else 'regular'::public.employment_type end,
            date '2022-07-17' + (i * 37),
            case when i = 25 then date '2027-01-14' end,
            true);
    insert into public.employee_profiles (user_id, gender) values (uid, genders[i]::public.gender_code);
  end loop;
  insert into public.employee_profiles (user_id, gender) values (admin_id, 'male'), (hr_id, 'female');

  -- projects and tasks
  insert into public.projects (name, client, is_demo, created_by) values ('[DEMO] Belimo product data package', 'Demo client A', true, admin_id) returning id into proj1;
  insert into public.projects (name, client, is_demo, created_by) values ('[DEMO] Revit family library', 'Demo client B', true, admin_id) returning id into proj2;
  insert into public.tasks (project_id, title, assignee_id, status, estimate_minutes, deadline, created_by)
  select case when g % 2 = 0 then proj1 else proj2 end,
         '[DEMO] Task ' || g, ids[3 + (g % 23)],
         (array['todo','in_progress','done']::public.task_status[])[1 + g % 3],
         60 * (2 + g % 10), date '2026-11-15' + g, admin_id
    from generate_series(1, 30) g;

  -- invented salaries (NPR → paisa)
  insert into public.allowance_types (code, name_en, part_of_basic, taxable, fixed_monthly) values
    ('demo_transport', '[DEMO] Transport allowance', false, true, true),
    ('demo_communication', '[DEMO] Communication allowance', false, true, true)
  on conflict (code) do nothing;
  for i in 1..27 loop
    insert into public.salary_records (user_id, effective_from_ad, basic_paisa, ssf_enrolled, reason, created_by)
    values (ids[i], date '2026-07-17', (30000 + (i * 1750)) * 100, i <> 24, '[DEMO] Opening salary', hr_id);
  end loop;
  insert into public.salary_allowances (salary_record_id, allowance_type_id, amount_paisa)
  select s.id, a.id, case a.code when 'demo_transport' then 300000 else 150000 end
    from public.salary_records s cross join public.allowance_types a
   where a.code like 'demo_%' and s.user_id = any (ids);

  -- EXAMPLE holidays (not the gazetted list)
  insert into public.holiday_calendar (holiday_ad, name_en, scope, is_demo) values
    (date '2026-10-21', '[DEMO] Example festival holiday 1', 'all', true),
    (date '2026-10-22', '[DEMO] Example festival holiday 2', 'all', true),
    (date '2026-11-09', '[DEMO] Example festival holiday 3', 'all', true),
    (date '2026-09-14', '[DEMO] Example women-only holiday', 'female', true),
    (date '2027-04-14', '[DEMO] Example New Year holiday', 'all', true);

  insert into public.assets (tag, model, serial, assigned_to, issued_on, is_demo)
  select '[DEMO]-LT-' || lpad(n::text, 3, '0'), 'Demo laptop', 'DEMO' || n, ids[n], date '2026-07-17', true
    from generate_series(1, 25) n;

  insert into public.announcements (title, body, published_at, created_by, is_demo) values
    ('[DEMO] Welcome to TeamPulse', 'This is demo content. Remove it with supabase/demo/demo_remove.sql.', now(), hr_id, true);

  raise notice 'Demo data loaded: 25 employees (2 managers), 1 admin, 1 HR.';
end $$;
