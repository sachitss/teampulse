-- =============================================================================
-- 0011 Built-in sign-in (replaces Supabase Auth)
--
-- Everything here lives in schema `auth`, which signed-in people (role
-- `authenticated`) cannot read or write at all. Only the web server's own
-- login (teampulse_app) touches it, inside the sign-in code.
--   * passwords: bcrypt via pgcrypto (cost 11), never stored or logged in clear
--   * sessions: the browser holds a random token; the database stores only its SHA-256
--   * two-factor: TOTP secrets encrypted by the app (AES-256-GCM) before storage
--   * invitation / reset links: single-use, short-lived, stored as SHA-256
-- =============================================================================

create table auth.credentials (
  user_id           uuid primary key references auth.users (id) on delete cascade,
  password_hash     text not null check (password_hash like '$2%'),   -- bcrypt
  updated_at        timestamptz not null default now(),
  failed_attempts   smallint not null default 0,
  locked_until      timestamptz
);

create table auth.mfa_factors (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users (id) on delete cascade,
  secret_enc    bytea not null,                  -- AES-256-GCM(iv|tag|ciphertext) of the base32 secret
  confirmed_at  timestamptz,                     -- null while enrolment is in progress
  last_counter  bigint,                          -- last accepted TOTP step: blocks code replay
  created_at    timestamptz not null default now()
);
create unique index mfa_one_confirmed_per_user on auth.mfa_factors (user_id) where confirmed_at is not null;

create table auth.sessions (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users (id) on delete cascade,
  token_hash    bytea not null unique,           -- sha256 of the cookie value
  aal           text not null default 'aal1' check (aal in ('aal1', 'aal2')),
  created_at    timestamptz not null default now(),
  last_seen_at  timestamptz not null default now(),
  expires_at    timestamptz not null,
  revoked_at    timestamptz,
  user_agent    text,
  ip            text
);
create index on auth.sessions (user_id) where revoked_at is null;

create table auth.one_time_tokens (
  token_hash  bytea primary key,                 -- sha256 of the link token
  user_id     uuid not null references auth.users (id) on delete cascade,
  kind        text not null check (kind in ('invite', 'reset')),
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null,
  used_at     timestamptz,
  created_by  uuid
);
create index on auth.one_time_tokens (user_id, kind);

-- Signed-in people get nothing in schema auth (beyond auth.uid()/auth.jwt()).
revoke all on all tables in schema auth from anon, authenticated, service_role;
grant all on all tables in schema auth to teampulse_app;

-- Audit the security-relevant events without copying secrets.
create or replace function app.audit_auth_event() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.audit_log (actor_id, actor_kind, action, target_table, target_id, details)
  values (coalesce(auth.uid(), new.user_id), 'user',
          tg_argv[0], 'auth.' || tg_table_name, new.user_id::text,
          case tg_table_name when 'sessions' then jsonb_build_object('aal', to_jsonb(new) ->> 'aal', 'ip', to_jsonb(new) ->> 'ip')
                             when 'one_time_tokens' then jsonb_build_object('kind', to_jsonb(new) ->> 'kind')
                             else '{}'::jsonb end);
  return null;
end $$;
create trigger sessions_audit after insert on auth.sessions for each row execute function app.audit_auth_event('sign_in');
create trigger mfa_audit after insert on auth.mfa_factors for each row execute function app.audit_auth_event('mfa_enrol_started');
create trigger tokens_audit after insert on auth.one_time_tokens for each row execute function app.audit_auth_event('link_issued');

grant execute on all functions in schema app to teampulse_app;
grant all on all tables in schema public to teampulse_app;
grant all on all sequences in schema public to teampulse_app;
