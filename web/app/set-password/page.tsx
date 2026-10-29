import Link from 'next/link';
import { asSystem } from '@/lib/db';
import { peekLink, POLICY } from '@/lib/signin-core';
import { ActionForm, Submit } from '@/components/action-form';
import { setPasswordAction } from './actions';

export const metadata = { title: 'Set your password', referrer: 'no-referrer' };

export default async function SetPassword({ searchParams }: { searchParams: Promise<{ token?: string }> }) {
  const { token = '' } = await searchParams;
  const link = await asSystem((db) => peekLink(db, token));
  return (
    <div className="center-page">
      <div className="card">
        {!link ? (
          <>
            <h1>Link expired</h1>
            <p className="muted">This link has expired or was already used. Ask PEACE’s admin for a new one, or use “Forgot password?” on the sign-in page.</p>
            <Link className="btn" href="/sign-in">Go to sign-in</Link>
          </>
        ) : (
          <>
            <h1>{link.kind === 'invite' ? 'Welcome to TeamPulse' : 'Choose a new password'}</h1>
            <p className="muted">For <strong>{link.email}</strong>. At least {POLICY.minPasswordLength} characters — a short sentence is easy to remember and hard to guess.</p>
            <ActionForm action={setPasswordAction}>
              <input type="hidden" name="token" value={token} />
              <input type="hidden" name="username" autoComplete="username" value={link.email} />
              <div className="field"><label htmlFor="pw">New password</label>
                <input id="pw" name="password" type="password" autoComplete="new-password" minLength={POLICY.minPasswordLength} maxLength={72} required /></div>
              <div className="field"><label htmlFor="pw2">Repeat password</label>
                <input id="pw2" name="password2" type="password" autoComplete="new-password" required /></div>
              <Submit testId="save-password">Save password</Submit>
            </ActionForm>
          </>
        )}
      </div>
    </div>
  );
}
