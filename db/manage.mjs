#!/usr/bin/env node
// TeamPulse database manager — runs inside the app container on the NAS.
//
//   node db/manage.mjs migrate                       apply new migrations + reference data (safe to re-run)
//   node db/manage.mjs create-admin <email> "<Full name>"
//                                                    first admin on a fresh install; prints an invitation link
//   node db/manage.mjs reset-link <email>            password reset link for anyone (e.g. a locked-out sole admin)
//   node db/manage.mjs reset-mfa <email>             remove someone's two-factor (lost phone, no other admin)
//   node db/manage.mjs load-demo | remove-demo       demo data — refused once real employees exist
//   node db/manage.mjs status                        what is applied, how many people, last backup check
//
// Needs DATABASE_ADMIN_URL (the database owner, e.g. postgres) — never given to the web app.
// APP_DB_PASSWORD, if set, becomes the password of the web app's own login (teampulse_app).
import { readFileSync, readdirSync } from 'node:fs';
import { createHash, randomBytes } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import pg from 'pg';

const DIR = fileURLToPath(new URL('.', import.meta.url));
const sha256 = (s) => createHash('sha256').update(s).digest();
const say = (...a) => console.log(...a);
const die = (msg) => { console.error(`\n✖ ${msg}\n`); process.exit(1); };

const url = process.env.DATABASE_ADMIN_URL;
if (!url) die('DATABASE_ADMIN_URL is not set.');
const client = new pg.Client({ connectionString: url });

const sqlFiles = (sub) => readdirSync(`${DIR}${sub}`).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => ({ name: `${sub}/${f}`, sql: readFileSync(`${DIR}${sub}/${f}`, 'utf8') }));

async function waitForDatabase() {
  for (let i = 1; ; i++) {
    try { await client.connect(); return; } catch (e) {
      if (i >= 30) die(`Cannot reach the database: ${e.message}`);
      say(`… waiting for the database (${i})`);
      await new Promise((r) => setTimeout(r, 2000));
    }
  }
}

async function migrate() {
  await client.query(`select pg_advisory_lock(727274)`);   // one runner at a time
  await client.query(`create table if not exists public.schema_migrations (
                        name text primary key, checksum text not null, applied_at timestamptz not null default now())`);
  const done = new Map((await client.query(`select name, checksum from public.schema_migrations`)).rows.map((r) => [r.name, r.checksum]));
  let applied = 0;
  for (const m of sqlFiles('migrations')) {
    const sum = sha256(m.sql).toString('hex');
    if (done.has(m.name)) {
      if (done.get(m.name) !== sum) die(`${m.name} was changed after it was applied. Migrations must never be edited — add a new one.`);
      continue;
    }
    say(`→ ${m.name}`);
    try {
      await client.query('begin');
      await client.query(m.sql);
      await client.query(`insert into public.schema_migrations (name, checksum) values ($1, $2)`, [m.name, sum]);
      await client.query('commit');
      applied++;
    } catch (e) {
      await client.query('rollback');
      die(`${m.name} failed: ${e.message}\nNothing from this file was applied.`);
    }
  }
  // Reference data is idempotent (never overwrites confirmed rows), so it is re-applied every time.
  for (const s of sqlFiles('seed')) {
    try { await client.query('begin'); await client.query(s.sql); await client.query('commit'); }
    catch (e) { await client.query('rollback'); die(`${s.name} failed: ${e.message}`); }
  }
  const pw = process.env.APP_DB_PASSWORD;
  if (pw) {
    if (pw.length < 20) die('APP_DB_PASSWORD must be at least 20 characters.');
    await client.query(`alter role teampulse_app with login password ${client.escapeLiteral(pw)}`);
  }
  await client.query(`select pg_advisory_unlock(727274)`);
  say(`✔ database up to date (${applied} new migration${applied === 1 ? '' : 's'}; reference data checked)`);
}

function appUrl(path) {
  return `${(process.env.APP_BASE_URL ?? 'https://teampulse.example').replace(/\/$/, '')}${path}`;
}

async function issueLink(userId, kind) {
  const token = randomBytes(32).toString('base64url');
  const ttl = kind === 'invite' ? '72 hours' : '1 hour';
  await client.query(`update auth.one_time_tokens set used_at = now() where user_id = $1 and kind = $2 and used_at is null`, [userId, kind]);
  await client.query(`insert into auth.one_time_tokens (token_hash, user_id, kind, expires_at) values ($1, $2, $3, now() + $4::interval)`,
                     [sha256(token), userId, kind, ttl]);
  return appUrl(`/set-password?token=${token}`);
}

