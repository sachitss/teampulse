import { redirect } from 'next/navigation';
import { requireMe, db } from '@/lib/me';
import { giveConsent } from './actions';

export const metadata = { title: 'Monitoring and HR data notice' };

export default async function Consent() {
  const me = await requireMe({ allowPendingNotice: true });
  if (!me.pendingNoticeVersion) redirect('/today');
  const notice = await db(me, (d) => d.one<{ version: number; title: string; body_en: string; body_ne: string | null }>(
    `select version, title, body_en, body_ne from notice_versions where version = $1`, [me.pendingNoticeVersion]));
  return (
    <div className="center-page">
      <div className="card" style={{ maxWidth: 720 }}>
        <h1>{notice!.title}</h1>
        <p className="muted small">Version {notice!.version}. Please read it before using TeamPulse.</p>
        <div className="notice-text" data-testid="notice-en">{notice!.body_en}</div>
        {notice!.body_ne && (
          <details style={{ marginTop: 12 }}>
            <summary>नेपालीमा पढ्नुहोस् (Read in Nepali)</summary>
            <div className="notice-text" lang="ne">{notice!.body_ne}</div>
          </details>
        )}
        <form action={giveConsent} style={{ marginTop: 16 }} className="spread">
          <input type="hidden" name="version" value={notice!.version} />
          <button className="btn big">I have read this and I consent</button>
        </form>
        <p className="small muted" style={{ marginTop: 12 }}>
          If you do not consent, nothing is recorded about your computer activity. Please speak to PEACE’s admin — you can still be paid and request leave.
        </p>
      </div>
    </div>
  );
}
