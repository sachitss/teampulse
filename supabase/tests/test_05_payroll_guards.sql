-- Payroll refuses to guess, locks after approval, freezes its rules, and never shows pay to managers.
begin;
select tst.mk_user('admin@t.test', 'admin')            as admin \gset
select tst.mk_user('hr@t.test', 'hr')                  as hr \gset
select tst.mk_user('mgr@t.test', 'manager', :'admin')  as mgr \gset
select tst.mk_user('emp@t.test', 'employee', :'mgr')   as emp \gset
insert into salary_records (user_id, effective_from_ad, basic_paisa, reason)
values (:'emp', '2026-07-17', 5000000, 'opening') returning id as sal \gset

-- No rules for FY 2084/85 yet → Shrawan 2084 cannot be started.
select tst.fails('insert into payroll_runs (bs_year, bs_month) values (2084, 4)', 'missing rules');

-- Incomplete tax slabs → refused (simulate the accountant deleting the top band).
savepoint s1;
delete from tax_slabs where fiscal_year = '2083/84' and band = 5;
select tst.ok(not app.tax_slabs_complete('2083/84'), 'gap detected');
select tst.fails('insert into payroll_runs (bs_year, bs_month) values (2083, 7)', 'tax slabs are incomplete');
rollback to savepoint s1;
select tst.ok(app.tax_slabs_complete('2083/84'), 'seeded FY 2083/84 slabs are contiguous');

-- Baisakh 2084 is inside FY 2083/84 but its BS calendar is provisional → flagged.
insert into payroll_runs (bs_year, bs_month) values (2084, 1) returning fiscal_year, calendar_provisional, period_start_ad \gset
select tst.ok(:'fiscal_year' = '2083/84' and :'calendar_provisional'::boolean and :'period_start_ad' = '2027-04-14',
              'Baisakh 2084 run is FY 2083/84 and flagged provisional');

-- A normal run, worked by HR.
select tst.claims(:'hr', true);
set local role authenticated;
insert into payroll_runs (bs_year, bs_month) values (2083, 7) returning id as run, is_parallel_run, period_start_ad, period_end_ad \gset
select tst.ok(:'is_parallel_run'::boolean, 'parallel-run badge on by default');
select tst.ok(:'period_start_ad' = '2026-10-18' and :'period_end_ad' = '2026-11-16', 'Kartik 2083 period from BS calendar');
insert into payroll_lines (run_id, user_id, salary_record_id, basic_paisa, gross_paisa, ssf_employee_paisa, tds_paisa, net_paisa)
values (:'run', :'emp', :'sal', 5000000, 5000000, 550000, 0, 4450000);
-- net must equal gross − deductions
select tst.fails(format('insert into payroll_adjustments (run_id, user_id, kind, amount_paisa, reason) values (%L, %L, %L, 0, %L)',
                        :'run', :'emp', 'addition', 'x'), 'check constraint');
select tst.fails(format('update payroll_lines set net_paisa = 1 where run_id = %L', :'run'), 'check constraint');
-- HR cannot approve; approval needs review first.
select tst.fails(format('update payroll_runs set status = %L where id = %L', 'approved', :'run'), 'only an admin');
update payroll_runs set status = 'review' where id = :'run';
reset role;

select tst.claims(:'admin', true);
set local role authenticated;
update payroll_runs set status = 'approved' where id = :'run';
select tst.ok((select approved_by from payroll_runs where id = :'run') = :'admin'::uuid, 'approver recorded');
select tst.ok((select rules_snapshot -> 'payroll_rules' -> 'ssf_employee_rate_bp' ->> 'value' from payroll_runs where id = :'run') = '1100',
              'rules frozen into the run');
select tst.ok((select jsonb_array_length(rules_snapshot -> 'tax_slabs') from payroll_runs where id = :'run') = 5, 'slabs frozen');
reset role;

-- Locked: lines, adjustments, status and salary versions it used can no longer change.
select tst.claims(:'hr', true);
set local role authenticated;
select tst.fails(format('update payroll_lines set tds_paisa = 1, net_paisa = 4449999 where run_id = %L', :'run'), 'locked');
select tst.fails(format('insert into payroll_adjustments (run_id, user_id, kind, amount_paisa, reason) values (%L, %L, %L, 100, %L)',
                        :'run', :'emp', 'addition', 'late bonus'), 'locked');
select tst.fails(format('update payroll_runs set status = %L where id = %L', 'draft', :'run'), 'locked');
select tst.fails(format('update salary_records set basic_paisa = 1 where id = %L', :'sal'), 'add a new version');
-- A new salary version is the right way.
insert into salary_records (user_id, effective_from_ad, basic_paisa, reason) values (:'emp', '2026-11-17', 5500000, 'Raise');
-- Changing a rule now does not change the frozen run.
update payroll_rules set value_numeric = 1200 where fiscal_year = '2083/84' and rule_key = 'ssf_employee_rate_bp';
select tst.ok((select rules_snapshot -> 'payroll_rules' -> 'ssf_employee_rate_bp' ->> 'value' from payroll_runs where id = :'run') = '1100',
              'snapshot unchanged after rule edit');
-- Publish.
update payroll_runs set status = 'published' where id = :'run';
select tst.ok((select published_at is not null from payroll_runs where id = :'run'), 'published_at set');
reset role;

select tst.fails(format('delete from payroll_runs where id = %L', :'run'), 'append-only');

-- Rules cannot be marked confirmed without who/when.
select tst.fails($$update payroll_rules set status = 'confirmed' where fiscal_year = '2083/84' and rule_key = 'tds_deposit_day'$$,
                 'check constraint');

-- Manager sees none of it; the employee sees their published line.
select tst.claims(:'mgr', false);
set local role authenticated;
select tst.ok(tst.n('select * from payroll_runs') = 0 and tst.n('select * from payroll_lines') = 0
              and tst.n('select * from payroll_rules') = 0, 'manager sees no payroll at all');
reset role;
select tst.claims(:'emp', false);
set local role authenticated;
select tst.ok(tst.n('select * from payroll_lines') = 1, 'employee sees own published line');
select tst.ok(tst.n('select * from payroll_rules') = 0, 'employee does not see internal payroll rules');
select tst.ok(tst.n('select * from tax_slabs') = 11, 'tax slabs (public law) are readable');
reset role;

rollback;
