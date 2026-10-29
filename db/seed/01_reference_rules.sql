-- =============================================================================
-- Reference data and rules — applied in every environment, including production.
--
-- EVERY legal value below is status 'to_confirm'. PEACE's accountant/HR must
-- review and confirm each one (docs/accountant-checklist.md) before the first
-- live payroll. Sources were checked on 2026-10-29 and are noted per row.
-- Idempotent: safe to re-run; confirmed rows are never overwritten.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Leave types
-- -----------------------------------------------------------------------------
insert into public.leave_types (code, name_en, name_ne, is_paid, is_statutory_right, tracks_balance, sort_order) values
  ('home',       'Home leave',        'घर बिदा',        true,  false, true,  10),
  ('sick',       'Sick leave',        'बिरामी बिदा',     true,  true,  true,  20),
  ('maternity',  'Maternity leave',   'प्रसूति बिदा',     true,  true,  false, 30),
  ('paternity',  'Paternity leave',   'प्रसूति स्याहार बिदा', true, false, false, 40),
  ('mourning',   'Mourning leave',    'किरिया बिदा',     true,  true,  false, 50),
  ('substitute', 'Substitute leave',  'सट्टा बिदा',      true,  false, true,  60),
  ('unpaid',     'Unpaid leave',      'बेतलबी बिदा',     false, false, false, 90)
on conflict (code) do nothing;

-- Labour Act 2074 commenced 2017-09-04 (19 Bhadra 2074).
insert into public.leave_rules
  (leave_type_id, effective_from_ad, accrual, per_days_worked, accrual_days, annual_days,
   max_days_per_event, paid_days_per_event, carry_forward_cap, encash_excess_at_year_end, encash_on_exit,
   certificate_after_days, applies_to, source_note)
select t.id, date '2017-09-04', r.accrual::public.leave_accrual, r.per_days_worked, r.accrual_days, r.annual_days,
       r.max_days_per_event, r.paid_days_per_event, r.cap, r.encash_excess, r.encash_exit,
       r.cert_after, r.applies_to::public.leave_applies, r.note
  from (values
    ('home',       'per_days_worked', 20,   1.00, null::numeric, null::numeric, null::numeric, 90.00, true,  true,  null::smallint, 'all',
     'Labour Act 2074: 1 day per 20 days worked, accumulate up to 90 days, encash excess and at exit'),
    ('sick',       'annual_grant',    null, null, 12.00,  null,  null,  45.00, true,  true,  3,    'all',
     'Labour Act 2074: 12 days/year fully paid, accumulate up to 45 days; certificate above 3 consecutive days (practice guide — confirm)'),
    ('maternity',  'per_event',       null, null, null,   98.00, 60.00, null,  false, false, null, 'female',
     'Labour Act 2074: 14 weeks (98 days), 60 days fully paid'),
    ('paternity',  'per_event',       null, null, null,   15.00, 15.00, null,  false, false, null, 'male',
     'Labour Act 2074: 15 days paid maternity-care leave for the husband'),
    ('mourning',   'per_event',       null, null, null,   13.00, 13.00, null,  false, false, null, 'all',
     'Labour Act 2074: 13 days paid mourning (kiriya) leave'),
    ('substitute', 'earned',          null, null, null,   null,  null,  null,  false, false, null, 'all',
     'One day for each approved day worked on a public or weekly holiday (PEACE policy — confirm)'),
    ('unpaid',     'none',            null, null, null,   null,  null,  null,  false, false, null, 'all',
     'Granted at management discretion; deducted in payroll')
  ) as r(code, accrual, per_days_worked, accrual_days, annual_days, max_days_per_event, paid_days_per_event,
         cap, encash_excess, encash_exit, cert_after, applies_to, note)
  join public.leave_types t on t.code = r.code
on conflict (leave_type_id, effective_from_ad) do nothing;

