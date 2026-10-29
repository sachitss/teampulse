import Link from 'next/link';
import { redirect } from 'next/navigation';
import { requireMe, db, isHr, isAdmin } from '@/lib/me';
import { fmtAdShort } from '@/lib/format';

export const metadata = { title: 'People' };

export default async function People() {
  const me = await requireMe();
  if (!isHr(me)) redirect('/today');
  const people = await db(me, (d) => d.query<{ id: string; full_name: string; email: string; role: string; manager: string | null; team: string | null; job_title: string | null; employment_type: string; join_date: string | null; active: boolean; consented: boolean; devices: number }>(`
    select p.id, p.full_name, p.email, p.role, m.full_name as manager, t.name as team, p.job_title, p.employment_type,
           p.join_date::text, p.active,
           exists (select 1 from notice_consents c where c.user_id = p.id
                     and c.version = (select max(version) from notice_versions where published_at is not null)) as consented,
           (select count(*) from devices dv where dv.user_id = p.id and dv.revoked_at is null)::int as devices
      from profiles p left join profiles m on m.id = p.manager_id left join teams t on t.id = p.team_id
     order by p.active desc, p.full_name`));
  const active = people.filter((p) => p.active).length;
  return (
    <>
      <div className="spread">
        <div><h1>People</h1><p className="muted">{active} active · {people.length - active} inactive</p></div>
        {isAdmin(me) && <Link className="btn" href="/people/new">Add employee</Link>}
      </div>
      <div className="card table-wrap">
        <table>
          <thead><tr><th>Name</th><th>Role</th><th>Manager / team</th><th>Joined</th><th>Notice</th></tr></thead>
          <tbody>
            {people.map((p) => (
              <tr key={p.id} style={p.active ? undefined : { opacity: 0.55 }}>
                <td><Link href={`/people/${p.id}`}>{p.full_name}</Link><div className="small muted">{p.job_title ?? p.email}</div></td>
                <td><span className="badge">{p.role}</span>{p.employment_type !== 'regular' && <div className="small muted">{p.employment_type}</div>}</td>
                <td className="small">{p.manager ?? '—'}<div className="muted">{p.team ?? ''}</div></td>
                <td className="small num">{p.join_date ? fmtAdShort(p.join_date) : '—'}</td>
                <td>{p.consented ? <span className="badge ok">consented</span> : <span className="badge warn">not yet</span>}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}
