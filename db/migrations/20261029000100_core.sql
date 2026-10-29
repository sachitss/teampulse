-- =============================================================================
-- TeamPulse Lite + HR — 0001 core
-- Single organization (PEACE Consultancy). Supabase Postgres.
--
-- Conventions
--   * UUID keys, timestamptz in UTC. Day boundaries use Asia/Kathmandu.
--   * Money is bigint paisa (1 NPR = 100 paisa). Never floating point.
--   * BS (Bikram Sambat) dates are stored as text 'YYYY-MM-DD' next to the AD
--     date and are filled by trigger from bs_calendar_months, so they can never
--     disagree with the AD date.
--   * Helper functions live in schema `app` (not exposed by the Supabase API).
-- =============================================================================

create extension if not exists pgcrypto;
create extension if not exists btree_gist;

create schema if not exists app;
grant usage on schema app to authenticated, anon, service_role;

-- -----------------------------------------------------------------------------
-- Enums
-- -----------------------------------------------------------------------------
create type public.user_role       as enum ('employee', 'manager', 'hr', 'admin');
create type public.employment_type as enum ('regular', 'probation', 'contract');
create type public.gender_code     as enum ('female', 'male', 'other');
create type public.rule_status     as enum ('to_confirm', 'confirmed');
create type public.bs_year_status  as enum ('verified', 'provisional');

-- -----------------------------------------------------------------------------
-- Organization settings (single row)
-- -----------------------------------------------------------------------------
create table public.org_settings (
  id                         boolean primary key default true check (id),
  org_name                   text not null default 'PEACE Consultancy',
  time_zone                  text not null default 'Asia/Kathmandu',
  -- ISO day of week: 1 = Monday … 7 = Sunday. Default: Saturday off.
  weekly_holidays            smallint[] not null default '{6}',
  report_recipients          text[] not null default '{peace.consultancy@gmail.com}',
  screenshot_retention_days  int not null default 14 check (screenshot_retention_days between 1 and 365),
  activity_retention_days    int not null default 365 check (activity_retention_days between 30 and 3650),
  hr_retention_years         int not null default 7 check (hr_retention_years between 1 and 30),
  -- Monitoring stays OFF until an admin confirms the monitoring notice was issued.
  monitoring_notice_confirmed_at timestamptz,
  monitoring_notice_confirmed_by uuid,
  -- Payroll "parallel run" badge until the accountant switches it off.
  payroll_parallel_run       boolean not null default true,
  updated_at                 timestamptz not null default now()
);
insert into public.org_settings default values;

-- -----------------------------------------------------------------------------
-- Bikram Sambat calendar (runtime source of truth, seeded from packages/bs-calendar)
-- -----------------------------------------------------------------------------
create table public.bs_calendar_months (
  bs_year   smallint not null check (bs_year between 2000 and 2200),
  bs_month  smallint not null check (bs_month between 1 and 12),
  days      smallint not null check (days between 29 and 32),
  ad_start  date not null unique,
  status    public.bs_year_status not null,
  primary key (bs_year, bs_month)
);

-- AD date → BS 'YYYY-MM-DD'. Raises if the date is outside the table.
create or replace function app.ad_to_bs(d date) returns text
language plpgsql stable set search_path = public as $$
declare r record;
begin
  select bs_year, bs_month, ad_start into r
    from public.bs_calendar_months
   where ad_start <= d
   order by ad_start desc
   limit 1;
  if r is null or d >= r.ad_start + (select days from public.bs_calendar_months
                                       where bs_year = r.bs_year and bs_month = r.bs_month) then
    raise exception 'Date % is outside the BS calendar table', d using errcode = '22008';
  end if;
  return lpad(r.bs_year::text, 4, '0') || '-' || lpad(r.bs_month::text, 2, '0') || '-' ||
         lpad(((d - r.ad_start) + 1)::text, 2, '0');
end $$;

