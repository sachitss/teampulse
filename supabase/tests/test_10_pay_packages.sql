-- Pay grades and the package overview: correct sums, grade fit, honest flags, and privacy.
begin;
select tst.mk_user('admin@t.test', 'admin')            as admin \gset
select tst.mk_user('hr@t.test', 'hr')                  as hr \gset
select tst.mk_user('mgr@t.test', 'manager', :'admin')  as mgr \gset
select tst.mk_user('emp@t.test', 'employee', :'mgr')   as emp \gset
select tst.mk_user('emp2@t.test', 'employee', :'mgr')  as emp2 \gset

select tst.claims(:'hr', true);
set local role authenticated;
insert into allowance_types (code, name_en, part_of_basic) values ('transport', 'Transport', false), ('grade_pay', 'Grade pay', true);
insert into pay_grades (code, name, effective_from_ad, basic_min_paisa, basic_max_paisa, increment_paisa)
values ('E2', 'Engineer II', '2026-07-17', 4000000, 6000000, 150000) returning id as g2 \gset
insert into pay_grade_allowances (grade_id, allowance_type_id, amount_paisa)
select :'g2', id, 300000 from allowance_types where code = 'transport';

-- emp: basic 50,000; transport 3,000; grade pay 2,000 (counts toward basic for SSF); insurance worth 12,000/yr.
insert into salary_records (user_id, effective_from_ad, basic_paisa, reason, pay_grade_id)
values (:'emp', '2026-07-17', 5000000, 'opening', :'g2') returning id as sal \gset
insert into salary_allowances (salary_record_id, allowance_type_id, amount_paisa)
select :'sal', id, case code when 'transport' then 300000 else 200000 end from allowance_types where code in ('transport', 'grade_pay');
insert into employee_benefits (user_id, benefit_type_id, annual_value_paisa, start_ad)
select :'emp', id, 1200000, '2026-07-17' from benefit_types where code = 'group_medical_insurance';
-- An expired benefit must not count.
insert into employee_benefits (user_id, benefit_type_id, annual_value_paisa, start_ad, end_ad)
select :'emp', id, 9999900, '2025-07-17', '2026-07-16' from benefit_types where code = 'lunch';
-- A future salary version must not count yet.
insert into salary_records (user_id, effective_from_ad, basic_paisa, reason, pay_grade_id) values (:'emp', '2030-01-01', 1, 'future', :'g2');
-- emp2: outside the grade range, not SSF-enrolled.
insert into salary_records (user_id, effective_from_ad, basic_paisa, reason, pay_grade_id, ssf_enrolled)
values (:'emp2', '2026-07-17', 7000000, 'opening', :'g2', false);

select basic_monthly_paisa b, allowances_monthly_paisa a, gross_monthly_paisa g, ssf_employee_monthly_paisa see,
       ssf_employer_monthly_paisa ser, festival_allowance_annual_paisa fest, benefits_annual_paisa ben,
       cash_pay_annual_paisa cash, cost_to_company_annual_paisa ctc, position_in_range_pct pos, outside_grade_range out,
       rules_missing rm, rules_unconfirmed ru
  from pay_package_overview where user_id = :'emp' \gset
select tst.ok(:'b'::bigint = 5000000 and :'a'::bigint = 500000 and :'g'::bigint = 5500000, 'monthly basic, allowances, gross');
-- SSF on basic + allowances that count as basic: (50,000 + 2,000) × 11% = 5,720; × 20% = 10,400
select tst.ok(:'see'::bigint = 572000 and :'ser'::bigint = 1040000, 'SSF uses basic incl. part-of-basic allowances');
select tst.ok(:'fest'::bigint = 5000000, 'festival allowance = 1 month basic');
select tst.ok(:'ben'::bigint = 1200000, 'only current benefits counted');
-- cash: 55,000 × 12 + 50,000 = 7,10,000.  CTC: + 10,400 × 12 + 12,000 = 8,46,800
select tst.ok(:'cash'::bigint = 71000000 and :'ctc'::bigint = 84680000, 'annual cash pay and cost to company');
select tst.ok(:'pos'::numeric = 50.0 and not :'out'::boolean, '50% through the E2 range');
select tst.ok(not :'rm'::boolean and :'ru'::boolean, 'rules present but flagged unconfirmed');

select tst.ok((select outside_grade_range and ssf_employer_monthly_paisa = 0 from pay_package_overview where user_id = :'emp2'),
              'emp2 flagged outside range; no SSF when not enrolled');
select tst.ok((select headcount = 2 and outside_range_count = 1 and standard_allowances_paisa = 300000
                 from pay_grade_overview where code = 'E2'), 'grade overview');
reset role;

-- Employee sees only their own package, and not the grade table.
select tst.claims(:'emp', false);
set local role authenticated;
select tst.ok(tst.n('select * from pay_package_overview') = 1, 'employee sees own package');
select tst.ok(tst.n('select * from pay_grades') = 0, 'employee cannot see the grade structure');
select tst.ok(tst.n('select * from employee_benefits') = 2, 'employee sees own benefits');
reset role;

-- Manager sees no pay at all.
select tst.claims(:'mgr', false);
set local role authenticated;
select tst.ok(tst.n('select * from pay_package_overview') = 0 and tst.n('select * from pay_grade_overview') = 0
              and tst.n('select * from employee_benefits') = 0, 'manager sees no packages');
reset role;

-- Missing rules are reported, not guessed.
delete from payroll_rules where rule_key = 'ssf_employer_rate_bp';
select tst.ok((select rules_missing from pay_package_overview where user_id = :'emp'), 'missing rule flagged');
rollback;
