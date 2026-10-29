-- =============================================================================
-- 0008 Pay scheme: grades (salary scales), standard allowances, non-cash benefits,
--      and the pay package overview (monthly pay and annual cost to company).
--
-- Visible to the employee (own package), HR and admin. Never to managers: the
-- overview views are security_invoker, so they inherit the salary tables' RLS.
-- =============================================================================

create table public.pay_grades (
  id                 uuid primary key default gen_random_uuid(),
  code               text not null check (code ~ '^[A-Za-z0-9_-]+$'),
  name               text not null,
  effective_from_ad  date not null,
  effective_from_bs  text,
  basic_min_paisa    bigint not null check (basic_min_paisa >= 0),
  basic_max_paisa    bigint not null,
  -- Annual grade increment: a fixed amount or a percentage of basic (or neither).
  increment_paisa    bigint check (increment_paisa is null or increment_paisa > 0),
  increment_bp       int check (increment_bp is null or increment_bp between 1 and 5000),
  sort_order         smallint not null default 100,
  notes              text,
  active             boolean not null default true,
  is_demo            boolean not null default false,
  created_at         timestamptz not null default now(),
  unique (code, effective_from_ad),
  check (basic_max_paisa >= basic_min_paisa),
  check (increment_paisa is null or increment_bp is null)
);
create trigger pay_grades_bs before insert or update on public.pay_grades
  for each row execute function app.fill_bs('effective_from_ad', 'effective_from_bs');

-- Standard allowances that come with a grade (the default package).
create table public.pay_grade_allowances (
  grade_id           uuid not null references public.pay_grades (id) on delete cascade,
  allowance_type_id  uuid not null references public.allowance_types (id),
  amount_paisa       bigint not null check (amount_paisa >= 0),
  primary key (grade_id, allowance_type_id)
);

-- Which grade a salary version belongs to (optional; exceptions outside the range are allowed but flagged).
alter table public.salary_records add column pay_grade_id uuid references public.pay_grades (id);

-- Non-cash benefits (group insurance, lunch, phone …), valued per year for the package overview.
create table public.benefit_types (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique check (code ~ '^[a-z_]+$'),
  name_en     text not null,
  name_ne     text,
  taxable     boolean not null default false,     -- accountant to confirm per benefit
  active      boolean not null default true
);

create table public.employee_benefits (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references public.profiles (id) on delete cascade,
  benefit_type_id    uuid not null references public.benefit_types (id),
  annual_value_paisa bigint not null check (annual_value_paisa >= 0),
  start_ad           date not null,
  end_ad             date,
  note               text,
  created_by         uuid references public.profiles (id),
  created_at         timestamptz not null default now(),
  check (end_ad is null or end_ad >= start_ad)
);
create index on public.employee_benefits (user_id);

-- -----------------------------------------------------------------------------
-- Rule lookup for the overview (current fiscal year in Kathmandu). Null when missing.
-- -----------------------------------------------------------------------------
create or replace function app.payroll_rule_now(p_key text) returns numeric
language sql stable security definer set search_path = public as $$
  select value_numeric from public.payroll_rules
   where fiscal_year = app.fiscal_year_of(app.kathmandu_date(now())) and rule_key = p_key
$$;

create or replace function app.payroll_rules_confirmed_now() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(bool_and(status = 'confirmed'), false) from public.payroll_rules
   where fiscal_year = app.fiscal_year_of(app.kathmandu_date(now()))
     and rule_key in ('ssf_employee_rate_bp', 'ssf_employer_rate_bp', 'festival_allowance_months')
$$;

-- Current salary version per person (as of today in Kathmandu).
create view public.current_salary with (security_invoker = true) as
  select distinct on (s.user_id) s.*
    from public.salary_records s
   where s.effective_from_ad <= app.kathmandu_date(now())
   order by s.user_id, s.effective_from_ad desc;

