import Link from 'next/link';
import { redirect } from 'next/navigation';
import { requireMe, db, isAdmin } from '@/lib/me';
import { ActionForm, Submit } from '@/components/action-form';
import { PersonFields } from '../person-form';
import { managersAndTeams } from '../data';
import { createPersonAction } from '../actions';

export const metadata = { title: 'Add employee' };

export default async function NewPerson() {
  const me = await requireMe();
  if (!isAdmin(me)) redirect('/people');
  const { managers, teams } = await db(me, managersAndTeams);
  return (
    <>
      <p className="small"><Link href="/people">← People</Link></p>
      <h1>Add employee</h1>
      <p className="muted">They will get an email invitation to set a password. Salary, PAN and bank details are added by HR afterwards.</p>
      <div className="card">
        <ActionForm action={createPersonAction}>
          <PersonFields managers={managers} teams={teams} canAdmin isNew />
          <Submit testId="create-person">Add and send invitation</Submit>
        </ActionForm>
      </div>
    </>
  );
}
