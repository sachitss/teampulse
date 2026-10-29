-- =============================================================================
-- 0009 Company holiday policy on top of the government holiday list
--
-- The government gazettes public holidays each year. As a private company, PEACE
-- decides its own provision:
--   * government_holidays  — the gazetted list, kept as a reference only
--   * for each one, a decision: observe it, skip it, or observe it on another date
--   * company-only holidays (e.g. company anniversary)
--   * optional ("floating") holidays: each employee picks up to N from a list
--   * holiday_policies     — one per fiscal year; an ADMIN approves it
-- Only holidays in an APPROVED policy count as days off (app.is_holiday_for).
-- Approval is refused if the policy falls below the legal minimum of paid public
-- holidays (seeded 13, plus 1 more for women — accountant to confirm).
-- =============================================================================

create type public.holiday_source   as enum ('government', 'company');
create type public.holiday_decision as enum ('pending', 'observe', 'skip', 'move');
create type public.policy_status    as enum ('draft', 'approved');

-- -----------------------------------------------------------------------------
-- Government (gazetted) list — reference only; does not by itself give a day off.
-- -----------------------------------------------------------------------------
create table public.government_holidays (
  id             uuid primary key default gen_random_uuid(),
  holiday_ad     date not null,
  holiday_bs     text,
  fiscal_year    text,
  name_en        text not null,
  name_ne        text,
  scope          public.holiday_scope not null default 'all',
  group_name     text,
  gazette_ref    text,                               -- notice / source the date came from
  decision       public.holiday_decision not null default 'pending',
  moved_to_ad    date,                               -- when decision = 'move'
  decision_note  text,
  decided_by     uuid references public.profiles (id),
  decided_at     timestamptz,
  is_demo        boolean not null default false,
  created_at     timestamptz not null default now(),
  check ((scope = 'group') = (group_name is not null)),
  check ((decision = 'move') = (moved_to_ad is not null)),
  unique nulls not distinct (holiday_ad, name_en, group_name)
);
create index on public.government_holidays (fiscal_year);
create trigger government_holidays_fill before insert or update of holiday_ad on public.government_holidays
  for each row execute function app.fill_holiday();

-- -----------------------------------------------------------------------------
-- The company calendar (holiday_calendar) gains its provenance and optional flag.
-- -----------------------------------------------------------------------------
alter table public.holiday_calendar
  add column source                 public.holiday_source not null default 'company',
  add column government_holiday_id  uuid unique references public.government_holidays (id) on delete cascade,
  add column is_optional            boolean not null default false,
  add constraint holiday_calendar_source_check check ((source = 'government') = (government_holiday_id is not null));

-- -----------------------------------------------------------------------------
-- Policy per fiscal year
-- -----------------------------------------------------------------------------
create table public.holiday_policies (
  fiscal_year            text primary key check (fiscal_year ~ '^\d{4}/\d{2}$'),
  -- legal minimums (seeded from Labour Act 2074 practice guides — accountant to confirm)
  min_paid_holidays      numeric(4,1) not null default 13 check (min_paid_holidays >= 0),
  extra_for_women        numeric(4,1) not null default 1  check (extra_for_women >= 0),
  -- optional/floating holidays each employee may choose from the optional list
  optional_quota         smallint not null default 0 check (optional_quota >= 0),
  status                 public.policy_status not null default 'draft',
  notes                  text,
  approved_by            uuid references public.profiles (id),
  approved_at            timestamptz,
  is_demo                boolean not null default false,
  created_at             timestamptz not null default now()
);

-- Paid holidays the policy gives, per group, against the minimum.
-- Weekly holidays are not counted: the law counts public holidays separately.
create or replace function app.holiday_policy_check(p_fy text)
returns table (group_label text, paid_holidays numeric, minimum numeric, meets boolean)
language sql stable security definer set search_path = public as $$
  with pol as (select * from public.holiday_policies where fiscal_year = p_fy),
       h as (select * from public.holiday_calendar where fiscal_year = p_fy),
       base as (select count(*) filter (where scope = 'all' and not is_optional) as all_fixed,
                       count(*) filter (where scope = 'female' and not is_optional) as women_fixed,
                       count(*) filter (where is_optional) as optional_offered
                  from h)
  select 'All staff', base.all_fixed + least(pol.optional_quota, base.optional_offered), pol.min_paid_holidays,
         base.all_fixed + least(pol.optional_quota, base.optional_offered) >= pol.min_paid_holidays
    from base, pol
  union all
  select 'Women', base.all_fixed + base.women_fixed + least(pol.optional_quota, base.optional_offered),
         pol.min_paid_holidays + pol.extra_for_women,
         base.all_fixed + base.women_fixed + least(pol.optional_quota, base.optional_offered) >= pol.min_paid_holidays + pol.extra_for_women
    from base, pol
