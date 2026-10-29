# Phase 1 report — Foundation (29 Oct 2026)

## Completed and tested end to end

**Database (6 migrations, 58 tables, 120 access policies)**

The schema covers all five modules: time and agent evidence, leave and holidays, payroll, administration, and reporting. Row Level Security is enabled on every table, with policies for each of the four roles.

**MFA enforced in the database**

HR and admin rights apply only in sessions with MFA (`aal2`). Without MFA, those accounts get employee rights.

**Integrity rules**

These are enforced by database constraints and triggers, so the web app and agent cannot bypass them:

- one running timer per person, and no overlapping time
- locked months freeze their time entries
- statutory leave cannot be rejected by a manager
- leave balances come from an append-only ledger
- payroll refuses to start when a rule or tax band is missing
- an approved payroll run is locked and keeps a snapshot of the rules it used
- the audit log is append-only and redacts encrypted fields and personal contact details

**Consent gate**

No activity evidence can be stored until two things are true:

- an admin has confirmed the monitoring notice was issued
- the employee has consented to the latest notice version

**Bikram Sambat calendar (`packages/bs-calendar`)**

- BS ↔ AD conversion, fiscal years, payroll months and Kathmandu day boundaries (UTC+05:45).
- Checked day by day against two independent libraries for BS 2000–2083.
- Correct whatever time zone the server uses: tested under five, including UTC+14 and UTC−11.
- The SQL calendar table is generated from the same data, and a test confirms it regenerates identically.

**Seeds**

- Leave rules from the Labour Act 2074.
- SSF 11% / 20%.
- Full FY 2083/84 tax table (5 bands), plus FY 2082/83.
- Onboarding and offboarding checklists, the SSF/TDS compliance calendar, report schedules, and the initial monitoring policy.
- Every legal value is flagged `to_confirm`.

**Demo data**

25 demo employees (2 managers), 1 admin and 1 HR, all labelled, with `@demo.invalid` emails and example holidays. One script removes all of it.

**Docs**

- Accountant's checklist.
- Monitoring and HR data notice in English, with a Nepali draft.
- README, `.env.example`.

## Test results

| Suite | Result |
|---|---|
| BS calendar (14 tests; 30,681 verified days checked against two libraries, 2,557 provisional days against one) | **pass** |
| SQL: RLS coverage, visibility by role and MFA, time rules, leave rules, payroll guards, consent gate, SQL calendar, audit (8 files, 155 assertions) | **pass** |
| Demo data load → remove round trip | **pass** |
| Mutation check: deliberately letting HR see screenshots, or managers see salaries | **caught by the tests** |

## Not done yet / stubbed

- **No user interface or API yet.** That is Phase 2.
- **Not yet applied to a hosted Supabase project.** It was tested on PostgreSQL 16 with a shim that imitates Supabase's auth and storage. Applying it to a staging project is the first step of Phase 2.
- **Encryption of PAN, bank account and SSF numbers** is designed (app-side AES-256-GCM) but not coded. The columns exist and are already audit-redacted.
- **Leave accrual, attendance summaries and the payroll calculation** are Phases 4–5. The database rules they depend on are already in place.

## Decisions to know about

1. **BS 2084 is provisional.** The two reference libraries disagree on 2084–2086. The official 2084 calendar did not appear to be published as of late September 2026, so the table uses the projection that matches two public 2084 calendars. Baisakh–Asar 2084 fall inside FY 2083/84 and are flagged in payroll.
2. **FY 2083/84 begins 17 July 2026 (1 Shrawan 2083).** Both libraries confirm this; one law-firm guide said 16 July, which is wrong.
3. **The full FY 2083/84 tax table was seeded:** 1% / 10% / 20% / 27% / 29% at 10, 15, 25 and 40 lakh. Two independent sources agreed, and one cites the IRD rate sheet. It is still `to_confirm`.
4. **Denied views are logged.** Denied screenshot, payslip and document views return no key instead of raising an error, so the denial stays in the audit log.
5. **Overtime rate and hour limits are unverified.** The seeds are 1.5×, 8 hours per day and 48 hours per week; the accountant must confirm them.

## Next: Phase 2 — Time (web app)

1. Apply the migrations and seeds to a Supabase staging project, enable MFA, and re-run the RLS tests there.
2. Next.js app with sign-in, a forced MFA set-up for HR and admin, and the consent screen.
3. People and teams admin, projects and tasks.
4. Web timer (start / break / resume / stop / switch task), idle resolution and manual entries with approval.
5. Timesheets by BS month: submit → approve → lock.
6. Agent endpoints (`/agent/v1/enroll`, `/token/refresh`, `/policy`, `/sessions`, `/heartbeat`, `/events`, `/screenshots`) so Phase 3 can start against a real backend.

---

## Addendum — 29 Oct 2026: loans, pay scheme, company holiday policy

Added at PEACE's request, as migrations 0007–0009, with three new test files. The database is now **9 migrations, 70 tables, 146 access policies**. The test suite is **11 SQL files with 228 assertions, plus the demo round trip**, and everything passes.

**Employee loans and salary advances**

- Three loan types (salary advance, personal, emergency), each with a cap and an instalment limit.
- A company loan policy: deduction cap 50% of gross, 1 active loan, 6 months' service, no loans during probation, recovery at exit.
- Only an admin approves.
- Schedules are exact to the paisa, with no interest, flat or reducing-balance interest.
- HR can defer an instalment or record a manual repayment.
- Payroll approval checks each loan deduction and posts it to an append-only ledger. A loan closes automatically at zero.
- Loans are never visible to managers.

**Pay scheme and package overview**

- Versioned pay grades with salary ranges, annual increments and standard allowances.
- Non-cash benefits.
- A per-employee package view: monthly gross, SSF both sides, festival allowance, benefits, annual cash pay, annual cost to company, and position in the grade range. It warns when payroll rules are missing or unconfirmed.
- A grade-level overview.

**Company holiday policy**

- The government's gazetted list is now a reference only.
- For each government holiday, PEACE decides to observe it, skip it, or move it to another date.
- PEACE can add company-only holidays and optional (floating) holidays with a yearly quota.
- An admin approves one policy per fiscal year. Approval is refused while any government holiday is undecided, or if the policy falls below the legal minimum (seed: 13 days, plus 1 for women). Once approved, the year's calendar is frozen.
- **Only holidays in an approved policy count as days off.**

New items for the accountant are in `accountant-checklist.md` §7–9. These include whether an interest-free employee loan is a taxable benefit, and which benefits are taxable.
