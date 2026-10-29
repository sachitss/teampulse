// End-to-end: a real browser against `next dev` and a fresh database with demo data.
// Run with:  npm run e2e   (see scripts/e2e.sh)
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import chromium from '@sparticuz/chromium';
import { chromium as pw, type Browser, type Page } from 'playwright-core';
import { totp, totpCounter } from '../lib/crypto.ts';

// localhost, not 127.0.0.1: Next.js 16 blocks dev resources for other origins.
const BASE = process.env.E2E_BASE ?? 'http://localhost:3200';
const SHOTS = process.env.E2E_SHOTS ?? '';
let browser: Browser;

before(async () => {
  // The bundled Chromium defaults to --single-process (for serverless), which crashes with many contexts.
  const args = chromium.args.filter((a) => a !== '--single-process' && !a.startsWith('--no-zygote'));
  browser = await pw.launch({ executablePath: await chromium.executablePath(), args, headless: true });
});
after(async () => { await browser?.close(); });

const PASSWORD = 'demo-password-CHANGE-ME';
// Authenticator app stand-in: remembers each person's two-factor secret, as their phone would.
const phones = new Map<string, { secret: string; last: number }>();

async function codeFor(email: string): Promise<string> {
  const p = phones.get(email)!;
  // A code can be used only once; wait for the next 30-second step if this one was used.
  while (totpCounter() <= p.last) await new Promise((r) => setTimeout(r, 1000));
  p.last = totpCounter();
  return totp(p.secret);
}

/** Real sign-in through the UI. mfa=true completes two-factor (setting it up the first time). */
async function signIn(email: string, mfa = true, viewport = { width: 1280, height: 860 }, password = PASSWORD): Promise<Page> {
  const ctx = await browser.newContext({ viewport, serviceWorkers: 'block' });
  const page = await ctx.newPage();
  await page.goto(`${BASE}/sign-in`);
  await page.locator('#email').fill(email);
  await page.locator('#password').fill(password);
  await page.getByTestId('sign-in').click();
  // HR/admin (and anyone with two-factor) are taken to /mfa; everyone else to /today (or /consent).
  await page.locator('[data-testid^="timer-"], [data-testid="notice-en"], [data-testid="verify-mfa"]').first().waitFor();
  if (page.url().endsWith('/mfa')) {
    if (!mfa) {
      await page.getByRole('link', { name: 'Not now' }).click();
    } else {
      if (await page.getByTestId('mfa-secret').count()) {
        phones.set(email, { secret: (await page.getByTestId('mfa-secret').innerText()).replace(/\s/g, ''), last: -1 });
      }
      await page.locator('#code').fill(await codeFor(email));
      await page.getByTestId('verify-mfa').click();
    }
    await page.locator('[data-testid^="timer-"], [data-testid="notice-en"]').first().waitFor();
  }
  return page;
}

async function consentIfAsked(page: Page) {
  if (await page.getByTestId('notice-en').count()) {
    await page.getByRole('button', { name: /I consent/ }).click();
    await page.waitForURL(/\/today$/);
  }
}

async function shot(page: Page, name: string) {
  if (SHOTS) await page.screenshot({ path: `${SHOTS}/${name}.png`, fullPage: true });
}

test('admin publishes the notice; nothing is recorded until it is confirmed', async () => {
  const page = await signIn('demo.admin@demo.invalid');
  assert.equal(await page.getByTestId('notice-en').count(), 0, 'no notice yet, so no consent screen');
  await page.goto(`${BASE}/settings`);
  await assert.doesNotReject(page.getByTestId('monitoring-status').getByText('Off').waitFor());

  // The template still has [bracketed] placeholders: publishing is refused.
  await page.getByTestId('publish-notice').click();
  await page.getByRole('alert').getByText(/Fill in the \[bracketed\] parts/).waitFor();

  // Fill the placeholders, then publish.
  for (const id of ['#n-en', '#n-ne']) {
    const v = await page.locator(id).inputValue();
    await page.locator(id).fill(v.replace(/\[([^\]]+)\]/g, '$1'));
  }
  await page.getByTestId('publish-notice').click();
  // Publishing takes the admin straight to the new notice: they must consent too.
  await page.waitForURL(/\/consent$/);
  await page.getByTestId('notice-en').waitFor();
  await consentIfAsked(page);

  await page.goto(`${BASE}/settings`);
  await page.getByTestId('confirm-notice').click();
  await page.getByRole('status').getByText(/Monitoring is now allowed/).waitFor();
  await page.getByTestId('monitoring-status').getByText('On').waitFor();
  await shot(page, 'desktop-settings');
  await page.context().close();
});

