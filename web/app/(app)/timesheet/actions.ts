'use server';
import { revalidatePath } from 'next/cache';
import { requireMe, db } from '@/lib/me';
import { friendlyError } from '@/lib/db';
import { submitMonth } from '@/lib/timesheet';
import type { ActionResult } from '@/components/action-form';

export async function submitAction(_: ActionResult, f: FormData): Promise<ActionResult> {
  const me = await requireMe();
  try {
    await db(me, (d) => submitMonth(d, Number(f.get('y')), Number(f.get('m'))));
    revalidatePath('/timesheet');
    return { ok: 'Submitted. Your manager will review it.' };
  } catch (e) {
    return { error: e instanceof Error && /already been submitted/.test(e.message) ? e.message : friendlyError(e) };
  }
}
