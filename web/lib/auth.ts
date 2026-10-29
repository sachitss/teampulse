// Who is signed in.
//
// Production: Supabase Auth. The session lives in Supabase's cookies; the server
// verifies the access token with supabase.auth.getClaims() (signature checked
// against the project's keys) and uses those claims — sub and aal (MFA level).
//
// Local development and automated tests only: a "dev sign-in" that mints a token
// signed with TP_DEV_AUTH_SECRET. It is impossible to enable in a production build
// (NODE_ENV=production), whatever the environment variables say.
import 'server-only';
import { cache } from 'react';
import { cookies } from 'next/headers';
import { redirect } from 'next/navigation';
import { jwtVerify, SignJWT } from 'jose';
import { createServerClient } from '@supabase/ssr';
import type { Claims } from './db.ts';

export const DEV_COOKIE = 'tp_dev_session';

export interface Session {
  userId: string;
  aal: 'aal1' | 'aal2';
  email?: string;
  claims: Claims;
  via: 'supabase' | 'dev';
}

export function devAuthEnabled(): boolean {
  return process.env.NODE_ENV !== 'production'
    && process.env.TP_DEV_AUTH === '1'
    && (process.env.TP_DEV_AUTH_SECRET ?? '').length >= 32;
}

export function supabaseConfigured(): boolean {
  return Boolean(process.env.NEXT_PUBLIC_SUPABASE_URL && process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY);
}

function devSecret(): Uint8Array {
  if (!devAuthEnabled()) throw new Error('Dev sign-in is disabled');
  return new TextEncoder().encode(process.env.TP_DEV_AUTH_SECRET);
}

function toSession(sub: string, aal: unknown, email: unknown, via: Session['via']): Session {
  const level = aal === 'aal2' ? 'aal2' : 'aal1';
  return {
    userId: sub, aal: level, email: typeof email === 'string' ? email : undefined, via,
    claims: { sub, aal: level, role: 'authenticated', email: typeof email === 'string' ? email : undefined },
  };
}

export async function mintDevToken(userId: string, email: string, mfa: boolean): Promise<string> {
  return new SignJWT({ aal: mfa ? 'aal2' : 'aal1', role: 'authenticated', email, tp_dev: true })
    .setProtectedHeader({ alg: 'HS256' })
    .setSubject(userId)
    .setIssuedAt()
    .setExpirationTime('8h')
    .sign(devSecret());
}

export async function verifyDevToken(token: string): Promise<Session | null> {
  if (!devAuthEnabled()) return null;
  try {
    const { payload } = await jwtVerify(token, devSecret(), { algorithms: ['HS256'] });
    if (!payload.sub || payload.tp_dev !== true) return null;
    return toSession(payload.sub, payload.aal, payload.email, 'dev');
  } catch {
    return null;
  }
}

/** Supabase server client bound to this request's cookies (also refreshes the session). */
export async function supabaseServer() {
  const store = await cookies();
  return createServerClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!, {
    cookies: {
      getAll: () => store.getAll(),
      setAll: (list) => {
        try { list.forEach(({ name, value, options }) => store.set(name, value, options)); } catch { /* read-only in Server Components */ }
      },
    },
  });
}

export const getSession = cache(async (): Promise<Session | null> => {
  // Always read the request cookies first. Besides being needed, this marks every page that
  // checks the session as per-request: otherwise a build without sign-in settings would
  // prerender these pages once and serve the same output to everyone.
  const store = await cookies();
  if (devAuthEnabled()) {
    const token = store.get(DEV_COOKIE)?.value;
    if (token) {
      const s = await verifyDevToken(token);
      if (s) return s;
    }
  }
  if (!supabaseConfigured()) return null;
  const sb = await supabaseServer();
  const { data, error } = await sb.auth.getClaims();
  if (error || !data?.claims?.sub) return null;
  const c = data.claims as Record<string, unknown>;
  return toSession(String(c.sub), c.aal, c.email, 'supabase');
});

export async function requireSession(): Promise<Session> {
  const s = await getSession();
  if (!s) redirect('/sign-in');
  return s;
}