$$;

create or replace function app.holiday_policy_approved(p_fy text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.holiday_policies where fiscal_year = p_fy and status = 'approved')
$$;

create or replace function app.guard_holiday_policy() returns trigger
language plpgsql security definer set search_path = public as $$
declare bad text;
begin
  if new.status = 'approved' and (tg_op = 'INSERT' or old.status <> 'approved') then
    if auth.uid() is not null and not app.is_admin() then
      raise exception 'Only an admin can approve the holiday policy' using errcode = '42501';
    end if;
    if exists (select 1 from public.government_holidays where fiscal_year = new.fiscal_year and decision = 'pending') then
      raise exception 'Decide every government holiday for FY % (observe, skip or move) before approving', new.fiscal_year
        using errcode = '23514';
    end if;
    -- Check the minimum with this row's NEW values (same counting as app.holiday_policy_check).
    select string_agg(format('%s: %s of %s', g, p, m), '; ') into bad from (
      select 'All staff' g, (count(*) filter (where scope = 'all' and not is_optional)
                             + least(new.optional_quota, count(*) filter (where is_optional))) p, new.min_paid_holidays m
        from public.holiday_calendar where fiscal_year = new.fiscal_year
      union all
      select 'Women', (count(*) filter (where scope in ('all', 'female') and not is_optional)
                       + least(new.optional_quota, count(*) filter (where is_optional))), new.min_paid_holidays + new.extra_for_women
        from public.holiday_calendar where fiscal_year = new.fiscal_year) y
     where p < m;
    if bad is not null then
      raise exception 'Holiday policy for FY % is below the legal minimum (%). Add holidays or raise the optional quota.', new.fiscal_year, bad
        using errcode = '23514';
    end if;
    new.approved_by := auth.uid(); new.approved_at := now();
  end if;
  if tg_op = 'UPDATE' and old.status = 'approved' and new.status = 'draft'
     and auth.uid() is not null and not app.is_admin() then
    raise exception 'Only an admin can reopen an approved holiday policy' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger holiday_policies_guard before insert or update on public.holiday_policies
  for each row execute function app.guard_holiday_policy();
create trigger holiday_policies_audit after insert or update or delete on public.holiday_policies
  for each row execute function app.audit_row();

-- Once a year's policy is approved, its calendar is frozen (reopen the policy to change it).
create or replace function app.guard_approved_calendar() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (tg_op <> 'INSERT' and app.holiday_policy_approved(old.fiscal_year))
     or (tg_op <> 'DELETE' and app.holiday_policy_approved(app.fiscal_year_of(new.holiday_ad))) then
    raise exception 'The holiday policy for this fiscal year is approved; an admin must reopen it first' using errcode = '42501';
  end if;
  return coalesce(new, old);
end $$;
create trigger holiday_calendar_frozen before insert or update or delete on public.holiday_calendar
  for each row execute function app.guard_approved_calendar();

-- -----------------------------------------------------------------------------
-- Turning a decision on a government holiday into the company calendar.
-- -----------------------------------------------------------------------------
create or replace function app.apply_holiday_decision() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' and new.decision is not distinct from old.decision
     and new.moved_to_ad is not distinct from old.moved_to_ad then
    return null;
  end if;
  delete from public.holiday_calendar where government_holiday_id = new.id;
  if new.decision in ('observe', 'move') then
    insert into public.holiday_calendar (holiday_ad, name_en, name_ne, scope, group_name, source, government_holiday_id, is_demo)
    values (case when new.decision = 'move' then new.moved_to_ad else new.holiday_ad end,
            new.name_en || case when new.decision = 'move' then ' (observed)' else '' end,
            new.name_ne, new.scope, new.group_name, 'government', new.id, new.is_demo);
  end if;
  return null;
end $$;
create trigger government_holidays_apply after insert or update on public.government_holidays
  for each row execute function app.apply_holiday_decision();

create or replace function app.stamp_holiday_decision() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' or new.decision is distinct from old.decision or new.moved_to_ad is distinct from old.moved_to_ad then
    new.decided_by := auth.uid(); new.decided_at := case when new.decision = 'pending' then null else now() end;
  end if;
  return new;
