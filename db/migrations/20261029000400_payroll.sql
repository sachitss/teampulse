-- =============================================================================
-- 0004 Module 3 — attendance → payroll
--
-- The app CALCULATES and DOCUMENTS payroll. It never moves money.
-- All amounts are bigint paisa. Rates are integer basis points (1% = 100 bp).
-- Rules are versioned per fiscal year; a run stores a snapshot of the exact rules
-- it used, so changing next year's rules can never change a locked past run.
-- =============================================================================

create type public.payroll_status   as enum ('draft', 'review', 'approved', 'published');
create type public.adjustment_kind  as enum ('addition', 'deduction');
create type public.export_kind      as enum ('register_csv', 'register_pdf', 'ssf_sheet', 'tds_summary', 'bank_csv',
                                             'encashment_statement', 'final_settlement');
create type public.summary_status   as enum ('draft', 'reviewed');

-- -----------------------------------------------------------------------------
-- Salary (HR only). Versioned by effective date; past payroll never changes.
-- -----------------------------------------------------------------------------
create table public.allowance_types (
  id              uuid primary key default gen_random_uuid(),
  code            text not null unique check (code ~ '^[a-z_]+$'),
  name_en         text not null,
  name_ne         text,
  part_of_basic   boolean not null default false,   -- counts toward basic for SSF?
  taxable         boolean not null default true,
  fixed_monthly   boolean not null default true,    -- included in unpaid-leave deduction base
  active          boolean not null default true
);

create table public.salary_records (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references public.profiles (id) on delete cascade,
  effective_from_ad date not null,
  effective_from_bs text,
  basic_paisa       bigint not null check (basic_paisa >= 0),
  ssf_enrolled      boolean not null default true,
  reason            text not null check (length(trim(reason)) > 0),
  created_by        uuid references public.profiles (id),
  created_at        timestamptz not null default now(),
  unique (user_id, effective_from_ad)
);
create trigger salary_records_bs before insert or update on public.salary_records
  for each row execute function app.fill_bs('effective_from_ad', 'effective_from_bs');

create table public.salary_allowances (
  salary_record_id  uuid not null references public.salary_records (id) on delete cascade,
  allowance_type_id uuid not null references public.allowance_types (id),
  amount_paisa      bigint not null check (amount_paisa >= 0),
  primary key (salary_record_id, allowance_type_id)
);

-- Salary versions are immutable once any payroll run has used them: add a new version instead.
create or replace function app.guard_used_salary() returns trigger
language plpgsql security definer set search_path = public as $$
declare sid uuid := coalesce(to_jsonb(old) ->> 'salary_record_id', to_jsonb(old) ->> 'id')::uuid;
begin
  if exists (select 1 from public.payroll_lines l where l.salary_record_id = sid) then
    raise exception 'This salary version was used by a payroll run; add a new version with a later effective date'
      using errcode = '42501';
  end if;
  return coalesce(new, old);
end $$;

-- Identifiers and bank details: encrypted in the APPLICATION (AES-256-GCM) before they
-- reach the database, so neither backups nor SQL access reveal them. Only the last 4
-- digits are stored in clear for display.
create table public.employee_bank_details (
  user_id              uuid primary key references public.profiles (id) on delete cascade,
  pan_enc              bytea,
  pan_last4            text check (pan_last4 ~ '^\d{0,4}$'),
  bank_name            text,
  bank_branch          text,
  bank_account_enc     bytea,
  bank_account_last4   text check (bank_account_last4 ~ '^[0-9A-Za-z]{0,4}$'),
  ssf_number_enc       bytea,
  updated_by           uuid references public.profiles (id),
  updated_at           timestamptz not null default now()
);
create trigger employee_bank_details_touch before update on public.employee_bank_details
  for each row execute function app.touch_updated_at();

-- -----------------------------------------------------------------------------
-- Payroll rules, per fiscal year. Every value is to_confirm until the accountant confirms it.
-- -----------------------------------------------------------------------------
create table public.payroll_rules (
  fiscal_year   text not null check (fiscal_year ~ '^\d{4}/\d{2}$'),
  rule_key      text not null check (rule_key ~ '^[a-z_]+$'),
  value_numeric numeric,
  value_text    text,
  unit          text not null,                    -- 'bp' | 'paisa' | 'day_of_month' | 'months' | 'multiplier' | 'bool' | 'hours'
  description   text not null,
  status        public.rule_status not null default 'to_confirm',
  confirmed_by  uuid references public.profiles (id),
  confirmed_at  timestamptz,
  source_note   text,
  primary key (fiscal_year, rule_key),
  check (value_numeric is not null or value_text is not null),
  check (status <> 'confirmed' or (confirmed_by is not null and confirmed_at is not null))
);
create trigger payroll_rules_audit after insert or update or delete on public.payroll_rules
  for each row execute function app.audit_row();

