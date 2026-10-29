import Link from 'next/link';
import { redirect } from 'next/navigation';
import { requireMe, db, isManagerOrAbove } from '@/lib/me';
import { fmtDayOf, fmtTime, minutesHm } from '@/lib/format';
import { MONTHS_EN } from '@teampulse/bs-calendar';
import { ActionForm, Submit } from '@/components/action-form';
import { decideEntryAction, decidePeriodAction } from './actions';

export const metadata = { title: 'Approvals' };

const DONE: Record<string, string> = {
  'entry-approved': 'Time approved.', 'entry-rejected': 'Time rejected.',
  'period-approved': 'Timesheet approved.', 'period-open': 'Timesheet sent back to the employee.',
  'period-locked': 'Timesheet locked for payroll.',
};

export default async function Approvals({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const me = await requireMe();
  if (!isManagerOrAbove(me)) redirect('/today');
  const done = DONE[(await searchParams).done ?? ''];
  const { manual, periods } = await db(me, async (d) => ({
    // RLS limits this to the caller's direct reports (or everyone for HR/admin).
    manual: await d.query<{ id: string; full_name: string; started_at: string; ended_at: string; reason: string; task: string | null }>(`
      select e.id, p.full_name, e.started_at, e.ended_at, e.reason, t.title as task
        from time_entries e join profiles p on p.id = e.user_id left join tasks t on t.id = e.task_id
       where e.approval = 'pending' and e.user_id <> auth.uid()
       order by e.started_at`),
    periods: await d.query<{ id: string; user_id: string; full_name: string; bs_year: number; bs_month: number; status: string; minutes: number; ended: boolean }>(`
      select tp.id, tp.user_id, p.full_name, tp.bs_year, tp.bs_month, tp.status, (tp.end_ad < app.kathmandu_date(now())) as ended,
             coalesce((select round(sum(extract(epoch from (e.ended_at - e.started_at))) / 60)::int from time_entries e
                        where e.user_id = tp.user_id and e.approval = 'approved' and e.ended_at is not null
                          and app.kathmandu_date(e.started_at) between tp.start_ad and tp.end_ad), 0) as minutes
        from timesheet_periods tp join profiles p on p.id = tp.user_id
       where tp.status in ('submitted', 'approved') and tp.user_id <> auth.uid()
       order by tp.bs_year, tp.bs_month, p.full_name`),
  }));

  return (
    <>
      <h1>Approvals</h1>
      {done && <p className="notice ok" role="status">{done}</p>}
      <p className="muted">You see requests from the people who report to you{me.role === 'hr' || me.role === 'admin' ? ' (HR and admin see everyone)' : ''}.</p>

      <div className="card">
        <h2>Time added without the timer <span className="badge">{manual.length}</span></h2>
        {manual.length === 0 ? <p className="muted">Nothing waiting.</p> : manual.map((e) => (
          <div key={e.id} className="spread" style={{ borderTop: '1px solid var(--line)', padding: '10px 0' }}>
            <div>
              <strong>{e.full_name}</strong> · {fmtDayOf(e.started_at)} {fmtTime(e.started_at)}–{fmtTime(e.ended_at)}
              <span className="muted"> ({minutesHm((new Date(e.ended_at).getTime() - new Date(e.started_at).getTime()) / 60000)})</span>
              <div className="small">{e.task ?? 'Unassigned'} — “{e.reason}”</div>
            </div>
            <ActionForm action={decideEntryAction} className="row">
              <input type="hidden" name="id" value={e.id} />
              <Submit className="btn small" name="decision" value="approved" testId="approve-entry">Approve</Submit>
              <Submit className="btn small secondary" name="decision" value="rejected">Reject</Submit>
            </ActionForm>
          </div>
        ))}
      </div>

      <div className="card">
        <h2>Monthly timesheets <span className="badge">{periods.length}</span></h2>
        {periods.length === 0 ? <p className="muted">Nothing waiting.</p> : periods.map((p) => (
          <div key={p.id} className="spread" style={{ borderTop: '1px solid var(--line)', padding: '10px 0' }}>
            <div>
              <strong>{p.full_name}</strong> · {MONTHS_EN[p.bs_month - 1]} {p.bs_year} · <span className="num">{minutesHm(p.minutes)}</span>{' '}
              <span className={`badge ${p.status === 'approved' ? 'ok' : 'warn'}`}>{p.status}</span>
              <div className="small"><Link href={`/timesheet?y=${p.bs_year}&m=${p.bs_month}&user=${p.user_id}`}>Open timesheet</Link></div>
            </div>
            <ActionForm action={decidePeriodAction} className="row">
              <input type="hidden" name="id" value={p.id} />
              {p.status === 'submitted' && <>
                <Submit className="btn small" name="to" value="approved" testId="approve-period">Approve</Submit>
                <Submit className="btn small secondary" name="to" value="open">Send back</Submit>
              </>}
              {p.status === 'approved' && (p.ended
                ? <Submit className="btn small" name="to" value="locked" testId="lock-period">Lock for payroll</Submit>
                : <span className="small muted">Can be locked after the month ends</span>)}
            </ActionForm>
          </div>
        ))}
        <p className="small muted">Locking a month freezes its time entries for payroll. Only an admin can unlock it.</p>
      </div>
    </>
  );
}
