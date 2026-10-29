import { redirect } from 'next/navigation';
import { getSession, supabaseConfigured } from '@/lib/auth';
import { SetPasswordForm } from '@/components/set-password-form';

export const metadata = { title: 'Set your password' };

export default async function ResetPassword() {
  const s = await getSession();
  if (!s || s.via !== 'supabase') redirect('/sign-in');
  return (
    <div className="center-page">
      <div className="card">
        <h1>Set your password</h1>
        <p className="muted">At least 12 characters. A short sentence is easy to remember and hard to guess.</p>
        {supabaseConfigured() && <SetPasswordForm url={process.env.NEXT_PUBLIC_SUPABASE_URL!} anonKey={process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!} />}
      </div>
    </div>
  );
}
