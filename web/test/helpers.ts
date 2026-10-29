// Test harness: a fresh database built from the real migrations + demo data,
// and an asUser() that behaves exactly like lib/db.ts (role authenticated + claims).
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import pg from 'pg';
import type { Db } from '../lib/db.ts';

const root = fileURLToPath(new URL('../../', import.meta.url));
export const TEST_DB = process.env.TP_WEB_TEST_DB ?? 'tp_web_test';
const PSQL = process.env.PSQL ?? 'runuser -u postgres -- psql';
export const DATABASE_URL = process.env.TP_WEB_TEST_URL ?? `postgresql://postgres:postgres@127.0.0.1:5432/${TEST_DB}`;

export function buildDatabase(): void {
  execFileSync('bash', [`${root}db/tests/run.sh`, '--no-tests'], {
    env: { ...process.env, TP_TEST_DB: TEST_DB, PSQL }, stdio: 'pipe',
  });
  execFileSync('bash', ['-c', `cat ${root}db/demo/demo_load.sql | ${PSQL} -X -q -v ON_ERROR_STOP=1 -d ${TEST_DB}`], { stdio: 'pipe' });
}

let pool: pg.Pool | null = null;
export function getPool(): pg.Pool {
  pool ??= new pg.Pool({ connectionString: DATABASE_URL, max: 4 });
  return pool;
}
export async function closePool() { await pool?.end(); pool = null; }

function wrap(c: pg.PoolClient): Db {
  return {
    query: async (t, p) => (await c.query(t, p as any[])).rows,
    one: async (t, p) => (await c.query(t, p as any[])).rows[0] ?? null,
  };
}

export async function asUser<T>(userId: string, fn: (db: Db) => Promise<T>, mfa = false): Promise<T> {
  const c = await getPool().connect();
  try {
    await c.query('begin');
    await c.query(`select set_config('request.jwt.claims', $1, true)`,
                  [JSON.stringify({ sub: userId, aal: mfa ? 'aal2' : 'aal1', role: 'authenticated' })]);
    await c.query('set local role authenticated');
    const r = await fn(wrap(c));
    await c.query('commit');
    return r;
  } catch (e) {
    await c.query('rollback'); throw e;
  } finally { c.release(); }
}

export async function asSystem<T>(fn: (db: Db) => Promise<T>): Promise<T> {
  const c = await getPool().connect();
  try { await c.query('begin'); const r = await fn(wrap(c)); await c.query('commit'); return r; }
  catch (e) { await c.query('rollback'); throw e; } finally { c.release(); }
}

// Demo accounts (db/demo/demo_load.sql)
export const DEMO = {
  admin: '00000000-0000-4000-8000-00000000d001',
  hr: '00000000-0000-4000-8000-00000000d002',
  manager1: '00000000-0000-4000-8000-0000000e0001',
  employee3: '00000000-0000-4000-8000-0000000e0003',   // reports to manager1
  employee4: '00000000-0000-4000-8000-0000000e0004',   // reports to manager2
};