async function userByEmail(email) {
  const r = await client.query(`select u.id, p.full_name, p.role from auth.users u left join profiles p on p.id = u.id where lower(u.email) = lower($1)`, [email]);
  if (!r.rows[0]) die(`No account with email ${email}.`);
  return r.rows[0];
}

async function createAdmin(email, name) {
  if (!email || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) die('Usage: create-admin <email> "<Full name>"');
  if (!name || name.trim().length < 2) die('Give the full name in quotes, e.g. create-admin director@peace.com.np "Ram Shrestha"');
  await client.query('begin');
  const exists = await client.query(`select 1 from auth.users where lower(email) = lower($1)`, [email]);
  if (exists.rowCount) { await client.query('rollback'); die('That email already has an account. Use reset-link instead.'); }
  const u = await client.query(`insert into auth.users (email) values (lower($1)) returning id`, [email]);
  const id = u.rows[0].id;
  await client.query(`insert into profiles (id, email, full_name, role, job_title) values ($1, lower($2), $3, 'admin', 'Administrator')`, [id, email, name.trim()]);
  await client.query(`insert into employee_profiles (user_id) values ($1)`, [id]);
  await client.query(`insert into audit_log (actor_kind, action, target_table, target_id, details)
                      values ('system', 'admin_created_from_console', 'profiles', $1, jsonb_build_object('email', lower($2)))`, [id, email]);
  const link = await issueLink(id, 'invite');
  await client.query('commit');
  say(`\n✔ Admin account created for ${name.trim()} <${email}>.\n\nOpen this link to choose the password (valid 72 hours, works once):\n\n  ${link}\n`);
  say('After the password, TeamPulse asks you to set up an authenticator app — admin rights need it.\n');
}

async function demo(load) {
  if (load) {
    const real = await client.query(`select count(*)::int as n from profiles where not is_demo`);
    if (real.rows[0].n > 0) die('Real employees exist in this database. Demo data is only for a separate trial install.');
  }
  await client.query(readFileSync(`${DIR}demo/${load ? 'demo_load' : 'demo_remove'}.sql`, 'utf8'));
  say(load ? '✔ demo data loaded — every demo account uses the password  demo-password-CHANGE-ME' : '✔ demo data removed');
}

async function status() {
  const m = await client.query(`select count(*)::int as n, max(applied_at) as last from public.schema_migrations`).catch(() => ({ rows: [{ n: 0 }] }));
  const p = await client.query(`select role, count(*)::int as n from profiles where active group by role order by role`).catch(() => ({ rows: [] }));
  say(`migrations applied: ${m.rows[0].n}${m.rows[0].last ? ` (last ${m.rows[0].last.toISOString()})` : ''}`);
  say(`active people: ${p.rows.map((r) => `${r.n} ${r.role}`).join(', ') || 'none yet'}`);
}

const [cmd = 'migrate', ...args] = process.argv.slice(2);
await waitForDatabase();
try {
  switch (cmd) {
    case 'migrate': await migrate(); break;
    case 'create-admin': await createAdmin(args[0], args.slice(1).join(' ')); break;
    case 'reset-link': {
      const u = await userByEmail(args[0] ?? '');
      say(`\nPassword link for ${u.full_name ?? args[0]} (valid 1 hour, works once):\n\n  ${await issueLink(u.id, 'reset')}\n`);
      break;
    }
    case 'reset-mfa': {
      const u = await userByEmail(args[0] ?? '');
      await client.query(`delete from auth.mfa_factors where user_id = $1`, [u.id]);
      await client.query(`update auth.sessions set aal = 'aal1' where user_id = $1`, [u.id]);
      await client.query(`insert into audit_log (actor_kind, action, target_table, target_id) values ('system', 'mfa_reset_from_console', 'auth.mfa_factors', $1)`, [u.id]);
      say(`✔ two-factor removed for ${u.full_name ?? args[0]}; they set it up again at next sign-in.`);
      break;
    }
    case 'load-demo': await demo(true); break;
    case 'remove-demo': await demo(false); break;
    case 'status': await status(); break;
    default: die(`Unknown command "${cmd}". Commands: migrate, create-admin, reset-link, reset-mfa, load-demo, remove-demo, status`);
  }
} finally {
  await client.end();
}
