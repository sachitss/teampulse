-- Who can see what: employees, managers, HR, admin — with and without MFA.
begin;

select tst.mk_user('admin@t.test', 'admin')              as admin \gset
select tst.mk_user('hr@t.test', 'hr')                    as hr \gset
select tst.mk_user('mgr.a@t.test', 'manager', :'admin')  as mgr_a \gset
select tst.mk_user('mgr.b@t.test', 'manager', :'admin')  as mgr_b \gset
select tst.mk_user('emp.a1@t.test', 'employee', :'mgr_a', 'female') as a1 \gset
select tst.mk_user('emp.a2@t.test', 'employee', :'mgr_a') as a2 \gset
select tst.mk_user('emp.b1@t.test', 'employee', :'mgr_b') as b1 \gset

-- Monitoring allowed: notice confirmed and consented by a1, a2, b1.
insert into notice_versions (version, title, body_en, published_at) values (1, 'Notice', 'text', now());
update org_settings set monitoring_notice_confirmed_at = now();
insert into notice_consents (user_id, version) values (:'a1', 1), (:'a2', 1), (:'b1', 1);

-- Devices and evidence for a1 and a2.
insert into devices (user_id, hostname, machine_fingerprint, device_token_hash)
values (:'a1', 'PC-A1', 'fp-a1', 'secret-hash-a1') returning id as dev_a1 \gset
insert into devices (user_id, hostname, machine_fingerprint, device_token_hash)
values (:'a2', 'PC-A2', 'fp-a2', 'secret-hash-a2') returning id as dev_a2 \gset
insert into screenshots (id, user_id, device_id, captured_at, status, storage_key)
values (gen_random_uuid(), :'a1', :'dev_a1', now(), 'stored', 'a1/1.jpg') returning id as shot_a1 \gset
insert into screenshots (id, user_id, device_id, captured_at, status, storage_key)
values (gen_random_uuid(), :'a2', :'dev_a2', now(), 'stored', 'a2/1.jpg');
insert into app_events (event_id, user_id, device_id, started_at, ended_at, app_name)
values (gen_random_uuid(), :'a1', :'dev_a1', now() - interval '5 min', now(), 'Revit.exe');

-- Work data.
insert into time_entries (user_id, source, started_at, ended_at)
values (:'a1', 'web', now() - interval '3 hours', now() - interval '2 hours'),
       (:'a2', 'web', now() - interval '3 hours', now() - interval '2 hours'),
       (:'b1', 'web', now() - interval '3 hours', now() - interval '2 hours');

-- Pay data.
insert into salary_records (user_id, effective_from_ad, basic_paisa, reason)
values (:'a1', '2026-07-17', 5000000, 'test') returning id as sal_a1 \gset
insert into salary_records (user_id, effective_from_ad, basic_paisa, reason)
values (:'a2', '2026-07-17', 6000000, 'test') returning id as sal_a2 \gset
insert into employee_bank_details (user_id, pan_last4, bank_account_last4) values (:'a1', '1234', '9876');

-- A published run (Kartik 2083) and a draft run (Mangsir 2083), both with a line for a1.
insert into payroll_runs (bs_year, bs_month) values (2083, 7) returning id as run_pub \gset
insert into payroll_lines (run_id, user_id, salary_record_id, basic_paisa, gross_paisa, ssf_employee_paisa, net_paisa)
values (:'run_pub', :'a1', :'sal_a1', 5000000, 5000000, 550000, 4450000),
       (:'run_pub', :'a2', :'sal_a2', 6000000, 6000000, 660000, 5340000);
update payroll_runs set status = 'review'    where id = :'run_pub';
update payroll_runs set status = 'approved'  where id = :'run_pub';
update payroll_runs set status = 'published' where id = :'run_pub';
insert into payroll_runs (bs_year, bs_month) values (2083, 8) returning id as run_draft \gset
insert into payroll_lines (run_id, user_id, salary_record_id, basic_paisa, gross_paisa, ssf_employee_paisa, net_paisa)
values (:'run_draft', :'a1', :'sal_a1', 5000000, 5000000, 550000, 4450000);

