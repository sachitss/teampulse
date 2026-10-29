'use server';
import { z } from 'zod';
import { selfServiceReset } from '@/lib/accounts';
import type { ActionResult } from '@/components/action-form';

export async function forgotPasswordAction(_: ActionResult, f: FormData): Promise<ActionResult> {
  const email = z.string().trim().email().max(200).safeParse(f.get('email'));
  if (!email.success) return { error: 'Please enter a valid email.' };
  try { await selfServiceReset(email.data); } catch (e) { console.error(e); }
  // Same answer whether or not the address exists.
  return { ok: 'If that email has an account, a reset link is on its way. Check your inbox (and spam folder).' };
}
