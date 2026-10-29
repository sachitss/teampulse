'use client';
// A form bound to a server action that returns { error?, ok? }. Shows the database's
// plain-language refusal (e.g. "This overlaps time you have already recorded") in place.
import { useActionState } from 'react';
import { useFormStatus } from 'react-dom';

export type ActionResult = { error?: string; ok?: string } | null;
export type Action = (prev: ActionResult, form: FormData) => Promise<ActionResult>;

export function ActionForm({ action, children, className, resetOnOk }: {
  action: Action; children: React.ReactNode; className?: string; resetOnOk?: boolean;
}) {
  const [state, formAction] = useActionState(action, null);
  return (
    <form action={formAction} className={className} key={resetOnOk && state?.ok ? state.ok + Date.now() : undefined}>
      {state?.error && <p className="notice bad" role="alert">{state.error}</p>}
      {state?.ok && <p className="notice ok" role="status">{state.ok}</p>}
      {children}
    </form>
  );
}

export function Submit({ children, className = 'btn', name, value, testId }: {
  children: React.ReactNode; className?: string; name?: string; value?: string; testId?: string;
}) {
  const { pending } = useFormStatus();
  return <button className={className} disabled={pending} name={name} value={value} data-testid={testId}>{pending ? '…' : children}</button>;
}
