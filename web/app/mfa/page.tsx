import { redirect } from 'next/navigation';
import { getSession, supabaseConfigured } from '@/lib/auth';
import { MfaForm } from '@/components/mfa-form';

export const metadata = { title: 'Two-factor sign-in' };

export default async function Mfa() {
  const s = await getSession();
  if (!s) redirect('/sign-in');
  if (s.via === 'dev') redirect('/today');
  return (
    <div className="center-page">
      <div className="card">
        <h1>Two-factor sign-in</h1>
        <p className="muted">HR and admin work needs a code from an authenticator app (Google Authenticator, Microsoft Authenticator, Authy…).</p>
        {supabaseConfigured() && <MfaForm url={process.env.NEXT_PUBLIC_SUPABASE_URL!} anonKey={process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!} />}
      </div>
    </div>
  );
}
