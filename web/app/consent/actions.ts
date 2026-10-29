'use server';
import { redirect } from 'next/navigation';
import { requireMe, db } from '@/lib/me';

export async function giveConsent(form: FormData) {
  const me = await requireMe({ allowPendingNotice: true });
  const version = Number(form.get('version'));
  if (version !== me.pendingNoticeVersion) redirect('/consent');
  await db(me, (d) => d.query(
    `insert into notice_consents (user_id, version, channel) values (auth.uid(), $1, 'web') on conflict do nothing`, [version]));
  redirect('/today');
}
