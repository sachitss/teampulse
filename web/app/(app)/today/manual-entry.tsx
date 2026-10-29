'use client';
import { ActionForm, Submit } from '@/components/action-form';
import { manualAction } from './actions';

type Task = { id: string; title: string; project: string };

export function ManualEntry({ tasks }: { tasks: Task[] }) {
  return (
    <details className="card">
      <summary><strong>Add time without the timer</strong> <span className="muted small">— e.g. a site visit. Your manager approves it.</span></summary>
      <ActionForm action={manualAction} resetOnOk>
        <div className="grid two" style={{ marginTop: 12 }}>
          <div className="field"><label htmlFor="m-start">From (Kathmandu time)</label><input id="m-start" name="start" type="datetime-local" required /></div>
          <div className="field"><label htmlFor="m-end">To</label><input id="m-end" name="end" type="datetime-local" required /></div>
        </div>
        <div className="field"><label htmlFor="m-task">Task</label>
          <select id="m-task" name="task"><option value="">Unassigned</option>{tasks.map((t) => <option key={t.id} value={t.id}>{t.title} — {t.project}</option>)}</select></div>
        <div className="field"><label htmlFor="m-reason">Reason</label><textarea id="m-reason" name="reason" required placeholder="Why wasn’t the timer used?" /></div>
        <Submit testId="manual-submit">Add time</Submit>
      </ActionForm>
    </details>
  );
}
