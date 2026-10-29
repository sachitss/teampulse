'use server';
import { cookies } from 'next/headers';
import { redirect, notFound } from 'next/navigation';
import { devAuthEnabled, mintDevToken, DEV_COOKIE } from '@/lib/auth';
import { asSystem } from '@/lib/db';

export async function devSignIn(form: FormData) {
  if (!devAuthEnabled()) notFound();
  const id = String(form.get('id'));
  const p = await asSystem((db) => db.one<{ email: string }>(`select email from profiles where id = $1`, [id]));
  if (!p) notFound();
  const token = await mintDevToken(id, p.email, form.get('mfa') === '1');
  (await cookies()).set(DEV_COOKIE, token, { httpOnly: true, sameSite: 'lax', path: '/', secure: false, maxAge: 8 * 3600 });
  redirect('/today');
}
