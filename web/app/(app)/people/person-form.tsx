// Shared fields for adding and editing an employee.
export type Option = { id: string; name: string };
export type PersonValues = {
  full_name?: string; email?: string; role?: string; manager_id?: string | null; team_id?: string | null;
  job_title?: string | null; employment_type?: string; join_date?: string | null; probation_end?: string | null;
  exit_date?: string | null; gender?: string | null; active?: boolean;
};

export function PersonFields({ v = {}, managers, teams, canAdmin, isNew }: {
  v?: PersonValues; managers: Option[]; teams: Option[]; canAdmin: boolean; isNew?: boolean;
}) {
  return (
    <>
      <div className="grid two">
        <div className="field"><label htmlFor="full_name">Full name</label><input id="full_name" name="full_name" required defaultValue={v.full_name} maxLength={120} /></div>
        <div className="field"><label htmlFor="email">Work email</label>
          <input id="email" name="email" type="email" required defaultValue={v.email} disabled={!isNew} /></div>
      </div>
      <div className="grid three">
        <div className="field"><label htmlFor="role">Role</label>
          <select id="role" name="role" defaultValue={v.role ?? 'employee'} disabled={!canAdmin}>
            <option value="employee">Employee</option><option value="manager">Manager</option><option value="hr">HR / Accounts</option><option value="admin">Admin</option>
          </select></div>
        <div className="field"><label htmlFor="manager_id">Reports to</label>
          <select id="manager_id" name="manager_id" defaultValue={v.manager_id ?? ''} disabled={!canAdmin}>
            <option value="">—</option>{managers.map((m) => <option key={m.id} value={m.id}>{m.name}</option>)}
          </select></div>
        <div className="field"><label htmlFor="team_id">Team</label>
          <select id="team_id" name="team_id" defaultValue={v.team_id ?? ''}>
            <option value="">—</option>{teams.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
          </select></div>
      </div>
      <div className="grid three">
        <div className="field"><label htmlFor="job_title">Job title</label><input id="job_title" name="job_title" defaultValue={v.job_title ?? ''} maxLength={120} /></div>
        <div className="field"><label htmlFor="employment_type">Employment</label>
          <select id="employment_type" name="employment_type" defaultValue={v.employment_type ?? 'regular'}>
            <option value="regular">Regular</option><option value="probation">Probation</option><option value="contract">Contract</option>
          </select></div>
        <div className="field"><label htmlFor="gender">Gender (for women’s holidays and maternity/paternity leave)</label>
          <select id="gender" name="gender" defaultValue={v.gender ?? ''}>
            <option value="">Not recorded</option><option value="female">Female</option><option value="male">Male</option><option value="other">Other</option>
          </select></div>
      </div>
      <div className="grid three">
        <div className="field"><label htmlFor="join_date">Join date (AD)</label><input id="join_date" name="join_date" type="date" defaultValue={v.join_date ?? ''} /></div>
        <div className="field"><label htmlFor="probation_end">Probation ends</label><input id="probation_end" name="probation_end" type="date" defaultValue={v.probation_end ?? ''} /></div>
        <div className="field"><label htmlFor="exit_date">Exit date</label><input id="exit_date" name="exit_date" type="date" defaultValue={v.exit_date ?? ''} /></div>
      </div>
      {!isNew && canAdmin && (
        <div className="field"><label><input type="checkbox" name="active" value="1" defaultChecked={v.active} style={{ width: 'auto', minHeight: 0, marginRight: 8 }} />Active (can sign in and be paid)</label></div>
      )}
    </>
  );
}
