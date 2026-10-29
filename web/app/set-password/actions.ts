'use server';
import { redirect } from 'next/navigation';
import { asSystem } from '@/lib/db';
import { endSession } from '@/lib/auth';
import { redeemLink, SignInError } from '@/lib/signin-core';
import type { ActionResult } from '@/components/action-form';

export async function setPasswordAction(_: ActionResult, f: FormData): Promise<ActionResult> {
  const token = String(f.get('token') ?? '');
  const pw = String(f.get('password') ?? ''), pw2 = String(f.get('password2') ?? '');
  if (pw !== pw2) return { error: 'The two passwords do not match.' };
  try {
    await asSystem((db) => redeemLink(db, token, pw));
  } catch (e) {
    if (e instanceof SignInError) return { error: e.message };
    console.error(e);
    return { error: 'Something went wrong. Please try again.' };
  }
  // Setting a password signs out every device; sign in fresh with the new password.
  await endSession();
  redirect('/sign-in?done=password');
}
