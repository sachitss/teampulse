import { redirect } from 'next/navigation';
import Link from 'next/link';
import QRCode from 'qrcode';
import { requireSession } from '@/lib/auth';
import { asSystem } from '@/lib/db';
import { hasMfa, pendingMfaSecret, startMfaEnrolment } from '@/lib/signin-core';
import { otpauthUri } from '@/lib/crypto';
import { ActionForm, Submit } from '@/components/action-form';
import { verifyMfaAction } from './actions';

export const metadata = { title: 'Two-factor sign-in' };

export default async function Mfa() {
  const s = await requireSession();
  if (s.aal === 'aal2') redirect('/today');
  const state = await asSystem(async (db) => {
    if (await hasMfa(db, s.userId)) return { enrolled: true as const };
    const secret = (await pendingMfaSecret(db, s.userId)) ?? (await startMfaEnrolment(db, s.userId));
    return { enrolled: false as const, secret };
  });
  const qr = state.enrolled ? null
    : await QRCode.toString(otpauthUri(state.secret, s.email), { type: 'svg', margin: 1, errorCorrectionLevel: 'M' });

  return (
    <div className="center-page">
      <div className="card">
        <h1>Two-factor sign-in</h1>
        {state.enrolled
          ? <p className="muted">Enter the 6-digit code from your authenticator app.</p>
          : <>
              <p className="muted">HR and admin work needs a second step: a code from an authenticator app on your phone
                (Google Authenticator, Microsoft Authenticator, Authy…). Set it up once:</p>
              <p>1. In the app, add an account and scan this code.</p>
              <div className="qr" style={{ background: '#fff', padding: 8, borderRadius: 8, width: 200 }}
                   dangerouslySetInnerHTML={{ __html: qr! }} />
              <p className="small muted">Can’t scan? Choose “enter a setup key” and type:{' '}
                <code data-testid="mfa-secret">{state.secret.replace(/(.{4})/g, '$1 ').trim()}</code></p>
              <p>2. Enter the 6-digit code the app shows.</p>
            </>}
        <ActionForm action={verifyMfaAction}>
          <div className="field">
            <label htmlFor="code">6-digit code</label>
            <input id="code" name="code" inputMode="numeric" autoComplete="one-time-code" pattern="[0-9 ]{6,7}" maxLength={7} required autoFocus />
          </div>
          <div className="spread">
            <Submit testId="verify-mfa">Verify</Submit>
            <Link className="small" href="/today">Not now</Link>
          </div>
        </ActionForm>
        <p className="small muted" style={{ marginTop: 12 }}>Lost your phone? Ask PEACE’s admin to reset your two-factor.</p>
      </div>
    </div>
  );
}
