-- Company holiday policy over the government list: decisions, optional holidays, legal minimum, approval.
begin;
select tst.mk_user('admin@t.test', 'admin')                       as admin \gset
select tst.mk_user('hr@t.test', 'hr')                             as hr \gset
select tst.mk_user('emp@t.test', 'employee', :'admin', 'female')  as emp \gset
select tst.mk_user('emp2@t.test', 'employee', :'admin', 'male')   as emp2 \gset

select tst.claims(:'hr', true);
set local role authenticated;
-- 14 gazetted holidays in FY 2083/84 (test dates on Sundays, a working day in Nepal), one women-only.
insert into government_holidays (holiday_ad, name_en, scope, gazette_ref)
select date '2026-08-02' + g * 7, 'Gov holiday ' || g, 'all', 'test gazette' from generate_series(1, 13) g;
insert into government_holidays (holiday_ad, name_en, scope) values ('2026-09-14', 'Gov women holiday', 'female');
select tst.ok(tst.n('select * from holiday_calendar') = 0, 'government list alone gives no days off');

-- The company decides: observe 11, skip 1, move 1 to another date.
update government_holidays set decision = 'observe' where name_en in
  (select 'Gov holiday ' || g from generate_series(1, 11) g) or scope = 'female';
update government_holidays set decision = 'skip', decision_note = 'Office open; replaced by company day' where name_en = 'Gov holiday 12';
update government_holidays set decision = 'move', moved_to_ad = '2026-12-25' where name_en = 'Gov holiday 13';
select tst.ok(tst.n('select * from holiday_calendar where source = ''government''') = 13, 'observed + moved copied to company calendar');
select tst.ok((select holiday_ad from holiday_calendar where name_en = 'Gov holiday 13 (observed)') = '2026-12-25', 'moved date used');
select tst.ok((select decided_by from government_holidays where name_en = 'Gov holiday 12') = :'hr'::uuid, 'decision recorded');
-- Changing a decision back removes the calendar row.
update government_holidays set decision = 'skip', decision_note = 'test' where name_en = 'Gov holiday 11';
select tst.ok(tst.n('select * from holiday_calendar where source = ''government''') = 12, 'skip removes it');

-- A company-only holiday and two optional (floating) holidays.
insert into holiday_calendar (holiday_ad, name_en, source) values ('2027-01-15', 'PEACE foundation day', 'company');
insert into holiday_calendar (holiday_ad, name_en, is_optional) values ('2027-02-10', 'Optional A', true), ('2027-03-10', 'Optional B', true);
select tst.fails($$insert into holiday_calendar (holiday_ad, name_en, source) values ('2027-01-16', 'Fake gov', 'government')$$, 'check constraint');

-- Policy: 13 minimum (+1 women); fixed all-staff = 11 gov + 1 company = 12 → needs 1 optional.
insert into holiday_policies (fiscal_year, min_paid_holidays, extra_for_women, optional_quota) values ('2083/84', 13, 1, 0);
select tst.ok((select not meets from app.holiday_policy_check('2083/84') where group_label = 'All staff'), 'below minimum detected');
-- HR cannot approve.
select tst.fails($$update holiday_policies set status = 'approved' where fiscal_year = '2083/84'$$, 'only an admin');
reset role;

select tst.claims(:'admin', true);
set local role authenticated;
select tst.fails($$update holiday_policies set status = 'approved' where fiscal_year = '2083/84'$$, 'below the legal minimum');
-- Raising the quota to 1 in the same update makes it compliant (all staff 12+1 = 13; women 12+1+1 = 14).
update holiday_policies set status = 'approved', optional_quota = 1 where fiscal_year = '2083/84';
select tst.ok((select bool_and(meets) from app.holiday_policy_check('2083/84')), 'policy meets minimum');
reset role;

-- Pending government decisions block approval (checked on a fresh year).
select tst.claims(:'hr', true);
set local role authenticated;
insert into government_holidays (holiday_ad, name_en) values ('2027-08-01', 'Next year gov holiday');
insert into holiday_policies (fiscal_year, min_paid_holidays, extra_for_women) values ('2084/85', 0, 0);
reset role;
select tst.claims(:'admin', true);
set local role authenticated;
select tst.fails($$update holiday_policies set status = 'approved' where fiscal_year = '2084/85'$$, 'decide every government holiday');
reset role;

-- Approved year is frozen for HR.
select tst.claims(:'hr', true);
set local role authenticated;
select tst.fails($$insert into holiday_calendar (holiday_ad, name_en) values ('2027-04-01', 'Late addition')$$, 'admin must reopen');
reset role;

-- Days off follow the approved policy.
select tst.ok(app.is_holiday_for(:'emp2', '2027-01-15'), 'company-only holiday counts');
select tst.ok(not app.is_holiday_for(:'emp2', (select holiday_ad from government_holidays where name_en = 'Gov holiday 12')), 'skipped gov holiday is a work day');
select tst.ok(app.is_holiday_for(:'emp', '2026-09-14') and not app.is_holiday_for(:'emp2', '2026-09-14'), 'women-only holiday');
select tst.ok(not app.is_holiday_for(:'emp2', '2027-02-10'), 'optional holiday only if chosen');

-- Employees choose optional holidays up to the quota.
select tst.claims(:'emp2', false);
set local role authenticated;
insert into employee_optional_holidays (user_id, holiday_id) select :'emp2', id from holiday_calendar where name_en = 'Optional A';
select tst.fails(format('insert into employee_optional_holidays (user_id, holiday_id) select %L, id from holiday_calendar where name_en = %L',
                        :'emp2', 'Optional B'), 'already chosen 1 of 1');
select tst.fails(format('insert into employee_optional_holidays (user_id, holiday_id) select %L, id from holiday_calendar where name_en = %L',
                        :'emp2', 'PEACE foundation day'), 'not optional');
select tst.fails(format('insert into employee_optional_holidays (user_id, holiday_id) select %L, id from holiday_calendar where name_en = %L',
                        :'emp', 'Optional B'), 'row-level security');
reset role;
select tst.ok(app.is_holiday_for(:'emp2', '2027-02-10'), 'chosen optional holiday is a day off');

-- Everyone can read the policy and lists (transparency).
select tst.claims(:'emp', false);
set local role authenticated;
select tst.ok(tst.n('select * from holiday_policies') = 2 and tst.n('select * from government_holidays') = 15, 'policy and lists readable');
reset role;
rollback;
