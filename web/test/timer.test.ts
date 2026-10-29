import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { buildDatabase, asUser, asSystem, closePool, DEMO } from './helpers.ts';
import * as timer from '../lib/timer.ts';
import { monthSheet, submitMonth } from '../lib/timesheet.ts';
import { todayBs } from '@teampulse/bs-calendar';

const emp = DEMO.employee3;

before(() => buildDatabase());
after(() => closePool());

async function aTask(): Promise<string> {
  const t = await asUser(emp, (db) => db.one<{ id: string }>(
    `select t.id from tasks t join projects p on p.id = t.project_id where p.active and t.status in ('todo','in_progress') limit 1`));
  return t!.id;
}

test('start → switch → break → resume → stop produces contiguous, non-overlapping entries', async () => {
  const task = await aTask();
  await asUser(emp, (db) => timer.startWork(db, task));
  let s = await asUser(emp, (db) => timer.getTimerState(db));
  assert.ok(s.session && s.running && !s.onBreak);
  assert.equal(s.running!.task_id, task);

  // Cannot start twice.
  await assert.rejects(asUser(emp, (db) => timer.startWork(db, task)), /already started/);

  await asUser(emp, (db) => timer.switchTask(db, null));
  await asUser(emp, (db) => timer.startBreak(db));
  s = await asUser(emp, (db) => timer.getTimerState(db));
  assert.ok(s.onBreak && !s.running, 'on break, no running entry');
  await assert.rejects(asUser(emp, (db) => timer.startBreak(db)), /already on a break/);

  await asUser(emp, (db) => timer.resumeWork(db));
  s = await asUser(emp, (db) => timer.getTimerState(db));
  assert.equal(s.running!.task_id, null, 'resume continues the task before the break (unassigned)');

  await asUser(emp, (db) => timer.stopWork(db));
  s = await asUser(emp, (db) => timer.getTimerState(db));
  assert.equal(s.session, null);
  assert.equal(s.running, null);

  const rows = await asSystem((db) => db.query(
    `select started_at, ended_at, task_id from time_entries where user_id = $1 order by started_at`, [emp]));
  assert.equal(rows.length, 3, 'three entries: task, unassigned, after-break');
  assert.equal(rows[0].ended_at.getTime(), rows[1].started_at.getTime(), 'switch has no gap');
  assert.ok(rows[2].started_at >= rows[1].ended_at, 'break separates entries');
});

test('manual entry needs a reason, cannot be in the future, and waits for approval', async () => {
  const now = Date.now();
  await assert.rejects(asUser(emp, (db) => timer.addManualEntry(db, {
    startedAt: new Date(now - 3600_000).toISOString(), endedAt: new Date(now + 3600_000).toISOString(), taskId: null, reason: 'x' })), /future/);
  await assert.rejects(asUser(emp, (db) => timer.addManualEntry(db, {
    startedAt: new Date(now - 7200_000).toISOString(), endedAt: new Date(now - 3600_000).toISOString(), taskId: null, reason: '  ' })), /reason/);
  // Far enough back not to touch today's timer entries.
  const start = new Date(now - 5 * 86400_000), end = new Date(now - 5 * 86400_000 + 2 * 3600_000);
  await asUser(emp, (db) => timer.addManualEntry(db, { startedAt: start.toISOString(), endedAt: end.toISOString(), taskId: null, reason: 'Site visit' }));
  const r = await asSystem((db) => db.one(`select approval from time_entries where user_id = $1 and source = 'manual'`, [emp]));
  assert.equal(r.approval, 'pending');
  // Overlapping manual time is refused by the database.
  await assert.rejects(asUser(emp, (db) => timer.addManualEntry(db, {
    startedAt: new Date(start.getTime() + 1800_000).toISOString(), endedAt: new Date(end.getTime() + 1800_000).toISOString(),
    taskId: null, reason: 'dup' })), (e: any) => e.constraint === 'time_entries_no_overlap');
});

test('monthly timesheet totals and submit', async () => {
  const today = todayBs();
  const sheet = await asUser(emp, (db) => monthSheet(db, emp, today.year, today.month));
  assert.equal(sheet.days.length, sheet.range.days, 'one row per BS day');
  assert.equal(sheet.days[0].bsDay, 1);
  assert.ok(sheet.days.filter((d) => d.weekday === 6).every((d) => d.holiday), 'Saturdays are holidays');
  assert.equal(sheet.period.status, 'open');
  await asUser(emp, (db) => submitMonth(db, today.year, today.month));
  const again = await asUser(emp, (db) => monthSheet(db, emp, today.year, today.month));
  assert.equal(again.period.status, 'submitted');
  await assert.rejects(asUser(emp, (db) => submitMonth(db, today.year, today.month)), /already been submitted/);
  // Another employee's sheet shows nothing to this employee (RLS), not an error.
  const other = await asUser(emp, (db) => monthSheet(db, DEMO.employee4, today.year, today.month));
  assert.equal(other.totalMinutes, 0);
  assert.equal(other.period.id, null);
});

test('approved leave blocks starting the timer', async () => {
  const today = await asSystem((db) => db.one<{ d: string }>(`select app.kathmandu_date(now())::text as d`));
  const home = await asSystem((db) => db.one<{ id: string }>(`select id from leave_types where code = 'home'`));
  await asSystem((db) => db.query(`insert into leave_requests (user_id, leave_type_id, start_ad, end_ad, days, status)
                                   values ($1, $2, $3, $3, 1, 'approved')`, [DEMO.employee4, home!.id, today!.d]));
  await assert.rejects(asUser(DEMO.employee4, (db) => timer.startWork(db, null)), /approved leave/);
});
