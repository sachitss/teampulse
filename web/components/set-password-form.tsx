'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { createBrowserClient } from '@supabase/ssr';

export function SetPasswordForm({ url, anonKey }: { url: string; anonKey: string }) {
  const router = useRouter();
  const [pw, setPw] = useState('');
  const [pw2, setPw2] = useState('');
  const [error, setError] = useState<string | null>(null);

  async function save(e: React.FormEvent) {
    e.preventDefault();
    if (pw.length < 12) { setError('Use at least 12 characters.'); return; }
    if (pw !== pw2) { setError('The two passwords do not match.'); return; }
    const { error } = await createBrowserClient(url, anonKey).auth.updateUser({ password: pw });
    if (error) { setError(error.message); return; }
    router.push('/today'); router.refresh();
  }

  return (
    <form onSubmit={save}>
      {error && <p className="notice bad" role="alert">{error}</p>}
      <div className="field"><label htmlFor="pw">New password</label>
        <input id="pw" type="password" autoComplete="new-password" required value={pw} onChange={(e) => setPw(e.target.value)} /></div>
      <div className="field"><label htmlFor="pw2">Repeat password</label>
        <input id="pw2" type="password" autoComplete="new-password" required value={pw2} onChange={(e) => setPw2(e.target.value)} /></div>
      <button className="btn">Save password</button>
    </form>
  );
}
