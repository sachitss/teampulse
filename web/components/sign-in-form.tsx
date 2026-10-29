'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { createBrowserClient } from '@supabase/ssr';

export function SignInForm({ url, anonKey }: { url: string; anonKey: string }) {
  const router = useRouter();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ kind: 'bad' | 'ok'; text: string } | null>(null);
  const supabase = createBrowserClient(url, anonKey);

  async function signIn(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true); setMsg(null);
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    if (error) { setBusy(false); setMsg({ kind: 'bad', text: 'Email or password is not correct.' }); return; }
    // If the account has two-factor set up, ask for the code now.
    const { data } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
    router.push(data && data.nextLevel === 'aal2' && data.currentLevel !== 'aal2' ? '/mfa' : '/today');
    router.refresh();
  }

  async function forgot() {
    if (!email) { setMsg({ kind: 'bad', text: 'Enter your email first.' }); return; }
    await supabase.auth.resetPasswordForEmail(email, { redirectTo: `${window.location.origin}/auth/confirm?next=/reset-password` });
    setMsg({ kind: 'ok', text: 'If that email has an account, a reset link is on its way.' });
  }

  return (
    <form onSubmit={signIn}>
      {msg && <p className={`notice ${msg.kind}`} role="alert">{msg.text}</p>}
      <div className="field">
        <label htmlFor="email">Work email</label>
        <input id="email" type="email" autoComplete="username" required value={email} onChange={(e) => setEmail(e.target.value)} />
      </div>
      <div className="field">
        <label htmlFor="password">Password</label>
        <input id="password" type="password" autoComplete="current-password" required value={password} onChange={(e) => setPassword(e.target.value)} />
      </div>
      <div className="spread">
        <button className="btn" disabled={busy}>{busy ? 'Signing in…' : 'Sign in'}</button>
        <button type="button" className="btn secondary small" onClick={forgot}>Forgot password</button>
      </div>
    </form>
  );
}
