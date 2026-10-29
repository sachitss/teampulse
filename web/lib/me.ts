// The signed-in person's profile and what the app should ask of them first.
import 'server-only';
import { cache } from 'react';
import { redirect } from 'next/navigation';
import { asUser, type Db } from './db.ts';
import { requireSession, type Session } from './auth.ts';

export type Role = 'employee' | 'manager' | 'hr' | 'admin';

export interface Me {
  session: Session;
  id: string;
  fullName: string;
  email: string;
  role: Role;
  active: boolean;
  /** HR and admin rights only apply with two-factor sign-in (enforced by the database). */
  needsMfa: boolean;
  /** Latest published notice not yet consented to. */
  pendingNoticeVersion: number | null;
}

export const getMe = cache(async (): Promise<Me | null> => {
  const session = await requireSession();
  return asUser(session.claims, async (db) => {
    const p = await db.one<{ full_name: string; email: string; role: Role; active: boolean }>(
      `select full_name, email, role, active from profiles where id = auth.uid()`);
    if (!p) return null;
    const n = await db.one<{ version: number | null }>(
      `select (select max(version) from notice_versions where published_at is not null) as version`);
    let pending: number | null = null;
    if (n?.version) {
      const c = await db.one(`select 1 from notice_consents where user_id = auth.uid() and version = $1`, [n.version]);
      if (!c) pending = n.version;
    }
    return {
      session, id: session.userId, fullName: p.full_name, email: p.email, role: p.role, active: p.active,
      needsMfa: (p.role === 'hr' || p.role === 'admin') && session.aal !== 'aal2',
      pendingNoticeVersion: pending,
    };
  });
});

/** For pages: signed in, has a profile, is active, and has consented to the latest notice. */
export async function requireMe(opts: { allowPendingNotice?: boolean } = {}): Promise<Me> {
  const me = await getMe();
  if (!me) redirect('/no-account');
  if (!me.active) redirect('/no-account');
  if (me.pendingNoticeVersion && !opts.allowPendingNotice) redirect('/consent');
  return me;
}

export function isManagerOrAbove(me: Me): boolean {
  return me.role === 'manager' || ((me.role === 'hr' || me.role === 'admin') && !me.needsMfa);
}
export function isHr(me: Me): boolean {
  return (me.role === 'hr' || me.role === 'admin') && !me.needsMfa;
}
export function isAdmin(me: Me): boolean {
  return me.role === 'admin' && !me.needsMfa;
}

/** Run as the signed-in person. */
export function db<T>(me: Me, fn: (db: Db) => Promise<T>): Promise<T> {
  return asUser(me.session.claims, fn);
}
