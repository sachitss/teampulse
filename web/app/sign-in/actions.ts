'use server';
import { redirect } from 'next/navigation';
import { z } from 'zod';
import { asSystem } from '@/lib/db';
import { startSession } from '@/lib/auth';
import { checkPassword, hasMfa, SignInError } from '@/lib/signin-core';
import type { ActionResult } from '@/components/action-form';

export async function signInAction(_: ActionResult, f: FormData): Promise<ActionResult> {
  const email = z.string().trim().email().max(200).safeParse(f.get('email'));
  const password = z.string().min(1).max(200).safeParse(f.get('password'));
  if (!email.success || !password.success) return { error: 'Enter your work email and password.' };
  let next: string;
  try {
    const { userId, mfa, elevated } = await asSystem(async (db) => {
      const userId = await checkPassword(db, email.data, password.data);
      const role = await db.one<{ role: string }>(`select role from profiles where id = $1`, [userId]);
      return { userId, mfa: await hasMfa(db, userId), elevated: role?.role === 'hr' || role?.role === 'admin' };
    });
    await startSession(userId, 'aal1');
    // Anyone who has two-factor set up is asked for the code; HR and admin are sent to set it up.
    next = mfa || elevated ? '/mfa' : '/today';
  } catch (e) {
    if (e instanceof SignInError) return { error: e.message };
    console.error(e);
    return { error: 'Something went wrong. Please try again.' };
  }
  redirect(next);
}
