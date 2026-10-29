'use server';
import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { z } from 'zod';
import { requireMe, db, isAdmin, isHr } from '@/lib/me';
import { friendlyError } from '@/lib/db';
import { createLoginAccount, removeLoginAccount } from '@/lib/accounts';
import type { ActionResult } from '@/components/action-form';

const optUuid = z.string().uuid().or(z.literal('')).transform((v) => v || null);
const optDate = z.string().regex(/^\d{4}-\d{2}-\d{2}$/).or(z.literal('')).transform((v) => v || null);
const fields = z.object({
  full_name: z.string().trim().min(2).max(120),
  role: z.enum(['employee', 'manager', 'hr', 'admin']).optional(),
  manager_id: optUuid.optional(),
  team_id: optUuid,
  job_title: z.string().trim().max(120).transform((v) => v || null),
  employment_type: z.enum(['regular', 'probation', 'contract']),
  gender: z.enum(['female', 'male', 'other']).or(z.literal('')).transform((v) => v || null),
  join_date: optDate, probation_end: optDate, exit_date: optDate,
});
const read = (f: FormData, keys: string[]) => Object.fromEntries(keys.filter((k) => f.has(k)).map((k) => [k, String(f.get(k))]));
const KEYS = ['full_name', 'role', 'manager_id', 'team_id', 'job_title', 'employment_type', 'gender', 'join_date', 'probation_end', 'exit_date'];

export async function createPersonAction(_: ActionResult, f: FormData): Promise<ActionResult> {
  const me = await requireMe();
  if (!isAdmin(me)) return { error: 'Only an admin can add employees.' };
  const email = z.string().trim().toLowerCase().email().safeParse(f.get('email'));
  const p = fields.safeParse(read(f, KEYS));
  if (!email.success) return { error: 'Please enter a valid work email.' };
  if (!p.success) return { error: 'Please check the details (name is required).' };
  const exists = await db(me, (d) => d.one(`select 1 from profiles where lower(email) = $1`, [email.data]));
  if (exists) return { error: 'Someone with that email address already exists.' };

  let account: { userId: string; invited: boolean };
  try { account = await createLoginAccount(email.data); } catch (e) { return { error: (e as Error).message }; }
  try {
    await db(me, async (d) => {
      const v = p.data;
      await d.query(`insert into profiles (id, email, full_name, role, manager_id, team_id, job_title, employment_type, join_date, probation_end, exit_date)
                     values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)`,
        [account.userId, email.data, v.full_name, v.role ?? 'employee', v.manager_id ?? null, v.team_id, v.job_title, v.employment_type,
         v.join_date, v.probation_end, v.exit_date]);
      await d.query(`insert into employee_profiles (user_id, gender) values ($1, $2)`, [account.userId, v.gender]);
      // Start their onboarding checklist from the standard template.
      await d.query(`
        with c as (insert into checklists (user_id, template_id, kind, anchor_date, started_by)
                   select $1, t.id, 'onboarding', coalesce($2::date, current_date), auth.uid() from checklist_templates t
                    where t.kind = 'onboarding' and t.active order by t.name limit 1 returning id, template_id, anchor_date)
        insert into checklist_items (checklist_id, position, title, due_on, action)
        select c.id, i.position, i.title, c.anchor_date + i.due_offset_days, i.action from c join checklist_template_items i on i.template_id = c.template_id`,
        [account.userId, v.join_date]);
    });
  } catch (e) {
    await removeLoginAccount(account.userId).catch(() => {});
    return { error: friendlyError(e) };
  }
  revalidatePath('/people');
  redirect(`/people/${account.userId}`);
}

export async function updatePersonAction(_: ActionResult, f: FormData): Promise<ActionResult> {
  const me = await requireMe();
  if (!isHr(me)) return { error: 'Only HR or an admin can edit employees.' };
  const id = z.string().uuid().safeParse(f.get('id'));
  const p = fields.safeParse(read(f, KEYS));
  if (!id.success || !p.success) return { error: 'Please check the details.' };
  const v = p.data;
  try {
    await db(me, async (d) => {
      const cur = await d.one(`select role, manager_id, active from profiles where id = $1`, [id.data]);
      if (!cur) throw Object.assign(new Error('Not found'), { code: '42501' });
      const admin = isAdmin(me);
      await d.query(`update profiles set full_name = $2, role = $3, manager_id = $4, team_id = $5, job_title = $6, employment_type = $7,
                                         join_date = $8, probation_end = $9, exit_date = $10, active = $11 where id = $1`,
        [id.data, v.full_name, admin && v.role ? v.role : cur.role, admin ? (v.manager_id ?? null) : cur.manager_id, v.team_id, v.job_title,
         v.employment_type, v.join_date, v.probation_end, v.exit_date, admin ? f.get('active') === '1' : cur.active]);
      await d.query(`insert into employee_profiles (user_id, gender) values ($1, $2)
                     on conflict (user_id) do update set gender = excluded.gender`, [id.data, v.gender]);
    });
    revalidatePath(`/people/${id.data}`);
    revalidatePath('/people');
    return { ok: 'Saved.' };
  } catch (e) { return { error: friendlyError(e) }; }
}
