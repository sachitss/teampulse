import Link from 'next/link';
import { redirect } from 'next/navigation';
import { requireMe, db, isManagerOrAbove } from '@/lib/me';
import { minutesHm } from '@/lib/format';
import { ActionForm, Submit } from '@/components/action-form';
import { createProjectAction } from './actions';

export const metadata = { title: 'Projects' };

export default async function Projects() {
  const me = await requireMe();
  if (!isManagerOrAbove(me)) redirect('/today');
  const projects = await db(me, (d) => d.query<{ id: string; name: string; client: string | null; active: boolean; open_tasks: number; tasks: number; est: number; minutes: number }>(`
    select p.id, p.name, p.client, p.active,
           count(t.id) filter (where t.status in ('todo', 'in_progress'))::int as open_tasks,
           count(t.id)::int as tasks,
           coalesce(sum(t.estimate_minutes), 0)::int as est,
           coalesce((select round(sum(extract(epoch from (coalesce(e.ended_at, now()) - e.started_at))) / 60)::int
                       from time_entries e join tasks t2 on t2.id = e.task_id
                      where t2.project_id = p.id and e.approval = 'approved'), 0) as minutes
      from projects p left join tasks t on t.project_id = p.id
     group by p.id order by p.active desc, p.name`));
  return (
    <>
      <h1>Projects</h1>
      <p className="muted small">Time shown is what your access lets you see — managers see their own team’s time.</p>
      <div className="card table-wrap">
        <table>
          <thead><tr><th>Project</th><th>Open tasks</th><th>Estimate</th><th>Recorded</th></tr></thead>
          <tbody>
            {projects.map((p) => (
              <tr key={p.id}>
                <td><Link href={`/projects/${p.id}`}>{p.name}</Link>{!p.active && <span className="badge grey" style={{ marginLeft: 6 }}>closed</span>}
                  {p.client && <div className="small muted">{p.client}</div>}</td>
                <td className="num">{p.open_tasks} / {p.tasks}</td>
                <td className="num">{p.est ? minutesHm(p.est) : '—'}</td>
                <td className="num">{minutesHm(p.minutes)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div className="card">
        <h2>New project</h2>
        <ActionForm action={createProjectAction} resetOnOk>
          <div className="grid two">
            <div className="field"><label htmlFor="p-name">Name</label><input id="p-name" name="name" required maxLength={120} /></div>
            <div className="field"><label htmlFor="p-client">Client</label><input id="p-client" name="client" maxLength={120} /></div>
          </div>
          <Submit testId="create-project">Create project</Submit>
        </ActionForm>
      </div>
    </>
  );
}
