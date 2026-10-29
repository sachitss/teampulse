'use server';
import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { z } from 'zod';
import { requireMe, db, isAdmin } from '@/lib/me';
import { friendlyError } from '@/lib/db';
import type { ActionResult } from '@/components/action-form';

async function admin() {
  const me = await requireMe();
  if (!isAdmin(me)) throw Object.assign(new Error('Only an admin can change settings.'), { code: '42501' });
  return me;
}

export async function publishNoticeAction(_: ActionResult, f: FormData): Promise<ActionResult> {
  const p = z.object({ title: z.string().trim().min(5).max(200), body_en: z.string().trim().min(200), body_ne: z.string().trim() })
    .safeParse({ title: f.get('title'), body_en: f.get('body_en'), body_ne: f.get('body_ne') ?? '' });
  if (!p.success) return { error: 'The notice needs a title and the full English text.' };
  if (/\[[^\]]+\]/.test(p.data.body_en)) return { error: 'Fill in the [bracketed] parts of the English text before publishing.' };
  if (/\[[^\]]+\]/.test(p.data.body_ne)) return { error: 'Fill in the [bracketed] parts of the Nepali text before publishing.' };
  let v: { version: number } | null;
  try {
    const me = await admin();
    v = await db(me, (d) => d.one<{ version: number }>(`
      insert into notice_versions (version, title, body_en, body_ne, published_at, created_by)
      values (coalesce((select max(version) from notice_versions), 0) + 1, $1, $2, nullif($3, ''), now(), auth.uid()) returning version`,
      [p.data.title, p.data.body_en, p.data.body_ne]));
  } catch (e) { return { error: friendlyError(e) }; }
  revalidatePath('/settings');
  // The publish form folds away once a notice exists, so confirm with a banner at the top.
  redirect(`/settings?published=${v!.version}`);
}

export async function confirmNoticeAction(_: ActionResult, _f: FormData): Promise<ActionResult> {
  try {
    const me = await admin();
    await db(me, (d) => d.query(`update org_settings set monitoring_notice_confirmed_at = now(), monitoring_notice_confirmed_by = auth.uid()`));
  } catch (e) { return { error: friendlyError(e) }; }
  revalidatePath('/settings');
  redirect('/settings?confirmed=1');
}

export async function saveOrgAction(_: ActionResult, f: FormData): Promise<ActionResult> {
  const weekly = f.getAll('weekly').map(Number).filter((n) => n >= 1 && n <= 7);
  const recips = String(f.get('recipients') ?? '').split(',').map((s) => s.trim()).filter(Boolean);
  if (recips.some((r) => !z.string().email().safeParse(r).success)) return { error: 'One of the report recipients is not a valid email address.' };
  if (weekly.length > 2) return { error: 'Choose at most two weekly holidays.' };
  try {
    const me = await admin();
    await db(me, (d) => d.query(`update org_settings set weekly_holidays = $1::smallint[], report_recipients = $2::text[]`, [weekly, recips]));
    revalidatePath('/settings');
    return { ok: 'Saved.' };
  } catch (e) { return { error: friendlyError(e) }; }
}
