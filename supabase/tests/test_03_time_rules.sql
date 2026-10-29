-- Timers, manual entries, approvals, locked periods, corrections.
begin;
select tst.mk_user('admin@t.test', 'admin')                as admin \gset
select tst.mk_user('mgr@t.test', 'manager', :'admin')      as mgr \gset
select tst.mk_user('emp@t.test', 'employee', :'mgr')       as emp \gset
select tst.mk_user('other@t.test', 'employee', :'admin')   as other \gset

select tst.claims(:'emp', false);
set local role authenticated;

-- One running timer per person.
insert into time_entries (user_id, source, started_at) values (:'emp', 'web', now() - interval '1 hour') returning id as running \gset
select tst.fails(format('insert into time_entries (user_id, source, started_at) values (%L, %L, now())', :'emp', 'web'),
                 'time_entries_one_running');

-- Stop it; then overlapping time is refused.
update time_entries set ended_at = now() - interval '10 minutes' where id = :'running';
select tst.fails(format('insert into time_entries (user_id, source, started_at, ended_at) values (%L, %L, now() - interval %L, now() - interval %L)',
                        :'emp', 'web', '50 minutes', '20 minutes'), 'time_entries_no_overlap');

-- Finished time cannot be edited directly by the owner.
select tst.fails(format('update time_entries set started_at = started_at - interval %L where id = %L', '1 hour', :'running'),
                 'correction request');

-- Manual entries need a reason and start pending; owner cannot approve own.
select tst.fails(format('insert into time_entries (user_id, source, started_at, ended_at) values (%L, %L, now() - interval %L, now() - interval %L)',
                        :'emp', 'manual', '5 hours', '4 hours'), 'check constraint');
insert into time_entries (user_id, source, started_at, ended_at, reason)
values (:'emp', 'manual', now() - interval '5 hours', now() - interval '4 hours', 'Site visit, agent offline') returning id as manual \gset
select tst.ok((select approval from time_entries where id = :'manual') = 'pending', 'manual entry starts pending');
select tst.fails(format('update time_entries set approval = %L where id = %L', 'approved', :'manual'), 'correction request');

-- Employee cannot create time for someone else.
select tst.fails(format('insert into time_entries (user_id, source, started_at, ended_at) values (%L, %L, now() - interval %L, now() - interval %L)',
                        :'other', 'web', '9 hours', '8 hours'), 'row-level security');

-- Correction request; the requester cannot decide it.
insert into time_corrections (entry_id, requested_by, old_value, new_value, reason)
values (:'running', :'emp', '{"started_at":"x"}', '{"started_at":"y"}', 'Forgot to start timer') returning id as corr \gset
-- (Under RLS a forbidden UPDATE matches zero rows rather than raising.)
update time_corrections set status = 'approved' where id = :'corr';
select tst.ok((select status from time_corrections where id = :'corr') = 'pending', 'requester cannot decide own correction');
reset role;

-- Manager approves the manual entry and the correction.
select tst.claims(:'mgr', false);
set local role authenticated;
update time_entries set approval = 'approved' where id = :'manual';
select tst.ok((select approved_by from time_entries where id = :'manual') = :'mgr'::uuid, 'approver recorded');
update time_corrections set status = 'approved' where id = :'corr';
select tst.ok((select decided_by from time_corrections where id = :'corr') = :'mgr'::uuid, 'decider recorded');
-- Manager of someone else cannot touch other's time.
select tst.ok(tst.n(format('select * from time_entries where user_id = %L', :'other')) = 0, 'mgr cannot see non-report');
reset role;

-- Timesheet period for the current BS month (Kathmandu).
insert into timesheet_periods (user_id, bs_year, bs_month)
select :'emp', split_part(app.ad_to_bs(app.kathmandu_date(now())), '-', 1)::int,
               split_part(app.ad_to_bs(app.kathmandu_date(now())), '-', 2)::int
returning id as period, start_ad, end_ad \gset
select tst.ok(:'start_ad'::date <= app.kathmandu_date(now()) and :'end_ad'::date >= app.kathmandu_date(now()),
              'period dates filled from the BS calendar');

-- Employee can submit but not approve or lock.
select tst.claims(:'emp', false);
set local role authenticated;
update timesheet_periods set status = 'submitted' where id = :'period';
select tst.fails(format('update timesheet_periods set status = %L where id = %L', 'locked', :'period'), 'only submit');
reset role;

-- Manager approves and locks.
select tst.claims(:'mgr', false);
set local role authenticated;
update timesheet_periods set status = 'approved' where id = :'period';
update timesheet_periods set status = 'locked' where id = :'period';
-- Locked: no new or changed time in that month, not even by the manager.
select tst.fails(format('update time_entries set approval = %L where id = %L', 'rejected', :'manual'), 'locked timesheet period');
-- Manager cannot unlock.
select tst.fails(format('update timesheet_periods set status = %L where id = %L', 'approved', :'period'), 'only an admin');
reset role;

select tst.claims(:'emp', false);
set local role authenticated;
select tst.fails(format('insert into time_entries (user_id, source, started_at, ended_at, reason) values (%L, %L, now() - interval %L, now() - interval %L, %L)',
                        :'emp', 'manual', '7 hours', '6 hours', 'late add'), 'locked timesheet period');
reset role;

-- Admin (with MFA) can unlock; it is audited.
select tst.claims(:'admin', true);
set local role authenticated;
update timesheet_periods set status = 'approved' where id = :'period';
select tst.ok(exists (select 1 from audit_log where target_table = 'timesheet_periods' and target_id = :'period'
                        and details -> 'status' ->> 'to' = 'approved' and actor_id = :'admin'::uuid),
              'unlock by admin is audited');
reset role;

rollback;
