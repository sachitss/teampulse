// LOCAL DEVELOPMENT ONLY. Returns 404 in any production build.
import { notFound } from 'next/navigation';
import { devAuthEnabled } from '@/lib/auth';
import { asSystem } from '@/lib/db';
import { devSignIn } from './actions';

export const metadata = { title: 'Developer sign-in' };

export default async function DevLogin() {
  if (!devAuthEnabled()) notFound();
  const people = await asSystem((db) => db.query<{ id: string; full_name: string; email: string; role: string }>(
    `select id, full_name, email, role from profiles where active
      order by case role when 'admin' then 1 when 'hr' then 2 when 'manager' then 3 else 4 end, full_name limit 60`));
  return (
    <main>
      <h1>Developer sign-in</h1>
      <p className="notice warn">Local testing only. This page does not exist in a production build.</p>
      <div className="card table-wrap">
        <table>
          <thead><tr><th>Person</th><th>Role</th><th></th></tr></thead>
          <tbody>
            {people.map((p) => (
              <tr key={p.id}>
                <td>{p.full_name}<div className="small muted">{p.email}</div></td>
                <td><span className="badge">{p.role}</span></td>
                <td>
                  <form action={devSignIn} className="row">
                    <input type="hidden" name="id" value={p.id} />
                    <button className="btn small" name="mfa" value="1" data-testid={`login-${p.email}`}>Sign in (with 2FA)</button>
                    <button className="btn small secondary" name="mfa" value="0">without 2FA</button>
                  </form>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </main>
  );
}
