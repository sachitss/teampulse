// Public privacy notice for the TeamPulse apps (App Store / Google Play require a URL).
// The binding, organisation-specific monitoring notice is the one each employee consents to in the app.
import Link from 'next/link';

export const metadata = { title: 'Privacy' };

export default function Privacy() {
  return (
    <main style={{ maxWidth: 760, margin: '0 auto', padding: '24px 16px 64px', lineHeight: 1.6 }}>
      <p className="small"><Link href="/sign-in">← TeamPulse</Link></p>
      <h1>TeamPulse privacy notice</h1>
      <p className="muted">Applies to the TeamPulse web app and the TeamPulse apps for iPhone and Android. Last updated 29 October 2026.</p>

      <h2>Who it is for</h2>
      <p>TeamPulse is an internal tool used by PEACE Consultancy for its own staff: work time, leave, holidays,
        payroll documents and administration. There is no public sign-up — accounts are created by the
        organisation’s administrator. If you are not an employee, the app is of no use to you and collects nothing.</p>

      <h2>Who is responsible</h2>
      <p>Your employer (PEACE Consultancy) decides what is recorded and is responsible for your data. The system runs on the
        organisation’s own server; no data is sold, shared with advertisers or used for tracking across other apps or websites.</p>

      <h2>What the phone app records</h2>
      <ul>
        <li>Your sign-in details (email, a hashed password, an encrypted two-factor key for HR and admin staff).</li>
        <li>What you enter yourself: work timers, breaks, tasks, manual time with reasons, leave requests, timesheet submissions and approvals.</li>
        <li>Technical records needed for security: sign-in times, the device type (browser user agent) and IP address of each sign-in, and an audit log of changes.</li>
      </ul>
      <p><strong>The phone app does not monitor you.</strong> It takes no screenshots, does not read other apps, contacts,
        photos, location, microphone or camera, and records nothing in the background. Nothing personal is stored on the phone itself.</p>

      <h2>Monitoring on company computers</h2>
      <p>Activity recording (for example app categories, idle time and screenshots during working sessions) happens only on
        company computers, only with the separate TeamPulse desktop agent, and only after the organisation has issued its
        monitoring notice <em>and</em> you have consented to it in TeamPulse. The exact rules, retention periods and your
        rights are in that notice, which you can read at any time under your account.</p>

      <h2>Who can see what</h2>
      <ul>
        <li>You see your own records.</li>
        <li>Your manager sees your team’s working time and leave, but never your salary.</li>
        <li>HR/Accounts see personnel and payroll records, but never screenshots.</li>
        <li>HR and admin access requires two-factor sign-in, and access to sensitive records is logged.</li>
      </ul>

      <h2>Your choices and rights</h2>
      <p>You can see and download your own records in TeamPulse, ask HR to correct them, and ask questions about how they are
        used. When you leave, your account is closed; records the law requires the organisation to keep (for example payroll and
        tax records) are kept for the legally required period and then deleted. Contact the organisation’s HR / administration
        for any request.</p>
    </main>
  );
}
