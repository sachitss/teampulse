-- Test helpers (schema tst). Loaded by tests/run.sh after migrations and seeds.
-- Each test file runs in a transaction that is rolled back, so tests never affect each other.
create schema if not exists tst;
grant usage on schema tst to authenticated, anon;

-- Create a user with a profile. Runs as the superuser (no RLS).
create or replace function tst.mk_user(p_email text, p_role public.user_role default 'employee',
                                       p_manager uuid default null, p_gender public.gender_code default null)
returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid();
begin
  insert into auth.users (id, email) values (u, p_email);
  insert into public.profiles (id, email, full_name, role, manager_id, join_date)
  values (u, p_email, initcap(split_part(p_email, '@', 1)), p_role, p_manager, date '2025-01-01');
  insert into public.employee_profiles (user_id, gender) values (u, p_gender);
  return u;
end $$;

-- Set the JWT claims Supabase would set for this user. Follow with: set local role authenticated;
create or replace function tst.claims(p_user uuid, p_mfa boolean default true) returns void
language sql as $$
  select set_config('request.jwt.claims',
                    json_build_object('sub', p_user, 'role', 'authenticated', 'aal', case when p_mfa then 'aal2' else 'aal1' end)::text,
                    true)
$$;

create or replace function tst.ok(cond boolean, msg text) returns void
language plpgsql as $$
begin
  if cond is distinct from true then raise exception 'ASSERTION FAILED: %', msg; end if;
end $$;

-- Run a statement as the current role; assert it fails (optionally with a message fragment).
create or replace function tst.fails(stmt text, fragment text default null) returns void
language plpgsql as $$
declare err text;
begin
  begin
    execute stmt;
  exception when others then
    err := sqlerrm;
    if fragment is not null and position(lower(fragment) in lower(err)) = 0 then
      raise exception 'ASSERTION FAILED: expected error containing "%" but got "%" for: %', fragment, err, stmt;
    end if;
    return;
  end;
  raise exception 'ASSERTION FAILED: expected an error but statement succeeded: %', stmt;
end $$;

-- Count rows a query returns as the current role.
create or replace function tst.n(query text) returns bigint
language plpgsql as $$
declare c bigint;
begin
  execute format('select count(*) from (%s) q', query) into c;
  return c;
end $$;

grant execute on all functions in schema tst to authenticated, anon;
