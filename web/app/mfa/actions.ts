'use server';
import { redirect } from 'next/navigation';
import { asSystem } from '@/lib/db';
import { requireSession, startSession } from '@/lib/auth';
import { verifyMfaCode, SignInError } from '@/lib/signin-core';
import type { ActionResult } from '@/components/action-form';

export async function verifyMfaAction(_: ActionResult, f: FormData): Promise<ActionResult> {
  const s = await requireSession();
  const code = String(f.get('code') ?? '').replace(/\s/g, '');
  try {
    await asSystem((db) => verifyMfaCode(db, s.userId, code));
  } catch (e) {
    if (e instanceof SignInError) return { error: e.message };
    console.error(e);
    return { error: 'Something went wrong. Please try again.' };
  }
  // A fresh session at the higher level (the old one is ended).
  await startSession(s.userId, 'aal2');
  redirect('/today');
}
