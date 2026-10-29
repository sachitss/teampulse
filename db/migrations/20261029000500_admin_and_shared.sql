-- =============================================================================
-- 0005 Module 4 — administration, and shared reporting tables
-- =============================================================================

create type public.document_kind   as enum ('contract', 'citizenship', 'pan_card', 'certificate', 'medical_certificate',
                                            'experience_letter', 'other');
create type public.checklist_kind  as enum ('onboarding', 'offboarding');
create type public.checklist_action as enum ('none', 'enroll_device', 'consent_notice', 'ssf_enrollment',
                                             'revoke_agent', 'final_settlement', 'remove_access');
create type public.recurrence      as enum ('once', 'monthly_bs', 'yearly_bs');
create type public.email_status    as enum ('queued', 'sent', 'failed', 'bounced');
create type public.report_kind     as enum ('daily', 'weekly', 'monthly');

-- -----------------------------------------------------------------------------
-- Documents (private bucket 'documents'; access via app.document_key_for_view)
-- -----------------------------------------------------------------------------
create table public.documents (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles (id) on delete cascade,
  kind          public.document_kind not null,
  title         text not null,
  storage_key   text not null unique,
  expires_on    date,
  uploaded_by   uuid references public.profiles (id) on delete set null,
  created_at    timestamptz not null default now()
);
create index on public.documents (user_id);
create index on public.documents (expires_on) where expires_on is not null;
create trigger documents_audit after insert or update or delete on public.documents
  for each row execute function app.audit_row();

alter table public.leave_requests
  add constraint leave_requests_attachment_fk foreign key (attachment_doc_id)
  references public.documents (id) on delete set null;

