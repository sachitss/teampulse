// Sign-in accounts for employees: created by an admin, activated by the employee through
// a single-use invitation link. Admin help when someone is locked out or loses their phone.
import 'server-only';
import { asSystem } from './db.ts';
import { issueLink, resetMfa } from './signin-core.ts';
import { sendMail, mailConfigured, appUrl } from './mail.ts';

export interface LinkResult {
  /** Emailed to the person. */
  emailed: boolean;
  /** Only when email is not set up (or failed): the link for the admin to pass on in person. */
  link?: string;
}

export async function createLoginAccount(email: string): Promise<string> {
  const row = await asSystem((db) => db.one<{ id: string }>(
    `insert into auth.users (email) values (lower($1)) on conflict do nothing returning id`, [email]));
  if (!row) throw new Error('That email already has an account.');
  return row.id;
}

/** Undo an account if creating the employee record failed afterwards. */
export async function removeLoginAccount(userId: string): Promise<void> {
  await asSystem((db) => db.query(`delete from auth.users where id = $1`, [userId]));
}

export async function sendSignInLink(userId: string, kind: 'invite' | 'reset', byAdmin: string | null): Promise<LinkResult> {
  const { token, email, name } = await asSystem(async (db) => {
    const u = await db.one<{ email: string; name: string | null }>(
      `select u.email, p.full_name as name from auth.users u left join public.profiles p on p.id = u.id where u.id = $1`, [userId]);
    if (!u) throw new Error('Account not found.');
    return { token: await issueLink(db, userId, kind, byAdmin), email: u.email, name: u.name };
  });
  const link = appUrl(`/set-password?token=${encodeURIComponent(token)}`);
  const hello = name ? `Hello ${name.replace(/^\[DEMO\]\s*/, '')},` : 'Hello,';
  const emailed = await sendMail(email,
    kind === 'invite' ? 'Your TeamPulse account at PEACE Consultancy' : 'Reset your TeamPulse password',
    kind === 'invite'
      ? `${hello}\n\nAn account has been created for you on TeamPulse, PEACE Consultancy's time, leave and payroll system.\n\n`
        + `Open this link to choose your password (valid for 72 hours, works once):\n${link}\n\n`
        + `Before anything is recorded from your computer, TeamPulse will show you the monitoring notice and ask for your consent.\n`
      : `${hello}\n\nSomeone asked to reset your TeamPulse password. Open this link to choose a new one (valid for 1 hour, works once):\n${link}\n\n`
        + `If this was not you, you can ignore this email — your password stays the same.\n`,
    kind === 'invite' ? 'invite' : 'password_reset');
  // The link goes back to the admin only if it could not be emailed (and never for a self-service reset).
  return emailed || !byAdmin ? { emailed } : { emailed, link };
}

/** "Forgot password" from the sign-in page. Says nothing about whether the email exists. */
export async function selfServiceReset(email: string): Promise<void> {
  if (!mailConfigured()) return;
  const u = await asSystem((db) => db.one<{ id: string }>(
    `select u.id from auth.users u join public.profiles p on p.id = u.id where lower(u.email) = lower($1) and p.active`, [email.trim()]));
  if (u) await sendSignInLink(u.id, 'reset', null);
}

export async function adminResetMfa(userId: string): Promise<void> {
  await asSystem((db) => resetMfa(db, userId));
}

export async function adminUnlock(userId: string): Promise<void> {
  await asSystem((db) => db.query(`update auth.credentials set failed_attempts = 0, locked_until = null where user_id = $1`, [userId]));
}

export interface SignInStatus { hasPassword: boolean; locked: boolean; hasMfa: boolean; lastSignIn: string | null; pendingInvite: boolean }

export async function signInStatus(userId: string): Promise<SignInStatus> {
  return (await asSystem((db) => db.one<SignInStatus>(`
    select exists (select 1 from auth.credentials where user_id = $1) as "hasPassword",
           exists (select 1 from auth.credentials where user_id = $1 and locked_until > now()) as locked,
           exists (select 1 from auth.mfa_factors where user_id = $1 and confirmed_at is not null) as "hasMfa",
           (select max(created_at)::text from auth.sessions where user_id = $1) as "lastSignIn",
           exists (select 1 from auth.one_time_tokens where user_id = $1 and kind = 'invite' and used_at is null and expires_at > now()) as "pendingInvite"`,
    [userId])))!;
}
