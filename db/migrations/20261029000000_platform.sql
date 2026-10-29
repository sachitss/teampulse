-- =============================================================================
-- 0000 Platform — makes a plain PostgreSQL 15+ database complete on its own
-- (self-hosted on the Synology NAS; no Supabase needed).
--
-- Provides what the rest of the schema expects:
--   * roles  anon / authenticated (what signed-in people run as) / service_role
--   * schema auth with auth.users, auth.uid(), auth.jwt()
--     — the app sets request.jwt.claims per transaction after verifying the session
--   * teampulse_app: the login the web app uses. It can bypass RLS only for
--     server-side work (sign-in, agent ingestion, jobs) and switches to
--     `authenticated` for everything a person does, so RLS applies to them.
--   * a tiny storage schema kept for compatibility (files live on the NAS disk)
-- =============================================================================
create extension if not exists pgcrypto;

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon')          then create role anon nologin noinherit; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin noinherit; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role')  then create role service_role nologin noinherit bypassrls; end if;
  -- The migration runner gives this role a password (APP_DB_PASSWORD) and LOGIN.
  if not exists (select 1 from pg_roles where rolname = 'teampulse_app') then create role teampulse_app nologin bypassrls; end if;
end $$;
grant authenticated to teampulse_app;   -- lets the app `set local role authenticated`

create schema if not exists auth;
create table if not exists auth.users (
  id          uuid primary key default gen_random_uuid(),
  email       text unique,
  created_at  timestamptz not null default now()
);

create or replace function auth.jwt() returns jsonb
language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb
$$;

create or replace function auth.uid() returns uuid
language sql stable as $$
  select nullif(auth.jwt() ->> 'sub', '')::uuid
$$;

grant usage on schema auth to anon, authenticated, service_role, teampulse_app;
grant execute on function auth.jwt(), auth.uid() to anon, authenticated, service_role, teampulse_app;

-- Kept so migration 0006 (private buckets) applies unchanged. Files are stored on disk.
create schema if not exists storage;
create table if not exists storage.buckets (id text primary key, name text not null, public boolean not null default false);
create table if not exists storage.objects (
  id uuid primary key default gen_random_uuid(), bucket_id text references storage.buckets (id),
  name text not null, owner uuid, created_at timestamptz default now());
alter table storage.objects enable row level security;

-- Table privileges: RLS does the restricting (same model as Supabase).
grant usage on schema public to anon, authenticated, service_role, teampulse_app;
alter default privileges in schema public grant all on tables    to anon, authenticated, service_role, teampulse_app;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role, teampulse_app;
alter default privileges in schema public grant execute on functions to anon, authenticated, service_role, teampulse_app;
grant usage on schema storage to teampulse_app;
grant all on all tables in schema storage to teampulse_app;
