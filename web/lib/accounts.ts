// Creating the sign-in account for a new employee.
// Production: Supabase Auth admin API sends an invitation email (needs the service key,
// which never leaves the server). Local development: a plain test account.
import 'server-only';
import { createClient } from '@supabase/supabase-js';
import { asSystem } from './db.ts';
import { devAuthEnabled, supabaseConfigured } from './auth.ts';

function admin() {
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!supabaseConfigured() || !key) return null;
  return createClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, key, { auth: { persistSession: false, autoRefreshToken: false } });
}

export async function createLoginAccount(email: string): Promise<{ userId: string; invited: boolean }> {
  const sb = admin();
  if (sb) {
    const base = process.env.APP_BASE_URL ?? '';
    const { data, error } = await sb.auth.admin.inviteUserByEmail(email, { redirectTo: `${base}/auth/confirm?next=/reset-password` });
    if (error || !data.user) throw new Error(error?.message?.includes('already') ? 'That email already has an account.' : 'Could not send the invitation.');
    return { userId: data.user.id, invited: true };
  }
  if (devAuthEnabled()) {
    const row = await asSystem((db) => db.one<{ id: string }>(`insert into auth.users (email) values ($1) returning id`, [email]));
    return { userId: row!.id, invited: false };
  }
  throw new Error('Sign-in is not configured, so accounts cannot be created yet.');
}

/** Undo an account if creating the employee record failed afterwards. */
export async function removeLoginAccount(userId: string): Promise<void> {
  const sb = admin();
  if (sb) { await sb.auth.admin.deleteUser(userId); return; }
  if (devAuthEnabled()) await asSystem((db) => db.query(`delete from auth.users where id = $1`, [userId]));
}
