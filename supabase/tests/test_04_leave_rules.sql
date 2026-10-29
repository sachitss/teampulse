-- Leave decisions, statutory rights, overlap, ledger, holidays.
begin;
select tst.mk_user('admin@t.test', 'admin')                          as admin \gset
select tst.mk_user('hr@t.test', 'hr')                                as hr \gset
select tst.mk_user('mgr@t.test', 'manager', :'admin')                as mgr \gset
select tst.mk_user('emp@t.test', 'employee', :'mgr', 'female')       as emp \gset
select tst.mk_user('emp2@t.test', 'employee', :'mgr', 'male')        as emp2 \gset
select id as sick from leave_types where code = 'sick' \gset
select id as home from leave_types where code = 'home' \gset
select id as mourning from leave_types where code = 'mourning' \gset

select tst.claims(:'emp', false);
set local role authenticated;
insert into leave_requests (user_id, leave_type_id, start_ad, end_ad, days, reason)
values (:'emp', :'sick', '2026-11-02', '2026-11-03', 2, 'Fever') returning id as sick_req, start_bs \gset
select tst.ok(:'start_bs' = '2083-07-16', 'BS date filled automatically (2 Nov 2026 = 16 Kartik 2083)');
insert into leave_requests (user_id, leave_type_id, start_ad, end_ad, days)
values (:'emp', :'home', '2026-12-01', '2026-12-02', 2) returning id as home_req \gset
-- Overlapping request refused.
select tst.fails(format('insert into leave_requests (user_id, leave_type_id, start_ad, end_ad, days) values (%L, %L, %L, %L, 1)',
                        :'emp', :'home', '2026-11-03', '2026-11-03'), 'leave_requests_no_overlap');
-- Cannot approve own request.
select tst.fails(format('update leave_requests set status = %L where id = %L', 'approved', :'home_req'), 'own leave request');
-- Cannot request leave for someone else.
select tst.fails(format('insert into leave_requests (user_id, leave_type_id, start_ad, end_ad, days) values (%L, %L, %L, %L, 1)',
                        :'emp2', :'home', '2026-12-10', '2026-12-10'), 'row-level security');
reset role;

-- Manager: may reject home leave, may NOT reject sick leave (statutory right), may request documents.
select tst.claims(:'mgr', false);
set local role authenticated;
update leave_requests set status = 'rejected', decision_comment = 'Deadline week' where id = :'home_req';
select tst.ok((select decided_by from leave_requests where id = :'home_req') = :'mgr'::uuid, 'decider recorded');
select tst.fails(format('update leave_requests set status = %L where id = %L', 'rejected', :'sick_req'), 'statutory right');
update leave_requests set status = 'documents_requested', decision_comment = 'Please upload certificate' where id = :'sick_req';
update leave_requests set status = 'approved' where id = :'sick_req';
reset role;

-- HR can reject statutory leave only with a logged override reason.
select tst.claims(:'emp2', false);
set local role authenticated;
insert into leave_requests (user_id, leave_type_id, start_ad, end_ad, days) values (:'emp2', :'mourning', '2026-11-20', '2026-11-20', 1)
returning id as mourn_req \gset
reset role;
select tst.claims(:'hr', true);
set local role authenticated;
select tst.fails(format('update leave_requests set status = %L where id = %L', 'rejected', :'mourn_req'), 'override reason');
update leave_requests set status = 'rejected', hr_override_reason = 'Duplicate of request filed on paper' where id = :'mourn_req';
reset role;

-- Ledger: HR adds balances; append-only; balance view sums.
select tst.claims(:'hr', true);
set local role authenticated;
insert into leave_ledger (user_id, leave_type_id, entry_ad, kind, days, reason) values
  (:'emp', :'home', '2026-07-17', 'opening_balance', 10, 'Carried over from paper records'),
  (:'emp', :'home', '2026-08-17', 'accrual', 1.5, null),
  (:'emp', :'home', '2026-09-01', 'usage', -2, null);
select tst.ok((select balance_days from leave_balances where user_id = :'emp' and leave_type_id = :'home') = 9.5, 'balance = sum of ledger');
select tst.ok((select fiscal_year from leave_ledger where user_id = :'emp' and kind = 'opening_balance') = '2083/84', 'ledger fiscal year filled');
select tst.fails(format('insert into leave_ledger (user_id, leave_type_id, entry_ad, kind, days) values (%L, %L, %L, %L, 2)',
                        :'emp', :'home', '2026-09-02', 'usage'), 'check constraint');   -- usage must be negative
select tst.fails(format('insert into leave_ledger (user_id, leave_type_id, entry_ad, kind, days) values (%L, %L, %L, %L, 2)',
                        :'emp', :'home', '2026-09-02', 'adjustment'), 'check constraint');   -- adjustment needs a reason
reset role;
select tst.fails(format('update leave_ledger set days = 100 where user_id = %L', :'emp'), 'append-only');
select tst.fails(format('delete from leave_ledger where user_id = %L', :'emp'), 'append-only');

-- Employees cannot write the ledger.
select tst.claims(:'emp', false);
set local role authenticated;
select tst.fails(format('insert into leave_ledger (user_id, leave_type_id, entry_ad, kind, days) values (%L, %L, %L, %L, 50)',
                        :'emp', :'home', '2026-09-02', 'accrual'), 'row-level security');
select tst.ok(tst.n('select * from leave_balances') = 1, 'employee sees own balance');
reset role;

-- Holidays: weekly holiday (Saturday) and scoped public holidays.
insert into holiday_calendar (holiday_ad, name_en, scope) values ('2026-11-09', 'Test holiday', 'all'),
                                                                 ('2026-09-14', 'Test women holiday', 'female');
select tst.ok(app.is_holiday_for(:'emp', '2026-10-31'), 'Saturday is a weekly holiday');
select tst.ok(not app.is_holiday_for(:'emp', '2026-11-01'), 'Sunday is a working day in Nepal');
select tst.ok(app.is_holiday_for(:'emp2', '2026-11-09'), 'all-staff holiday applies to everyone');
select tst.ok(app.is_holiday_for(:'emp', '2026-09-14'), 'women-only holiday applies to a woman');
select tst.ok(not app.is_holiday_for(:'emp2', '2026-09-14'), 'women-only holiday does not apply to a man');
select tst.ok((select fiscal_year from holiday_calendar where name_en = 'Test holiday') = '2083/84', 'holiday fiscal year filled');

rollback;