end $$;
create trigger government_holidays_stamp before insert or update on public.government_holidays
  for each row execute function app.stamp_holiday_decision();
create trigger government_holidays_audit after insert or update or delete on public.government_holidays
  for each row execute function app.audit_row();

-- -----------------------------------------------------------------------------
-- Optional (floating) holidays chosen by each employee, up to the policy quota.
-- -----------------------------------------------------------------------------
create table public.employee_optional_holidays (
  user_id      uuid not null references public.profiles (id) on delete cascade,
  holiday_id   uuid not null references public.holiday_calendar (id) on delete cascade,
  fiscal_year  text,
  chosen_at    timestamptz not null default now(),
  primary key (user_id, holiday_id)
);

create or replace function app.guard_optional_choice() returns trigger
language plpgsql security definer set search_path = public as $$
declare h record; quota int; used int;
begin
  if tg_op = 'DELETE' then
    select * into h from public.holiday_calendar where id = old.holiday_id;
    if h.holiday_ad <= app.kathmandu_date(now()) and auth.uid() is not null and not app.is_hr() then
      raise exception 'You cannot drop an optional holiday on or after its date' using errcode = '42501';
    end if;
    return old;
  end if;
  select * into h from public.holiday_calendar where id = new.holiday_id;
  if not h.is_optional then raise exception 'That holiday is not optional' using errcode = '23514'; end if;
  if h.holiday_ad < app.kathmandu_date(now()) and auth.uid() is not null and not app.is_hr() then
    raise exception 'Optional holidays must be chosen in advance' using errcode = '23514';
  end if;
  new.fiscal_year := h.fiscal_year;
  select optional_quota into quota from public.holiday_policies where fiscal_year = h.fiscal_year and status = 'approved';
  if quota is null then raise exception 'No approved holiday policy for FY %', h.fiscal_year using errcode = '23514'; end if;
  select count(*) into used from public.employee_optional_holidays where user_id = new.user_id and fiscal_year = h.fiscal_year;
  if used >= quota then
    raise exception 'You have already chosen % of % optional holidays for FY %', used, quota, h.fiscal_year using errcode = '23514';
  end if;
  return new;
end $$;
create trigger optional_holidays_guard before insert or delete on public.employee_optional_holidays
  for each row execute function app.guard_optional_choice();

-- -----------------------------------------------------------------------------
-- Day-off test now follows the approved company policy.
-- -----------------------------------------------------------------------------
create or replace function app.is_holiday_for(p_user uuid, p_date date) returns boolean
language sql stable security definer set search_path = public as $$
  select extract(isodow from p_date)::smallint = any (coalesce((select weekly_holidays from public.org_settings), '{}'::smallint[]))
      or exists (
        select 1 from public.holiday_calendar h
         where h.holiday_ad = p_date
           and app.holiday_policy_approved(h.fiscal_year)
           and (not h.is_optional
                or exists (select 1 from public.employee_optional_holidays o where o.user_id = p_user and o.holiday_id = h.id))
           and (h.scope = 'all'
                or (h.scope = 'female' and exists (select 1 from public.employee_profiles e
                                                    where e.user_id = p_user and e.gender = 'female'))
                or (h.scope = 'group' and exists (select 1 from public.holiday_groups g
                                                   where g.user_id = p_user and g.group_name = h.group_name)))
      )
$$;

-- -----------------------------------------------------------------------------
-- Access
-- -----------------------------------------------------------------------------
alter table public.government_holidays        enable row level security;
alter table public.holiday_policies           enable row level security;
alter table public.employee_optional_holidays enable row level security;

create policy gov_holidays_read  on public.government_holidays for select to authenticated using (true);
create policy gov_holidays_write on public.government_holidays for all to authenticated using (app.is_hr()) with check (app.is_hr());
create policy hol_policies_read  on public.holiday_policies for select to authenticated using (true);
create policy hol_policies_write on public.holiday_policies for all to authenticated using (app.is_hr()) with check (app.is_hr());
create policy optional_read   on public.employee_optional_holidays for select to authenticated using (app.can_see_work(user_id));
create policy optional_choose on public.employee_optional_holidays for insert to authenticated with check (user_id = auth.uid() or app.is_hr());
create policy optional_drop   on public.employee_optional_holidays for delete to authenticated using (user_id = auth.uid() or app.is_hr());

revoke execute on all functions in schema app from public, anon;
grant execute on all functions in schema app to authenticated, service_role;