-- -----------------------------------------------------------------------------
-- Payroll rules for FY 2082/83 and 2083/84 (same values both years)
-- -----------------------------------------------------------------------------
insert into public.payroll_rules (fiscal_year, rule_key, value_numeric, value_text, unit, description, source_note)
select fy, k, v, vt, u, d, n
  from (values ('2082/83'), ('2083/84')) as y(fy)
  cross join (values
    ('ssf_employee_rate_bp',        1100::numeric, null, 'bp',           'SSF: employee contribution, % of basic (11%)',
     'Contribution-Based Social Security Act 2074: 11% employee'),
    ('ssf_employer_rate_bp',        2000,          null, 'bp',           'SSF: employer contribution on top, % of basic (20%)',
     'Contribution-Based Social Security Act 2074: 20% employer'),
    ('sst_waived_for_ssf',          1,             null, 'bool',         'First tax band (1% SST) waived for SSF contributors',
     'Practice guides and IRD rate sheet note SSF contributors are exempt from the 1% band — confirm'),
    ('festival_allowance_months',   1,             null, 'months',       'Festival (Dashain) allowance: one month of basic per year',
     'Labour Act 2074 festival expense: one month basic remuneration per year'),
    ('festival_allowance_bs_month', 6,             null, 'bs_month',     'BS month the festival allowance is paid (6 = Ashwin)',
     'PEACE practice — set to the month you actually pay'),
    ('overtime_multiplier',         1.5,           null, 'multiplier',   'Overtime pay as a multiple of hourly basic',
     'Not verified — accountant must confirm against Labour Act 2074'),
    ('daily_hours_limit',           8,             null, 'hours',        'Hours per day before approved time counts as overtime',
     'Not verified — confirm against Labour Act 2074 and contracts'),
    ('weekly_hours_limit',          48,            null, 'hours',        'Hours per week before approved time counts as overtime',
     'Not verified — confirm against Labour Act 2074 and contracts'),
    ('ssf_deposit_day',             15,            null, 'day_of_month', 'SSF deposit due by this day of the following BS month',
     'SSF guidance: deposit by the 15th of the following month'),
    ('tds_deposit_day',             25,            null, 'day_of_month', 'TDS deposit due by this day of the following BS month',
     'Payroll guides: TDS by the 25th of the following Nepali month — confirm'),
    ('holiday_work_compensation',   null,          'substitute_leave', 'choice', 'Compensation for approved work on a holiday',
     'PEACE policy: substitute_leave or overtime_pay')
  ) as r(k, v, vt, u, d, n)
on conflict (fiscal_year, rule_key) do nothing;

-- -----------------------------------------------------------------------------
-- Income-tax slabs (resident individuals). Amounts in paisa.
-- -----------------------------------------------------------------------------
-- FY 2083/84 — one table for all resident individuals (Finance Act 2083).
-- Two independent sources agreed on 2026-10-29; one cites the IRD rate sheet for income year 2083/084.
insert into public.tax_slabs (fiscal_year, band, lower_paisa, upper_paisa, rate_bp, is_sst_band, source_note) values
  ('2083/84', 1,           0,  100000000,  100, true,  'Up to Rs 10,00,000 — 1% (SST band)'),
  ('2083/84', 2,   100000000,  150000000, 1000, false, 'Rs 10,00,001–15,00,000 — 10%'),
  ('2083/84', 3,   150000000,  250000000, 2000, false, 'Rs 15,00,001–25,00,000 — 20%'),
  ('2083/84', 4,   250000000,  400000000, 2700, false, 'Rs 25,00,001–40,00,000 — 27%'),
  ('2083/84', 5,   400000000,       null, 2900, false, 'Above Rs 40,00,000 — 29% (27% + 2% additional)')
on conflict (fiscal_year, band) do nothing;

