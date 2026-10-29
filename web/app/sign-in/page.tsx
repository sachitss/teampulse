import { redirect } from 'next/navigation';
import Link from 'next/link';
import { getSession, devAuthEnabled, supabaseConfigured } from '@/lib/auth';
import { SignInForm } from '@/components/sign-in-form';

export const metadata = { title: 'Sign in' };

export default async function SignIn() {
  if (await getSession()) redirect('/today');
  return (
    <div className="center-page">
      <div className="card">
        <img className="logo-big" src="/icons/icon-192.png" alt="" />
        <h1>TeamPulse</h1>
        <p className="muted">PEACE Consultancy</p>
        {supabaseConfigured()
          ? <SignInForm url={process.env.NEXT_PUBLIC_SUPABASE_URL!} anonKey={process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!} />
          : <p className="notice warn">Sign-in is not configured yet. Set the Supabase variables in the environment.</p>}
        {devAuthEnabled() && (
          <p className="small"><Link href="/dev-login">Developer sign-in (local only) →</Link></p>
        )}
      </div>
    </div>
  );
}
