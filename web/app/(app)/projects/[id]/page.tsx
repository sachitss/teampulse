import { notFound, redirect } from 'next/navigation';
import Link from 'next/link';
import { requireMe, db, isManagerOrAbove } from '@/lib/me';
import { minutesHm, fmtAdShort } from '@/lib/format';
import { ActionForm, Submit } from '@/components/action-form';
import { createTaskAction, updateTaskAction, setProjectActiveAction } from '../actions';

export const metadata = { title: 'Project' };

const STATUSES = ['todo', 'in_progress', 'done', 'cancelled'] as const;
const LABEL: Record<string, string> = { todo: 'To do', in_progress: 'In progress', done: 'Done', cancelled: 'Cancelled' };

export default async function ProjectPage({ params }: { params: Promise<{ id: string }> }) {
  const me = await requireMe();
  if (!isManagerOrAbove(me)) redirect('/today');
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const data = await db(me, async (d) => {
    const project = await d.one<{ id: string; name: string; client: string | null; active: boolean }>(`select id, name, client, active from projects where id = $1`, [id]);
    if (!project) return null;
    const tasks = await d.query<{ id: string; title: string; status: string; assignee_id: string | null; assignee: string | null; estimate_minutes: number | null; deadline: string | null; priority: number; minutes: number }>(`
      select t.id, t.title, t.status, t.assignee_id, p.full_name as assignee, t.estimate_minutes, t.deadline::text, t.priority,
             coalesce((select round(sum(extract(epoch from (coalesce(e.ended_at, now()) - e.started_at))) / 60)::int
                         from time_entries e where e.task_id = t.id and e.approval = 'approved'), 0) as minutes
        from tasks t left join profiles p on p.id = t.assignee_id
       where t.project_id = $1
       order by case t.status when 'in_progress' then 1 when 'todo' then 2 when 'done' then 3 else 4 end, t.priority, t.deadline nulls last`, [id]);
    const people = await d.query<{ id: string; full_name: string }>(`select id, full_name from profiles where active order by full_name`);
    return { project, tasks, people };
  });
  if (!data) notFound();
  const { project, tasks, people } = data;

  return (
    <>
      <p className="small"><Link href="/projects">← Projects</Link></p>
      <div className="spread">
        <div><h1>{project.name}</h1>{project.client && <p className="muted">{project.client}</p>}</div>
        <ActionForm action={setProjectActiveAction}>
          <input type="hidden" name="id" value={project.id} /><input type="hidden" name="active" value={project.active ? '0' : '1'} />
          <Submit className="btn secondary small">{project.active ? 'Close project' : 'Re-open project'}</Submit>
        </ActionForm>
      </div>

      <div className="card table-wrap">
        <table>
          <thead><tr><th>Task</th><th>Assignee</th><th>Estimate / recorded</th><th>Due</th><th>Status</th></tr></thead>
          <tbody>
            {tasks.map((t) => {
              const over = t.estimate_minutes != null && t.minutes > t.estimate_minutes;
              return (
                <tr key={t.id}>
                  <td>{t.title}{t.priority === 1 && <span className="badge bad" style={{ marginLeft: 6 }}>urgent</span>}</td>
                  <td colSpan={4}>
                    <ActionForm action={updateTaskAction} className="row">
                      <input type="hidden" name="id" value={t.id} /><input type="hidden" name="project" value={project.id} />
                      <select name="assignee" defaultValue={t.assignee_id ?? ''} aria-label="Assignee" style={{ maxWidth: 200 }}>
                        <option value="">Unassigned</option>{people.map((p) => <option key={p.id} value={p.id}>{p.full_name}</option>)}
                      </select>
                      <span className={`num small ${over ? 'badge bad' : 'muted'}`}>{t.estimate_minutes ? minutesHm(t.estimate_minutes) : '—'} / {minutesHm(t.minutes)}</span>
                      <span className="small muted">{t.deadline ? fmtAdShort(t.deadline) : ''}</span>
                      <select name="status" defaultValue={t.status} aria-label="Status" style={{ maxWidth: 150 }}>
                        {STATUSES.map((s) => <option key={s} value={s}>{LABEL[s]}</option>)}
                      </select>
                      <Submit className="btn small secondary">Save</Submit>
                    </ActionForm>
                  </td>
                </tr>
              );
            })}
            {tasks.length === 0 && <tr><td colSpan={5} className="muted">No tasks yet.</td></tr>}
          </tbody>
        </table>
      </div>

      {project.active && (
        <div className="card">
          <h2>New task</h2>
          <ActionForm action={createTaskAction} resetOnOk>
            <input type="hidden" name="project" value={project.id} />
            <div className="field"><label htmlFor="t-title">Title</label><input id="t-title" name="title" required maxLength={200} /></div>
            <div className="grid three">
              <div className="field"><label htmlFor="t-assignee">Assignee</label>
                <select id="t-assignee" name="assignee"><option value="">Unassigned</option>{people.map((p) => <option key={p.id} value={p.id}>{p.full_name}</option>)}</select></div>
              <div className="field"><label htmlFor="t-est">Estimate (hours)</label><input id="t-est" name="estimate" type="number" min="0.25" step="0.25" /></div>
              <div className="field"><label htmlFor="t-due">Due date</label><input id="t-due" name="deadline" type="date" /></div>
            </div>
            <div className="field"><label htmlFor="t-prio">Priority</label>
              <select id="t-prio" name="priority" defaultValue="2"><option value="1">Urgent</option><option value="2">Normal</option><option value="3">Low</option></select></div>
            <Submit testId="create-task">Add task</Submit>
          </ActionForm>
        </div>
      )}
    </>
  );
}