-- ---------------------------------------------------------------- employee a1
select tst.claims(:'a1', false);   -- employees need no MFA
set local role authenticated;
select tst.ok(tst.n('select * from profiles') = 2, 'a1 sees self + own manager only');
select tst.ok(tst.n('select * from screenshots') = 1, 'a1 sees only own screenshots');
select tst.ok(tst.n('select * from app_events') = 1, 'a1 sees own app events');
select tst.ok(tst.n('select * from time_entries') = 1, 'a1 sees only own time');
select tst.ok(tst.n('select * from salary_records') = 1, 'a1 sees only own salary');
select tst.ok(tst.n('select * from payroll_lines') = 1, 'a1 sees only own line of the PUBLISHED run (not the draft)');
select tst.ok(tst.n('select * from payroll_runs') = 1, 'a1 sees only the published run');
select tst.ok(tst.n('select * from employee_bank_details') = 1, 'a1 sees own bank summary');
select tst.ok(tst.n('select * from audit_log') = 0, 'a1 cannot read the audit log');
select tst.fails('select device_token_hash from devices', 'permission denied');
select tst.ok(app.screenshot_key_for_view(gen_random_uuid()) is null, 'unknown screenshot returns no key');
select tst.fails(format('update profiles set role = %L where id = %L', 'admin', :'a1'), 'only change your own display name');
update profiles set full_name = 'A1 Renamed' where id = :'a1';
select tst.ok((select full_name from profiles where id = :'a1') = 'A1 Renamed', 'a1 can rename self');
reset role;

-- ---------------------------------------------------------------- manager A
select tst.claims(:'mgr_a', false);
set local role authenticated;
select tst.ok(tst.n('select * from profiles') = 4, 'mgr_a sees self, own manager (admin), a1, a2');
select tst.ok(tst.n('select * from screenshots') = 2, 'mgr_a sees team screenshots');
select tst.ok(tst.n('select * from time_entries') = 2, 'mgr_a sees team time, not team B');
select tst.ok(tst.n('select * from salary_records') = 0, 'manager must NOT see salaries');
select tst.ok(tst.n('select * from salary_allowances') = 0, 'manager must NOT see allowances');
select tst.ok(tst.n('select * from payroll_lines') = 0, 'manager must NOT see payroll lines');
select tst.ok(tst.n('select * from payroll_runs') = 0, 'manager must NOT see payroll runs');
select tst.ok(tst.n('select * from employee_bank_details') = 0, 'manager must NOT see bank details');
select tst.ok(tst.n('select * from employee_profiles') = 1, 'manager sees only own personal record');
select tst.ok(app.screenshot_key_for_view(:'shot_a1') = 'a1/1.jpg', 'manager can open team screenshot');
reset role;

-- ---------------------------------------------------------------- manager B (other team)
select tst.claims(:'mgr_b', false);
set local role authenticated;
select tst.ok(tst.n('select * from screenshots') = 0, 'mgr_b sees no team-A screenshots');
select tst.ok(app.screenshot_key_for_view(:'shot_a1') is null, 'mgr_b gets no key for team-A screenshot');
reset role;

-- ---------------------------------------------------------------- HR with MFA
select tst.claims(:'hr', true);
set local role authenticated;
select tst.ok(tst.n('select * from salary_records') = 2, 'HR sees all salaries');
select tst.ok(tst.n('select * from payroll_lines') = 3, 'HR sees all payroll lines incl. drafts');
select tst.ok(tst.n('select * from time_entries') = 3, 'HR sees all time (needed for attendance)');
select tst.ok(tst.n('select * from employee_profiles') = 7, 'HR sees all personal records');
select tst.ok(tst.n('select * from screenshots') = 0, 'HR must NOT see screenshots');
select tst.ok(tst.n('select * from app_events') = 0, 'HR must NOT see app activity');
select tst.ok(app.screenshot_key_for_view(:'shot_a1') is null, 'HR gets no screenshot key');
reset role;

-- ---------------------------------------------------------------- HR without MFA
select tst.claims(:'hr', false);
set local role authenticated;
select tst.ok(tst.n('select * from salary_records') = 0, 'HR without MFA gets employee rights only');
select tst.fails(format('insert into salary_records (user_id, effective_from_ad, basic_paisa, reason) values (%L, %L, 1, %L)',
                        :'b1', '2026-07-17', 'x'), 'row-level security');
reset role;

-- ---------------------------------------------------------------- admin with and without MFA
select tst.claims(:'admin', true);
set local role authenticated;
select tst.ok(tst.n('select * from screenshots') = 2, 'admin sees all screenshots');
select tst.ok(tst.n('select * from salary_records') = 2, 'admin sees all salaries');
select tst.ok(tst.n('select * from audit_log where action = ''view_screenshot''') = 1, 'manager screenshot view was audited');
select tst.ok(tst.n('select * from audit_log where action = ''view_screenshot_denied''') >= 2, 'denied views were audited');
reset role;
select tst.claims(:'admin', false);
set local role authenticated;
select tst.ok(tst.n('select * from salary_records') = 0, 'admin without MFA gets no admin rights');
select tst.ok(tst.n('select * from audit_log') = 0, 'admin without MFA cannot read audit log');
reset role;

rollback;
