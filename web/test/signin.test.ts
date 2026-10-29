// Built-in sign-in: TOTP against the RFC 6238 test vectors, encryption, and the database
// rules (lockout, single-use links, session expiry, two-factor replay) on a real database.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { buildDatabase, asSystem, closePool, DEMO } from './helpers.ts';
import { hotp, totp, verifyTotp, base32Encode, base32Decode, encrypt, decrypt, otpauthUri } from '../lib/crypto.ts';
import {
  checkPassword, setPassword, createSession, findSession, revokeSession, issueLink, peekLink, redeemLink,
  startMfaEnrolment, pendingMfaSecret, verifyMfaCode, hasMfa, resetMfa, passwordProblem, SignInError, POLICY,
} from '../lib/signin-core.ts';

process.env.ENCRYPTION_KEY ??= randomBytes(32).toString('base64');
const DEMO_PW = 'demo-password-CHANGE-ME';
const EMP = DEMO.employee3, EMP_EMAIL = 'demo.employee03@demo.invalid';

before(() => buildDatabase());
after(() => closePool());

// --- pure functions -------------------------------------------------------
test('TOTP matches RFC 6238 SHA-1 test vectors (8 digits)', () => {
  const secret = Buffer.from('12345678901234567890');
  const vectors: [number, string][] = [[59, '94287082'], [1111111109, '07081804'], [1111111111, '14050471'],
    [1234567890, '89005924'], [2000000000, '69279037'], [20000000000, '65353130']];
  for (const [t, code] of vectors) assert.equal(hotp(secret, Math.floor(t / 30), 8), code, `t=${t}`);
});

