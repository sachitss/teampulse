import Link from 'next/link';
import { requireMe, db, isManagerOrAbove } from '@/lib/me';
import { monthSheet } from '@/lib/timesheet';
import { todayBs, MONTHS_EN, FIRST_BS_YEAR, LAST_BS_YEAR } from '@teampulse/bs-calendar';
import { minutesHm, fmtAdShort, WEEKDAY } from '@/lib/format';
import { ActionForm, Submit } from '@/components/action-form';
import { submitAction } from './actions';

export const metadata = { title: 'Timesheet' };

const STATUS: Record<string, { label: string; cls: string }> = {
  open: { label: 'Open', cls: 'grey' }, submitted: { label: 'Submitted', cls: 'warn' },
  approved: { label: 'Approved', cls: 'ok' }, locked: { label: 'Locked for payroll', cls: 'ok' },
};

function shift(y: number, m: number, by: number) {
  let mm = m + by, yy = y;
  if (mm < 1) { mm = 12; yy--; } if (mm > 12) { mm = 1; yy++; }
  return { y: yy, m: mm };
}

export default async function Timesheet({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const me = await requireMe();
  const sp = await searchParams;
  const now = todayBs();
  const y = Math.min(LAST_BS_YEAR, Math.max(FIRST_BS_YEAR, Number(sp.y) || now.year));
  const m = Math.min(12, Math.max(1, Number(sp.m) || now.month));
  const userId = sp.user && isManagerOrAbove(me) ? sp.user : me.id;

  const { sheet, person, team } = await db(me, async (d) => ({
    sheet: await monthSheet(d, userId, y, m),
    person: await d.one<{ full_name: string }>(`select full_name from profiles where id = $1`, [userId]),
    team: isManagerOrAbove(me)
      ? await d.query<{ id: string; full_name: string }>(`select id, full_name from profiles where active and id <> auth.uid() and (manager_id = auth.uid() or app.is_hr()) order by full_name`)
      : [],
  }));
  const prev = shift(y, m, -1), next = shift(y, m, 1);
  const q = (p: { y: number; m: number }) => `/timesheet?y=${p.y}&m=${p.m}${userId !== me.id ? `&user=${userId}` : ''}`;
  const st = STATUS[sheet.period.status];
  const mine = userId === me.id;

  return (
    <>
      <div className="spread">
        <div>
          <h1>{mine ? 'My timesheet' : person?.full_name ?? 'Timesheet'}</h1>
          <p className="muted">{sheet.label} · {fmtAdShort(sheet.range.startAd)} – {fmtAdShort(sheet.range.endAd)}
            {sheet.range.provisional && <> · <span className="badge warn" title="The official calendar for this year is not published yet">provisional calendar</span></>}</p>
        </div>
        <div className="row">
          <Link className="btn secondary small" href={q(prev)} aria-label="Previous month">← {MONTHS_EN[prev.m - 1]}</Link>
          <Link className="btn secondary small" href={q(next)} aria-label="Next month">{MONTHS_EN[next.m - 1]} →</Link>
        </div>
      </div>

      {team.length > 0 && (
        <form className="row" style={{ margin: '8px 0 16px' }}>
          <input type="hidden" name="y" value={y} /><input type="hidden" name="m" value={m} />
          <select name="user" defaultValue={userId} aria-label="Person" style={{ maxWidth: 320 }}>
            <option value={me.id}>Me</option>
            {team.map((t) => <option key={t.id} value={t.id}>{t.full_name}</option>)}
          </select>
          <button className="btn secondary small">Show</button>
        </form>
      )}

      <div className="grid three">
        <div className="card"><div className="muted small">Recorded</div><div className="clock" style={{ fontSize: '1.8rem' }} data-testid="month-total">{minutesHm(sheet.totalMinutes)}</div></div>
        <div className="card"><div className="muted small">Waiting for approval</div><div className="clock" style={{ fontSize: '1.8rem' }}>{minutesHm(sheet.pendingMinutes)}</div></div>
        <div className="card"><div className="muted small">Status</div><div style={{ marginTop: 8 }}><span className={`badge ${st.cls}`} data-testid="period-status">{st.label}</span></div>
          {mine && sheet.period.status === 'open' && (
            <ActionForm action={submitAction} className="stack" >
              <input type="hidden" name="y" value={y} /><input type="hidden" name="m" value={m} />
              <Submit className="btn small" testId="submit-month">Submit {MONTHS_EN[m - 1]} for approval</Submit>
            </ActionForm>
          )}
        </div>
      </div>

      <div className="card table-wrap">
        <table>
          <thead><tr><th>BS</th><th>Day</th><th>AD</th><th>Time</th><th></th></tr></thead>
          <tbody>
            {sheet.days.map((d) => (
              <tr key={d.ad} className={d.onLeave ? 'leave' : d.holiday ? 'holiday' : undefined}>
                <td className="num">{d.bsDay}</td>
                <td>{WEEKDAY[d.weekday]}</td>
                <td className="num small muted">{fmtAdShort(d.ad)}</td>
                <td className="num">{d.minutes ? minutesHm(d.minutes) : <span className="muted">—</span>}
                  {d.pendingMinutes > 0 && <span className="badge warn" style={{ marginLeft: 6 }}>+{minutesHm(d.pendingMinutes)} pending</span>}</td>
                <td className="small">{d.onLeave ? 'Leave' : d.holiday ? 'Holiday' : ''}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}
