// Who is signed in — TeamPulse's own sign-in (no outside service).
//
// The browser holds one random cookie (tp_session). The database stores only its SHA-256,
// with the person, the level of the sign-in (aal1 = password, aal2 = password + authenticator
// code) and when it expires. Every page looks the cookie up; the database's Row Level
// Security then works with the same claims it always did (sub + aal).
import 'server-only';
import { cache } from 'react';
import { cookies, headers } from 'next/headers';
import { redirect } from 'next/navigation';
import { asSystem, type Claims } from './db.ts';
import { createSession, findSession, revokeSession, POLICY } from './signin-core.ts';

export const SESSION_COOKIE = 'tp_session';

export interface Session {
  id: string;
  userId: string;
  aal: 'aal1' | 'aal2';
  email: string;
  claims: Claims;
}

/** Cookies are marked Secure whenever the site is served over https (always, through the tunnel). */
function secureCookies(): boolean {
  return (process.env.APP_BASE_URL ?? '').startsWith('https://');
}

export async function clientMeta(): Promise<{ ip?: string; userAgent?: string }> {
  const h = await headers();
  const ip = h.get('cf-connecting-ip') ?? h.get('x-forwarded-for')?.split(',')[0]?.trim() ?? undefined;
  return { ip, userAgent: h.get('user-agent') ?? undefined };
}

export const getSession = cache(async (): Promise<Session | null> => {
  // Reading the cookies also marks every page that checks the session as per-request,
  // so nothing personal is ever prerendered.
  const token = (await cookies()).get(SESSION_COOKIE)?.value;
  if (!token) return null;
  const s = await asSystem((db) => findSession(db, token));
  if (!s) return null;
  return {
    id: s.id, userId: s.user_id, aal: s.aal, email: s.email,
    claims: { sub: s.user_id, aal: s.aal, role: 'authenticated', email: s.email },
  };
});

export async function requireSession(): Promise<Session> {
  const s = await getSession();
  if (!s) redirect('/sign-in');
  return s;
}

/** Start a new session (and end the one this browser had, if any). */
export async function startSession(userId: string, aal: 'aal1' | 'aal2'): Promise<void> {
  const store = await cookies();
  const old = store.get(SESSION_COOKIE)?.value;
  const meta = await clientMeta();
  const token = await asSystem(async (db) => {
    if (old) await revokeSession(db, old);
    return createSession(db, userId, aal, meta);
  });
  store.set(SESSION_COOKIE, token, {
    httpOnly: true, sameSite: 'lax', path: '/', secure: secureCookies(),
    maxAge: aal === 'aal2' ? POLICY.mfaSessionHours * 3600 : POLICY.sessionDays * 86400,
  });
}

export async function endSession(): Promise<void> {
  const store = await cookies();
  const token = store.get(SESSION_COOKIE)?.value;
  if (token) await asSystem((db) => revokeSession(db, token));
  store.delete(SESSION_COOKIE);
}
