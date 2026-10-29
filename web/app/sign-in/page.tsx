import { redirect } from 'next/navigation';
import Link from 'next/link';
import { getSession } from '@/lib/auth';
import { ActionForm, Submit } from '@/components/action-form';
import { signInAction } from './actions';

export const metadata = { title: 'Sign in' };

export default async function SignIn({ searchParams }: { searchParams: Promise<{ done?: string }> }) {
  if (await getSession()) redirect('/today');
  const { done } = await searchParams;
  return (
    <div className="center-page">
      <div className="card">
        <img className="logo-big" src="/icons/icon-192.png" alt="" />
        <h1>TeamPulse</h1>
        <p className="muted">PEACE Consultancy</p>
        {done === 'password' && <p className="notice ok" role="status">Password saved. Sign in with it now.</p>}
        <ActionForm action={signInAction}>
          <div className="field">
            <label htmlFor="email">Work email</label>
            <input id="email" name="email" type="email" autoComplete="username" required />
          </div>
          <div className="field">
            <label htmlFor="password">Password</label>
            <input id="password" name="password" type="password" autoComplete="current-password" required />
          </div>
          <div className="spread">
            <Submit testId="sign-in">Sign in</Submit>
            <Link className="small" href="/forgot-password">Forgot password?</Link>
          </div>
        </ActionForm>
      </div>
    </div>
  );
}