-- FY 2082/83 — single-person schedule (a separate couple schedule applied that year;
-- the accountant must add it if any employee was assessed as a couple).
insert into public.tax_slabs (fiscal_year, band, lower_paisa, upper_paisa, rate_bp, is_sst_band, source_note) values
  ('2082/83', 1,           0,   50000000,  100, true,  'Up to Rs 5,00,000 — 1% (SST band), single'),
  ('2082/83', 2,    50000000,   70000000, 1000, false, 'Rs 5,00,001–7,00,000 — 10%'),
  ('2082/83', 3,    70000000,  100000000, 2000, false, 'Rs 7,00,001–10,00,000 — 20%'),
  ('2082/83', 4,   100000000,  200000000, 3000, false, 'Rs 10,00,001–20,00,000 — 30%'),
  ('2082/83', 5,   200000000,  500000000, 3600, false, 'Rs 20,00,001–50,00,000 — 36%'),
  ('2082/83', 6,   500000000,       null, 3900, false, 'Above Rs 50,00,000 — 39%')
on conflict (fiscal_year, band) do nothing;

-- -----------------------------------------------------------------------------
-- Checklist templates
-- -----------------------------------------------------------------------------
insert into public.checklist_templates (kind, name) values
  ('onboarding', 'Standard onboarding'), ('offboarding', 'Standard offboarding')
on conflict (kind, name) do nothing;

insert into public.checklist_template_items (template_id, position, title, owner_role, due_offset_days, action)
select t.id, i.pos, i.title, i.owner::public.user_role, i.offset_days, i.action::public.checklist_action
  from public.checklist_templates t
  join (values
    ('onboarding', 1, 'Employment contract signed and uploaded',      'hr',      0, 'none'),
    ('onboarding', 2, 'Citizenship and PAN documents collected',       'hr',      0, 'none'),
    ('onboarding', 3, 'PAN and bank details recorded',                 'hr',      3, 'none'),
    ('onboarding', 4, 'Enrolled in the Social Security Fund (SSF)',    'hr',      7, 'ssf_enrollment'),
    ('onboarding', 5, 'Salary record created',                         'hr',      0, 'none'),
    ('onboarding', 6, 'Monitoring and HR data notice read and consented', 'employee', 0, 'consent_notice'),
    ('onboarding', 7, 'Company laptop issued and agent enrolled',      'admin',   1, 'enroll_device'),
    ('offboarding', 1, 'Final timesheet approved and locked',          'manager', 0, 'none'),
    ('offboarding', 2, 'Company laptop returned',                      'admin',   0, 'none'),
    ('offboarding', 3, 'Monitoring agent revoked',                     'admin',   0, 'revoke_agent'),
    ('offboarding', 4, 'System access removed',                        'admin',   0, 'remove_access'),
    ('offboarding', 5, 'Final settlement calculated (leave encashment, festival allowance)', 'hr', 3, 'final_settlement'),
    ('offboarding', 6, 'Experience letter issued',                     'hr',      7, 'none')
  ) as i(kind, pos, title, owner, offset_days, action)
    on i.kind::public.checklist_kind = t.kind
on conflict (template_id, position) do nothing;

-- -----------------------------------------------------------------------------
-- Compliance calendar (BS due dates)
-- -----------------------------------------------------------------------------
insert into public.admin_tasks (title, description, owner_role, recurrence, due_day_bs, due_month_bs, remind_days_before)
select * from (values
  ('SSF deposit',                 'Deposit 31% of basic (11% employee + 20% employer) for last month via the SSF portal', 'hr'::public.user_role, 'monthly_bs'::public.recurrence, 15::smallint, null::smallint, 3::smallint),
  ('TDS deposit',                 'Deposit last month''s salary TDS and file with IRD',            'hr', 'monthly_bs', 25, null, 3),
  ('Monthly payroll run',         'Lock timesheets, review attendance, run and approve payroll',   'hr', 'monthly_bs',  7, null, 3),
  ('Fiscal-year leave close',     'Apply carry-forward caps and flag encashable leave (1 Shrawan)', 'hr', 'yearly_bs',   1,    4, 14),
  ('Holiday calendar for new BS year', 'Import the gazetted public holidays for the coming year', 'hr', 'yearly_bs',  15,   12, 14),
  ('Official BS calendar check',  'Replace provisional BS month lengths with the official calendar once published', 'hr', 'yearly_bs', 1, 10, 30),
  ('Annual tax return support',   'Prepare annual salary and TDS statements for the accountant',  'hr', 'yearly_bs',   1,    6, 14)
) as v(title, description, owner_role, recurrence, due_day_bs, due_month_bs, remind_days_before)
where not exists (select 1 from public.admin_tasks a where a.title = v.title);