-- Income-tax slabs, per fiscal year. Bands must be contiguous from 0 to open-ended;
-- app.tax_slabs_complete() checks this and payroll refuses to run otherwise.
create table public.tax_slabs (
  fiscal_year   text not null check (fiscal_year ~ '^\d{4}/\d{2}$'),
  band          smallint not null check (band >= 1),
  lower_paisa   bigint not null check (lower_paisa >= 0),
  upper_paisa   bigint,                            -- null = no upper limit (top band)
  rate_bp       int not null check (rate_bp between 0 and 10000),
  -- The first band is the 1% Social Security Tax, waived for SSF contributors.
  is_sst_band   boolean not null default false,
  status        public.rule_status not null default 'to_confirm',
  confirmed_by  uuid references public.profiles (id),
  confirmed_at  timestamptz,
  source_note   text,
  primary key (fiscal_year, band),
  check (upper_paisa is null or upper_paisa > lower_paisa)
);
create trigger tax_slabs_audit after insert or update or delete on public.tax_slabs
  for each row execute function app.audit_row();

create or replace function app.tax_slabs_complete(p_fy text) returns boolean
language sql stable security definer set search_path = public as $$
  with s as (
    select band, lower_paisa, upper_paisa,
           lag(upper_paisa) over (order by band) as prev_upper,
           row_number() over (order by band) as rn,
           count(*) over () as n
      from public.tax_slabs where fiscal_year = p_fy
  )
  select coalesce(bool_and(
           (rn = 1 and lower_paisa = 0 or rn > 1 and lower_paisa = prev_upper)
           and (rn = n) = (upper_paisa is null)), false)
    from s
$$;

-- Deductions that reduce taxable income (retirement fund, insurance …), maintained by the accountant.
create table public.tax_deduction_rules (
  fiscal_year   text not null check (fiscal_year ~ '^\d{4}/\d{2}$'),
  code          text not null check (code ~ '^[a-z_]+$'),
  description   text not null,
  max_annual_paisa bigint,
  max_percent_bp   int,
  status        public.rule_status not null default 'to_confirm',
  confirmed_by  uuid references public.profiles (id),
  confirmed_at  timestamptz,
  primary key (fiscal_year, code)
);

