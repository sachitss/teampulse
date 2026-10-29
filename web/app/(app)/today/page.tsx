import { requireMe, db } from '@/lib/me';
import { getTimerState } from '@/lib/timer';
import { fmtTime, fmtDayOf, minutesHm } from '@/lib/format';
import { TimerPanel } from './timer-panel';
import { ManualEntry } from './manual-entry';

export const metadata = { title: 'Today' };

export default async function Today() {
  const me = await requireMe();
  const { state, tasks, entries } = await db(me, async (d) => ({
    state: await getTimerState(d),
    tasks: await d.query<{ id: string; title: string; project: string; mine: boolean }>(`
      select t.id, t.title, p.name as project, (t.assignee_id = auth.uid()) as mine
        from tasks t join projects p on p.id = t.project_id
       where p.active and t.status in ('todo', 'in_progress')
       order by (t.assignee_id = auth.uid()) desc, p.name, t.title limit 200`),
    entries: await d.query<{ id: string; started_at: string; ended_at: string | null; task: string | null; project: string | null; source: string; approval: string }>(`
      select e.id, e.started_at, e.ended_at, t.title as task, p.name as project, e.source, e.approval
        from time_entries e left join tasks t on t.id = e.task_id left join projects p on p.id = t.project_id
       where e.user_id = auth.uid() and e.started_at >= app.kathmandu_day_start(app.kathmandu_date(now()))
       order by e.started_at desc`),
  }));

  return (
    <>
      <div className="spread" style={{ marginBottom: 12 }}>
        <div>
          <h1>Namaste, {me.fullName.replace(/^\[DEMO\]\s*/, '').split(' ')[0]}</h1>
          <p className="muted">{fmtDayOf(state.now)}</p>
        </div>
        {state.isHoliday && <span className="badge warn">Holiday today — time counts as holiday work</span>}
        {state.onLeave && <span className="badge">On approved leave today</span>}
      </div>

      <TimerPanel state={state} tasks={tasks} />

      <div className="card">
        <div className="spread"><h2>Today’s time</h2><strong className="num">{minutesHm(state.todayMinutes)}</strong></div>
        {entries.length === 0 ? <p className="muted">Nothing recorded yet today.</p> : (
          <div className="table-wrap">
            <table>
              <thead><tr><th>From</th><th>To</th><th>Task</th><th></th></tr></thead>
              <tbody>
                {entries.map((e) => (
                  <tr key={e.id}>
                    <td className="num">{fmtTime(e.started_at)}</td>
                    <td className="num">{e.ended_at ? fmtTime(e.ended_at) : <span className="badge ok">running</span>}</td>
                    <td>{e.task ?? <span className="muted">Unassigned</span>}{e.project && <div className="small muted">{e.project}</div>}</td>
                    <td>{e.source === 'manual' && <span className={`badge ${e.approval === 'approved' ? 'ok' : e.approval === 'rejected' ? 'bad' : 'warn'}`}>{e.approval}</span>}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>

      <ManualEntry tasks={tasks} />
    </>
  );
}
