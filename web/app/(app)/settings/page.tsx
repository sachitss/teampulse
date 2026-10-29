import { redirect } from 'next/navigation';
import { requireMe, db, isAdmin } from '@/lib/me';
import { fmtDateTime, WEEKDAY } from '@/lib/format';
import { ActionForm, Submit } from '@/components/action-form';
import { NOTICE_TITLE, NOTICE_EN, NOTICE_NE } from '@/lib/notice-template';
import { publishNoticeAction, confirmNoticeAction, saveOrgAction } from './actions';

export const metadata = { title: 'Settings' };

export default async function Settings({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const me = await requireMe();
  if (!isAdmin(me)) redirect('/today');
  const sp = await searchParams;
  const { org, notices, consent } = await db(me, async (d) => ({
    org: await d.one<{ weekly_holidays: number[]; report_recipients: string[]; monitoring_notice_confirmed_at: string | null; screenshot_retention_days: number }>(
      `select weekly_holidays, report_recipients, monitoring_notice_confirmed_at, screenshot_retention_days from org_settings`),
    notices: await d.query<{ version: number; title: string; published_at: string | null }>(`select version, title, published_at from notice_versions order by version desc`),
    consent: await d.one<{ consented: number; total: number }>(`
      select (select count(*) from notice_consents c join profiles p on p.id = c.user_id
               where p.active and c.version = (select max(version) from notice_versions where published_at is not null))::int as consented,
             (select count(*) from profiles where active)::int as total`),
  }));
  const latest = notices.find((n) => n.published_at);
  const monitoringOn = Boolean(org?.monitoring_notice_confirmed_at && latest);

  return (
    <>
      <h1>Settings</h1>
      {sp.published && <p className="notice ok" role="status">Notice version {Number(sp.published)} published. Everyone will be asked to consent when they next open TeamPulse.</p>}
      {sp.confirmed && <p className="notice ok" role="status">Confirmed. Monitoring is now allowed for people who have consented.</p>}

      <div className="card">
        <h2>Monitoring status</h2>
        <p data-testid="monitoring-status">
          {monitoringOn ? <span className="badge ok">On</span> : <span className="badge warn">Off</span>}{' '}
          {monitoringOn
            ? `Notice version ${latest!.version} is published and you confirmed it was issued on ${fmtDateTime(org!.monitoring_notice_confirmed_at!)}. Activity is recorded only for people who consented (${consent?.consented} of ${consent?.total}).`
            : 'Nothing is recorded from anyone’s computer until a notice is published and you confirm it was issued to the team.'}
        </p>
        {latest && !org?.monitoring_notice_confirmed_at && (
          <ActionForm action={confirmNoticeAction}>
            <p className="small">Confirm only after every employee has received the notice (for example in a staff meeting or by email) and had the chance to ask questions.</p>
            <Submit className="btn warn" testId="confirm-notice">I confirm the notice was issued to all employees</Submit>
          </ActionForm>
        )}
      </div>

      <div className="card">
        <h2>Monitoring and HR data notice</h2>
        {notices.length > 0 && (
          <ul className="small">{notices.map((n) => <li key={n.version}>Version {n.version}: {n.title} — {n.published_at ? `published ${fmtDateTime(n.published_at)}` : 'draft'}</li>)}</ul>
        )}
        <details open={notices.length === 0}>
          <summary><strong>{notices.length ? 'Publish a new version' : 'Publish the first notice'}</strong></summary>
          <p className="notice warn small" style={{ marginTop: 12 }}>Fill in the [bracketed] parts before publishing. Publishing a new version asks everyone to consent again; monitoring pauses for each person until they do.</p>
          <ActionForm action={publishNoticeAction}>
            <div className="field"><label htmlFor="n-title">Title</label><input id="n-title" name="title" defaultValue={NOTICE_TITLE} required /></div>
            <div className="field"><label htmlFor="n-en">English text</label><textarea id="n-en" name="body_en" defaultValue={NOTICE_EN} rows={14} required /></div>
            <div className="field"><label htmlFor="n-ne">Nepali text (check with a fluent reader)</label><textarea id="n-ne" name="body_ne" defaultValue={NOTICE_NE} rows={10} lang="ne" /></div>
            <Submit testId="publish-notice">Publish notice</Submit>
          </ActionForm>
        </details>
      </div>

      <div className="card">
        <h2>Company settings</h2>
        <ActionForm action={saveOrgAction}>
          <fieldset style={{ border: 0, padding: 0, margin: '0 0 12px' }}>
            <legend style={{ fontWeight: 600, marginBottom: 6 }}>Weekly holiday</legend>
            <div className="row">
              {[7, 1, 2, 3, 4, 5, 6].map((d) => (
                <label key={d} style={{ fontWeight: 400 }}>
                  <input type="checkbox" name="weekly" value={d} defaultChecked={org?.weekly_holidays.includes(d)} style={{ width: 'auto', minHeight: 0, marginRight: 4 }} />{WEEKDAY[d]}
                </label>
              ))}
            </div>
          </fieldset>
          <div className="field"><label htmlFor="recips">Report recipients (comma-separated)</label>
            <input id="recips" name="recipients" defaultValue={org?.report_recipients.join(', ')} /></div>
          <Submit>Save settings</Submit>
        </ActionForm>
        <p className="small muted" style={{ marginTop: 12 }}>Screenshots are kept {org?.screenshot_retention_days} days, then deleted automatically.</p>
      </div>
    </>
  );
}