create or replace function app.document_key_for_view(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare d record;
begin
  select * into d from public.documents where id = p_id;
  -- A manager may open a medical certificate attached to a leave request they decide.
  if d is null or not (
       app.can_see_personal(d.user_id)
       or (d.kind = 'medical_certificate' and app.is_manager_of(d.user_id)
           and exists (select 1 from public.leave_requests r where r.attachment_doc_id = d.id))) then
    perform app.audit('view_document_denied', 'documents', p_id::text, '{}');
    return null;   -- denied: the API answers 403. (Raising would roll back the audit entry.)
  end if;
  perform app.audit('view_document', 'documents', p_id::text, jsonb_build_object('employee', d.user_id, 'kind', d.kind));
  return d.storage_key;
end $$;
grant execute on function app.document_key_for_view(uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- Onboarding / offboarding checklists
-- -----------------------------------------------------------------------------
create table public.checklist_templates (
  id          uuid primary key default gen_random_uuid(),
  kind        public.checklist_kind not null,
  name        text not null,
  active      boolean not null default true,
  unique (kind, name)
);

create table public.checklist_template_items (
  id               uuid primary key default gen_random_uuid(),
  template_id      uuid not null references public.checklist_templates (id) on delete cascade,
  position         smallint not null,
  title            text not null,
  owner_role       public.user_role not null default 'hr',
  -- due date relative to the employee's join date (onboarding) or exit date (offboarding)
  due_offset_days  smallint not null default 0,
  action           public.checklist_action not null default 'none',
  unique (template_id, position)
);

create table public.checklists (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.profiles (id) on delete cascade,
  template_id  uuid references public.checklist_templates (id) on delete set null,
  kind         public.checklist_kind not null,
  anchor_date  date not null,          -- join date or exit date
  started_by   uuid references public.profiles (id),
  started_at   timestamptz not null default now(),
  completed_at timestamptz
);

create table public.checklist_items (
  id            uuid primary key default gen_random_uuid(),
  checklist_id  uuid not null references public.checklists (id) on delete cascade,
  position      smallint not null,
  title         text not null,
  owner_id      uuid references public.profiles (id) on delete set null,
  due_on        date,
  action        public.checklist_action not null default 'none',
  done_at       timestamptz,
  done_by       uuid references public.profiles (id),
  note          text
);

-- Starting an offboarding checklist schedules agent revocation on the exit date.
create or replace function app.on_offboarding_started() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.kind = 'offboarding' then
    update public.devices set revoke_scheduled_for = new.anchor_date
     where user_id = new.user_id and revoked_at is null;
    update public.profiles set exit_date = coalesce(exit_date, new.anchor_date) where id = new.user_id;
  end if;
  return new;
end $$;
create trigger checklists_offboarding after insert on public.checklists
  for each row execute function app.on_offboarding_started();
create trigger checklists_audit after insert or update or delete on public.checklists
  for each row execute function app.audit_row();

-- -----------------------------------------------------------------------------
-- Compliance and admin task calendar (due dates in BS)
-- -----------------------------------------------------------------------------
create table public.admin_tasks (
  id                 uuid primary key default gen_random_uuid(),
  title              text not null,
  description        text,
  owner_id           uuid references public.profiles (id) on delete set null,
  owner_role         public.user_role not null default 'hr',
  recurrence         public.recurrence not null,
  due_day_bs         smallint check (due_day_bs between 1 and 32),   -- monthly: day of following BS month
  due_month_bs       smallint check (due_month_bs between 1 and 12), -- yearly: BS month
  due_once_ad        date,
  remind_days_before smallint not null default 3,
  active             boolean not null default true,
  created_at         timestamptz not null default now(),
  check (recurrence <> 'monthly_bs' or due_day_bs is not null),
  check (recurrence <> 'yearly_bs' or (due_day_bs is not null and due_month_bs is not null)),
  check (recurrence <> 'once' or due_once_ad is not null)
);

create table public.admin_task_occurrences (
  id          uuid primary key default gen_random_uuid(),
  task_id     uuid not null references public.admin_tasks (id) on delete cascade,
  due_ad      date not null,
  due_bs      text,
  reminded_at timestamptz,
  done_at     timestamptz,
  done_by     uuid references public.profiles (id),
  note        text,
  unique (task_id, due_ad)
);
create trigger admin_task_occurrences_bs before insert or update on public.admin_task_occurrences
  for each row execute function app.fill_bs('due_ad', 'due_bs');

-- -----------------------------------------------------------------------------
-- Assets register (linked to the enrolled agent device)
-- -----------------------------------------------------------------------------
create table public.assets (
  id            uuid primary key default gen_random_uuid(),
  tag           text not null unique,
  kind          text not null default 'laptop',
  model         text,
  serial        text,
  assigned_to   uuid references public.profiles (id) on delete set null,
  issued_on     date,
  returned_on   date,
  device_id     uuid references public.devices (id) on delete set null,
  note          text,
  is_demo       boolean not null default false,
  created_at    timestamptz not null default now(),
  check (returned_on is null or issued_on is null or returned_on >= issued_on)
);
create trigger assets_audit after insert or update or delete on public.assets
  for each row execute function app.audit_row();

-- -----------------------------------------------------------------------------
-- Announcements
-- -----------------------------------------------------------------------------
create table public.announcements (
  id            uuid primary key default gen_random_uuid(),
  title         text not null,
  body          text not null,
  requires_ack  boolean not null default false,
  published_at  timestamptz,
  expires_at    timestamptz,
  created_by    uuid references public.profiles (id) on delete set null,
  is_demo       boolean not null default false,
  created_at    timestamptz not null default now()
);

create table public.acknowledgements (
  announcement_id uuid not null references public.announcements (id) on delete cascade,
  user_id         uuid not null references public.profiles (id) on delete cascade,
  acked_at        timestamptz not null default now(),
  primary key (announcement_id, user_id)
);

-- -----------------------------------------------------------------------------
-- Email reports
-- -----------------------------------------------------------------------------
create table public.report_schedules (
  id            uuid primary key default gen_random_uuid(),
  kind          public.report_kind not null unique,
  local_time    time not null default '18:00',        -- Asia/Kathmandu
  weekday       smallint check (weekday between 1 and 7),   -- weekly: ISO day
  recipients    text[] not null default '{peace.consultancy@gmail.com}',
  enabled       boolean not null default true,
  -- Monthly payroll totals go only to HR/Admin addresses, never the general list.
  restricted    boolean not null default false
);

create table public.email_log (
  id            uuid primary key default gen_random_uuid(),
  kind          text not null,
  recipients    text[] not null,
  subject       text not null,
  status        public.email_status not null default 'queued',
  provider_id   text,
  attempts      smallint not null default 0,
  last_error    text,
  created_at    timestamptz not null default now(),
  sent_at       timestamptz
);
create index on public.email_log (created_at desc);
