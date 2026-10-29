-- =============================================================================
-- 0002 Module 1 — time tracking, timesheets, Windows agent, activity evidence
-- =============================================================================

create type public.task_status        as enum ('todo', 'in_progress', 'done', 'cancelled');
create type public.entry_source       as enum ('agent', 'web', 'manual');
create type public.entry_kind         as enum ('work', 'meeting');
create type public.approval_status    as enum ('pending', 'approved', 'rejected');
create type public.period_status      as enum ('open', 'submitted', 'approved', 'locked');
create type public.break_kind         as enum ('break', 'privacy_pause');
create type public.idle_resolution    as enum ('pending', 'kept', 'discarded', 'reassigned');
create type public.screenshot_status  as enum ('pending_upload', 'stored', 'capture_failed', 'refused_by_policy', 'deleted');
create type public.activity_category  as enum ('productive', 'neutral', 'distracting', 'unclassified');

-- -----------------------------------------------------------------------------
-- Projects and tasks
-- -----------------------------------------------------------------------------
create table public.projects (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  client       text,
  active       boolean not null default true,
  is_demo      boolean not null default false,
  created_by   uuid references public.profiles (id) on delete set null,
  created_at   timestamptz not null default now(),
  unique (name)
);

create table public.tasks (
  id                uuid primary key default gen_random_uuid(),
  project_id        uuid not null references public.projects (id) on delete cascade,
  title             text not null,
  assignee_id       uuid references public.profiles (id) on delete set null,
  status            public.task_status not null default 'todo',
  estimate_minutes  int check (estimate_minutes is null or estimate_minutes > 0),
  deadline          date,
  priority          smallint not null default 2 check (priority between 1 and 4),
  created_by        uuid references public.profiles (id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create index on public.tasks (project_id);
create index on public.tasks (assignee_id, status);
create trigger tasks_touch before update on public.tasks for each row execute function app.touch_updated_at();

-- -----------------------------------------------------------------------------
-- Agent: devices, enrollment, policy
-- -----------------------------------------------------------------------------
create table public.devices (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid not null references public.profiles (id) on delete cascade,
  hostname              text not null,
  os                    text,
  agent_version         text,
  machine_fingerprint   text not null unique,      -- sha256, non-reversible (contract §3.1)
  device_token_hash     text not null,             -- sha256 of the long-lived token; the token itself is never stored
  enrolled_at           timestamptz not null default now(),
  last_seen_at          timestamptz,
  policy_version_seen   int,
  queue_depth           int,
  capabilities          jsonb not null default '{}',   -- contract §8 statuses
  last_error            text,
  revoked_at            timestamptz,
  revoke_scheduled_for  date,                      -- set by offboarding (exit date)
  unique (id, user_id)                             -- target of composite FKs below
);
create index on public.devices (user_id);

create table public.enrollment_codes (
  id           uuid primary key default gen_random_uuid(),
  code_hash    text not null unique,     -- sha256 of the one-time code; never the code itself
  user_id      uuid not null references public.profiles (id) on delete cascade,
  expires_at   timestamptz not null,
  used_at      timestamptz,
  device_id    uuid references public.devices (id) on delete set null,
  created_by   uuid references public.profiles (id) on delete set null,
  created_at   timestamptz not null default now(),
  check (expires_at > created_at)
);

-- Org-wide monitoring policy (contract §4). Versions are immutable; the newest active one applies.
create table public.policies (
  version      int generated always as identity primary key,
  settings     jsonb not null,
  created_by   uuid references public.profiles (id) on delete set null,
  created_at   timestamptz not null default now(),
  note         text
);
create trigger policies_append_only before update or delete on public.policies
  for each row execute function app.block_mutation();

-- -----------------------------------------------------------------------------
-- Work sessions, breaks, time entries
-- -----------------------------------------------------------------------------
create table public.work_sessions (
  id           uuid primary key default gen_random_uuid(),   -- agent-generated when source = agent
  user_id      uuid not null references public.profiles (id) on delete cascade,
  device_id    uuid,
  source       public.entry_source not null,
  started_at   timestamptz not null,
  ended_at     timestamptz,
  is_holiday_work boolean not null default false,             -- session on a leave day / holiday (Module 3)
  created_at   timestamptz not null default now(),
  check (ended_at is null or ended_at >= started_at),
  foreign key (device_id, user_id) references public.devices (id, user_id)
);
create index on public.work_sessions (user_id, started_at);
-- One open session per person.
create unique index work_sessions_one_open on public.work_sessions (user_id) where ended_at is null;

create table public.breaks (
  id           uuid primary key default gen_random_uuid(),
  session_id   uuid not null references public.work_sessions (id) on delete cascade,
  kind         public.break_kind not null,
  started_at   timestamptz not null,
  ended_at     timestamptz,
  check (ended_at is null or ended_at >= started_at),
  exclude using gist (session_id with =, tstzrange(started_at, coalesce(ended_at, 'infinity')) with &&)
);

create table public.time_entries (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles (id) on delete cascade,
  task_id       uuid references public.tasks (id) on delete set null,   -- null = unassigned time
  session_id    uuid references public.work_sessions (id) on delete set null,
  source        public.entry_source not null,
  kind          public.entry_kind not null default 'work',
  started_at    timestamptz not null,
  ended_at      timestamptz,                                           -- null = timer running
  -- Manual entries need a reason and a manager's approval.
  reason        text,
  approval      public.approval_status not null default 'approved',
  approved_by   uuid references public.profiles (id) on delete set null,
  approved_at   timestamptz,
  created_at    timestamptz not null default now(),
  check (ended_at is null or ended_at > started_at),
  check (source <> 'manual' or (reason is not null and length(trim(reason)) > 0)),
  check (source <> 'manual' or ended_at is not null)
);
create index on public.time_entries (user_id, started_at);
create index on public.time_entries (task_id);
-- Exactly one running timer per person, enforced by the database.
create unique index time_entries_one_running on public.time_entries (user_id) where ended_at is null;
-- No overlapping time for the same person (rejected entries don't count).
alter table public.time_entries add constraint time_entries_no_overlap
  exclude using gist (user_id with =, tstzrange(started_at, coalesce(ended_at, 'infinity')) with &&)
  where (approval <> 'rejected');

-- Manual entries start as pending.
create or replace function app.manual_entries_pending() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' and new.source = 'manual' then
    new.approval := 'pending'; new.approved_by := null; new.approved_at := null;
  end if;
  return new;
end $$;
create trigger time_entries_manual_pending before insert on public.time_entries
  for each row execute function app.manual_entries_pending();

-- Corrections keep the original value, the new value, who and why.
create table public.time_corrections (
  id            uuid primary key default gen_random_uuid(),
  entry_id      uuid not null references public.time_entries (id) on delete cascade,
  requested_by  uuid not null references public.profiles (id),
  old_value     jsonb not null,
  new_value     jsonb not null,
  reason        text not null check (length(trim(reason)) > 0),
  status        public.approval_status not null default 'pending',
  decided_by    uuid references public.profiles (id),
  decided_at    timestamptz,
  decision_note text,
  created_at    timestamptz not null default now()
);
create index on public.time_corrections (entry_id);

-- -----------------------------------------------------------------------------
-- Timesheet periods (per BS month). A locked period feeds payroll and freezes its entries.
-- -----------------------------------------------------------------------------
create table public.timesheet_periods (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.profiles (id) on delete cascade,
  bs_year      smallint not null,
  bs_month     smallint not null check (bs_month between 1 and 12),
  start_ad     date not null,
  end_ad       date not null,
  status       public.period_status not null default 'open',
  submitted_at timestamptz,
  approved_by  uuid references public.profiles (id),
  approved_at  timestamptz,
  locked_at    timestamptz,
  unique (user_id, bs_year, bs_month),
  foreign key (bs_year, bs_month) references public.bs_calendar_months (bs_year, bs_month)
);

-- Fill start/end from the BS calendar so a period always matches its month exactly.
create or replace function app.fill_period_dates() returns trigger
language plpgsql set search_path = public as $$
declare r record;
begin
  select * into r from public.bs_calendar_months where bs_year = new.bs_year and bs_month = new.bs_month;
  new.start_ad := r.ad_start;
  new.end_ad   := r.ad_start + (r.days - 1);
  return new;
end $$;
create trigger timesheet_periods_dates before insert or update of bs_year, bs_month on public.timesheet_periods
  for each row execute function app.fill_period_dates();

-- Is this instant inside a locked timesheet period for this user? (Kathmandu day boundaries)
create or replace function app.in_locked_period(p_user uuid, t timestamptz) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.timesheet_periods p
     where p.user_id = p_user and p.status = 'locked'
       and app.kathmandu_date(t) between p.start_ad and p.end_ad
  )
$$;

create or replace function app.guard_locked_entries() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op in ('UPDATE', 'DELETE') and app.in_locked_period(old.user_id, old.started_at) then
    raise exception 'This time is in a locked timesheet period; add a correction in the next period instead'
      using errcode = '42501';
  end if;
  if tg_op in ('INSERT', 'UPDATE') and app.in_locked_period(new.user_id, new.started_at) then
    raise exception 'This time is in a locked timesheet period' using errcode = '42501';
  end if;
  return coalesce(new, old);
end $$;
create trigger time_entries_locked before insert or update or delete on public.time_entries
  for each row execute function app.guard_locked_entries();

-- A locked period can only be unlocked by an admin (audited).
create or replace function app.guard_period_unlock() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.status = 'locked' and new.status <> 'locked' and auth.uid() is not null and not app.is_admin() then
    raise exception 'Only an admin can unlock a locked timesheet period' using errcode = '42501';
  end if;
  if new.status = 'locked' and old.status <> 'locked' then new.locked_at := now(); end if;
  return new;
end $$;
create trigger timesheet_periods_unlock before update on public.timesheet_periods
  for each row execute function app.guard_period_unlock();
create trigger timesheet_periods_audit after insert or update or delete on public.timesheet_periods
  for each row execute function app.audit_row();

-- -----------------------------------------------------------------------------
-- Activity evidence uploaded by the agent (contract §6, §7).
-- Written only by the server (service role) after it has authenticated the device.
-- Every row must belong to a device that belongs to the same user (composite FK),
-- and is refused unless monitoring is allowed for that user (notice + consent).
-- -----------------------------------------------------------------------------
create table public.agent_batches (
  batch_id     uuid primary key,             -- Idempotency-Key for POST /events
  device_id    uuid not null references public.devices (id) on delete cascade,
  received_at  timestamptz not null default now(),
  accepted     int not null default 0,
  rejected     int not null default 0
);

create table public.idle_events (
  event_id       uuid primary key,           -- agent-generated; dedup key
  user_id        uuid not null,
  device_id      uuid not null,
  session_id     uuid references public.work_sessions (id) on delete set null,
  started_at     timestamptz not null,
  ended_at       timestamptz not null,
  resolution     public.idle_resolution not null default 'pending',
  reassigned_task_id uuid references public.tasks (id) on delete set null,
  received_at    timestamptz not null default now(),
  check (ended_at >= started_at),
  foreign key (device_id, user_id) references public.devices (id, user_id) on delete cascade
);
create index on public.idle_events (user_id, started_at);

create table public.app_events (
  event_id     uuid primary key,
  user_id      uuid not null,
  device_id    uuid not null,
  session_id   uuid references public.work_sessions (id) on delete set null,
  task_id      uuid references public.tasks (id) on delete set null,
  started_at   timestamptz not null,
  ended_at     timestamptz not null,
  app_name     text not null,                -- e.g. 'Code.exe'. No window titles in Lite.
  process_name text,
  received_at  timestamptz not null default now(),
  check (ended_at >= started_at),
  foreign key (device_id, user_id) references public.devices (id, user_id) on delete cascade
);
create index on public.app_events (user_id, started_at);

create table public.web_events (
  event_id     uuid primary key,
  user_id      uuid not null,
  device_id    uuid not null,
  session_id   uuid references public.work_sessions (id) on delete set null,
  task_id      uuid references public.tasks (id) on delete set null,
  started_at   timestamptz not null,
  ended_at     timestamptz not null,
  -- Domain only. A full URL would contain '/' or '?' and is refused.
  domain       text not null check (domain ~ '^[a-z0-9.-]+$' and length(domain) <= 253),
  received_at  timestamptz not null default now(),
  check (ended_at >= started_at),
  foreign key (device_id, user_id) references public.devices (id, user_id) on delete cascade
);
create index on public.web_events (user_id, started_at);

-- Counts only. There is deliberately no column that could hold typed text.
create table public.input_metrics (
  event_id       uuid primary key,
  user_id        uuid not null,
  device_id      uuid not null,
  session_id     uuid references public.work_sessions (id) on delete set null,
  recorded_at    timestamptz not null,
  window_seconds smallint not null check (window_seconds between 10 and 600),
  key_events     int not null check (key_events >= 0),
  mouse_events   int not null check (mouse_events >= 0),
  active         boolean not null,
  received_at    timestamptz not null default now(),
  foreign key (device_id, user_id) references public.devices (id, user_id) on delete cascade
);
create index on public.input_metrics (user_id, recorded_at);

create table public.screenshots (
  id           uuid primary key,             -- agent-generated screenshot_id; dedup key
  user_id      uuid not null,
  device_id    uuid not null,
  session_id   uuid references public.work_sessions (id) on delete set null,
  task_id      uuid references public.tasks (id) on delete set null,
  captured_at  timestamptz not null,
  reason       text not null default 'scheduled' check (reason in ('scheduled')),  -- no manager-triggered capture in Lite
  status       public.screenshot_status not null default 'pending_upload',
  storage_key  text,                          -- path in the private 'screenshots' bucket
  width        int, height int, bytes int,
  detail       text,                          -- e.g. reason for capture_failed
  deleted_at   timestamptz,
  received_at  timestamptz not null default now(),
  foreign key (device_id, user_id) references public.devices (id, user_id) on delete cascade
);
create index on public.screenshots (user_id, captured_at);
create index on public.screenshots (captured_at) where status = 'stored';   -- retention job

-- Refuse evidence for anyone who has not consented / before the notice is confirmed.
create or replace function app.require_monitoring_allowed() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not app.monitoring_allowed(new.user_id) then
    raise exception 'Monitoring is not allowed for this user (notice not confirmed or no consent)'
      using errcode = '42501';
  end if;
  return new;
end $$;
create trigger idle_events_consent   before insert on public.idle_events   for each row execute function app.require_monitoring_allowed();
create trigger app_events_consent    before insert on public.app_events    for each row execute function app.require_monitoring_allowed();
create trigger web_events_consent    before insert on public.web_events    for each row execute function app.require_monitoring_allowed();
create trigger input_metrics_consent before insert on public.input_metrics for each row execute function app.require_monitoring_allowed();
create trigger screenshots_consent   before insert on public.screenshots   for each row execute function app.require_monitoring_allowed();

-- -----------------------------------------------------------------------------
-- App and website categories (manager-editable). Default for anything unmatched: unclassified.
-- -----------------------------------------------------------------------------
create table public.app_categories (
  id          uuid primary key default gen_random_uuid(),
  match_type  text not null check (match_type in ('app', 'domain')),
  pattern     text not null,                -- exact app name or domain; '*.example.com' allowed
  category    public.activity_category not null,
  team_id     uuid references public.teams (id) on delete cascade,   -- null = applies to everyone
  created_by  uuid references public.profiles (id) on delete set null,
  created_at  timestamptz not null default now(),
  unique nulls not distinct (match_type, pattern, team_id)
);

-- -----------------------------------------------------------------------------
-- Evidence access log helper: the API calls this before minting a signed URL.
-- Returns the storage key only if the caller may see it, and always logs the view.
-- -----------------------------------------------------------------------------
create or replace function app.screenshot_key_for_view(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare s record;
begin
  select * into s from public.screenshots where id = p_id and status = 'stored';
  if s is null or not app.can_see_activity(s.user_id) then
    perform app.audit('view_screenshot_denied', 'screenshots', p_id::text, '{}');
    return null;   -- denied: the API answers 403. (Raising would roll back the audit entry.)
  end if;
  perform app.audit('view_screenshot', 'screenshots', p_id::text, jsonb_build_object('employee', s.user_id));
  return s.storage_key;
end $$;
grant execute on function app.screenshot_key_for_view(uuid) to authenticated;

create trigger devices_audit after insert or update of revoked_at, revoke_scheduled_for, user_id or delete on public.devices
  for each row execute function app.audit_row('device_token_hash');
create trigger time_corrections_audit after insert or update or delete on public.time_corrections
  for each row execute function app.audit_row();
create trigger app_categories_audit after insert or update or delete on public.app_categories
  for each row execute function app.audit_row();
create trigger policies_audit after insert on public.policies
  for each row execute function app.audit_row();
