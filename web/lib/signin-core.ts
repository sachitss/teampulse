// Sign-in rules, independent of the web framework so they can be tested against the
// database directly. Every function takes a server-side Db (the app's own login, which
// may read schema auth). Nothing here ever runs as a signed-in person.
import type { Db } from './db.ts';
import { sha256, randomToken, encrypt, decrypt, newTotpSecret, verifyTotp } from './crypto.ts';

export class SignInError extends Error {}

export const POLICY = {
  maxFailedAttempts: 5,
  lockMinutes: 15,
  minPasswordLength: 12,
  bcryptCost: 11,
  /** Ordinary sessions: 14 days, signed out after 3 days without use. */
  sessionDays: 14, idleDays: 3,
  /** Two-factor (HR/admin) sessions: 12 hours. */
  mfaSessionHours: 12,
  inviteHours: 72, resetMinutes: 60,
};

// ---------------------------------------------------------------------------
// Passwords
// ---------------------------------------------------------------------------
export function passwordProblem(pw: string): string | null {
  if (pw.length < POLICY.minPasswordLength) return `Use at least ${POLICY.minPasswordLength} characters.`;
  if (pw.length > 72) return 'Use at most 72 characters.';
  if (/^(.)\1+$/.test(pw) || /^(?:0123456789|1234567890|password|qwerty)/i.test(pw)) return 'Choose a less predictable password.';
  return null;
}

/** Check email + password. Locks the account for a while after repeated failures. */
export async function checkPassword(db: Db, email: string, password: string): Promise<string> {
  const row = await db.one<{ user_id: string; ok: boolean; locked: boolean; active: boolean }>(`
    select u.id as user_id,
           coalesce(c.password_hash = crypt($2, c.password_hash), false) as ok,
           coalesce(c.locked_until > now(), false) as locked,
           coalesce(p.active, false) as active
      from auth.users u
      left join auth.credentials c on c.user_id = u.id
      left join public.profiles p on p.id = u.id
     where lower(u.email) = lower($1)`, [email.trim(), password]);
  if (!row) {
    // Same work and same message whether or not the email exists.
    await db.one(`select crypt($1, gen_salt('bf', ${POLICY.bcryptCost}))`, [password]);
    throw new SignInError('Email or password is not correct.');
  }
  if (row.locked) throw new SignInError(`Too many attempts. Try again in ${POLICY.lockMinutes} minutes, or ask the admin for a reset link.`);
  if (!row.ok) {
    await db.query(`
      update auth.credentials set failed_attempts = failed_attempts + 1,
             locked_until = case when failed_attempts + 1 >= $2 then now() + make_interval(mins => $3) end
       where user_id = $1`, [row.user_id, POLICY.maxFailedAttempts, POLICY.lockMinutes]);
    throw new SignInError('Email or password is not correct.');
  }
  if (!row.active) throw new SignInError('This account is not active. Please contact PEACE’s admin.');
  await db.query(`update auth.credentials set failed_attempts = 0, locked_until = null where user_id = $1`, [row.user_id]);
  return row.user_id;
}

export async function setPassword(db: Db, userId: string, password: string): Promise<void> {
  const problem = passwordProblem(password);
  if (problem) throw new SignInError(problem);
  await db.query(`
    insert into auth.credentials (user_id, password_hash) values ($1, crypt($2, gen_salt('bf', ${POLICY.bcryptCost})))
    on conflict (user_id) do update set password_hash = excluded.password_hash, updated_at = now(), failed_attempts = 0, locked_until = null`,
    [userId, password]);
  // A new password signs out every other device.
  await db.query(`update auth.sessions set revoked_at = now() where user_id = $1 and revoked_at is null`, [userId]);
}

// ---------------------------------------------------------------------------
// Sessions (the cookie holds the token; the database only its hash)
// ---------------------------------------------------------------------------
export interface SessionRow { id: string; user_id: string; aal: 'aal1' | 'aal2'; email: string }

export async function createSession(db: Db, userId: string, aal: 'aal1' | 'aal2', meta: { ip?: string; userAgent?: string } = {}): Promise<string> {
  const token = randomToken();
  const expires = aal === 'aal2' ? `now() + interval '${POLICY.mfaSessionHours} hours'` : `now() + interval '${POLICY.sessionDays} days'`;
  await db.query(`insert into auth.sessions (user_id, token_hash, aal, expires_at, ip, user_agent)
                  values ($1, $2, $3, ${expires}, $4, left($5, 300))`, [userId, sha256(token), aal, meta.ip ?? null, meta.userAgent ?? null]);
  return token;
}

export async function findSession(db: Db, token: string): Promise<SessionRow | null> {
  if (!token || token.length > 100) return null;
  const s = await db.one<SessionRow & { stale: boolean }>(`
    select s.id, s.user_id, s.aal, u.email, (s.last_seen_at < now() - interval '5 minutes') as stale
      from auth.sessions s join auth.users u on u.id = s.user_id
     where s.token_hash = $1 and s.revoked_at is null and s.expires_at > now()
       and s.last_seen_at > now() - interval '${POLICY.idleDays} days'`, [sha256(token)]);
  if (!s) return null;
  if (s.stale) await db.query(`update auth.sessions set last_seen_at = now() where id = $1`, [s.id]);
  return { id: s.id, user_id: s.user_id, aal: s.aal, email: s.email };
}

