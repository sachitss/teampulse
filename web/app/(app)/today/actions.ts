'use server';
import { revalidatePath } from 'next/cache';
import { requireMe, db } from '@/lib/me';
import { friendlyError } from '@/lib/db';
import * as timer from '@/lib/timer';
import type { ActionResult } from '@/components/action-form';

async function run(fn: Parameters<typeof db>[1], ok?: string): Promise<ActionResult> {
  const me = await requireMe();
  try {
    await db(me, fn);
    revalidatePath('/today');
    return ok ? { ok } : null;
  } catch (e) {
    return { error: e instanceof timer.TimerError ? e.message : friendlyError(e) };
  }
}

const task = (f: FormData) => (String(f.get('task') ?? '') || null);

export async function startAction(_: ActionResult, f: FormData) { return run((d) => timer.startWork(d, task(f))); }
export async function switchAction(_: ActionResult, f: FormData) { return run((d) => timer.switchTask(d, task(f))); }
export async function breakAction(_: ActionResult, f: FormData) {
  return run((d) => timer.startBreak(d, f.get('kind') === 'privacy_pause' ? 'privacy_pause' : 'break'));
}
export async function resumeAction(_: ActionResult, _f: FormData) { return run((d) => timer.resumeWork(d)); }
export async function stopAction(_: ActionResult, _f: FormData) { return run((d) => timer.stopWork(d), 'Work stopped. See you tomorrow.'); }

export async function manualAction(_: ActionResult, f: FormData): Promise<ActionResult> {
  // <input type="datetime-local"> gives Kathmandu wall-clock time without a zone.
  const toUtc = (v: FormDataEntryValue | null) => new Date(`${String(v)}:00+05:45`).toISOString();
  return run((d) => timer.addManualEntry(d, {
    startedAt: toUtc(f.get('start')), endedAt: toUtc(f.get('end')), taskId: task(f), reason: String(f.get('reason') ?? ''),
  }), 'Added. Your manager will review it.');
}
