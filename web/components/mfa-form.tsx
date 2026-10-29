'use client';
import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { createBrowserClient } from '@supabase/ssr';

type Step = { kind: 'loading' } | { kind: 'enroll'; factorId: string; qr: string; secret: string } | { kind: 'challenge'; factorId: string };

export function MfaForm({ url, anonKey }: { url: string; anonKey: string }) {
  const router = useRouter();
  const supabase = createBrowserClient(url, anonKey);
  const [step, setStep] = useState<Step>({ kind: 'loading' });
  const [code, setCode] = useState('');
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      const { data } = await supabase.auth.mfa.listFactors();
      const verified = data?.totp?.find((f) => f.status === 'verified');
      if (verified) { setStep({ kind: 'challenge', factorId: verified.id }); return; }
      // Remove half-finished enrolments, then start a fresh one.
      for (const f of data?.all ?? []) if (f.status !== 'verified') await supabase.auth.mfa.unenroll({ factorId: f.id });
      const { data: en, error } = await supabase.auth.mfa.enroll({ factorType: 'totp', friendlyName: 'TeamPulse' });
      if (error || !en) { setError('Could not start two-factor set-up. Try again.'); return; }
      setStep({ kind: 'enroll', factorId: en.id, qr: en.totp.qr_code, secret: en.totp.secret });
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  async function verify(e: React.FormEvent) {
    e.preventDefault();
    if (step.kind === 'loading') return;
    setError(null);
    const { error } = await supabase.auth.mfa.challengeAndVerify({ factorId: step.factorId, code: code.trim() });
    if (error) { setError('That code did not work. Check the time on your phone and try the newest code.'); return; }
    router.push('/today');
    router.refresh();
  }

  if (step.kind === 'loading') return <p className="muted">Loading…</p>;
  return (
    <form onSubmit={verify}>
      {error && <p className="notice bad" role="alert">{error}</p>}
      {step.kind === 'enroll' && (
        <div className="field">
          <p>1. Scan this code with your authenticator app.</p>
          <img src={step.qr} alt="Two-factor QR code" width={200} height={200} style={{ background: '#fff', padding: 8, borderRadius: 8 }} />
          <p className="small muted">Can’t scan? Enter this key: <code>{step.secret}</code></p>
          <p>2. Enter the 6-digit code it shows.</p>
        </div>
      )}
      <div className="field">
        <label htmlFor="code">6-digit code</label>
        <input id="code" inputMode="numeric" autoComplete="one-time-code" pattern="[0-9]{6}" maxLength={6} required
               value={code} onChange={(e) => setCode(e.target.value)} />
      </div>
      <button className="btn">Verify</button>
    </form>
  );
}