-- BS 'YYYY-MM-DD' → AD date. Raises on an invalid BS date (never rolls over).
create or replace function app.bs_to_ad(bs text) returns date
language plpgsql stable set search_path = public as $$
declare y int; m int; dd int; r record;
begin
  if bs !~ '^\d{4}-\d{1,2}-\d{1,2}$' then
    raise exception 'BS date must be YYYY-MM-DD, got %', bs using errcode = '22007';
  end if;
  y := split_part(bs, '-', 1)::int; m := split_part(bs, '-', 2)::int; dd := split_part(bs, '-', 3)::int;
  select * into r from public.bs_calendar_months where bs_year = y and bs_month = m;
  if r is null or dd < 1 or dd > r.days then
    raise exception 'Invalid BS date %', bs using errcode = '22008';
  end if;
  return r.ad_start + (dd - 1);
end $$;

-- Fiscal year label ('2083/84') for an AD date. FY starts 1 Shrawan (month 4).
create or replace function app.fiscal_year_of(d date) returns text
language sql stable set search_path = public as $$
  with b as (select split_part(app.ad_to_bs(d), '-', 1)::int as y,
                    split_part(app.ad_to_bs(d), '-', 2)::int as m)
  select case when m >= 4 then y else y - 1 end || '/' ||
         lpad((((case when m >= 4 then y else y - 1 end) + 1) % 100)::text, 2, '0')
    from b
$$;

-- Is the BS year of this AD date only provisional (official calendar not yet published)?
create or replace function app.is_provisional_date(d date) returns boolean
language sql stable set search_path = public as $$
  select status = 'provisional' from public.bs_calendar_months
   where bs_year = split_part(app.ad_to_bs(d), '-', 1)::int limit 1
$$;

-- Start of a Kathmandu calendar day as a UTC instant (e.g. 2026-10-29 → 2026-10-28 18:15Z).
create or replace function app.kathmandu_day_start(d date) returns timestamptz
language sql immutable as $$
  select (d::timestamp at time zone 'Asia/Kathmandu')
$$;

-- The Kathmandu calendar date of an instant.
create or replace function app.kathmandu_date(t timestamptz) returns date
language sql immutable as $$
  select (t at time zone 'Asia/Kathmandu')::date
$$;

-- Generic trigger: fill a *_bs text column from its AD date column.
-- Usage: create trigger … before insert or update … execute function app.fill_bs('start_ad','start_bs','end_ad','end_bs')
create or replace function app.fill_bs() returns trigger
language plpgsql set search_path = public as $$
declare i int := 0; ad_col text; bs_col text; ad_val date; j jsonb;
begin
  j := to_jsonb(new);
  while i < tg_nargs loop
    ad_col := tg_argv[i]; bs_col := tg_argv[i + 1];
    ad_val := (j ->> ad_col)::date;
    j := jsonb_set(j, array[bs_col], case when ad_val is null then 'null'::jsonb
                                          else to_jsonb(app.ad_to_bs(ad_val)) end);
    i := i + 2;
  end loop;
  new := jsonb_populate_record(new, j);
  return new;
end $$;

-- -----------------------------------------------------------------------------
-- People
-- -----------------------------------------------------------------------------
create table public.teams (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique,
  is_demo     boolean not null default false,
  created_at  timestamptz not null default now()
);

-- Work profile: visible to the person, their manager, HR and admin.
create table public.profiles (
  id               uuid primary key references auth.users (id) on delete cascade,
  email            text not null unique,
  full_name        text not null,
  role             public.user_role not null default 'employee',
  manager_id       uuid references public.profiles (id) on delete set null,
  team_id          uuid references public.teams (id) on delete set null,
  job_title        text,
  employment_type  public.employment_type not null default 'regular',
  join_date        date,
  probation_end    date,
  exit_date        date,
  time_zone        text not null default 'Asia/Kathmandu',
  -- Scheduled hours, e.g. {"days":[1,2,3,4,5,7],"start":"10:00","end":"17:00"}
  working_hours    jsonb not null default '{"days":[1,2,3,4,5,7],"start":"10:00","end":"17:00"}',
  active           boolean not null default true,
  is_demo          boolean not null default false,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check (manager_id is distinct from id),
  check (exit_date is null or join_date is null or exit_date >= join_date)
);
create index on public.profiles (manager_id);
create index on public.profiles (team_id);