export async function revokeSession(db: Db, token: string): Promise<void> {
  await db.query(`update auth.sessions set revoked_at = now() where token_hash = $1 and revoked_at is null`, [sha256(token)]);
}

// ---------------------------------------------------------------------------
// Invitation and reset links (single use, short-lived)
// ---------------------------------------------------------------------------
export async function issueLink(db: Db, userId: string, kind: 'invite' | 'reset', createdBy: string | null = null): Promise<string> {
  const token = randomToken();
  const ttl = kind === 'invite' ? `${POLICY.inviteHours} hours` : `${POLICY.resetMinutes} minutes`;
  // Any older unused link of the same kind stops working.
  await db.query(`update auth.one_time_tokens set used_at = now() where user_id = $1 and kind = $2 and used_at is null`, [userId, kind]);
  await db.query(`insert into auth.one_time_tokens (token_hash, user_id, kind, expires_at, created_by)
                  values ($1, $2, $3, now() + interval '${ttl}', $4)`, [sha256(token), userId, kind, createdBy]);
  return token;
}

/** Look at a link without using it up (to show the right page). */
export async function peekLink(db: Db, token: string): Promise<{ user_id: string; kind: 'invite' | 'reset'; email: string } | null> {
  if (!token || token.length > 100) return null;
  return db.one(`select t.user_id, t.kind, u.email from auth.one_time_tokens t join auth.users u on u.id = t.user_id
                  where t.token_hash = $1 and t.used_at is null and t.expires_at > now()`, [sha256(token)]);
}

/** Use the link to set a password. Returns the user id. */
export async function redeemLink(db: Db, token: string, password: string): Promise<string> {
  const problem = passwordProblem(password);
  if (problem) throw new SignInError(problem);
  const row = await db.one<{ user_id: string }>(`
    update auth.one_time_tokens set used_at = now()
     where token_hash = $1 and used_at is null and expires_at > now() returning user_id`, [sha256(token ?? '')]);
  if (!row) throw new SignInError('This link has expired or was already used. Ask the admin for a new one.');
  await setPassword(db, row.user_id, password);
  return row.user_id;
}

// ---------------------------------------------------------------------------
// Two-factor (TOTP)
// ---------------------------------------------------------------------------
export async function hasMfa(db: Db, userId: string): Promise<boolean> {
  return Boolean(await db.one(`select 1 from auth.mfa_factors where user_id = $1 and confirmed_at is not null`, [userId]));
}

/** Start (or restart) enrolment; returns the secret to show as a QR code. */
export async function startMfaEnrolment(db: Db, userId: string): Promise<string> {
  if (await hasMfa(db, userId)) throw new SignInError('Two-factor is already set up.');
  await db.query(`delete from auth.mfa_factors where user_id = $1 and confirmed_at is null`, [userId]);
  const secret = newTotpSecret();
  await db.query(`insert into auth.mfa_factors (user_id, secret_enc) values ($1, $2)`, [userId, encrypt(secret)]);
  return secret;
}

export async function pendingMfaSecret(db: Db, userId: string): Promise<string | null> {
  const f = await db.one<{ secret_enc: Buffer }>(`select secret_enc from auth.mfa_factors where user_id = $1 and confirmed_at is null
                                                   order by created_at desc limit 1`, [userId]);
  return f ? decrypt(f.secret_enc) : null;
}

/** Verify a code — confirming enrolment if it is still pending. Blocks reuse of a code. */
export async function verifyMfaCode(db: Db, userId: string, code: string, nowMs = Date.now()): Promise<void> {
  const f = await db.one<{ id: string; secret_enc: Buffer; confirmed_at: string | null; last_counter: string | null }>(`
    select id, secret_enc, confirmed_at, last_counter from auth.mfa_factors
     where user_id = $1 order by (confirmed_at is not null) desc, created_at desc limit 1`, [userId]);
  if (!f) throw new SignInError('Two-factor is not set up yet.');
  const counter = verifyTotp(decrypt(f.secret_enc), code.trim(), nowMs, f.last_counter === null ? null : Number(f.last_counter));
  if (counter === null) throw new SignInError('That code did not work. Check that your phone’s time is set automatically and try the newest code.');
  await db.query(`update auth.mfa_factors set last_counter = $2, confirmed_at = coalesce(confirmed_at, now()) where id = $1`, [f.id, counter]);
}

/** Admin action when someone loses their phone: removes two-factor so they can set it up again. */
export async function resetMfa(db: Db, userId: string): Promise<void> {
  await db.query(`delete from auth.mfa_factors where user_id = $1`, [userId]);
  await db.query(`update auth.sessions set aal = 'aal1' where user_id = $1 and aal = 'aal2'`, [userId]);
}

export async function upgradeSession(db: Db, sessionId: string): Promise<void> {
  await db.query(`update auth.sessions set aal = 'aal2', expires_at = least(expires_at, now() + interval '${POLICY.mfaSessionHours} hours')
                  where id = $1`, [sessionId]);
}