test('employee: consent, full timer day, manual time, submit the month', async () => {
  const page = await signIn('demo.employee03@demo.invalid', false);
  assert.equal(await page.getByTestId('notice-en').count(), 1, 'employee is asked to consent first');
  await consentIfAsked(page);

  await page.getByTestId('timer-idle').waitFor();
  await page.locator('[data-testid="timer-idle"] select').selectOption({ index: 1 });
  await page.getByTestId('start').click();
  await page.getByTestId('timer-running').waitFor();
  // The clock is client-side; give the page time to load its script (dev mode compiles on first use).
  const t1 = await page.getByTestId('clock').textContent();
  let ticked = false;
  for (let i = 0; i < 20 && !ticked; i++) { await page.waitForTimeout(500); ticked = (await page.getByTestId('clock').textContent()) !== t1; }
  assert.ok(ticked, 'clock ticks');

  await page.locator('[data-testid="timer-running"] select').selectOption('');
  await page.getByTestId('switch').click();
  await page.getByText('Unassigned time').waitFor();
  await page.getByTestId('break').click();
  await page.getByTestId('timer-break').waitFor();
  await page.getByTestId('resume').click();
  await page.getByTestId('timer-running').waitFor();
  await shot(page, 'desktop-today-running');
  await page.getByTestId('stop').click();
  await page.getByTestId('timer-idle').waitFor();
  assert.equal(await page.locator('table tbody tr').count(), 3, 'three entries today');

  // Manual time two days ago, 10:00–12:00 Kathmandu.
  const d = new Date(Date.now() - 2 * 86400_000 + (5 * 60 + 45) * 60_000).toISOString().slice(0, 10);
  await page.getByText('Add time without the timer').click();
  await page.locator('#m-start').fill(`${d}T10:00`);
  await page.locator('#m-end').fill(`${d}T12:00`);
  await page.locator('#m-reason').fill('Site visit at client office');
  await page.getByTestId('manual-submit').click();
  await page.getByText(/Your manager will review it/).waitFor();

  // Same slot again is refused by the database with a plain message.
  await page.locator('#m-start').fill(`${d}T11:00`);
  await page.locator('#m-end').fill(`${d}T13:00`);
  await page.locator('#m-reason').fill('Duplicate');
  await page.getByTestId('manual-submit').click();
  await page.getByText('This overlaps time you have already recorded.').waitFor();

  await page.goto(`${BASE}/timesheet`);
  await page.getByTestId('submit-month').click();
  await page.getByTestId('period-status').getByText('Submitted').waitFor();
  await shot(page, 'desktop-timesheet');
  // Also submit last month (it has ended, so it can be locked).
  await page.getByRole('link', { name: 'Previous month' }).click();
  await page.getByTestId('submit-month').click();
  await page.getByTestId('period-status').getByText('Submitted').waitFor();

  // Employees have no manager screens.
  await page.goto(`${BASE}/approvals`);
  await page.waitForURL(/\/today$/);
  await page.context().close();
});