-- -----------------------------------------------------------------------------
-- Reports
-- -----------------------------------------------------------------------------
insert into public.report_schedules (kind, local_time, weekday, recipients, restricted) values
  ('daily',   '18:00', null, '{peace.consultancy@gmail.com}', false),
  ('weekly',  '17:00', 5,    '{peace.consultancy@gmail.com}', false),   -- Friday (Sun–Fri week)
  ('monthly', '10:00', null, '{peace.consultancy@gmail.com}', true)     -- payroll totals: HR/Admin addresses only
on conflict (kind) do nothing;

-- -----------------------------------------------------------------------------
-- Initial monitoring policy (contract §4, Lite restrictions). Collection still stays
-- off until an admin confirms the notice was issued and each employee consents.
-- -----------------------------------------------------------------------------
insert into public.policies (settings, note)
select '{
  "monitoring": {
    "work_schedule": { "timezone": "Asia/Kathmandu",
                       "windows": [ { "days": ["sun","mon","tue","wed","thu","fri"], "start": "10:00", "end": "17:00" } ] },
    "session_mode": "schedule+manual",
    "screenshots": { "enabled": true, "interval_seconds": 600, "jitter_seconds": 30,
                     "image_format": "jpeg", "max_long_edge_px": 1280, "jpeg_quality": 70 },
    "app_activity":     { "enabled": true, "capture_window_title": false },
    "website_activity": { "enabled": true, "capture_full_url": false },
    "input_metrics":    { "enabled": true, "window_seconds": 60 },
    "idle":             { "threshold_seconds": 300 },
    "file_activity":    { "enabled": false, "watched_paths": [], "store_hash": false },
    "exclusions": { "apps": ["1password.exe", "keepass.exe", "keepassxc.exe", "bitwarden.exe"],
                    "domains": [], "paths": [] },
    "respect_leave_and_holidays": true
  },
  "privacy_pause": { "employee_can_pause": true, "max_pause_minutes": 30 }
}'::jsonb, 'Initial Lite policy'
where not exists (select 1 from public.policies);

-- -----------------------------------------------------------------------------
-- Loans and advances — PEACE company policy (not law). Edit to match your policy.
-- The loan_policy row is created by migration 0007 with status to_confirm.
-- -----------------------------------------------------------------------------
insert into public.loan_types (code, name_en, name_ne, max_months_of_basic, max_instalments, default_interest_bp, interest_method) values
  ('salary_advance', 'Salary advance',  'तलब पेस्की',   1, 3,  0, 'none'),
  ('personal_loan',  'Personal loan',   'व्यक्तिगत ऋण',  6, 24, 0, 'none'),
  ('emergency_loan', 'Emergency loan',  'आपतकालीन ऋण',   3, 12, 0, 'none')
on conflict (code) do nothing;

-- -----------------------------------------------------------------------------
-- Non-cash benefit types for the pay package overview (values are set per employee).
-- -----------------------------------------------------------------------------
insert into public.benefit_types (code, name_en, name_ne, taxable) values
  ('group_medical_insurance',  'Group medical insurance',  'सामूहिक स्वास्थ्य बीमा', false),
  ('group_accident_insurance', 'Group accident insurance', 'सामूहिक दुर्घटना बीमा', false),
  ('lunch',                    'Lunch',                    'खाजा/खाना',           true),
  ('mobile_phone',             'Mobile phone and plan',    'मोबाइल फोन',          true),
  ('training',                 'Training and certification', 'तालिम',            false)
on conflict (code) do nothing;

-- Offboarding: recover outstanding loans in the final settlement.
insert into public.checklist_template_items (template_id, position, title, owner_role, due_offset_days, action)
select t.id, 7, 'Outstanding loans recovered in final settlement', 'hr', 0, 'final_settlement'
  from public.checklist_templates t where t.kind = 'offboarding' and t.name = 'Standard offboarding'
on conflict (template_id, position) do nothing;