-- Personal HR record: visible only to the person, HR and admin.
create table public.employee_profiles (
  user_id                  uuid primary key references public.profiles (id) on delete cascade,
  gender                   public.gender_code,   -- needed for women-only holidays and maternity/paternity leave
  date_of_birth            date,
  phone                    text,
  address                  text,
  emergency_contact_name   text,
  emergency_contact_phone  text,
  updated_at               timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- Role helpers used by Row Level Security.
-- SECURITY DEFINER so they can read profiles without recursive RLS.
-- Admin and HR rights require MFA (Supabase JWT claim aal = 'aal2'):
-- an admin who signs in without MFA only gets employee rights.
-- -----------------------------------------------------------------------------
create or replace function app.uid() returns uuid
language sql stable as $$ select auth.uid() $$;

create or replace function app.has_mfa() returns boolean
language sql stable as $$ select coalesce(auth.jwt() ->> 'aal', '') = 'aal2' $$;

create or replace function app.my_role() returns public.user_role
language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid() and active
$$;

create or replace function app.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(app.my_role() = 'admin' and app.has_mfa(), false)
$$;

-- HR rights: HR or admin, with MFA.
create or replace function app.is_hr() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(app.my_role() in ('hr', 'admin') and app.has_mfa(), false)
$$;

-- Is the caller (a manager or admin) the direct manager of `target`?
create or replace function app.is_manager_of(target uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(app.my_role() in ('manager', 'admin') and exists (
    select 1 from public.profiles p where p.id = target and p.manager_id = auth.uid()
  ), false)
$$;

-- Work data (time, tasks, timesheets, leave): self, their manager, HR, admin.
create or replace function app.can_see_work(target uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select target = auth.uid() or app.is_hr() or app.is_manager_of(target)
$$;

-- Activity evidence (screenshots, apps, websites, input counts): self, their manager, admin.
-- HR is deliberately excluded.
create or replace function app.can_see_activity(target uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select target = auth.uid() or app.is_admin() or app.is_manager_of(target)
$$;

-- Pay data: self (published only — enforced per table), HR, admin. Never managers.
create or replace function app.can_see_pay(target uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select target = auth.uid() or app.is_hr()
$$;

-- Personal HR data and documents: self, HR, admin.
create or replace function app.can_see_personal(target uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select target = auth.uid() or app.is_hr()
$$;

grant execute on all functions in schema app to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Audit log (append-only; nobody can update or delete, not even admin)
-- -----------------------------------------------------------------------------
create table public.audit_log (
  id           bigint generated always as identity primary key,
  at           timestamptz not null default now(),
  actor_id     uuid,                      -- null for system jobs
  actor_kind   text not null default 'user' check (actor_kind in ('user', 'agent', 'system')),
  action       text not null,             -- e.g. 'insert', 'update', 'view_screenshot'
  target_table text,
  target_id    text,
  details      jsonb not null default '{}'
);
create index on public.audit_log (at desc);
create index on public.audit_log (target_table, target_id);
create index on public.audit_log (actor_id, at desc);

create or replace function app.block_mutation() returns trigger
language plpgsql as $$
begin
  raise exception '% is append-only', tg_table_name using errcode = '42501';
end $$;

create trigger audit_log_append_only before update or delete on public.audit_log
  for each row execute function app.block_mutation();

-- Write an audit entry (callable by API code and triggers).
create or replace function app.audit(p_action text, p_table text, p_id text, p_details jsonb default '{}')
returns void language sql security definer set search_path = public as $$
  insert into public.audit_log (actor_id, actor_kind, action, target_table, target_id, details)
  values (auth.uid(),
          case when auth.uid() is null then 'system' else 'user' end,
          p_action, p_table, p_id, coalesce(p_details, '{}'))
$$;

-- Generic row-change audit trigger.
-- TG_ARGV[0] (optional) = comma-separated column names whose VALUES must not be
-- copied into the log (e.g. encrypted bank details). Changes are noted by name only.
create or replace function app.audit_row() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  redact text[] := case when tg_nargs > 0 then string_to_array(tg_argv[0], ',') else '{}' end;
  old_j jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end;
  new_j jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end;
  changed jsonb := '{}';
  k text;
  row_id text;
begin
  row_id := coalesce(new_j ->> 'id', old_j ->> 'id', new_j ->> 'user_id', old_j ->> 'user_id');
  if tg_op = 'UPDATE' then
    for k in select key from jsonb_each(new_j) loop
      if (old_j -> k) is distinct from (new_j -> k) and k not in ('updated_at') then
        changed := changed || jsonb_build_object(k,
          case when k = any (redact) then jsonb_build_object('changed', true)
               else jsonb_build_object('from', old_j -> k, 'to', new_j -> k) end);
      end if;
    end loop;
    if changed = '{}' then return new; end if;
  else
    changed := coalesce(new_j, old_j);
    foreach k in array redact loop changed := changed - k; end loop;
  end if;
  perform app.audit(lower(tg_op), tg_table_name, row_id, changed);
  return coalesce(new, old);
end $$;

-- Keep updated_at current.
create or replace function app.touch_updated_at() returns trigger
language plpgsql as $$ begin new.updated_at := now(); return new; end $$;

create trigger profiles_touch before update on public.profiles
  for each row execute function app.touch_updated_at();
create trigger employee_profiles_touch before update on public.employee_profiles
  for each row execute function app.touch_updated_at();
create trigger org_settings_touch before update on public.org_settings
  for each row execute function app.touch_updated_at();

-- Only admins may change role, manager, team, active flag or employment dates.
-- Everyone else may only edit their own name.
create or replace function app.guard_profile_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or app.is_admin() then return new; end if;   -- service role / admin
  if app.is_hr() then
    -- HR may maintain employment details but not roles or reporting lines.
    if new.role is distinct from old.role or new.manager_id is distinct from old.manager_id then
      raise exception 'Only an admin can change roles or managers' using errcode = '42501';
    end if;
    return new;
  end if;
  if new.role is distinct from old.role or new.manager_id is distinct from old.manager_id
     or new.team_id is distinct from old.team_id or new.active is distinct from old.active
     or new.employment_type is distinct from old.employment_type
     or new.join_date is distinct from old.join_date or new.probation_end is distinct from old.probation_end
     or new.exit_date is distinct from old.exit_date or new.email is distinct from old.email
     or new.working_hours is distinct from old.working_hours or new.is_demo is distinct from old.is_demo then
    raise exception 'You can only change your own display name' using errcode = '42501';
  end if;
  return new;
end $$;

create trigger profiles_guard before update on public.profiles
  for each row execute function app.guard_profile_update();

create trigger profiles_audit after insert or update or delete on public.profiles
  for each row execute function app.audit_row();
create trigger org_settings_audit after update on public.org_settings
  for each row execute function app.audit_row();
create trigger employee_profiles_audit after insert or update or delete on public.employee_profiles
  for each row execute function app.audit_row('date_of_birth,phone,address,emergency_contact_name,emergency_contact_phone');

-- -----------------------------------------------------------------------------
-- Monitoring notice and consent (Nepal Individual Privacy Act 2075)
-- -----------------------------------------------------------------------------
create table public.notice_versions (
  version       int primary key,
  title         text not null,
  body_en       text not null,
  body_ne       text,
  published_at  timestamptz,
  created_by    uuid references public.profiles (id),
  created_at    timestamptz not null default now()
);

create table public.notice_consents (
  user_id       uuid not null references public.profiles (id) on delete cascade,
  version       int not null references public.notice_versions (version),
  consented_at  timestamptz not null default now(),
  channel       text not null default 'web' check (channel in ('web', 'agent')),
  primary key (user_id, version)
);
create trigger notice_consents_append_only before update or delete on public.notice_consents
  for each row execute function app.block_mutation();

-- Is monitoring allowed for this user right now?
--   1. an admin has confirmed the notice was issued, and
--   2. the user has consented to the latest published notice version.
create or replace function app.monitoring_allowed(target uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select (select monitoring_notice_confirmed_at is not null from public.org_settings)
     and exists (
       select 1 from public.notice_consents c
        where c.user_id = target
          and c.version = (select max(version) from public.notice_versions where published_at is not null)
     )
$$;
grant execute on function app.monitoring_allowed(uuid) to authenticated, service_role;
