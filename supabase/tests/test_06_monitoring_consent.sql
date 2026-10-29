-- No evidence without a confirmed notice and the employee's consent; evidence shape limits.
begin;
select tst.mk_user('admin@t.test', 'admin')           as admin \gset
select tst.mk_user('emp@t.test', 'employee', :'admin') as emp \gset
select tst.mk_user('emp2@t.test', 'employee', :'admin') as emp2 \gset
insert into devices (user_id, hostname, machine_fingerprint, device_token_hash) values (:'emp', 'PC1', 'fp1', 'h1') returning id as dev \gset
insert into devices (user_id, hostname, machine_fingerprint, device_token_hash) values (:'emp2', 'PC2', 'fp2', 'h2') returning id as dev2 \gset

-- 1. Nothing confirmed yet → refused (this runs as the server/service role, which bypasses RLS).
select tst.fails(format('insert into screenshots (id, user_id, device_id, captured_at) values (gen_random_uuid(), %L, %L, now())', :'emp', :'dev'),
                 'monitoring is not allowed');

-- 2. Notice published but admin has not confirmed issuing it → still refused.
insert into notice_versions (version, title, body_en, published_at) values (1, 'Notice v1', 'text', now());
insert into notice_consents (user_id, version) values (:'emp', 1);
select tst.fails(format('insert into app_events (event_id, user_id, device_id, started_at, ended_at, app_name) values (gen_random_uuid(), %L, %L, now(), now(), %L)',
                        :'emp', :'dev', 'x.exe'), 'monitoring is not allowed');

-- 3. Confirmed, but emp2 has not consented → refused for emp2, allowed for emp.
update org_settings set monitoring_notice_confirmed_at = now(), monitoring_notice_confirmed_by = :'admin';
insert into app_events (event_id, user_id, device_id, started_at, ended_at, app_name)
values (gen_random_uuid(), :'emp', :'dev', now() - interval '1 min', now(), 'Revit.exe');
select tst.fails(format('insert into app_events (event_id, user_id, device_id, started_at, ended_at, app_name) values (gen_random_uuid(), %L, %L, now(), now(), %L)',
                        :'emp2', :'dev2', 'x.exe'), 'monitoring is not allowed');

-- 4. A new notice version needs fresh consent.
insert into notice_versions (version, title, body_en, published_at) values (2, 'Notice v2', 'text v2', now());
select tst.ok(not app.monitoring_allowed(:'emp'), 'consent to v1 does not cover v2');
insert into notice_consents (user_id, version) values (:'emp', 2);
select tst.ok(app.monitoring_allowed(:'emp'), 'consent to v2 restores monitoring');
select tst.fails(format('delete from notice_consents where user_id = %L', :'emp'), 'append-only');

-- Evidence must come from the user's own device.
select tst.fails(format('insert into app_events (event_id, user_id, device_id, started_at, ended_at, app_name) values (gen_random_uuid(), %L, %L, now(), now(), %L)',
                        :'emp', :'dev2', 'x.exe'), 'foreign key');

-- Websites: domain only — a full URL is refused.
insert into web_events (event_id, user_id, device_id, started_at, ended_at, domain) values (gen_random_uuid(), :'emp', :'dev', now(), now(), 'github.com');
select tst.fails(format('insert into web_events (event_id, user_id, device_id, started_at, ended_at, domain) values (gen_random_uuid(), %L, %L, now(), now(), %L)',
                        :'emp', :'dev', 'github.com/peace/secret?token=abc'), 'check constraint');

-- Input metrics: counts only — the table has no column that could hold text.
select tst.ok(not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'input_metrics'
                           and data_type in ('text', 'character varying', 'character', 'json', 'jsonb', 'bytea')),
              'input_metrics cannot store typed content');

-- Duplicate upload of the same event_id is refused (dedup key), so replay is safe.
select gen_random_uuid() as ev \gset
insert into input_metrics (event_id, user_id, device_id, recorded_at, window_seconds, key_events, mouse_events, active)
values (:'ev', :'emp', :'dev', now(), 60, 120, 300, true);
select tst.fails(format('insert into input_metrics (event_id, user_id, device_id, recorded_at, window_seconds, key_events, mouse_events, active) values (%L, %L, %L, now(), 60, 1, 1, true)',
                        :'ev', :'emp', :'dev'), 'duplicate key');

-- No manager-triggered screenshots in Lite.
select tst.fails(format($q$insert into screenshots (id, user_id, device_id, captured_at, reason) values (gen_random_uuid(), %L, %L, now(), 'manager_request')$q$,
                        :'emp', :'dev'), 'check constraint');

-- Signed-in users cannot write evidence at all (only the server, after authenticating the device).
select tst.claims(:'emp', false);
set local role authenticated;
select tst.fails(format('insert into app_events (event_id, user_id, device_id, started_at, ended_at, app_name) values (gen_random_uuid(), %L, %L, now(), now(), %L)',
                        :'emp', :'dev', 'fake.exe'), 'row-level security');
-- Employees can read the policy (right to know what is collected).
select tst.ok(tst.n('select * from policies') = 1, 'employee can read the monitoring policy');
reset role;

-- Offboarding schedules agent revocation for the exit date (started by HR).
select tst.mk_user('hr@t.test', 'hr') as hr \gset
select tst.claims(:'hr', true);
insert into checklists (user_id, kind, anchor_date) values (:'emp', 'offboarding', '2026-12-31');
select tst.ok((select revoke_scheduled_for from devices where id = :'dev') = '2026-12-31', 'agent revocation scheduled');
select tst.ok((select exit_date from profiles where id = :'emp') = '2026-12-31', 'exit date recorded');

rollback;
