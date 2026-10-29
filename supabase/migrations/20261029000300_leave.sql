-- =============================================================================
-- 0003 Module 2 — leave and holidays
--
-- Every legal number lives in leave_rules (versioned by effective date, each row
-- flagged to_confirm until PEACE's accountant/HR confirms it). Balances are never
-- stored: they are the sum of leave_ledger, which is append-only.
-- =============================================================================

create type public.leave_accrual   as enum ('per_days_worked', 'annual_grant', 'per_event', 'earned', 'none');
create type public.leave_applies   as enum ('all', 'female', 'male');
create type public.leave_req_status as enum ('pending', 'documents_requested', 'approved', 'rejected', 'cancelled');
create type public.half_day        as enum ('none', 'first_half', 'second_half');
create type public.ledger_kind     as enum ('opening_balance', 'accrual', 'usage', 'usage_reversal',
                                            'adjustment', 'encashment', 'lapse');
create type public.holiday_scope   as enum ('all', 'female', 'group');

create table public.leave_types (
  id                    uuid primary key default gen_random_uuid(),
  code                  text not null unique check (code ~ '^[a-z_]+$'),
  name_en               text not null,
  name_ne               text,
  is_paid               boolean not null,
  -- Labour Act 2074 s.51: sick, mourning and maternity leave are rights, not facilities.
  -- A manager may ask for documents but may never reject these.
  is_statutory_right    boolean not null default false,
  tracks_balance        boolean not null default true,    -- unpaid leave does not
  sort_order            smallint not null default 100,
  active                boolean not null default true
);

create table public.leave_rules (
  id                       uuid primary key default gen_random_uuid(),
  leave_type_id            uuid not null references public.leave_types (id) on delete cascade,
  effective_from_ad        date not null,
  effective_from_bs        text,
  accrual                  public.leave_accrual not null,
  -- per_days_worked: `accrual_days` per `per_days_worked` days worked (home leave: 1 per 20)
  per_days_worked          smallint check (per_days_worked is null or per_days_worked > 0),
  accrual_days             numeric(6,2),
  -- annual_grant: days per fiscal year (sick leave: 12)
  annual_days              numeric(6,2),
  -- per_event: maximum days per occurrence (maternity 98, paternity 15, mourning 13)
  max_days_per_event       numeric(6,2),
  -- how many of those days are paid (maternity: 60 of 98)
  paid_days_per_event      numeric(6,2),
  carry_forward_cap        numeric(6,2),          -- home 90, sick 45; null = no cap / no carry
  encash_excess_at_year_end boolean not null default false,
  encash_on_exit           boolean not null default false,
  certificate_after_days   smallint,              -- sick: medical certificate above 3 consecutive days
  applies_to               public.leave_applies not null default 'all',
  pro_rata_in_probation    boolean not null default true,
  status                   public.rule_status not null default 'to_confirm',
  confirmed_by             uuid references public.profiles (id),
  confirmed_at             timestamptz,
  source_note              text,                  -- where the seed value came from
  created_at               timestamptz not null default now(),
  unique (leave_type_id, effective_from_ad),
  check (status <> 'confirmed' or (confirmed_by is not null and confirmed_at is not null)),
  check (accrual <> 'per_days_worked' or (per_days_worked is not null and accrual_days is not null)),
  check (accrual <> 'annual_grant' or annual_days is not null),
  check (accrual <> 'per_event' or max_days_per_event is not null)
);
create trigger leave_rules_bs before insert or update on public.leave_rules
  for each row execute function app.fill_bs('effective_from_ad', 'effective_from_bs');
create trigger leave_rules_audit after insert or update or delete on public.leave_rules
  for each row execute function app.audit_row();

-- The rule in force for a leave type on a date.
create or replace function app.leave_rule_on(p_type uuid, p_date date) returns public.leave_rules
language sql stable security definer set search_path = public as $$
  select * from public.leave_rules
   where leave_type_id = p_type and effective_from_ad <= p_date
   order by effective_from_ad desc limit 1
$$;

-- -----------------------------------------------------------------------------
-- Holiday calendar (gazetted yearly, lunar — HR maintains it; never hard-coded)
-- -----------------------------------------------------------------------------
create table public.holiday_calendar (
  id           uuid primary key default gen_random_uuid(),
  holiday_ad   date not null,
  holiday_bs   text,
  fiscal_year  text,
  name_en      text not null,
  name_ne      text,
  scope        public.holiday_scope not null default 'all',
  group_name   text,                          -- when scope = 'group'
  is_demo      boolean not null default false,
  created_by   uuid references public.profiles (id) on delete set null,
  created_at   timestamptz not null default now(),
  check ((scope = 'group') = (group_name is not null)),
  unique nulls not distinct (holiday_ad, name_en, group_name)
);
create index on public.holiday_calendar (holiday_ad);

create or replace function app.fill_holiday() returns trigger
language plpgsql set search_path = public as $$
begin
  new.holiday_bs  := app.ad_to_bs(new.holiday_ad);
  new.fiscal_year := app.fiscal_year_of(new.holiday_ad);
  return new;
end $$;
create trigger holiday_calendar_fill before insert or update on public.holiday_calendar
  for each row execute function app.fill_holiday();
create trigger holiday_calendar_audit after insert or update or delete on public.holiday_calendar
  for each row execute function app.audit_row();

-- Optional group membership for 'group' holidays (e.g. a community festival).
create table public.holiday_groups (
  user_id     uuid not null references public.profiles (id) on delete cascade,
  group_name  text not null,
  primary key (user_id, group_name)
);

-- Does a given day count as a holiday for this person? (weekly holiday or public holiday that applies)
create or replace function app.is_holiday_for(p_user uuid, p_date date) returns boolean
language sql stable security definer set search_path = public as $$
  select extract(isodow from p_date)::smallint = any (coalesce((select weekly_holidays from public.org_settings), '{}'::smallint[]))
      or exists (
        select 1 from public.holiday_calendar h
         where h.holiday_ad = p_date
           and (h.scope = 'all'
                or (h.scope = 'female' and exists (select 1 from public.employee_profiles e
                                                    where e.user_id = p_user and e.gender = 'female'))
                or (h.scope = 'group' and exists (select 1 from public.holiday_groups g
                                                   where g.user_id = p_user and g.group_name = h.group_name)))
      )
$$;

-- -----------------------------------------------------------------------------
-- Leave requests
-- -----------------------------------------------------------------------------
create table public.leave_requests (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references public.profiles (id) on delete cascade,
  leave_type_id      uuid not null references public.leave_types (id),
  start_ad           date not null,
  end_ad             date not null,
  start_bs           text,
  end_bs             text,
  half_day           public.half_day not null default 'none',
  days               numeric(6,2) not null check (days > 0),   -- working days requested (server-computed)
  reason             text,
  attachment_doc_id  uuid,                                     -- FK added in 0005 (documents)
  status             public.leave_req_status not null default 'pending',
  decided_by         uuid references public.profiles (id),
  decided_at         timestamptz,
  decision_comment   text,
  hr_override_reason text,
  created_at         timestamptz not null default now(),
  check (end_ad >= start_ad),
  check (half_day = 'none' or start_ad = end_ad)
);
create index on public.leave_requests (user_id, start_ad);
create index on public.leave_requests (status);
create trigger leave_requests_bs before insert or update on public.leave_requests
  for each row execute function app.fill_bs('start_ad', 'start_bs', 'end_ad', 'end_bs');

-- No two approved/pending requests may overlap for one person.
alter table public.leave_requests add constraint leave_requests_no_overlap
  exclude using gist (user_id with =, daterange(start_ad, end_ad, '[]') with &&)
  where (status in ('pending', 'documents_requested', 'approved'));

-- Decision rules enforced by the database:
--  * statutory-right leave (sick, mourning, maternity) can never be rejected by a manager;
--    only HR/admin can reject it and only with a logged override reason.
--  * only the person's manager, HR or admin may decide; nobody may decide their own request.
--  * the employee may only cancel their own request.
create or replace function app.guard_leave_decision() returns trigger
language plpgsql security definer set search_path = public as $$
declare t record;
begin
  if auth.uid() is null then return new; end if;            -- service role (system jobs)
  if new.status = old.status then
    -- Non-status edits: only while pending, by the owner.
    if old.status not in ('pending', 'documents_requested') or (new.user_id <> auth.uid() and not app.is_hr()) then
      raise exception 'This leave request can no longer be edited' using errcode = '42501';
    end if;
    return new;
  end if;

  select * into t from public.leave_types where id = new.leave_type_id;

  if new.status = 'cancelled' then
    if old.user_id <> auth.uid() and not app.is_hr() then
      raise exception 'Only the employee or HR can cancel a leave request' using errcode = '42501';
    end if;
    return new;
  end if;

  if old.user_id = auth.uid() then
    raise exception 'You cannot decide your own leave request' using errcode = '42501';
  end if;
  if not (app.is_manager_of(old.user_id) or app.is_hr()) then
    raise exception 'Only the employee''s manager or HR can decide this request' using errcode = '42501';
  end if;

  if new.status = 'rejected' and t.is_statutory_right then
    if not app.is_hr() then
      raise exception '% is a statutory right under the Labour Act and cannot be rejected by a manager. Request documents instead.', t.name_en
        using errcode = '42501';
    end if;
    if new.hr_override_reason is null or length(trim(new.hr_override_reason)) = 0 then
      raise exception 'HR must record an override reason to reject statutory leave' using errcode = '23514';
    end if;
  end if;

  new.decided_by := auth.uid();
  new.decided_at := now();
  return new;
end $$;
create trigger leave_requests_guard before update on public.leave_requests
  for each row execute function app.guard_leave_decision();
create trigger leave_requests_audit after insert or update or delete on public.leave_requests
  for each row execute function app.audit_row();

-- -----------------------------------------------------------------------------
-- Leave ledger (append-only). Balance = sum(days). Corrections are new rows.
-- -----------------------------------------------------------------------------
create table public.leave_ledger (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references public.profiles (id) on delete cascade,
  leave_type_id  uuid not null references public.leave_types (id),
  entry_ad       date not null,
  entry_bs       text,
  fiscal_year    text,
  kind           public.ledger_kind not null,
  days           numeric(7,2) not null check (days <> 0),
  request_id     uuid references public.leave_requests (id) on delete set null,
  reason         text,
  created_by     uuid references public.profiles (id),
  created_at     timestamptz not null default now(),
  -- sign must match the kind
  check ((kind in ('opening_balance', 'accrual', 'usage_reversal') and days > 0)
      or (kind in ('usage', 'encashment', 'lapse') and days < 0)
      or  kind = 'adjustment'),
  check (kind <> 'adjustment' or (reason is not null and length(trim(reason)) > 0))
);
create index on public.leave_ledger (user_id, leave_type_id, entry_ad);
create or replace function app.fill_ledger() returns trigger
language plpgsql set search_path = public as $$
begin
  new.entry_bs    := app.ad_to_bs(new.entry_ad);
  new.fiscal_year := app.fiscal_year_of(new.entry_ad);
  return new;
end $$;
create trigger leave_ledger_fill before insert on public.leave_ledger
  for each row execute function app.fill_ledger();
create trigger leave_ledger_append_only before update or delete on public.leave_ledger
  for each row execute function app.block_mutation();
create trigger leave_ledger_audit after insert on public.leave_ledger
  for each row execute function app.audit_row();

-- Balances, derived — never stored.
create view public.leave_balances with (security_invoker = true) as
  select user_id, leave_type_id, sum(days)::numeric(7,2) as balance_days, max(entry_ad) as last_entry_ad
    from public.leave_ledger
   group by user_id, leave_type_id;

-- Substitute leave earned by working on a holiday.
create table public.substitute_leave (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles (id) on delete cascade,
  worked_ad     date not null,
  holiday_id    uuid references public.holiday_calendar (id) on delete set null,
  session_id    uuid references public.work_sessions (id) on delete set null,
  ledger_id     uuid references public.leave_ledger (id),
  created_at    timestamptz not null default now(),
  unique (user_id, worked_ad)
);
