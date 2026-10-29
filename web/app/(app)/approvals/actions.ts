'use server';
import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { requireMe, db } from '@/lib/me';
import { friendlyError } from '@/lib/db';
import type { ActionResult } from '@/components/action-form';

export async function decideEntryAction(_: ActionResult, f: FormData): Promise<ActionResult> {
  const me = await requireMe();
  const decision = f.get('decision') === 'approved' ? 'approved' : 'rejected';
  try {
    const rows = await db(me, (d) => d.query(
      `update time_entries set approval = $2 where id = $1 and approval = 'pending' returning id`, [String(f.get('id')), decision]));
    if (rows.length === 0) return { error: 'This entry was already decided, or you cannot decide it.' };
  } catch (e) { return { error: friendlyError(e) }; }
  // The decided item leaves the list, so report the result at the top of the page.
  revalidatePath('/approvals');
  redirect(`/approvals?done=entry-${decision}`);
}

export async function decidePeriodAction(_: ActionResult, f: FormData): Promise<ActionResult> {
  const me = await requireMe();
  const to = String(f.get('to'));
  const from = { approved: 'submitted', open: 'submitted', locked: 'approved' }[to];
  if (!from) return { error: 'Unknown action.' };
  try {
    const rows = await db(me, (d) => d.query(
      `update timesheet_periods set status = $2 where id = $1 and status = $3 returning id`, [String(f.get('id')), to, from]));
    if (rows.length === 0) return { error: 'This timesheet changed in the meantime, or you cannot decide it.' };
  } catch (e) { return { error: friendlyError(e) }; }
  revalidatePath('/approvals');
  redirect(`/approvals?done=period-${to}`);
}