-- -----------------------------------------------------------------------------
-- Pay package overview — one row per person with a current salary.
-- Estimates before income tax (tax depends on the whole year and is done by payroll).
-- -----------------------------------------------------------------------------
create view public.pay_package_overview with (security_invoker = true) as
with s as (
  select cs.*, p.full_name, p.job_title, p.employment_type, p.team_id,
         coalesce((select sum(a.amount_paisa) from public.salary_allowances a where a.salary_record_id = cs.id), 0)::bigint as allowances_paisa,
         coalesce((select sum(a.amount_paisa) from public.salary_allowances a join public.allowance_types t on t.id = a.allowance_type_id
                    where a.salary_record_id = cs.id and t.part_of_basic), 0)::bigint as allowances_in_basic_paisa,
         coalesce((select sum(b.annual_value_paisa) from public.employee_benefits b
                    where b.user_id = cs.user_id and b.start_ad <= app.kathmandu_date(now())
                      and (b.end_ad is null or b.end_ad >= app.kathmandu_date(now()))), 0)::bigint as benefits_annual_paisa,
         app.payroll_rule_now('ssf_employee_rate_bp')      as ssf_ee_bp,
         app.payroll_rule_now('ssf_employer_rate_bp')      as ssf_er_bp,
         app.payroll_rule_now('festival_allowance_months') as festival_months
    from public.current_salary cs
    join public.profiles p on p.id = cs.user_id
)
select
  s.user_id, s.full_name, s.job_title, s.employment_type, s.team_id,
  g.code  as grade_code, g.name as grade_name,
  s.id    as salary_record_id, s.effective_from_ad, s.effective_from_bs, s.ssf_enrolled,
  -- monthly
  s.basic_paisa                                                    as basic_monthly_paisa,
  s.allowances_paisa                                               as allowances_monthly_paisa,
  s.basic_paisa + s.allowances_paisa                               as gross_monthly_paisa,
  case when s.ssf_enrolled then round((s.basic_paisa + s.allowances_in_basic_paisa) * s.ssf_ee_bp / 10000)::bigint else 0 end as ssf_employee_monthly_paisa,
  case when s.ssf_enrolled then round((s.basic_paisa + s.allowances_in_basic_paisa) * s.ssf_er_bp / 10000)::bigint else 0 end as ssf_employer_monthly_paisa,
  -- annual
  round(s.basic_paisa * s.festival_months)::bigint                 as festival_allowance_annual_paisa,
  s.benefits_annual_paisa,
  (s.basic_paisa + s.allowances_paisa) * 12
    + round(s.basic_paisa * s.festival_months)::bigint             as cash_pay_annual_paisa,
  (s.basic_paisa + s.allowances_paisa) * 12
    + round(s.basic_paisa * s.festival_months)::bigint
    + case when s.ssf_enrolled then round((s.basic_paisa + s.allowances_in_basic_paisa) * s.ssf_er_bp / 10000)::bigint * 12 else 0 end
    + s.benefits_annual_paisa                                      as cost_to_company_annual_paisa,
  -- grade fit
  g.basic_min_paisa, g.basic_max_paisa,
  case when g.id is null or g.basic_max_paisa = g.basic_min_paisa then null
       else round(100.0 * (s.basic_paisa - g.basic_min_paisa) / (g.basic_max_paisa - g.basic_min_paisa), 1) end as position_in_range_pct,
  (g.id is not null and (s.basic_paisa < g.basic_min_paisa or s.basic_paisa > g.basic_max_paisa))      as outside_grade_range,
  -- honesty flags
  (s.ssf_ee_bp is null or s.ssf_er_bp is null or s.festival_months is null)                            as rules_missing,
  not app.payroll_rules_confirmed_now()                                                                  as rules_unconfirmed
from s
left join public.pay_grades g on g.id = s.pay_grade_id;

-- Grade-level overview of the scheme.
create view public.pay_grade_overview with (security_invoker = true) as
select g.id as grade_id, g.code, g.name, g.effective_from_ad, g.effective_from_bs,
       g.basic_min_paisa, g.basic_max_paisa, g.increment_paisa, g.increment_bp,
       coalesce((select sum(a.amount_paisa) from public.pay_grade_allowances a where a.grade_id = g.id), 0)::bigint as standard_allowances_paisa,
       count(o.user_id)                                   as headcount,
       min(o.basic_monthly_paisa)                         as basic_lowest_paisa,
       round(avg(o.basic_monthly_paisa))::bigint          as basic_average_paisa,
       max(o.basic_monthly_paisa)                         as basic_highest_paisa,
       count(*) filter (where o.outside_grade_range)      as outside_range_count,
       sum(o.cost_to_company_annual_paisa)::bigint        as cost_to_company_annual_paisa
  from public.pay_grades g
  left join public.pay_package_overview o on o.grade_code = g.code
 where g.active
 group by g.id;

-- -----------------------------------------------------------------------------
-- Audit and access
-- -----------------------------------------------------------------------------
create trigger pay_grades_audit after insert or update or delete on public.pay_grades
  for each row execute function app.audit_row();
create trigger pay_grade_allowances_audit after insert or update or delete on public.pay_grade_allowances
  for each row execute function app.audit_row();
create trigger employee_benefits_audit after insert or update or delete on public.employee_benefits
  for each row execute function app.audit_row();

alter table public.pay_grades           enable row level security;
alter table public.pay_grade_allowances enable row level security;
alter table public.benefit_types        enable row level security;
alter table public.employee_benefits    enable row level security;

-- The grade structure itself is internal to HR/admin; employees see their own package via the view.
create policy grades_read   on public.pay_grades for select to authenticated using (app.is_hr());
create policy grades_write  on public.pay_grades for all to authenticated using (app.is_hr()) with check (app.is_hr());
create policy grade_allow_read  on public.pay_grade_allowances for select to authenticated using (app.is_hr());
create policy grade_allow_write on public.pay_grade_allowances for all to authenticated using (app.is_hr()) with check (app.is_hr());
create policy benefit_types_read  on public.benefit_types for select to authenticated using (true);
create policy benefit_types_write on public.benefit_types for all to authenticated using (app.is_hr()) with check (app.is_hr());
create policy benefits_read  on public.employee_benefits for select to authenticated using (app.can_see_pay(user_id));
create policy benefits_write on public.employee_benefits for all to authenticated using (app.is_hr()) with check (app.is_hr());

revoke execute on all functions in schema app from public, anon;
grant execute on all functions in schema app to authenticated, service_role;