-- Required payroll rule keys. A run refuses to calculate if any is missing for its fiscal year.
create table public.payroll_rule_keys (
  rule_key    text primary key,
  description text not null
);
insert into public.payroll_rule_keys (rule_key, description) values
  ('ssf_employee_rate_bp',       'SSF contribution deducted from the employee, % of basic'),
  ('ssf_employer_rate_bp',       'SSF contribution paid by the employer on top, % of basic'),
  ('sst_waived_for_ssf',         'Social Security Tax (first tax band) waived for SSF-enrolled employees (1 = yes)'),
  ('festival_allowance_months',  'Festival (Dashain) allowance, in months of basic per year'),
  ('festival_allowance_bs_month','BS month in which the festival allowance is paid'),
  ('overtime_multiplier',        'Overtime pay as a multiple of the hourly basic rate'),
  ('daily_hours_limit',          'Hours per day above which approved time counts as overtime'),
  ('weekly_hours_limit',         'Hours per week above which approved time counts as overtime'),
  ('ssf_deposit_day',            'SSF deposit due by this day of the following BS month'),
  ('tds_deposit_day',            'TDS deposit due by this day of the following BS month'),
  ('holiday_work_compensation',  '''substitute_leave'' or ''overtime_pay'' for work on a holiday');

create or replace function app.missing_payroll_rules(p_fy text) returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(k.rule_key order by k.rule_key), '{}')
    from public.payroll_rule_keys k
   where not exists (select 1 from public.payroll_rules r where r.fiscal_year = p_fy and r.rule_key = k.rule_key)
$$;

-- -----------------------------------------------------------------------------
-- Monthly attendance summary (per BS month, per employee)
-- -----------------------------------------------------------------------------
create table public.attendance_summaries (
  id                      uuid primary key default gen_random_uuid(),
  user_id                 uuid not null references public.profiles (id) on delete cascade,
  bs_year                 smallint not null,
  bs_month                smallint not null,
  days_in_month           smallint not null,
  working_days            numeric(5,2) not null,
  days_worked             numeric(5,2) not null,
  paid_leave_days         jsonb not null default '{}',   -- {"home": 2, "sick": 1}
  unpaid_leave_days       numeric(5,2) not null default 0,
  public_holidays         numeric(5,2) not null default 0,
  weekly_holidays         numeric(5,2) not null default 0,
  holiday_days_worked     numeric(5,2) not null default 0,
  overtime_hours_approved numeric(6,2) not null default 0,
  status                  public.summary_status not null default 'draft',
  generated_at            timestamptz not null default now(),
  reviewed_by             uuid references public.profiles (id),
  reviewed_at             timestamptz,
  unique (user_id, bs_year, bs_month),
  foreign key (bs_year, bs_month) references public.bs_calendar_months (bs_year, bs_month)
);
create trigger attendance_summaries_audit after update on public.attendance_summaries
  for each row execute function app.audit_row();

-- -----------------------------------------------------------------------------
-- Payroll runs
-- -----------------------------------------------------------------------------
create table public.payroll_runs (
  id                   uuid primary key default gen_random_uuid(),
  bs_year              smallint not null,
  bs_month             smallint not null,
  fiscal_year          text not null,
  period_start_ad      date not null,
  period_end_ad        date not null,
  status               public.payroll_status not null default 'draft',
  is_parallel_run      boolean not null default true,
  calendar_provisional boolean not null default false,  -- period falls in a provisional BS year
  rules_snapshot       jsonb,                           -- exact rules + slabs used, frozen on approval
  created_by           uuid references public.profiles (id),
  created_at           timestamptz not null default now(),
  approved_by          uuid references public.profiles (id),
  approved_at          timestamptz,
  published_at         timestamptz,
  unique (bs_year, bs_month),
  foreign key (bs_year, bs_month) references public.bs_calendar_months (bs_year, bs_month)
);

create or replace function app.fill_payroll_run() returns trigger
language plpgsql set search_path = public as $$
declare r record;
begin
  select * into r from public.bs_calendar_months where bs_year = new.bs_year and bs_month = new.bs_month;
  new.period_start_ad      := r.ad_start;
  new.period_end_ad        := r.ad_start + (r.days - 1);
  new.fiscal_year          := app.fiscal_year_of(r.ad_start);
  new.calendar_provisional := (r.status = 'provisional');
  if tg_op = 'INSERT' then
    new.is_parallel_run := (select payroll_parallel_run from public.org_settings);
  end if;
  return new;
end $$;
create trigger payroll_runs_fill before insert or update of bs_year, bs_month on public.payroll_runs
  for each row execute function app.fill_payroll_run();

-- Status machine: draft → review → approved (admin only, locks) → published.
-- Calculation refuses to start if rules or tax slabs are missing for the fiscal year.
create or replace function app.guard_payroll_run() returns trigger
language plpgsql security definer set search_path = public as $$
declare missing text[];
begin
  if tg_op = 'INSERT' then
    missing := app.missing_payroll_rules(new.fiscal_year);
    if array_length(missing, 1) > 0 then
      raise exception 'Cannot start payroll for FY %: missing rules %', new.fiscal_year, missing using errcode = '23514';
    end if;
    if not app.tax_slabs_complete(new.fiscal_year) then
      raise exception 'Cannot start payroll for FY %: income-tax slabs are incomplete. The accountant must enter every band from 0 to the top rate.', new.fiscal_year
        using errcode = '23514';
    end if;
    return new;
  end if;

  if old.status in ('approved', 'published') then
    if new.status = 'published' and old.status = 'approved' then
      new.published_at := now();
      return new;
    end if;
    raise exception 'Payroll run is locked (status %); corrections go into the next month as adjustments', old.status
      using errcode = '42501';
  end if;

  if new.status = 'approved' and old.status <> 'approved' then
    if auth.uid() is not null and not app.is_admin() then
      raise exception 'Only an admin can approve payroll' using errcode = '42501';
    end if;
    if old.status <> 'review' then
      raise exception 'Payroll must be reviewed before approval' using errcode = '23514';
    end if;
    new.approved_by := auth.uid();
    new.approved_at := now();
    -- Freeze the exact rules used.
    new.rules_snapshot := jsonb_build_object(
      'payroll_rules', (select jsonb_object_agg(rule_key, jsonb_build_object('value', coalesce(to_jsonb(value_numeric), to_jsonb(value_text)), 'status', status))
                          from public.payroll_rules where fiscal_year = new.fiscal_year),
      'tax_slabs',     (select jsonb_agg(to_jsonb(s) - 'fiscal_year' order by band) from public.tax_slabs s where fiscal_year = new.fiscal_year),
      'frozen_at',     now());
  end if;
  if new.status = 'published' and old.status <> 'approved' then
    raise exception 'Payroll must be approved before publishing' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger payroll_runs_guard before insert or update on public.payroll_runs
  for each row execute function app.guard_payroll_run();
create trigger payroll_runs_no_delete before delete on public.payroll_runs
  for each row when (old.status in ('approved', 'published')) execute function app.block_mutation();
create trigger payroll_runs_audit after insert or update or delete on public.payroll_runs
  for each row execute function app.audit_row('rules_snapshot');

create table public.payroll_lines (
  id                       uuid primary key default gen_random_uuid(),
  run_id                   uuid not null references public.payroll_runs (id) on delete cascade,
  user_id                  uuid not null references public.profiles (id),
  salary_record_id         uuid not null references public.salary_records (id),
  basic_paisa              bigint not null,
  allowances               jsonb not null default '{}',   -- {"transport": 300000}
  overtime_paisa           bigint not null default 0,
  festival_allowance_paisa bigint not null default 0,
  additions_paisa          bigint not null default 0,
  unpaid_leave_deduction_paisa bigint not null default 0,
  gross_paisa              bigint not null,
  ssf_employee_paisa       bigint not null default 0,
  ssf_employer_paisa       bigint not null default 0,
  tds_paisa                bigint not null default 0,
  other_deductions_paisa   bigint not null default 0,
  net_paisa                bigint not null,
  -- Calculation trace: inputs → rule → result, shown on the register.
  working                  jsonb not null default '[]',
  flags                    text[] not null default '{}',   -- 'no_pan', 'no_bank_account', 'variance_gt_threshold' …
  unique (run_id, user_id),
  check (net_paisa = gross_paisa - ssf_employee_paisa - tds_paisa - other_deductions_paisa)
);

create table public.payroll_adjustments (
  id            uuid primary key default gen_random_uuid(),
  run_id        uuid not null references public.payroll_runs (id) on delete cascade,
  user_id       uuid not null references public.profiles (id),
  kind          public.adjustment_kind not null,
  amount_paisa  bigint not null check (amount_paisa > 0),
  taxable       boolean not null default true,
  reason        text not null check (length(trim(reason)) > 0),
  created_by    uuid references public.profiles (id),
  created_at    timestamptz not null default now()
);

-- Lines and adjustments are frozen once their run is approved.
create or replace function app.guard_run_children() returns trigger
language plpgsql security definer set search_path = public as $$
declare st public.payroll_status;
begin
  select status into st from public.payroll_runs where id = coalesce(new.run_id, old.run_id);
  if st in ('approved', 'published') then
    raise exception 'Payroll run is locked; corrections go into the next month as adjustments' using errcode = '42501';
  end if;
  return coalesce(new, old);
end $$;
create trigger payroll_lines_locked before insert or update or delete on public.payroll_lines
  for each row execute function app.guard_run_children();
create trigger payroll_adjustments_locked before insert or update or delete on public.payroll_adjustments
  for each row execute function app.guard_run_children();
create trigger payroll_adjustments_audit after insert or update or delete on public.payroll_adjustments
  for each row execute function app.audit_row();

create trigger salary_records_used before update or delete on public.salary_records
  for each row execute function app.guard_used_salary();
create trigger salary_allowances_used before update or delete on public.salary_allowances
  for each row execute function app.guard_used_salary();
create trigger salary_records_audit after insert or update or delete on public.salary_records
  for each row execute function app.audit_row();
create trigger salary_allowances_audit after insert or update or delete on public.salary_allowances
  for each row execute function app.audit_row();
create trigger employee_bank_details_audit after insert or update or delete on public.employee_bank_details
  for each row execute function app.audit_row('pan_enc,bank_account_enc,ssf_number_enc');

create table public.payslips (
  id            uuid primary key default gen_random_uuid(),
  run_id        uuid not null references public.payroll_runs (id) on delete cascade,
  user_id       uuid not null references public.profiles (id),
  lang          text not null default 'en' check (lang in ('en', 'ne')),
  storage_key   text not null,              -- private 'payslips' bucket
  created_at    timestamptz not null default now(),
  unique (run_id, user_id, lang)
);

create table public.payroll_exports (
  id            uuid primary key default gen_random_uuid(),
  run_id        uuid references public.payroll_runs (id) on delete cascade,
  user_id       uuid references public.profiles (id),   -- for per-employee exports (final settlement)
  kind          public.export_kind not null,
  storage_key   text not null,
  total_paisa   bigint,                                  -- must equal the register total (acceptance test 14)
  created_by    uuid references public.profiles (id),
  created_at    timestamptz not null default now()
);

-- Payslip access goes through this function so every view is logged.
create or replace function app.payslip_key_for_view(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare s record; st public.payroll_status;
begin
  select * into s from public.payslips where id = p_id;
  select status into st from public.payroll_runs where id = s.run_id;
  if s is null or not (app.is_hr() or (s.user_id = auth.uid() and st = 'published')) then
    perform app.audit('view_payslip_denied', 'payslips', p_id::text, '{}');
    return null;   -- denied: the API answers 403. (Raising would roll back the audit entry.)
  end if;
  perform app.audit('view_payslip', 'payslips', p_id::text, jsonb_build_object('employee', s.user_id));
  return s.storage_key;
end $$;
grant execute on function app.payslip_key_for_view(uuid) to authenticated;
