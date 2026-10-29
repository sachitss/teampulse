// Work-session and timer logic for the signed-in person.
// All writes run as that person (RLS + triggers enforce the rules); this module only
// sequences them. Every timestamp comes from the database clock in one transaction,
// so "stop the old entry" and "start the new one" meet exactly with no gap or overlap.
import type { Db } from './db.ts';

export class TimerError extends Error {}

export interface TimerState {
  now: string;
  todayAd: string;
  session: { id: string; started_at: string; is_holiday_work: boolean; source: string } | null;
  running: { id: string; task_id: string | null; task_title: string | null; project_name: string | null; started_at: string } | null;
  onBreak: { id: string; kind: 'break' | 'privacy_pause'; started_at: string } | null;
  todayMinutes: number;
  isHoliday: boolean;
  onLeave: boolean;
}

export async function getTimerState(db: Db): Promise<TimerState> {
  const base = await db.one<{ now: string; today: string; is_holiday: boolean; on_leave: boolean }>(`
    select now() as now, app.kathmandu_date(now())::text as today,
           app.is_holiday_for(auth.uid(), app.kathmandu_date(now())) as is_holiday,
           exists (select 1 from leave_requests r where r.user_id = auth.uid() and r.status = 'approved'
                     and app.kathmandu_date(now()) between r.start_ad and r.end_ad) as on_leave`);
  const session = await db.one(`
    select id, started_at, is_holiday_work, source from work_sessions
     where user_id = auth.uid() and ended_at is null`);
  const running = await db.one(`
    select e.id, e.task_id, t.title as task_title, p.name as project_name, e.started_at
      from time_entries e left join tasks t on t.id = e.task_id left join projects p on p.id = t.project_id
     where e.user_id = auth.uid() and e.ended_at is null`);
  const onBreak = session
    ? await db.one(`select id, kind, started_at from breaks where session_id = $1 and ended_at is null`, [session.id])
    : null;
  const mins = await db.one<{ m: number }>(`
    select coalesce(round(sum(extract(epoch from (least(coalesce(ended_at, now()), app.kathmandu_day_start(app.kathmandu_date(now()) + 1))
                                         - greatest(started_at, app.kathmandu_day_start(app.kathmandu_date(now())))))) / 60), 0)::int as m
      from time_entries
     where user_id = auth.uid() and approval <> 'rejected'
       and started_at < app.kathmandu_day_start(app.kathmandu_date(now()) + 1)
       and coalesce(ended_at, now()) > app.kathmandu_day_start(app.kathmandu_date(now()))`);
  return {
    now: base!.now, todayAd: base!.today, session, running, onBreak, todayMinutes: mins?.m ?? 0,
    isHoliday: base!.is_holiday, onLeave: base!.on_leave,
  };
}

async function assertTaskUsable(db: Db, taskId: string | null) {
  if (!taskId) return;
  const t = await db.one(`select t.status, p.active from tasks t join projects p on p.id = t.project_id where t.id = $1`, [taskId]);
  if (!t) throw new TimerError('That task does not exist.');
  if (!t.active) throw new TimerError('That project is no longer active.');
  if (t.status === 'done' || t.status === 'cancelled') throw new TimerError('That task is closed.');
}

/** Start the working day (or a new session) on a task, or unassigned. */
export async function startWork(db: Db, taskId: string | null): Promise<void> {
  const s = await getTimerState(db);
  if (s.session) throw new TimerError('You have already started work. Use switch task, break or stop.');
  if (s.onLeave) throw new TimerError('You are on approved leave today. Cancel the leave first if you are working.');
  await assertTaskUsable(db, taskId);
  const session = await db.one<{ id: string }>(`
    insert into work_sessions (user_id, source, started_at, is_holiday_work)
    values (auth.uid(), 'web', now(), $1) returning id`, [s.isHoliday]);
  await db.query(`insert into time_entries (user_id, task_id, session_id, source, started_at)
                  values (auth.uid(), $1, $2, 'web', now())`, [taskId, session!.id]);
  if (taskId) await db.query(`update tasks set status = 'in_progress' where id = $1 and status = 'todo' and assignee_id = auth.uid()`, [taskId]);
}

/** Close the running entry and continue on another task with no gap. */
export async function switchTask(db: Db, taskId: string | null): Promise<void> {
  const s = await getTimerState(db);
  if (!s.running) throw new TimerError('No timer is running.');
  if ((s.running.task_id ?? null) === (taskId ?? null)) return;
  await assertTaskUsable(db, taskId);
  await db.query(`update time_entries set ended_at = now() where id = $1`, [s.running.id]);
  await db.query(`insert into time_entries (user_id, task_id, session_id, source, started_at)
                  values (auth.uid(), $1, $2, 'web', now())`, [taskId, s.session?.id ?? null]);
}

export async function startBreak(db: Db, kind: 'break' | 'privacy_pause' = 'break'): Promise<void> {
  const s = await getTimerState(db);
  if (!s.session) throw new TimerError('Start work before taking a break.');
  if (s.onBreak) throw new TimerError('You are already on a break.');
  if (s.running) await db.query(`update time_entries set ended_at = now() where id = $1`, [s.running.id]);
  await db.query(`insert into breaks (session_id, kind, started_at) values ($1, $2, now())`, [s.session.id, kind]);
}

/** End the break and continue on the same task as before (or another one). */
export async function resumeWork(db: Db, taskId?: string | null): Promise<void> {
  const s = await getTimerState(db);
  if (!s.session || !s.onBreak) throw new TimerError('You are not on a break.');
  let next = taskId;
  if (next === undefined) {
    const last = await db.one<{ task_id: string | null }>(`
      select task_id from time_entries where session_id = $1 order by started_at desc limit 1`, [s.session.id]);
    next = last?.task_id ?? null;
  }
  await assertTaskUsable(db, next ?? null);
  await db.query(`update breaks set ended_at = now() where id = $1`, [s.onBreak.id]);
  await db.query(`insert into time_entries (user_id, task_id, session_id, source, started_at)
                  values (auth.uid(), $1, $2, 'web', now())`, [next ?? null, s.session.id]);
}

export async function stopWork(db: Db): Promise<void> {
  const s = await getTimerState(db);
  if (!s.session) throw new TimerError('You have not started work.');
  if (s.running) await db.query(`update time_entries set ended_at = now() where id = $1`, [s.running.id]);
  if (s.onBreak) await db.query(`update breaks set ended_at = now() where id = $1`, [s.onBreak.id]);
  await db.query(`update work_sessions set ended_at = now() where id = $1`, [s.session.id]);
}

/** Time recorded without a timer (e.g. a site visit). Needs a reason; starts pending approval. */
export async function addManualEntry(db: Db, input: { startedAt: string; endedAt: string; taskId: string | null; reason: string }): Promise<void> {
  const start = new Date(input.startedAt), end = new Date(input.endedAt);
  if (!(start < end)) throw new TimerError('The end must be after the start.');
  if (end.getTime() - start.getTime() > 16 * 3600_000) throw new TimerError('A single entry cannot be longer than 16 hours.');
  const nowRow = await db.one<{ now: string }>(`select now() as now`);
  if (end > new Date(nowRow!.now)) throw new TimerError('You cannot record time in the future.');
  if (!input.reason.trim()) throw new TimerError('Please give a reason.');
  await assertTaskUsable(db, input.taskId);
  await db.query(`insert into time_entries (user_id, task_id, source, started_at, ended_at, reason)
                  values (auth.uid(), $1, 'manual', $2, $3, $4)`, [input.taskId, start.toISOString(), end.toISOString(), input.reason.trim()]);
}
