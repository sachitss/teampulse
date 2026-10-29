'use client';
import { useEffect, useState } from 'react';
import { ActionForm, Submit } from '@/components/action-form';
import { startAction, switchAction, breakAction, resumeAction, stopAction } from './actions';
import type { TimerState } from '@/lib/timer';

type Task = { id: string; title: string; project: string; mine: boolean };

function elapsed(fromIso: string, offsetMs: number): string {
  const s = Math.max(0, Math.floor((Date.now() + offsetMs - new Date(fromIso).getTime()) / 1000));
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
  return `${h}:${String(m).padStart(2, '0')}:${String(sec).padStart(2, '0')}`;
}

function TaskSelect({ tasks, value }: { tasks: Task[]; value?: string | null }) {
  const mine = tasks.filter((t) => t.mine), other = tasks.filter((t) => !t.mine);
  return (
    <select name="task" defaultValue={value ?? ''} aria-label="Task">
      <option value="">Unassigned (no task)</option>
      {mine.length > 0 && <optgroup label="My tasks">{mine.map((t) => <option key={t.id} value={t.id}>{t.title} — {t.project}</option>)}</optgroup>}
      {other.length > 0 && <optgroup label="Other open tasks">{other.map((t) => <option key={t.id} value={t.id}>{t.title} — {t.project}</option>)}</optgroup>}
    </select>
  );
}

export function TimerPanel({ state, tasks }: { state: TimerState; tasks: Task[] }) {
  // Correct for a device clock that is clearly wrong (> 1 minute off the server), but not for
  // ordinary page-load delay, which would make the clock lag by a few seconds.
  const [offset] = useState(() => {
    const raw = new Date(state.now).getTime() - Date.now();
    return Math.abs(raw) > 60_000 ? raw : 0;
  });
  const [, tick] = useState(0);
  useEffect(() => { const t = setInterval(() => tick((n) => n + 1), 1000); return () => clearInterval(t); }, []);

  const { session, running, onBreak } = state;

  if (!session) {
    return (
      <div className="card" data-testid="timer-idle">
        <div className="row"><span className="status-dot" /> <strong>Not working</strong></div>
        <ActionForm action={startAction} className="stack" >
          <TaskSelect tasks={tasks} />
          <Submit className="btn big" testId="start">Start work</Submit>
        </ActionForm>
      </div>
    );
  }

  if (onBreak) {
    return (
      <div className="card" data-testid="timer-break">
        <div className="row"><span className="status-dot break" /> <strong>{onBreak.kind === 'privacy_pause' ? 'Privacy pause' : 'On a break'}</strong></div>
        <div className="clock" style={{ margin: '12px 0' }}>{elapsed(onBreak.started_at, offset)}</div>
        {onBreak.kind === 'privacy_pause' && <p className="small muted">Nothing is recorded during a privacy pause (up to 30 minutes).</p>}
        <div className="row">
          <ActionForm action={resumeAction}><Submit className="btn big" testId="resume">Resume work</Submit></ActionForm>
          <ActionForm action={stopAction}><Submit className="btn secondary" testId="stop">Stop for the day</Submit></ActionForm>
        </div>
      </div>
    );
  }

  return (
    <div className="card" data-testid="timer-running">
      <div className="row"><span className="status-dot on" /> <strong>Working</strong>
        <span className="muted small">{running?.task_title ? `${running.task_title} — ${running.project_name}` : 'Unassigned time'}</span></div>
      <div className="clock" style={{ margin: '12px 0' }} data-testid="clock">{running ? elapsed(running.started_at, offset) : '—'}</div>
      <ActionForm action={switchAction} className="row">
        <div style={{ flex: '1 1 260px' }}><TaskSelect tasks={tasks} value={running?.task_id} /></div>
        <Submit className="btn secondary" testId="switch">Switch task</Submit>
      </ActionForm>
      <div className="row" style={{ marginTop: 12 }}>
        <ActionForm action={breakAction}><input type="hidden" name="kind" value="break" /><Submit className="btn warn" testId="break">Take a break</Submit></ActionForm>
        <ActionForm action={breakAction}><input type="hidden" name="kind" value="privacy_pause" /><Submit className="btn secondary">Privacy pause</Submit></ActionForm>
        <ActionForm action={stopAction}><Submit className="btn secondary" testId="stop">Stop for the day</Submit></ActionForm>
      </div>
    </div>
  );
}
