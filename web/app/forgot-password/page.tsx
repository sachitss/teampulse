import Link from 'next/link';
import { connection } from 'next/server';
import { mailConfigured } from '@/lib/mail';
import { ActionForm, Submit } from '@/components/action-form';
import { forgotPasswordAction } from './actions';

export const metadata = { title: 'Forgot password' };

export default async function ForgotPassword() {
  await connection();   // decide at request time whether email is set up, not at build time
  return (
    <div className="center-page">
      <div className="card">
        <h1>Forgot password</h1>
        {mailConfigured() ? (
          <ActionForm action={forgotPasswordAction}>
            <p className="muted">Enter your work email. If it has an account, we’ll email a link to choose a new password (valid for 1 hour).</p>
            <div className="field"><label htmlFor="email">Work email</label>
              <input id="email" name="email" type="email" autoComplete="username" required /></div>
            <Submit>Send reset link</Submit>
          </ActionForm>
        ) : (
          <p className="muted">Please ask PEACE’s admin for a password reset link. They can create one from your page under People.</p>
        )}
        <p className="small" style={{ marginTop: 12 }}><Link href="/sign-in">← Back to sign-in</Link></p>
      </div>
    </div>
  );
}