test('HOTP matches RFC 4226 vectors and base32 round-trips', () => {
  const secret = Buffer.from('12345678901234567890');
  assert.deepEqual([0, 1, 2, 9].map((c) => hotp(secret, c)), ['755224', '287082', '359152', '520489']);
  const b = randomBytes(20);
  assert.deepEqual(base32Decode(base32Encode(b)), b);
  assert.equal(base32Encode(Buffer.from('12345678901234567890')), 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ');
});

test('verifyTotp accepts ±1 step, rejects older, and blocks replay', () => {
  const s = base32Encode(randomBytes(20));
  const now = 1_800_000_000_000;
  assert.ok(verifyTotp(s, totp(s, now), now) !== null);
  assert.ok(verifyTotp(s, totp(s, now - 30_000), now) !== null);
  assert.equal(verifyTotp(s, totp(s, now - 90_000), now), null);
  const c = verifyTotp(s, totp(s, now), now)!;
  assert.equal(verifyTotp(s, totp(s, now), now, c), null, 'same code twice is refused');
  assert.equal(verifyTotp(s, 'abcdef', now), null);
  assert.match(otpauthUri(s, 'a@b.c'), /^otpauth:\/\/totp\/TeamPulse%3Aa%40b\.c\?secret=/);
});

test('AES-GCM encryption round-trips and detects tampering', () => {
  const blob = encrypt('JBSWY3DPEHPK3PXP');
  assert.equal(decrypt(blob), 'JBSWY3DPEHPK3PXP');
  blob[blob.length - 1] ^= 1;
  assert.throws(() => decrypt(blob));
});

test('password rules', () => {
  assert.ok(passwordProblem('short'));
  assert.ok(passwordProblem('aaaaaaaaaaaaaaa'));
  assert.ok(passwordProblem('password12345'));
  assert.equal(passwordProblem('tea at four in Patan'), null);
});

// --- database ---------------------------------------------------------------
test('password check: right, wrong, unknown email, case-insensitive email', async () => {
  await asSystem(async (db) => {
    assert.equal(await checkPassword(db, EMP_EMAIL.toUpperCase(), DEMO_PW), EMP);
    await assert.rejects(checkPassword(db, EMP_EMAIL, 'wrong-password'), SignInError);
    await assert.rejects(checkPassword(db, 'nobody@demo.invalid', DEMO_PW), /not correct/);
    // a correct password resets the failure count
    assert.equal(await checkPassword(db, EMP_EMAIL, DEMO_PW), EMP);
    const r = await db.one(`select failed_attempts from auth.credentials where user_id = $1`, [EMP]);
    assert.equal(r.failed_attempts, 0);
  });
});

test(`lockout after ${POLICY.maxFailedAttempts} failures, even with the right password`, async () => {
  const email = 'demo.employee04@demo.invalid';
  await asSystem(async (db) => {
    for (let i = 0; i < POLICY.maxFailedAttempts; i++) await assert.rejects(checkPassword(db, email, 'nope'), /not correct/);
    await assert.rejects(checkPassword(db, email, DEMO_PW), /Too many attempts/);
    await db.query(`update auth.credentials set failed_attempts = 0, locked_until = null where user_id = $1`, [DEMO.employee4]);
    assert.equal(await checkPassword(db, email, DEMO_PW), DEMO.employee4);
  });
});

test('inactive employees cannot sign in', async () => {
  await asSystem(async (db) => {
    await db.query(`update profiles set active = false where id = $1`, [DEMO.manager1]);
    await assert.rejects(checkPassword(db, 'demo.employee01@demo.invalid', DEMO_PW), /not active/);
    await db.query(`update profiles set active = true where id = $1`, [DEMO.manager1]);
  });
});

test('sessions: found by token only, revocable, expire, idle out', async () => {
  await asSystem(async (db) => {
    const t = await createSession(db, EMP, 'aal1');
    const s = await findSession(db, t);
    assert.equal(s?.user_id, EMP);
    assert.equal(s?.aal, 'aal1');
    assert.equal(await findSession(db, t + 'x'), null);
    const stored = await db.one(`select count(*)::int as n from auth.sessions where token_hash::text like '%' || $1 || '%'`, [t]);
    assert.equal(stored.n, 0, 'token is not stored in clear');
    await revokeSession(db, t);
    assert.equal(await findSession(db, t), null);

    const t2 = await createSession(db, EMP, 'aal1');
    await db.query(`update auth.sessions set expires_at = now() - interval '1 second' where user_id = $1 and revoked_at is null`, [EMP]);
    assert.equal(await findSession(db, t2), null, 'expired');
    const t3 = await createSession(db, EMP, 'aal1');
    await db.query(`update auth.sessions set last_seen_at = now() - interval '${POLICY.idleDays + 1} days' where user_id = $1 and revoked_at is null and expires_at > now()`, [EMP]);
    assert.equal(await findSession(db, t3), null, 'idle too long');
  });
});

test('links: single use, expire, newer replaces older, password change signs out everywhere', async () => {
  await asSystem(async (db) => {
    const old = await issueLink(db, EMP, 'reset');
    const link = await issueLink(db, EMP, 'reset');
    assert.equal(await peekLink(db, old), null, 'older link stops working');
    assert.equal((await peekLink(db, link))?.email, EMP_EMAIL);
    const session = await createSession(db, EMP, 'aal1');
    await assert.rejects(redeemLink(db, link, 'short'), /at least/);
    assert.ok(await peekLink(db, link), 'a refused password does not use up the link');
    assert.equal(await redeemLink(db, link, 'a brand new long password'), EMP);
    await assert.rejects(redeemLink(db, link, 'another long password'), /expired or was already used/);
    assert.equal(await findSession(db, session), null, 'other sessions ended');
    assert.equal(await checkPassword(db, EMP_EMAIL, 'a brand new long password'), EMP);
    const expired = await issueLink(db, EMP, 'invite');
    await db.query(`update auth.one_time_tokens set expires_at = now() - interval '1 second' where user_id = $1 and kind = 'invite'`, [EMP]);
    await assert.rejects(redeemLink(db, expired, 'yet another long password'), /expired/);
    await setPassword(db, EMP, DEMO_PW.padEnd(12, 'x'));
  });
});

test('two-factor: enrol, confirm, replay blocked, admin reset', async () => {
  const HR = DEMO.hr;
  await asSystem(async (db) => {
    assert.equal(await hasMfa(db, HR), false);
    const secret = await startMfaEnrolment(db, HR);
    assert.equal(await pendingMfaSecret(db, HR), secret);
    const raw = await db.one(`select secret_enc from auth.mfa_factors where user_id = $1`, [HR]);
    assert.ok(!raw.secret_enc.toString('latin1').includes(secret), 'secret encrypted at rest');
    const now = Date.now();
    await assert.rejects(verifyMfaCode(db, HR, '000000', now), /did not work/);
    await verifyMfaCode(db, HR, totp(secret, now), now);
    assert.equal(await hasMfa(db, HR), true);
    await assert.rejects(verifyMfaCode(db, HR, totp(secret, now), now), /did not work/, 'same code cannot be used twice');
    await verifyMfaCode(db, HR, totp(secret, now + 30_000), now + 30_000);
    await assert.rejects(startMfaEnrolment(db, HR), /already set up/);
    const t = await createSession(db, HR, 'aal2');
    await resetMfa(db, HR);
    assert.equal(await hasMfa(db, HR), false);
    assert.equal((await findSession(db, t))?.aal, 'aal1', 'existing sessions drop to password level');
  });
});

test('sign-in events are audited without secrets', async () => {
  await asSystem(async (db) => {
    const rows = await db.query(`select details::text as d from audit_log where target_table like 'auth.%'`);
    assert.ok(rows.length > 0);
    for (const r of rows) assert.ok(!/token_hash|secret|password/.test(r.d), r.d);
  });
});
