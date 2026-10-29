# TeamPulse Lite + HR — PEACE Consultancy

Time and activity tracking, leave and holidays, attendance → payroll, and administration for a 25-person team in Nepal. Single organization; not a SaaS.

The build follows `docs/prompts/PEACE-TeamPulse-Lite-prompt.md` and, for the Windows agent, `docs/prompts/agent-api-contract.md` and `docs/prompts/prompt-B-windows-agent.md`.

## Status

| Phase | What | State |
|---|---|---|
| **1. Foundation** | Database schema, Row Level Security, roles and MFA enforcement, BS calendar, rules seed, demo data | **Done, tested** (see `docs/phase-1-report.md`) |
| **2. Time (web app)** | Installable web app for desktop and phone: sign-in with two-factor, consent, timer, timesheets with monthly lock, approvals, projects and tasks, people, settings | **Done, tested** (see `docs/phase-2-report.md`) |
| **2b. Self-hosting** | Runs on PEACE's Synology NAS: built-in sign-in (no outside service), Docker image, compose stack with backups and Cloudflare Tunnel | **Done, tested** (see `docs/nas-guide.md`) |
| 3. Agent | Windows agent: enrollment, policy, tray, screenshots, collectors, offline sync, plus the server endpoints it talks to | Next |
| 4. Leave and holidays | Requests, approvals, government-list import, company holiday policy, accrual job | Database rules done in Phase 1 |
| 5. Payroll | Calculation engine, payslips, SSF / TDS / bank exports, loan deductions, pay package screens, parallel run | Database guards, loans and pay scheme done in Phase 1 |
| 6. Admin | Records, documents, checklists, compliance calendar, assets, announcements | Tables done in Phase 1 |
| 7. Reports | Dashboards, email reports, retention jobs | |
| 8. Pilot | 3 consenting employees, then all 25 | |

## Layout

```
packages/bs-calendar/   Bikram Sambat calendar (TypeScript), shared by web, jobs and SQL seed
db/migrations/          Schema and Row Level Security (applied in filename order by db/manage.mjs)
db/seed/                Reference data for every environment: BS calendar, leave/SSF/tax rules, checklists, compliance tasks
db/demo/                Labelled demo data for trials, plus one-command removal
db/tests/               SQL tests that sign in as each role and exercise the real policies
db/manage.mjs           Database manager: migrate, create-admin, reset-link, reset-mfa, status
Dockerfile, docker-compose.yml   The NAS installation (see docs/nas-guide.md)
docs/                   Build prompts, accountant's checklist, monitoring notice template (EN + NE), phase reports
web/                    Next.js 16 web app — installable on desktop, Android and iPhone (PWA)
scripts/                End-to-end browser tests, notice-template generator
agent/                  Windows agent, C#/.NET 8 (Phase 3)
```

## The web app

`web/` is a Next.js 16 app you install from the browser on Windows, macOS, Android and iPhone. See `docs/install-guide.md` for staff, and `docs/nas-guide.md` to run it on the office Synology NAS.

- **Every query runs as the signed-in person.** The server connects with its own restricted login (`teampulse_app`) and, for each request, opens a transaction as the Postgres role `authenticated` carrying that person's id and sign-in level. The Row Level Security policies, and their tests, therefore decide what each person sees.
- **Sign-in is built in:** email and password (bcrypt, lockout after 5 failures), plus an authenticator app (TOTP) for HR and admin, whose secrets are encrypted with `ENCRYPTION_KEY`. Sessions are random cookies stored only as hashes. New employees get a single-use invitation link, emailed over SMTP or handed over by the admin.
- **Privacy on devices:** the service worker caches only icons and build files, never pages or data. Nothing personal is stored on a phone or laptop.

Run it locally against a database built from the migrations and demo data:

```bash
TP_TEST_DB=tp_web_dev bash db/tests/run.sh --no-tests
psql -d tp_web_dev -f db/demo/demo_load.sql
cat > web/.env.local <<ENV
DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:5432/tp_web_dev
ENCRYPTION_KEY=$(openssl rand -base64 32)
APP_BASE_URL=http://localhost:3000
ENV
cd web && npx next dev          # open http://localhost:3000 — any demo email, password demo-password-CHANGE-ME
```

Demo emails: `demo.admin@demo.invalid`, `demo.hr@demo.invalid`, `demo.employee01@demo.invalid` … `demo.employee25@demo.invalid` (01 and 02 are managers). HR and admin are asked to set up an authenticator app on first sign-in.

## Run the tests

Requires Node 22.18+ and a local PostgreSQL 15+ you can reach as a superuser.

