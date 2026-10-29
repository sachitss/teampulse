// Database access. Every request from a signed-in person runs in a transaction
// as the Postgres role `authenticated` with that person's JWT claims — exactly
// what Supabase's own API does — so the Row Level Security policies in
// supabase/migrations decide what they can see and change. Nothing in the app
// layer can widen that.
import 'server-only';
import pg from 'pg';

export interface Claims {
  sub: string;
  aal: 'aal1' | 'aal2';
  role: 'authenticated';
  email?: string;
}

export type Db = {
  query<R extends pg.QueryResultRow = any>(text: string, params?: unknown[]): Promise<R[]>;
  one<R extends pg.QueryResultRow = any>(text: string, params?: unknown[]): Promise<R | null>;
};

declare global {
  // Re-use one pool across hot reloads in development.
  // eslint-disable-next-line no-var
  var __tpPool: pg.Pool | undefined;
}

function pool(): pg.Pool {
  if (!globalThis.__tpPool) {
    const connectionString = process.env.DATABASE_URL;
    if (!connectionString) throw new Error('DATABASE_URL is not set');
    globalThis.__tpPool = new pg.Pool({ connectionString, max: Number(process.env.DATABASE_POOL_MAX ?? 10) });
  }
  return globalThis.__tpPool;
}

function wrap(client: pg.PoolClient): Db {
  return {
    async query(text, params) {
      return (await client.query(text, params as any[])).rows;
    },
    async one(text, params) {
      return (await client.query(text, params as any[])).rows[0] ?? null;
    },
  };
}

async function inTransaction<T>(setup: (c: pg.PoolClient) => Promise<void>, fn: (db: Db) => Promise<T>): Promise<T> {
  const client = await pool().connect();
  try {
    await client.query('begin');
    await setup(client);
    const result = await fn(wrap(client));
    await client.query('commit');
    return result;
  } catch (e) {
    await client.query('rollback').catch(() => {});
    throw e;
  } finally {
    client.release();
  }
}

/** Run as the signed-in person. RLS applies. */
export function asUser<T>(claims: Claims, fn: (db: Db) => Promise<T>): Promise<T> {
  return inTransaction(async (c) => {
    await c.query(`select set_config('request.jwt.claims', $1, true)`, [JSON.stringify(claims)]);
    await c.query('set local role authenticated');
  }, fn);
}

/**
 * Run as the server itself (bypasses RLS). Only for work no person can do through
 * their own rights: agent ingestion after the device token is checked, scheduled jobs,
 * and creating the login account for a new employee after an admin asked for it.
 */
export function asSystem<T>(fn: (db: Db) => Promise<T>): Promise<T> {
  return inTransaction(async (c) => {
    await c.query(`select set_config('request.jwt.claims', '', true)`);
  }, fn);
}

// ---------------------------------------------------------------------------
// Turn database refusals into messages a person can act on.
// The triggers already raise plain-language messages; constraints get a mapping.
// ---------------------------------------------------------------------------
const CONSTRAINT_MESSAGES: Record<string, string> = {
  time_entries_one_running: 'You already have a timer running. Stop or switch it first.',
  work_sessions_one_open: 'You already have a work session open.',
  time_entries_no_overlap: 'This overlaps time you have already recorded.',
  leave_requests_no_overlap: 'You already have leave requested or approved for those dates.',
  profiles_email_key: 'Someone with that email address already exists.',
  projects_name_key: 'A project with that name already exists.',
};

export function friendlyError(e: unknown): string {
  const err = e as { code?: string; constraint?: string; message?: string };
  if (err?.constraint && CONSTRAINT_MESSAGES[err.constraint]) return CONSTRAINT_MESSAGES[err.constraint];
  // 42501 insufficient privilege (RLS / guard triggers), 23514 check/rule violations raised by triggers
  if (err?.code === '42501') {
    if (/row-level security/i.test(err.message ?? '')) return 'You do not have permission to do that.';
    return err.message ?? 'You do not have permission to do that.';
  }
  if (err?.code === '23514' || err?.code === '22008' || err?.code === '22007') return err.message ?? 'That is not allowed.';
  if (err?.code === '23505') return 'That already exists.';
  console.error(e);
  return 'Something went wrong. Please try again.';
}
