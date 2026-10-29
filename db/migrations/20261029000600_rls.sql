-- =============================================================================
-- 0006 Row Level Security
--
-- Who sees what (from the build prompt):
--   Employee  own time, tasks, leave, payslips (published only), documents, own evidence
--   Manager   their direct reports' work and activity evidence; NEVER salaries or pay
--   HR        employee records, leave, attendance, payroll; NEVER screenshots/activity
--   Admin     everything, final payroll approval
-- Admin and HR rights require MFA (see app.is_hr / app.is_admin in 0001).
--
-- The agent never talks to the database directly: the server authenticates the
-- device token and writes with the service role, which bypasses RLS. That is why
-- the evidence tables have no INSERT policy for signed-in users.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Extra helpers
-- -----------------------------------------------------------------------------
create or replace function app.is_manager_or_above() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(app.my_role() = 'manager', false) or app.is_hr()
$$;

create or replace function app.my_manager_id() returns uuid
language sql stable security definer set search_path = public as $$
  select manager_id from public.profiles where id = auth.uid()
$$;

-- True if only the listed columns differ between two row images.
create or replace function app.only_changed(old_row jsonb, new_row jsonb, allowed text[]) returns boolean
language sql immutable as $$
  select not exists (
    select 1 from jsonb_each(new_row) n
     where n.key <> all (allowed) and (old_row -> n.key) is distinct from n.value
  )
$$;

create or replace function app.run_is_published(p_run uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.payroll_runs where id = p_run and status = 'published')
$$;

