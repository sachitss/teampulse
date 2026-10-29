import Link from 'next/link';
import { notFound, redirect } from 'next/navigation';
import { requireMe, db, isHr, isAdmin } from '@/lib/me';
import { fmtDateTime } from '@/lib/format';
import { ActionForm, Submit } from '@/components/action-form';
import { PersonFields } from '../person-form';
import { managersAndTeams } from '../data';
import { updatePersonAction, signInHelpAction } from '../actions';
import { signInStatus } from '@/lib/accounts';

export const metadata = { title: 'Employee' };

export default async function PersonPage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ invite?: string }> }) {
  const me = await requireMe();
  if (!isHr(me)) redirect('/today');
  const { id } = await params;
  const { invite } = await searchParams;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const data = await db(me, async (d) => {
    const p = await d.one(`
      select p.*, p.join_date::text as join_date, p.probation_end::text as probation_end, p.exit_date::text as exit_date, e.gender
        from profiles p left join employee_profiles e on e.user_id = p.id where p.id = $1`, [id]);
    if (!p) return null;
    const consents = await d.query<{ version: number; consented_at: string; channel: string }>(
      `select version, consented_at, channel from notice_consents where user_id = $1 order by version desc`, [id]);
    return { p, consents, ...(await managersAndTeams(d)) };
  });
  if (!data) notFound();
  const { p, consents, managers, teams } = data;
  const signIn = isAdmin(me) ? await signInStatus(id) : null;
  return (
    <>
      <p className="small"><Link href="/people">← People</Link></p>
      <h1>{p.full_name}</h1>
      <p className="muted">{p.email}</p>
      {invite === 'emailed' && <p className="notice ok" role="status">Employee added. The invitation was emailed to {p.email}.</p>}
      {invite === 'pending' && <p className="notice warn" role="status">Employee added. Email is not set up, so create the invitation link under “Sign-in” below and give it to them yourself.</p>}
      <div className="card">
        <ActionForm action={updatePersonAction}>
          <input type="hidden" name="id" value={p.id} />
          <PersonFields v={p} managers={managers.filter((m) => m.id !== p.id)} teams={teams} canAdmin={isAdmin(me)} />
          <Submit testId="save-person">Save</Submit>
          {!isAdmin(me) && <p className="small muted" style={{ marginTop: 8 }}>Only an admin can change role, reporting line or active status.</p>}
        </ActionForm>
      </div>
      {signIn && (
        <div className="card">
          <h2>Sign-in</h2>
          <ul className="small">
            <li>Password: {signIn.hasPassword ? 'set' : signIn.pendingInvite ? 'invitation sent, not used yet' : 'not set'}{signIn.locked && <strong> — locked after too many attempts</strong>}</li>
            <li>Two-factor: {signIn.hasMfa ? 'set up' : 'not set up'}{(p.role === 'hr' || p.role === 'admin') && !signIn.hasMfa ? ' (needed for HR/admin rights)' : ''}</li>
            <li>Last sign-in: {signIn.lastSignIn ? fmtDateTime(signIn.lastSignIn) : 'never'}</li>
          </ul>
          <ActionForm action={signInHelpAction} className="row">
            <input type="hidden" name="id" value={p.id} />
            {signIn.hasPassword
              ? <Submit name="what" value="reset" className="btn small secondary" testId="reset-link">Password reset link</Submit>
              : <Submit name="what" value="invite" className="btn small secondary" testId="invite-link">{signIn.pendingInvite ? 'New invitation link' : 'Create invitation link'}</Submit>}
            {signIn.hasMfa && p.id !== me.id && <Submit name="what" value="mfa" className="btn small secondary" testId="reset-mfa">Reset two-factor</Submit>}
            {signIn.locked && <Submit name="what" value="unlock" className="btn small secondary">Unlock</Submit>}
          </ActionForm>
        </div>
      )}
      <div className="card">
        <h2>Notice consent</h2>
        {consents.length === 0 ? <p className="muted">Not consented yet. Nothing is recorded from their computer until they do.</p>
          : <ul>{consents.map((c) => <li key={c.version}>Version {c.version} — {fmtDateTime(c.consented_at)} ({c.channel})</li>)}</ul>}
      </div>
    </>
  );
}
