'use server';
import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { requireMe, db } from '@/lib/me';
import { friendlyError } from '@/lib/db';
import type { ActionResult } from '@/components/action-form';

const uuid = z.string().uuid();
const optUuid = z.string().uuid().or(z.literal('')).transform((v) => v || null);

export async function createProjectAction(_: ActionResult, f: FormData): Promise<ActionResult> {
  const me = await requireMe();
  const p = z.object({ name: z.string().trim().min(2).max(120), client: z.string().trim().max(120) })
    .safeParse({ name: f.get('name'), client: f.get('client') ?? '' });
  if (!p.success) return { error: 'Please give the project a name (at least 2 characters).' };
  try {
    await db(me, (d) => d.query(`insert into projects (name, client, created_by) values ($1, nullif($2, ''), auth.uid())`, [p.data.name, p.data.client]));
    revalidatePath('/projects');
    return { ok: `Project “${p.data.name}” created.` };
  } catch (e) { return { error: friendlyError(e) }; }
}

export async function setProjectActiveAction(_: ActionResult, f: FormData): Promise<ActionResult> {
  const me = await requireMe();
  const id = uuid.safeParse(f.get('id'));
  if (!id.success) return { error: 'Unknown project.' };
  try {
    await db(me, (d) => d.query(`update projects set active = $2 where id = $1`, [id.data, f.get('active') === '1']));
    revalidatePath(`/projects/${id.data}`);
    return null;
  } catch (e) { return { error: friendlyError(e) }; }
}

export async function createTaskAction(_: ActionResult, f: FormData): Promise<ActionResult> {
  const me = await requireMe();
  const p = z.object({
    project: uuid, title: z.string().trim().min(2).max(200), assignee: optUuid,
    estimate: z.string().transform((v) => (v ? Math.round(Number(v) * 60) : null)).refine((v) => v === null || (v > 0 && v < 100000)),
    deadline: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).or(z.literal('')).transform((v) => v || null),
    priority: z.coerce.number().int().min(1).max(4),
  }).safeParse(Object.fromEntries(['project', 'title', 'assignee', 'estimate', 'deadline', 'priority'].map((k) => [k, String(f.get(k) ?? '')])));
  if (!p.success) return { error: 'Please check the task details.' };
  try {
    await db(me, (d) => d.query(`insert into tasks (project_id, title, assignee_id, estimate_minutes, deadline, priority, created_by)
                                 values ($1, $2, $3, $4, $5, $6, auth.uid())`,
      [p.data.project, p.data.title, p.data.assignee, p.data.estimate, p.data.deadline, p.data.priority]));
    revalidatePath(`/projects/${p.data.project}`);
    return { ok: 'Task added.' };
  } catch (e) { return { error: friendlyError(e) }; }
}

export async function updateTaskAction(_: ActionResult, f: FormData): Promise<ActionResult> {
  const me = await requireMe();
  const p = z.object({ id: uuid, project: uuid, assignee: optUuid, status: z.enum(['todo', 'in_progress', 'done', 'cancelled']) })
    .safeParse({ id: f.get('id'), project: f.get('project'), assignee: String(f.get('assignee') ?? ''), status: f.get('status') });
  if (!p.success) return { error: 'Please check the task details.' };
  try {
    const r = await db(me, (d) => d.query(`update tasks set assignee_id = $2, status = $3 where id = $1 returning id`, [p.data.id, p.data.assignee, p.data.status]));
    if (r.length === 0) return { error: 'You cannot change this task.' };
    revalidatePath(`/projects/${p.data.project}`);
    return { ok: 'Saved.' };
  } catch (e) { return { error: friendlyError(e) }; }
}
