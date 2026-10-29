-- The audit trail records sensitive changes, redacts secrets, and cannot be altered by anyone.
begin;
select tst.mk_user('admin@t.test', 'admin')            as admin \gset
select tst.mk_user('hr@t.test', 'hr')                  as hr \gset
select tst.mk_user('emp@t.test', 'employee', :'admin') as emp \gset

select tst.claims(:'hr', true);
set local role authenticated;
insert into salary_records (user_id, effective_from_ad, basic_paisa, reason) values (:'emp', '2026-07-17', 4000000, 'opening');
insert into employee_bank_details (user_id, pan_enc, pan_last4, bank_account_enc, bank_account_last4)
values (:'emp', '\xdeadbeef', '1234', '\xcafebabe', '5678');
update employee_bank_details set bank_account_enc = '\x00ff', bank_account_last4 = '9999' where user_id = :'emp';
update employee_profiles set phone = '98XXXXXXXX' where user_id = :'emp';
reset role;

select tst.ok(exists (select 1 from audit_log where target_table = 'salary_records' and action = 'insert' and actor_id = :'hr'::uuid
                        and (details ->> 'basic_paisa')::bigint = 4000000), 'salary insert audited with value');
select tst.ok(not exists (select 1 from audit_log where target_table = 'employee_bank_details'
                            and (details ? 'pan_enc' or details ? 'bank_account_enc' and details -> 'bank_account_enc' ? 'from')),
              'encrypted bank fields never copied into the log');
select tst.ok(exists (select 1 from audit_log where target_table = 'employee_bank_details' and action = 'update'
                        and details -> 'bank_account_enc' ->> 'changed' = 'true'), 'bank change noted by name only');
select tst.ok(exists (select 1 from audit_log where target_table = 'employee_profiles' and action = 'update'
                        and details -> 'phone' ->> 'changed' = 'true' and not (details -> 'phone' ? 'to')),
              'phone change redacted');

-- Role change by admin is audited.
select tst.claims(:'admin', true);
set local role authenticated;
update profiles set role = 'manager' where id = :'emp';
reset role;
select tst.ok(exists (select 1 from audit_log where target_table = 'profiles' and target_id = :'emp'
                        and details -> 'role' ->> 'to' = 'manager' and actor_id = :'admin'::uuid), 'role change audited');

-- Nobody can alter or delete the log — not even the database owner.
select tst.fails('update audit_log set action = ''nothing''', 'append-only');
select tst.fails('delete from audit_log', 'append-only');
rollback;
