# TeamPulse Lite + HR — PEACE Consultancy

Time and activity tracking, leave and holidays, attendance → payroll, and administration for a 25-person team in Nepal. Single organization; not a SaaS.

The build follows `docs/prompts/PEACE-TeamPulse-Lite-prompt.md` and, for the Windows agent, `docs/prompts/agent-api-contract.md` and `docs/prompts/prompt-B-windows-agent.md`.

## Status

| Phase | What | State |
|---|---|---|
| **1. Foundation** | Database schema, Row Level Security, roles and MFA enforcement, BS calendar, rules seed, demo data | **Done, tested** (see `docs/phase-1-report.md`) |
| 2. Time | Web app: sign-in, people, projects, tasks, timers, timesheets with monthly lock | Next |
| 3. Agent | Windows agent: enrollment, policy, tray, screenshots, collectors, offline sync | |
| 4. Leave and holidays | Requests, approvals, government-list import, company holiday policy, accrual job | Database rules done in Phase 1 |
| 5. Payroll | Calculation engine, payslips, SSF / TDS / bank exports, loan deductions, pay package screens, parallel run | Database guards, loans and pay scheme done in Phase 1 |
| 6. Admin | Records, documents, checklists, compliance calendar, assets, announcements | Tables done in Phase 1 |
| 7. Reports | Dashboards, email reports, retention jobs | |
| 8. Pilot | 3 consenting employees, then all 25 | |

## Layout

```
packages/bs-calendar/   Bikram Sambat calendar (TypeScript), shared by web, jobs and SQL seed
supabase/migrations/    Schema and Row Level Security (apply in filename order)
supabase/seed/          Reference data for every environment: BS calendar, leave/SSF/tax rules, checklists, compliance tasks
supabase/demo/          Labelled demo data for dev/staging, plus one-command removal
supabase/tests/         SQL tests that sign in as each role and exercise the real policies
docs/                   Build prompts, accountant's checklist, monitoring notice template (EN + NE), phase reports
web/                    Next.js app (Phase 2)
agent/                  Windows agent, C#/.NET 8 (Phase 3)
```

## Run the tests

Requires Node 22.18+ and a local PostgreSQL 15+ you can reach as a superuser.

```bash
npm install
npm test                 # calendar tests + full SQL suite on a throw-away database
# or separately:
npm run test:calendar
PSQL="psql -h localhost -U postgres" npm run test:db
```

The SQL suite rebuilds a database from scratch every run. It uses a small shim (`supabase/tests/supabase_shim.sql`) that imitates the parts of Supabase the schema depends on: `auth.uid()`, `auth.jwt()`, the `authenticated` / `anon` / `service_role` roles, and storage tables. That lets each test sign in as an employee, manager, HR or admin, with or without MFA, and check what they can really see and change.

## Access model (enforced in the database, not only in the UI)

| Data | Employee | Manager | HR / Accounts | Admin |
|---|---|---|---|---|
| Own time, tasks, leave | ✓ | — | — | — |
| Team's time, tasks, leave | — | direct reports | all | all |
| Screenshots, apps, websites, activity counts | own | direct reports | **no** | all |
| Salary, payroll lines, bank details | own (published only) | **no** | all | all |
| Personal record and documents | own | — | all | all |
| Audit log | — | — | — | read only |

- **HR and admin rights need MFA.** The policies check the Supabase session's `aal2` claim. An admin who signs in without MFA gets employee rights only.
- **Evidence and files go through the server.** The agent never writes to the database directly. The server checks the device token and writes with the service role. Storage buckets are private with no user policies. Files open only through short-lived signed links, minted after `app.screenshot_key_for_view()` / `app.payslip_key_for_view()` / `app.document_key_for_view()`, which also log every view and every denied attempt.
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

## Deploying Phase 1 to Supabase

> Tested on PostgreSQL 16 with the shim above. **It has not yet been applied to a hosted Supabase project.** Do that on a staging project first.

1. Create a Supabase project in an Asian region close to Nepal.
2. **Authentication → enable MFA (TOTP).** Require it for every HR and admin account.
3. Apply the schema: `supabase link --project-ref <ref>` then `supabase db push`, or run each file in `supabase/migrations/` in order in the SQL editor.
4. Load reference data: run `supabase/seed/00_bs_calendar.sql` and `supabase/seed/01_reference_rules.sql`.
5. Staging only: `supabase/demo/demo_load.sql`. To remove it: `supabase/demo/demo_remove.sql`. **Never load demo data in production.**
6. Copy `.env.example` to `.env.local` for the web app (Phase 2).

## The Nepali calendar

`packages/bs-calendar` converts BS ↔ AD from a year-by-year table of month lengths, never a formula.

- **2000–2083 are verified**: two independent open-source tables agree on every day, and the official calendar has been published.
- **2084 onward is provisional.** The libraries disagree, so the table uses the projection that matches two public 2084 calendars. Every result in a provisional year is flagged. Payroll runs for Baisakh–Asar 2084 carry `calendar_provisional = true`.
- When the official 2084 calendar is out, put its month lengths into `OFFICIAL_OVERRIDES` in `scripts/generate-data.mjs` and run `npm run generate && npm run calendar:sql`. HR can also correct the `bs_calendar_months` table directly.