test('manager approves the manual time, approves and locks the month', async () => {
  const page = await signIn('demo.employee01@demo.invalid', false);   // employee01 is a manager
  await consentIfAsked(page);
  await page.goto(`${BASE}/approvals`);
  await page.getByText('Site visit at client office').waitFor();
  await page.getByTestId('approve-entry').first().click();
  await page.getByRole('status').getByText('Time approved.').waitFor();
  assert.equal(await page.getByText('Site visit at client office').count(), 0, 'approved entry leaves the list');
  // Approve both months; only the one that has ended offers locking.
  await page.getByTestId('approve-period').first().click();
  await page.getByRole('status').getByText('Timesheet approved.').waitFor();
  await page.getByTestId('approve-period').first().click();
  await page.getByRole('status').getByText('Timesheet approved.').waitFor();
  assert.equal(await page.getByTestId('lock-period').count(), 1, 'only the finished month can be locked');
  await page.getByText('Can be locked after the month ends').waitFor();
  await page.getByTestId('lock-period').click();
  await page.getByRole('status').getByText('Timesheet locked for payroll.').waitFor();
  await shot(page, 'desktop-approvals');
  // A manager never sees People or Settings.
  await page.goto(`${BASE}/people`);
  await page.waitForURL(/\/today$/);
  await page.context().close();
});

test('employee sees last month locked and this month approved', async () => {
  const page = await signIn('demo.employee03@demo.invalid', false);
  await page.goto(`${BASE}/timesheet`);
  await page.getByTestId('period-status').getByText('Approved').waitFor();
  await page.getByRole('link', { name: 'Previous month' }).click();
  await page.getByTestId('period-status').getByText('Locked for payroll').waitFor();
  await page.context().close();
});

test('HR without two-factor gets employee rights only', async () => {
  const page = await signIn('demo.hr@demo.invalid', false);
  await consentIfAsked(page);
  await page.getByText(/rights are switched off for this session/).waitFor();
  assert.equal(await page.getByRole('link', { name: 'People' }).count(), 0);
  await page.goto(`${BASE}/people`);
  await page.waitForURL(/\/today$/);
  await page.context().close();
});

test('admin adds an employee; HR with two-factor sees them', async () => {
  const page = await signIn('demo.admin@demo.invalid');
  await page.goto(`${BASE}/people/new`);
  await page.locator('#full_name').fill('E2E New Starter');
  await page.locator('#email').fill('new.starter@demo.invalid');
  await page.locator('#job_title').fill('BIM Modeller');
  await page.getByTestId('create-person').click();
  await page.waitForURL(/\/people\/[0-9a-f-]{36}\?invite=pending$/);
  await page.getByRole('heading', { name: 'E2E New Starter' }).waitFor();
  await page.getByText(/Not consented yet/).waitFor();
  // No email server in tests: the admin creates the invitation link and hands it over.
  await page.getByText(/Email is not set up/).waitFor();
  await page.getByTestId('invite-link').click();
  const link = await page.getByTestId('one-time-link').inputValue();
  assert.match(link, /\/set-password\?token=/);
  // Duplicate email refused.
  await page.goto(`${BASE}/people/new`);
  await page.locator('#full_name').fill('Again');
  await page.locator('#email').fill('new.starter@demo.invalid');
  await page.getByTestId('create-person').click();
  await page.getByText('Someone with that email address already exists.').waitFor();
  await page.context().close();

  const hr = await signIn('demo.hr@demo.invalid', true);
  await consentIfAsked(hr);
  await hr.goto(`${BASE}/people`);
  await hr.getByRole('link', { name: 'E2E New Starter' }).waitFor();
  await hr.context().close();

  // The new starter opens the link, chooses a password, signs in and is asked to consent.
  const ctx = await browser.newContext({ serviceWorkers: 'block' });
  const starter = await ctx.newPage();
  await starter.goto(link.replace(/^https?:\/\/[^/]+/, BASE));
  await starter.getByRole('heading', { name: 'Welcome to TeamPulse' }).waitFor();
  await starter.locator('#pw').fill('aaaaaaaaaaaaaaaa');
  await starter.locator('#pw2').fill('aaaaaaaaaaaaaaaa');
  await starter.getByTestId('save-password').click();
  await starter.getByRole('alert').getByText(/less predictable/).waitFor();
  await starter.locator('#pw').fill('mountain view from Nagarkot');
  await starter.locator('#pw2').fill('mountain view from Nagarkot');
  await starter.getByTestId('save-password').click();
  await starter.waitForURL(/\/sign-in\?done=password$/);
  // The link works once only.
  await starter.goto(link.replace(/^https?:\/\/[^/]+/, BASE));
  await starter.getByRole('heading', { name: 'Link expired' }).waitFor();
  await ctx.close();
  const signedIn = await signIn('new.starter@demo.invalid', false, undefined, 'mountain view from Nagarkot');
  assert.equal(await signedIn.getByTestId('notice-en').count(), 1, 'new starter must consent first');
  await signedIn.context().close();
});