create or replace function app.entry_owner(p_entry uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select user_id from public.time_entries where id = p_entry
$$;

create or replace function app.session_owner(p_session uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select user_id from public.work_sessions where id = p_session
$$;

create or replace function app.salary_owner(p_salary uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select user_id from public.salary_records where id = p_salary
$$;

-- Medical certificate attached to a leave request the caller manages.
create or replace function app.is_attached_medical_cert(p_doc uuid, p_owner uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.is_manager_of(p_owner) and exists (
    select 1 from public.documents d join public.leave_requests r on r.attachment_doc_id = d.id
     where d.id = p_doc and d.kind = 'medical_certificate')
$$;

-- -----------------------------------------------------------------------------
-- Guards for what owners may change on their own rows
-- -----------------------------------------------------------------------------

-- Owners may only stop a running timer or switch its task. Everything else on a
-- finished entry goes through time_corrections. Approval is for the manager/HR only.
create or replace function app.guard_time_entry_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return new; end if;                       -- service role
  if app.is_manager_of(old.user_id) or app.is_hr() then
    if old.user_id = auth.uid() and new.approval is distinct from old.approval then
      raise exception 'You cannot approve your own time' using errcode = '42501';
    end if;
    if new.approval is distinct from old.approval then
      new.approved_by := auth.uid(); new.approved_at := now();
    end if;
    return new;
  end if;
  if old.user_id = auth.uid() and old.ended_at is null
     and app.only_changed(to_jsonb(old), to_jsonb(new), array['ended_at', 'task_id']) then
    return new;
  end if;
  raise exception 'Finished time can only be changed through a correction request' using errcode = '42501';
end $$;
create trigger time_entries_owner_guard before update on public.time_entries
  for each row execute function app.guard_time_entry_update();

-- Owners may only resolve their own pending idle periods.
create or replace function app.guard_idle_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return new; end if;
  if old.user_id = auth.uid() and old.resolution = 'pending'
     and app.only_changed(to_jsonb(old), to_jsonb(new), array['resolution', 'reassigned_task_id']) then
    return new;
  end if;
  raise exception 'Only the employee can resolve their own pending idle time' using errcode = '42501';
end $$;
create trigger idle_events_owner_guard before update on public.idle_events
  for each row execute function app.guard_idle_update();

-- Timesheet periods: the employee submits; the manager/HR approves and locks.
create or replace function app.guard_period_transition() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or new.status = old.status then return new; end if;
  if old.user_id = auth.uid() and not app.is_hr() then
    if old.status = 'open' and new.status = 'submitted' then new.submitted_at := now(); return new; end if;
    raise exception 'You can only submit your own timesheet' using errcode = '42501';
  end if;
  if not (app.is_manager_of(old.user_id) or app.is_hr()) then
    raise exception 'Only the employee''s manager or HR can approve timesheets' using errcode = '42501';
  end if;
  if new.status = 'approved' then new.approved_by := auth.uid(); new.approved_at := now(); end if;
  return new;
end $$;
create trigger timesheet_periods_transition before update on public.timesheet_periods
  for each row execute function app.guard_period_transition();

-- Correction decisions: never by the person who asked.
create or replace function app.guard_correction_decision() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or new.status = old.status then return new; end if;
  if old.requested_by = auth.uid() then
    raise exception 'You cannot decide your own correction request' using errcode = '42501';
  end if;
  new.decided_by := auth.uid(); new.decided_at := now();
  return new;
end $$;
create trigger time_corrections_decision before update on public.time_corrections
  for each row execute function app.guard_correction_decision();

-- -----------------------------------------------------------------------------
-- Enable RLS on every table in public (a test fails if any table is missed)
-- -----------------------------------------------------------------------------
do $$
declare t record;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t.tablename);
  end loop;
end $$;

-- -----------------------------------------------------------------------------
-- Settings, calendar, reference data
-- -----------------------------------------------------------------------------
create policy org_settings_read   on public.org_settings for select to authenticated using (true);
create policy org_settings_write  on public.org_settings for update to authenticated using (app.is_admin()) with check (app.is_admin());

create policy bs_calendar_read    on public.bs_calendar_months for select to authenticated using (true);
create policy bs_calendar_write   on public.bs_calendar_months for all to authenticated using (app.is_hr()) with check (app.is_hr());

create policy teams_read          on public.teams for select to authenticated using (true);
create policy teams_write         on public.teams for all to authenticated using (app.is_admin()) with check (app.is_admin());

-- -----------------------------------------------------------------------------
-- People
-- -----------------------------------------------------------------------------
create policy profiles_read on public.profiles for select to authenticated
  using (app.can_see_work(id) or id = app.my_manager_id());
create policy profiles_insert on public.profiles for insert to authenticated with check (app.is_admin());
create policy profiles_update on public.profiles for update to authenticated
  using (id = auth.uid() or app.is_hr()) with check (id = auth.uid() or app.is_hr());   -- columns guarded by trigger
create policy profiles_delete on public.profiles for delete to authenticated using (app.is_admin());

create policy employee_profiles_read  on public.employee_profiles for select to authenticated using (app.can_see_personal(user_id));
create policy employee_profiles_write on public.employee_profiles for insert to authenticated with check (app.can_see_personal(user_id));
create policy employee_profiles_upd   on public.employee_profiles for update to authenticated
  using (app.can_see_personal(user_id)) with check (app.can_see_personal(user_id));

create policy notice_versions_read  on public.notice_versions for select to authenticated using (published_at is not null or app.is_hr());
create policy notice_versions_write on public.notice_versions for all to authenticated using (app.is_admin()) with check (app.is_admin());

create policy notice_consents_read   on public.notice_consents for select to authenticated using (user_id = auth.uid() or app.is_hr());
create policy notice_consents_insert on public.notice_consents for insert to authenticated with check (user_id = auth.uid());

create policy audit_log_read on public.audit_log for select to authenticated using (app.is_admin());

-- -----------------------------------------------------------------------------
-- Module 1 — work
-- -----------------------------------------------------------------------------
create policy projects_read  on public.projects for select to authenticated using (true);
create policy projects_write on public.projects for all to authenticated using (app.is_manager_or_above()) with check (app.is_manager_or_above());

create policy tasks_read   on public.tasks for select to authenticated using (true);
create policy tasks_insert on public.tasks for insert to authenticated with check (app.is_manager_or_above());
create policy tasks_update on public.tasks for update to authenticated
  using (app.is_manager_or_above() or assignee_id = auth.uid())
  with check (app.is_manager_or_above() or assignee_id = auth.uid());
create policy tasks_delete on public.tasks for delete to authenticated using (app.is_manager_or_above());

create policy devices_read  on public.devices for select to authenticated using (app.can_see_work(user_id));
create policy devices_admin on public.devices for update to authenticated using (app.is_admin()) with check (app.is_admin());

create policy enrollment_codes_admin on public.enrollment_codes for all to authenticated using (app.is_admin()) with check (app.is_admin());

-- Everyone can read the policy: employees have a right to see what is collected.
create policy policies_read   on public.policies for select to authenticated using (true);
create policy policies_insert on public.policies for insert to authenticated with check (app.is_admin());

create policy sessions_read   on public.work_sessions for select to authenticated using (app.can_see_work(user_id));
create policy sessions_insert on public.work_sessions for insert to authenticated with check (user_id = auth.uid() and source = 'web');
create policy sessions_update on public.work_sessions for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy breaks_read  on public.breaks for select to authenticated using (app.can_see_work(app.session_owner(session_id)));
create policy breaks_write on public.breaks for insert to authenticated with check (app.session_owner(session_id) = auth.uid());
create policy breaks_upd   on public.breaks for update to authenticated
  using (app.session_owner(session_id) = auth.uid()) with check (app.session_owner(session_id) = auth.uid());

create policy entries_read   on public.time_entries for select to authenticated using (app.can_see_work(user_id));
create policy entries_insert on public.time_entries for insert to authenticated
  with check (user_id = auth.uid() and source in ('web', 'manual'));
create policy entries_update on public.time_entries for update to authenticated
  using (user_id = auth.uid() or app.is_manager_of(user_id) or app.is_hr())
  with check (user_id = auth.uid() or app.is_manager_of(user_id) or app.is_hr());

create policy corrections_read   on public.time_corrections for select to authenticated using (app.can_see_work(app.entry_owner(entry_id)));
create policy corrections_insert on public.time_corrections for insert to authenticated
  with check (requested_by = auth.uid() and (app.entry_owner(entry_id) = auth.uid() or app.is_manager_of(app.entry_owner(entry_id)) or app.is_hr()));
create policy corrections_decide on public.time_corrections for update to authenticated
  using (app.is_manager_of(app.entry_owner(entry_id)) or app.is_hr())
  with check (app.is_manager_of(app.entry_owner(entry_id)) or app.is_hr());

create policy periods_read   on public.timesheet_periods for select to authenticated using (app.can_see_work(user_id));
create policy periods_insert on public.timesheet_periods for insert to authenticated with check (user_id = auth.uid() or app.is_hr());
create policy periods_update on public.timesheet_periods for update to authenticated
  using (app.can_see_work(user_id)) with check (app.can_see_work(user_id));

-- Activity evidence: self, their manager, admin. Not HR.
create policy idle_read    on public.idle_events   for select to authenticated using (app.can_see_activity(user_id));
create policy idle_resolve on public.idle_events   for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy apps_read    on public.app_events    for select to authenticated using (app.can_see_activity(user_id));
create policy web_read     on public.web_events    for select to authenticated using (app.can_see_activity(user_id));
create policy input_read   on public.input_metrics for select to authenticated using (app.can_see_activity(user_id));
create policy shots_read   on public.screenshots   for select to authenticated using (app.can_see_activity(user_id));
create policy shots_admin  on public.screenshots   for update to authenticated using (app.is_admin()) with check (app.is_admin());
create policy batches_read on public.agent_batches for select to authenticated using (app.is_admin());

create policy categories_read  on public.app_categories for select to authenticated using (true);
create policy categories_write on public.app_categories for all to authenticated
  using (app.is_manager_or_above()) with check (app.is_manager_or_above());

-- -----------------------------------------------------------------------------
-- Module 2 — leave
-- -----------------------------------------------------------------------------
create policy leave_types_read  on public.leave_types for select to authenticated using (true);
create policy leave_types_write on public.leave_types for all to authenticated using (app.is_hr()) with check (app.is_hr());
create policy leave_rules_read  on public.leave_rules for select to authenticated using (true);
create policy leave_rules_write on public.leave_rules for all to authenticated using (app.is_hr()) with check (app.is_hr());
create policy holidays_read     on public.holiday_calendar for select to authenticated using (true);
create policy holidays_write    on public.holiday_calendar for all to authenticated using (app.is_hr()) with check (app.is_hr());
create policy holiday_groups_read  on public.holiday_groups for select to authenticated using (user_id = auth.uid() or app.is_hr());
create policy holiday_groups_write on public.holiday_groups for all to authenticated using (app.is_hr()) with check (app.is_hr());

create policy leave_req_read   on public.leave_requests for select to authenticated using (app.can_see_work(user_id));
create policy leave_req_insert on public.leave_requests for insert to authenticated
  with check ((user_id = auth.uid() and status = 'pending') or app.is_hr());
create policy leave_req_update on public.leave_requests for update to authenticated
  using (app.can_see_work(user_id)) with check (app.can_see_work(user_id));   -- transitions guarded by trigger

create policy ledger_read   on public.leave_ledger for select to authenticated using (app.can_see_work(user_id));
create policy ledger_insert on public.leave_ledger for insert to authenticated with check (app.is_hr());

create policy substitute_read  on public.substitute_leave for select to authenticated using (app.can_see_work(user_id));
create policy substitute_write on public.substitute_leave for insert to authenticated with check (app.is_hr());

-- -----------------------------------------------------------------------------
-- Module 3 — payroll (never visible to managers)
-- -----------------------------------------------------------------------------
create policy allowance_types_read  on public.allowance_types for select to authenticated using (true);
create policy allowance_types_write on public.allowance_types for all to authenticated using (app.is_hr()) with check (app.is_hr());

create policy salary_read  on public.salary_records for select to authenticated using (app.can_see_pay(user_id));
create policy salary_write on public.salary_records for all to authenticated using (app.is_hr()) with check (app.is_hr());
create policy salary_allow_read  on public.salary_allowances for select to authenticated using (app.can_see_pay(app.salary_owner(salary_record_id)));
create policy salary_allow_write on public.salary_allowances for all to authenticated using (app.is_hr()) with check (app.is_hr());

create policy bank_read  on public.employee_bank_details for select to authenticated using (app.can_see_pay(user_id));
create policy bank_write on public.employee_bank_details for all to authenticated using (app.is_hr()) with check (app.is_hr());

create policy payroll_rules_read  on public.payroll_rules for select to authenticated using (app.is_hr());
create policy payroll_rules_write on public.payroll_rules for all to authenticated using (app.is_hr()) with check (app.is_hr());
create policy rule_keys_read      on public.payroll_rule_keys for select to authenticated using (app.is_hr());
create policy tax_slabs_read      on public.tax_slabs for select to authenticated using (true);   -- public law
create policy tax_slabs_write     on public.tax_slabs for all to authenticated using (app.is_hr()) with check (app.is_hr());
create policy tax_ded_read        on public.tax_deduction_rules for select to authenticated using (true);
create policy tax_ded_write       on public.tax_deduction_rules for all to authenticated using (app.is_hr()) with check (app.is_hr());

create policy attendance_read  on public.attendance_summaries for select to authenticated using (app.can_see_work(user_id));
create policy attendance_write on public.attendance_summaries for all to authenticated using (app.is_hr()) with check (app.is_hr());

create policy runs_read on public.payroll_runs for select to authenticated
  using (app.is_hr() or (status = 'published' and exists (
           select 1 from public.payroll_lines l where l.run_id = payroll_runs.id and l.user_id = auth.uid())));
create policy runs_write on public.payroll_runs for all to authenticated using (app.is_hr()) with check (app.is_hr());

create policy lines_read  on public.payroll_lines for select to authenticated
  using (app.is_hr() or (user_id = auth.uid() and app.run_is_published(run_id)));
create policy lines_write on public.payroll_lines for all to authenticated using (app.is_hr()) with check (app.is_hr());

create policy adjustments_rw on public.payroll_adjustments for all to authenticated using (app.is_hr()) with check (app.is_hr());

create policy payslips_read  on public.payslips for select to authenticated
  using (app.is_hr() or (user_id = auth.uid() and app.run_is_published(run_id)));
create policy payslips_write on public.payslips for all to authenticated using (app.is_hr()) with check (app.is_hr());

create policy exports_rw on public.payroll_exports for all to authenticated using (app.is_hr()) with check (app.is_hr());

-- -----------------------------------------------------------------------------
-- Module 4 — administration
-- -----------------------------------------------------------------------------
create policy documents_read on public.documents for select to authenticated
  using (app.can_see_personal(user_id) or app.is_attached_medical_cert(id, user_id));
create policy documents_insert on public.documents for insert to authenticated
  with check (app.is_hr() or (user_id = auth.uid() and uploaded_by = auth.uid() and kind in ('medical_certificate', 'certificate', 'other')));
create policy documents_update on public.documents for update to authenticated using (app.is_hr()) with check (app.is_hr());
create policy documents_delete on public.documents for delete to authenticated using (app.is_hr());

create policy cl_templates_read  on public.checklist_templates for select to authenticated using (app.is_manager_or_above());
create policy cl_templates_write on public.checklist_templates for all to authenticated using (app.is_hr()) with check (app.is_hr());
create policy cl_titems_read     on public.checklist_template_items for select to authenticated using (app.is_manager_or_above());
create policy cl_titems_write    on public.checklist_template_items for all to authenticated using (app.is_hr()) with check (app.is_hr());

create policy checklists_read  on public.checklists for select to authenticated
  using (app.can_see_personal(user_id) or app.is_manager_of(user_id));
create policy checklists_write on public.checklists for all to authenticated using (app.is_hr()) with check (app.is_hr());
create policy cl_items_read on public.checklist_items for select to authenticated
  using (owner_id = auth.uid() or exists (select 1 from public.checklists c where c.id = checklist_id
                                          and (app.can_see_personal(c.user_id) or app.is_manager_of(c.user_id))));
create policy cl_items_done on public.checklist_items for update to authenticated
  using (owner_id = auth.uid() or app.is_hr()) with check (owner_id = auth.uid() or app.is_hr());
create policy cl_items_write on public.checklist_items for insert to authenticated with check (app.is_hr());

create policy admin_tasks_read  on public.admin_tasks for select to authenticated using (app.is_hr() or owner_id = auth.uid());
create policy admin_tasks_write on public.admin_tasks for all to authenticated using (app.is_hr()) with check (app.is_hr());
create policy task_occ_read  on public.admin_task_occurrences for select to authenticated
  using (app.is_hr() or exists (select 1 from public.admin_tasks t where t.id = task_id and t.owner_id = auth.uid()));
create policy task_occ_write on public.admin_task_occurrences for update to authenticated
  using (app.is_hr() or exists (select 1 from public.admin_tasks t where t.id = task_id and t.owner_id = auth.uid()))
  with check (app.is_hr() or exists (select 1 from public.admin_tasks t where t.id = task_id and t.owner_id = auth.uid()));
create policy task_occ_insert on public.admin_task_occurrences for insert to authenticated with check (app.is_hr());

create policy assets_read  on public.assets for select to authenticated
  using (app.is_hr() or assigned_to = auth.uid() or app.is_manager_of(assigned_to));
create policy assets_write on public.assets for all to authenticated using (app.is_hr()) with check (app.is_hr());

create policy announcements_read  on public.announcements for select to authenticated
  using ((published_at is not null and published_at <= now() and (expires_at is null or expires_at > now())) or app.is_hr());
create policy announcements_write on public.announcements for all to authenticated using (app.is_hr()) with check (app.is_hr());
create policy acks_read   on public.acknowledgements for select to authenticated using (user_id = auth.uid() or app.is_hr());
create policy acks_insert on public.acknowledgements for insert to authenticated with check (user_id = auth.uid());

create policy report_schedules_admin on public.report_schedules for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy email_log_read on public.email_log for select to authenticated using (app.is_admin());

-- -----------------------------------------------------------------------------
-- Secrets never readable by signed-in users, even where the row is.
-- -----------------------------------------------------------------------------
revoke select on public.devices from authenticated, anon;
grant select (id, user_id, hostname, os, agent_version, enrolled_at, last_seen_at, policy_version_seen,
              queue_depth, capabilities, last_error, revoked_at, revoke_scheduled_for)
  on public.devices to authenticated;
revoke select on public.enrollment_codes from authenticated, anon;
grant select (id, user_id, expires_at, used_at, device_id, created_by, created_at) on public.enrollment_codes to authenticated;

-- Anonymous users get nothing at all.
revoke all on all tables in schema public from anon;

-- Functions: no PUBLIC execute on anything that returns data.
revoke execute on all functions in schema app from public, anon;
grant execute on all functions in schema app to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Storage: every bucket is private and has NO policies for signed-in users.
-- Files are reached only through short-lived signed URLs minted by the server
-- after the app.*_key_for_view() check, which also writes the audit entry.
-- -----------------------------------------------------------------------------
insert into storage.buckets (id, name, public) values
  ('screenshots', 'screenshots', false),
  ('documents',   'documents',   false),
  ('payslips',    'payslips',    false),
  ('exports',     'exports',     false)
on conflict (id) do update set public = false;