```bash
npm install
npm test                 # calendar + full SQL suite + web logic, on throw-away databases
bash scripts/e2e.sh      # real browser (bundled Chromium): sign-in with two-factor, invitations, consent, timer, approvals, phone layout, installability
# or separately:
npm run test:calendar
PSQL="psql -h localhost -U postgres" npm run test:db
```

On GitHub, the **Image** workflow also builds the Docker image, starts the whole `docker-compose.yml` stack, runs the browser tests against the containers, and publishes the image to `ghcr.io/sachitss/teampulse`.

The SQL suite rebuilds a database from scratch every run, on plain PostgreSQL. Migration 0000 creates what the schema needs (`auth.uid()`, `auth.jwt()`, the roles), so each test can sign in as an employee, manager, HR or admin, with or without MFA, and check what they can really see and change.

## Access model (enforced in the database, not only in the UI)

| Data | Employee | Manager | HR / Accounts | Admin |
|---|---|---|---|---|
| Own time, tasks, leave | ✓ | — | — | — |
| Team's time, tasks, leave | — | direct reports | all | all |
| Screenshots, apps, websites, activity counts | own | direct reports | **no** | all |
| Salary, payroll lines, bank details | own (published only) | **no** | all | all |
| Personal record and documents | own | — | all | all |
| Audit log | — | — | — | read only |

- **HR and admin rights need MFA.** The policies check the session's `aal2` level, which is set only after a correct authenticator code. An admin who signs in without MFA gets employee rights only.
- **Evidence and files go through the server.** The agent never writes to the database directly. The server checks the device token and writes it. Files (from Phase 3) are stored in the NAS `files` folder, outside the web root, and open only through the server after `app.screenshot_key_for_view()` / `app.payslip_key_for_view()` / `app.document_key_for_view()`, which also log every view and every denied attempt.
- **No monitoring without notice and consent.** The database refuses activity evidence until an admin has confirmed the notice was issued **and** that employee has consented to the latest notice version. A new notice version requires fresh consent.

## Integrity rules built into the database

- One running timer per person. No overlapping time. Manual time needs a reason and the manager's approval. Nobody approves their own time, leave or corrections.
- A locked timesheet month freezes its time entries. Only an admin can unlock it, and the unlock is audited.
- Sick, mourning and maternity leave cannot be rejected by a manager (Labour Act 2074 s.51). HR can reject them only with a recorded override reason.
- Leave balances are the sum of an append-only ledger. They are never edited directly.
- Payroll refuses to start if any rule or tax band is missing for the fiscal year. Approval is admin-only and freezes a snapshot of the exact rules used. Approved runs, their lines, and the salary versions they used can no longer change.
- Money is integer paisa. Every BS date is filled from the calendar table by trigger, so it can never disagree with its AD date.
- **Loans:** an admin approves (never their own). Repayment schedules are exact to the paisa (no interest, flat, or reducing balance). Payroll approval refuses loan deductions that don't match the schedule or exceed the policy cap, then posts the repayment. The balance comes from an append-only ledger.
- **Pay scheme:** pay grades with ranges and standard allowances, non-cash benefits, and a package overview per person (monthly pay, SSF, festival allowance, benefits, annual cost to company). Employees see their own; managers see none.
- **Holidays follow the company's policy, not the government list directly.** The government list is a reference; the company observes, skips or moves each holiday, and adds company-only and optional days. Only an admin-approved policy that meets the legal minimum (counted separately for women) gives days off.
- The audit log is append-only for everyone, including the database owner. Encrypted fields and personal contact details are noted by name only, never by value.

## Installing at PEACE

Follow `docs/nas-guide.md`: Synology Container Manager, Cloudflare Tunnel, nightly backups plus Hyper Backup off-site, and `node db/manage.mjs create-admin` for the first admin. **Never load demo data in a real installation**. `manage.mjs load-demo` refuses once real employees exist.

## The Nepali calendar

`packages/bs-calendar` converts BS ↔ AD from a year-by-year table of month lengths, never a formula.

- **2000–2083 are verified**: two independent open-source tables agree on every day, and the official calendar has been published.
- **2084 onward is provisional.** The libraries disagree, so the table uses the projection that matches two public 2084 calendars. Every result in a provisional year is flagged. Payroll runs for Baisakh–Asar 2084 carry `calendar_provisional = true`.
- When the official 2084 calendar is out, put its month lengths into `OFFICIAL_OVERRIDES` in `scripts/generate-data.mjs` and run `npm run generate && npm run calendar:sql`. HR can also correct the `bs_calendar_months` table directly.