test('sign-in refuses a wrong password, and sign-out ends the session', async () => {
  const ctx = await browser.newContext({ serviceWorkers: 'block' });
  const page = await ctx.newPage();
  await page.goto(`${BASE}/sign-in`);
  await page.locator('#email').fill('demo.employee05@demo.invalid');
  await page.locator('#password').fill('not-the-password');
  await page.getByTestId('sign-in').click();
  await page.getByRole('alert').getByText('Email or password is not correct.').waitFor();
  await page.goto(`${BASE}/today`);
  await page.waitForURL(/\/sign-in$/);
  await ctx.close();

  const p2 = await signIn('demo.employee05@demo.invalid', false);
  const cookie = (await p2.context().cookies()).find((c) => c.name === 'tp_session');
  assert.ok(cookie?.httpOnly, 'session cookie is httpOnly');
  assert.equal(cookie?.sameSite, 'Lax');
  await consentIfAsked(p2);
  await p2.getByRole('button', { name: 'Sign out' }).click();
  await p2.waitForURL(/\/sign-in$/);
  // The old cookie no longer works even if replayed.
  const replay = await browser.newContext({ serviceWorkers: 'block' });
  await replay.addCookies([{ ...cookie!, expires: -1 }]);
  const r = await replay.newPage();
  await r.goto(`${BASE}/today`);
  await r.waitForURL(/\/sign-in$/);
  await replay.close();
  await p2.context().close();
});

test('manager creates a project and a task', async () => {
  const page = await signIn('demo.employee01@demo.invalid', false);
  await page.goto(`${BASE}/projects`);
  await page.locator('#p-name').fill('E2E Hospital HVAC families');
  await page.getByTestId('create-project').click();
  await page.getByText(/created/).waitFor();
  await page.getByRole('link', { name: 'E2E Hospital HVAC families' }).click();
  await page.locator('#t-title').fill('Model AHU family');
  await page.locator('#t-est').fill('6');
  await page.getByTestId('create-task').click();
  await page.getByText('Task added.').waitFor();
  await page.getByText('Model AHU family').waitFor();
  await page.context().close();
});

test('phone: bottom tabs, no top nav, timer usable', async () => {
  const page = await signIn('demo.employee03@demo.invalid', false, { width: 390, height: 844 });
  await page.locator('.tabbar').waitFor();
  assert.ok(await page.locator('.tabbar').isVisible(), 'tab bar visible on phone');
  assert.ok(!(await page.locator('.topbar nav').isVisible()), 'top nav hidden on phone');
  const scroll = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  assert.ok(scroll <= 0, `no horizontal scroll (overflow ${scroll}px)`);
  await page.getByTestId('start').click();
  await page.getByTestId('timer-running').waitFor();
  await shot(page, 'phone-today');
  await page.getByTestId('stop').click();
  await page.getByTestId('timer-idle').waitFor();
  await page.context().close();
});

test('installable: manifest, icons and service worker', async () => {
  const ctx = await browser.newContext();
  const page = await ctx.newPage();
  const res = await page.goto(`${BASE}/manifest.webmanifest`);
  const m = await res!.json();
  assert.equal(m.display, 'standalone');
  assert.equal(m.start_url, '/today');
  assert.ok(m.icons.some((i: any) => i.sizes === '512x512' && i.purpose === 'maskable'), 'maskable icon');
  for (const i of m.icons) assert.equal((await page.request.get(`${BASE}${i.src}`)).status(), 200, i.src);
  await page.goto(`${BASE}/sign-in`);
  assert.equal(await page.locator('link[rel="manifest"]').count(), 1, 'manifest linked');
  const sw = await page.evaluate(async () => {
    const reg = await navigator.serviceWorker.ready;
    return reg.active?.scriptURL ?? null;
  });
  assert.match(String(sw), /\/sw\.js$/, 'service worker active');
  await ctx.close();
});
