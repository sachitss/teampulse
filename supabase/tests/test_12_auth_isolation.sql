-- Built-in sign-in tables are unreachable for signed-in people; the app login gets RLS once it acts as a person.
begin;
select tst.mk_user('emp@t.test', 'employee') as emp \gset
select tst.mk_user('other@t.test', 'employee') as other \gset
insert into auth.credentials (user_id, password_hash) values (:'emp', crypt('correct horse battery', gen_salt('bf', 4)));
insert into auth.sessions (user_id, token_hash, expires_at) values (:'emp', digest('tok', 'sha256'), now() + interval '1 day');

-- bcrypt verification works in SQL (what the sign-in code relies on).
select tst.ok((select password_hash = crypt('correct horse battery', password_hash) from auth.credentials where user_id = :'emp'), 'right password verifies');
select tst.ok((select password_hash <> crypt('wrong', password_hash) from auth.credentials where user_id = :'emp'), 'wrong password fails');
select tst.fails($$insert into auth.credentials (user_id, password_hash) values (gen_random_uuid(), 'plaintext')$$, 'check constraint');

-- A signed-in person cannot see or touch any sign-in table.
select tst.claims(:'emp', true);
set local role authenticated;
select tst.fails('select * from auth.credentials', 'permission denied');
select tst.fails('select * from auth.sessions', 'permission denied');
select tst.fails('select * from auth.mfa_factors', 'permission denied');
select tst.fails('select * from auth.one_time_tokens', 'permission denied');
select tst.fails('select * from auth.users', 'permission denied');
select tst.ok(auth.uid() = :'emp'::uuid, 'auth.uid() still works');
reset role;
set local role anon;
select tst.fails('select * from auth.credentials', 'permission denied');
reset role;

-- The app's own login: full access to auth (for sign-in) …
set local role teampulse_app;
select tst.ok((select count(*) from auth.sessions where user_id = :'emp') = 1, 'app login can read sessions');
-- … but once it switches to the signed-in person, RLS applies exactly as for that person.
select tst.claims(:'emp', false);
set local role authenticated;
select tst.ok(tst.n('select * from profiles') = 1, 'acting as emp: only own profile');
select tst.ok(tst.n(format('select * from profiles where id = %L', :'other')) = 0, 'acting as emp: cannot see a colleague');
reset role;

-- Sign-ins are audited (without the token).
select tst.ok(exists (select 1 from audit_log where action = 'sign_in' and target_id = :'emp'), 'sign-in audited');
select tst.ok(not exists (select 1 from audit_log where action = 'sign_in' and details ? 'token_hash'), 'token never logged');
rollback;
